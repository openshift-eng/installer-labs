# The manifest contract

Everything the partner supplies lives under one directory in the install directory:

```
<install-dir>/
  install-config.yaml
  external-install/            <- pkg/types/external/doc.go:23  ManifestDir
    cluster.yaml                  the Cluster and the infrastructure CR
    machines/                  <- doc.go:28   MachineManifestDir
    extra-manifests/           <- doc.go:63   ExtraManifestDir
    hooks/                        the programs the installer execs
    hook-state/                <- doc.go:75   HookStateDir, written by hooks
```

Citations are against `openshift/installer` at commit `6e028d5597`.

## Why `external-install/` and not `cluster-api/`

The installer has a `cluster-api/` directory already, and it is the wrong place
(`pkg/types/external/doc.go:14-20`):

- It is an **asset load path**. The asset store discards assets whose dependencies are dirty,
  so files placed there alongside an unconsumed `install-config.yaml` are silently thrown
  away.
- It is also where the installer **unpacks the Cluster API and envtest binaries** at
  provisioning time. It is scratch space, not a user interface.

`external-install/` is read during asset generation, not instead of it. That difference is
what lets a single `create cluster` work at all.

> The directory name is **provisional** (`doc.go:22`) and may change before this lands.

## `cluster.yaml` — the Cluster and the infrastructure CR

The partner's `Cluster` object and whatever infrastructure resource their provider
reconciles. The installer applies these to its local control plane and then waits for
`Cluster.status.infrastructureReady`.

The installer does **not** know the infrastructure CR's type. It is handled as an
unstructured object, resolved against the CRDs the partner's `componentsPath` installed.

## `machines/` — the Machine objects

Separated from `cluster.yaml` because the installer creates them in a **second stage**, after
the infrastructure reports ready (`doc.go:25-28`).

Three things a partner must get right, all documented in detail with worked examples in
[../examples/aws-capa/external-install/machines/README.md](../examples/aws-capa/external-install/machines/README.md):

1. **`Machine.spec.bootstrap.dataSecretName` must be `<infraID>-bootstrap`,
   `<infraID>-master` or `<infraID>-worker`.** The installer picks those names itself and
   publishes the Ignition configs under them.
2. **The whole tree is named by infrastructure ID, not cluster name.** Resource tags, load
   balancer names and subnet names must all agree with what the installed cluster calls
   itself.
3. **The infrastructure ID does not exist until asset resolution has run.** This is why the
   sample runs `create manifests` first, reads the ID out of the generated
   `cluster-infrastructure-02-config.yml`, substitutes it into `external-install/`, and only
   then runs `create cluster`. Editing between the two commands is safe precisely because
   `external-install/` is not an asset load path.

### Day-0 workers are possible, and they are waited for

The pre-bootstrap machine wait has **no control-plane filter** — every machine the installer
created is in it, workers included. Verified from a run:

```
Waiting up to 15m0s ... for machines [<infraID>-bootstrap <infraID>-master-0 <infraID>-master-1
  <infraID>-master-2 <infraID>-worker-0 <infraID>-worker-1] to provision...
```

Two consequences, and the second is a hazard:

- Workers really are created on day 0, so the install is not capped at a compact three-node
  cluster by the installer.
- **A worker that fails to provision fails the whole install.** On an integrated platform a
  failed worker is a degraded MachineSet; here it is a failed `create cluster`.

Booting a worker is not the same as getting one admitted — see
[limitations.md](limitations.md#worker-admission-is-not-automatic).

## `extra-manifests/` — day-0 cluster objects

Files here are **added to** the generated `openshift/` manifest directory, so bootkube moves
them in with the rest and `cluster-bootstrap` applies them to the bootstrap control plane
before it waits for the cluster to come up
(`data/data/bootstrap/files/usr/local/bin/bootkube.sh.template:78`). A `MachineConfig` placed
here is rendered by the bootstrap machine-config server, so it reaches the control-plane
machines on their first boot.

**This is the directory `platform: external` cannot do without.** The installer delivers no
cloud controller manager — `cloudControllerManager.state: External` is a declaration that the
partner supplies one — and until a CCM runs, every node keeps the
`node.cloudprovider.kubernetes.io/uninitialized` taint, no control-plane operator can
schedule, and bootstrap times out (`doc.go:34-41`). So the one thing this platform cannot
finish without is the one thing it has no way to deliver, and this directory is the delivery
mechanism.

The installer does not parse, validate or template anything here beyond the two rules below.
It does not know what a partner's CCM needs, and acquiring an opinion about it is the
coupling this platform exists to avoid (`doc.go:60-62`).

### Rule 1 — one object per file

**A file here must contain exactly one Kubernetes object.** Multi-document YAML — the
ordinary `---`-separated form that every `kubectl apply -f` accepts — is **refused** at
`create manifests` with an error naming the file.

This rule is enforced because of a failure that cost a cluster its worker nodes and reported
nothing. A file held two `MachineConfig`s, one per pool. The installer copied all 8564 bytes
through, as it should, and logged it:

```
Including the external manifest 99_external-00-kubelet-providerid.yaml (8564 bytes) in the openshift manifests
```

The bootstrap node then **applied the first object and dropped the second without a word**.
The worker pool never got its `providerID` drop-in, its kubelet registered a `Node` with no
`providerID`, and the cloud controller manager deleted that Node as an instance it could not
find:

```
node_lifecycle_controller.go:182] deleting node since it is no longer present in cloud provider: ip-10-0-17-179
```

The install reported success. Masters were unaffected because theirs was document one.

The enforcement that loses the object is **on the bootstrap node, not in the installer** —
in a component the installer does not vendor and cannot cite. Every manifest the installer
itself writes into `openshift/` holds exactly one object, which is why the case could not
arise until a user-supplied file did.

So `externalExtraManifests` counts documents and refuses more than one
(`pkg/asset/manifests/openshift.go:388-395`, helper at `:426`). Comment-only and
whitespace-only documents are not counted, so the common shape — a licence header, a `---`,
one object — is still one object. The cost to you is one `csplit`; the cost of not doing it
was a cluster that looked healthy and had no workers.

### Rule 2 — do not collide with a generated filename

A file here sharing a name with a manifest the installer generates is refused
(`openshift.go:378-382`). One would silently overwrite the other, and the loss — a missing
feature gate, a missing kubeadmin password secret — would surface nowhere near its cause.

## `hook-state/` — what a hook created

A directory the installer guarantees exists, is writable, and **survives from
`create cluster` to `destroy cluster`** in the same install directory (`doc.go:65-75`).

It exists because a hook creates resources outside Cluster API's ownership, and nothing else
will ever clean those up: deleting the `Cluster` deletes what the provider built, and a DNS
zone the hook created is not that.

The installer does not read or interpret anything here.
