# Blocker 2 — delivering the bootstrap Ignition on OCI

**Status: designed, not run. 2026-09-30.**

Unlike [the boot image](boot-image.md), this one has an answer that needs no
installer change and no CAPOCI change. It needs a third phase in the run script.

## The size wall

Oracle's *Creating an Instance* documentation states:

> "The total maximum size for user data and other metadata that you provide is
> 32,000 bytes."

CAPOCI base64-encodes the bootstrap data before putting it in `metadata.user_data`
(`cloud/scope/machine.go:353`), and base64 inflates by 4/3. The `metadata` map
also carries whatever `OCIMachine.spec.metadata` holds — at minimum an SSH key.
So the practical payload budget is **roughly 23,900 bytes**.

Against that:

| Config | Approximate size | Fits? |
| --- | --- | --- |
| Master pointer config (`master.ign`) | ~1.7 KiB | yes, easily |
| Worker pointer config (`worker.ign`) | ~1.7 KiB | yes, easily |
| **Bootstrap config (`bootstrap.ign`)** | **hundreds of KiB** | **no** |

The master and worker configs the installer generates are already *pointer*
Ignition — a few hundred bytes of JSON telling the machine to fetch its real
config from `https://api-int.<clusterDomain>:22623/config/<role>`. They are not
the problem.

`bootstrap.ign` is the whole cluster's day-0 content: the release payload
references, the bootstrap systemd units, the kubelet config, the certificates.
It is not compressible into 24 KB and never will be.

## What other platforms do, and why neither applies

**CAPA solves it in the provider.** `AWSCluster.spec.s3Bucket` plus
`AWSMachine.spec.ignition.storageType: ClusterObjectStore` makes CAPA upload the
bootstrap data to S3 itself and place a presigned URL in the instance's user-data
— bounded by `presignedURLDuration: 1h0m0s`, as the
[aws-capa example](../../aws-capa/external-install/cluster.yaml) shows.

**CAPOCI has no equivalent.** There is no object-storage field anywhere in
`api/v1beta2/`, and no `objectstorage` client in `cloud/services/`. The provider
hands whatever it is given straight to the instance.

**The integrated installer platforms solve it in the installer.** GCP, Azure and
IBM Cloud each build a pointer shim inside their own `Ignition()` implementation
and upload the real config to their own object store:

| Platform | Where |
| --- | --- |
| GCP | `pkg/infrastructure/gcp/clusterapi/clusterapi.go:158` |
| Azure | `pkg/infrastructure/azure/azure.go:1119` |
| IBM Cloud | `pkg/infrastructure/ibmcloud/clusterapi/clusterapi.go:464` |

The External provider structurally cannot do this. It has no cloud credentials
and no cloud SDK — that is the entire premise of `platform: external`. Its
`Ignition()` (`pkg/infrastructure/external/clusterapi/ignition.go`) only wraps
the configs it is handed into `<infraID>-{bootstrap,master,worker}` Secrets.

## The answer: replace `bootstrap.ign` between two installer phases

This is the standard UPI pattern, and the installer already supports it — not as
a special case, but because `bootstrap.ign` is a normal loadable asset.

### Why it works

`bootstrap.Bootstrap` is a `WritableAsset` with a `Load()` that reads
`bootstrap.ign` back off disk:

- `pkg/asset/ignition/bootstrap/bootstrap.go:10` —
  `bootstrapIgnFilename = "bootstrap.ign"`
- `pkg/asset/ignition/bootstrap/bootstrap.go:18` —
  `var _ asset.WritableAsset = (*Bootstrap)(nil)`
- `pkg/asset/ignition/bootstrap/bootstrap.go:39-41` — `Load()` reads the file
- `pkg/asset/targets/targets.go:56-64` — it is in the `IgnitionConfigs` target,
  so `create ignition-configs` writes it and a later `create cluster` loads it

So whatever is on disk at `create cluster` time is what ends up in the
`<infraID>-bootstrap` Secret. Overwrite the file and you have overwritten the
bootstrap machine's user-data.

### The workflow

```
1.  openshift-install create manifests
2.  substitute <infraID> and <imageId> into external-install/
3.  openshift-install create ignition-configs
4.  upload bootstrap.ign to OCI Object Storage
5.  create a pre-authenticated request (PAR) over that object
6.  overwrite bootstrap.ign with a pointer config naming the PAR URL
7.  openshift-install create cluster
```

Steps 4–6 are the only new ones relative to the AWS example, which is a two-phase
workflow. They are implemented in
[`scripts/run-create-command.sh`](../scripts/run-create-command.sh).

### The pointer config

```json
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [{ "source": "https://objectstorage.<region>.oraclecloud.com/p/<par>/n/<ns>/b/<bucket>/o/bootstrap.ign" }]
    }
  }
}
```

Roughly 300 bytes, well inside the budget. It is the same shape the installer
generates for masters and workers, differing only in that the source is an
object-store URL rather than the MCS.

**Note:** no `security.tls.certificateAuthorities` entry is needed, because the
OCI Object Storage endpoint has a publicly trusted certificate. The master and
worker pointer configs *do* carry a CA, because the MCS uses the cluster's own.

## Security — say this out loud, do not bury it

**A pre-authenticated request is an unauthenticated HTTPS URL, and
`bootstrap.ign` contains the cluster's day-0 secrets** — including the bootstrap
kubeconfig and the certificates used to bring up the control plane. Anyone who
obtains the URL, from a log, a terminal scrollback or a process listing, has
them.

AWS has the same exposure through the presigned S3 URL; CAPA bounds it with
`presignedURLDuration`. The OCI equivalent must be bounded the same way:

- **Set a short PAR expiry** — one hour is enough for a bootstrap and matches the
  AWS example. The PAR's `timeExpires` is set at creation.
- **Delete the PAR and the object in the `preDestroy` hook.** The expiry is a
  backstop, not the cleanup.
- **Never log the URL.** The workspace rule — log artifact path, source and
  SHA-256, never contents — extends here: the PAR URL *is* the credential, so log
  the object name and the SHA-256 of the file, never the URL.
- **Use a private bucket.** A PAR on a private bucket grants access to exactly
  one object; a public bucket grants it to everything.

An authenticated fetch would be better and is what a productised version should
do. Ignition supports HTTP headers in `config.merge[].httpHeaders`, so an
`Authorization` header carrying a scoped token is possible — but the token then
sits in the pointer config in plain user-data, which is readable from inside the
instance via IMDS. That is a different exposure, not obviously a smaller one. The
short-lived PAR is the honest pilot choice.

## This is not OCI-specific

Any CAPI provider without object-store offload hits this wall. It is worth
deciding whether the three-phase bootstrap-stub workflow should be documented as
**the general External answer** for that whole class of provider, rather than as
an OCI workaround. Recorded as an open question in
[capi-requirements.md](capi-requirements.md).

The alternative — teaching the External provider to offload — requires giving it
cloud credentials, which contradicts the platform's premise. A third option is a
new hook that runs *between* `Ignition()` and Secret creation
(`pkg/infrastructure/clusterapi/clusterapi.go:361` and `:372`), letting a partner
rewrite the bootstrap payload in-process. That would be an installer change, and
the stub workflow makes it unnecessary for now.
