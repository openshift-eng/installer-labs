# Running the pilot

This walks through a complete `create cluster` and `destroy cluster` on `platform: external`
driven by a Cluster API provider, using AWS and CAPA as the reference. A partner substitutes
their own cloud, provider and manifests at the marked points.

The runnable version of every step is in
[../examples/aws-capa/](../examples/aws-capa/). Read
[limitations.md](limitations.md) first.

## Prerequisites

| Need | Notes |
| --- | --- |
| An installer build with this work | branch `pilot-platform-external-capi`; a `MODE=dev` build is assumed below |
| A CAPI infrastructure provider **binary** | for the reference path, CAPA |
| The provider's **CRDs and components** | one YAML file or a directory |
| Cloud credentials | for the reference path, an AWS credentials file |
| A pull secret | kept **outside** the install directory — see "Handling secrets" |
| `jq` | the sample scripts use it to resolve the RHCOS image |

### Getting the reference provider artifacts

The installer can extract the CAPA artifacts it already ships, which is the simplest way to
get a known-good binary and component set:

```sh
./openshift-install extract cluster-api aws --dest-dir=/tmp/capa-artifacts
```

This yields `cluster-api-provider-aws` and `aws-infrastructure-components.yaml`. A partner
builds their own provider's equivalents.

## 1. Point the install-config at the provider

```yaml
platform:
  external:
    platformName: aws                  # your cloud
    cloudControllerManager: External   # you supply the CCM; see step 3
    clusterAPI:
      name: aws
      binaryPath: /tmp/capa-artifacts/cluster-api-provider-aws
      componentsPath: /tmp/capa-artifacts/aws-infrastructure-components.yaml
      args:
      - --feature-gates=BootstrapFormatIgnition=true,...
      hooks:
        infraReady:
          program: hooks/infra-hook.sh
        postProvision:
          program: hooks/infra-hook.sh
          args:
          - --input-service=openshift-ingress/router-external-default
          - --input-dns-zone=<your hosted zone id>
        preDestroy:
          program: hooks/infra-hook.sh
```

`args` are **appended** to the four arguments the installer supplies to every provider
(`pkg/clusterapi/external.go:153-159`). Anything provider-specific goes here.

For CAPA specifically, `BootstrapFormatIgnition=true` is **not optional**. Without it CAPA's
validating webhook rejects the `AWSCluster` outright —
`spec.s3Bucket: Forbidden: can be set only if the BootstrapFormatIgnition feature gate is
enabled` — and the same gate is what makes `AWSMachine.spec.ignition` legal.

See [hooks.md](hooks.md) for the hook contract.

## 2. Write the CAPI manifests

Under `external-install/`, per [manifest-contract.md](manifest-contract.md):

- `cluster.yaml` — the `Cluster` and your infrastructure CR
- `machines/` — `Machine` + infrastructure `Machine` objects for bootstrap, masters and any
  day-0 workers

## 3. Write the day-0 extra manifests

Under `external-install/extra-manifests/`, **one object per file**. At minimum you need a
**cloud controller manager**, because nothing else removes the
`node.cloudprovider.kubernetes.io/uninitialized` taint and bootstrap will otherwise time out
with a healthy API server and three registered masters that cannot schedule anything.

The reference set is:

| File | Why |
| --- | --- |
| `99_external-00-kubelet-providerid-master.yaml` | `MachineConfig` giving the master kubelet its `providerID` |
| `99_external-00-kubelet-providerid-worker.yaml` | the same for workers — **a separate file, not a second document** |
| `99_external-01-ccm-credentials.yaml` | the CCM's cloud credentials |
| `99_external-02-ccm-aws.yaml` | the CCM itself |
| `99_external-03-ingress-nlb.yaml` | the ingress `Service` whose load balancer `postProvision` waits for |

A node without a `providerID` is deleted by the CCM as an instance it cannot find. Both pools
need one, in separate files.

## 4. Run it, in two phases

The install is **two commands, not one**, and the reason is ordering rather than preference:

`Machine.spec.bootstrap.dataSecretName` must be `<infraID>-bootstrap`, the installer picks
that name itself, and **the infrastructure ID does not exist until asset resolution has
run.** So:

```sh
# phase one: generate assets, which fixes the infrastructure ID
./openshift-install create manifests --dir=<install-dir>

# read the ID back out of a generated, non-secret file
INFRA_ID=$(grep -oE '^  infrastructureName: .*' \
  <install-dir>/manifests/cluster-infrastructure-02-config.yml | awk '{print $2}')

# substitute it through the CAPI tree
sed -i "s/<placeholder>/${INFRA_ID}/g" <install-dir>/external-install/cluster.yaml
sed -i "s/<placeholder>/${INFRA_ID}/g" <install-dir>/external-install/machines/*.yaml

# phase two
./openshift-install create cluster --dir=<install-dir>
```

Editing between the two commands is safe **because `external-install/` is not an asset load
path**. That is the whole reason it is a separate directory.

**Assert that every substitution landed.** A no-op `sed` is indistinguishable from a
successful one, and an unsubstituted placeholder reaches the cloud as a literal — noticed
only once resources exist. The sample scripts fail hard on any surviving placeholder.

### The RHCOS image

`pkg/asset/rhcos/image.go` returns `""` for `platform: external`, so the machine image must
come from somewhere else. The same source the CI jobs use:

```sh
OPENSHIFT_INSTALL_DATA=<path-to-clone>/data/data ./openshift-install coreos print-stream-json |
  jq -r '.architectures.x86_64.images.aws.regions["us-east-1"].image'
```

**Two traps in that one command, and both answer with something rather than failing
obviously.**

A `MODE=dev` build does not embed its data assets; `data/assets.go:16-22` reads them from
`$OPENSHIFT_INSTALL_DATA`, defaulting to the **relative** path `data`. So unless you happen to
be standing in the clone root, the command fails:

```console
$ ./openshift-install coreos print-stream-json
FATAL ... failed to read embedded CoreOS stream metadata:
      open data/coreos/coreos-rhel-10.json: no such file or directory
```

Point the variable at `<clone>/data/data` — note the doubled component; the stream files are
at `data/data/coreos/coreos-rhel-10.json`. A release build embeds them and needs none of this.

And run **`./openshift-install`**, not `openshift-install`. A stale binary earlier on `$PATH`
will answer the question happily, for a different release, and nothing in the output says so.
That one is worse than the FATAL above, because it succeeds.

### Infrastructure only

`OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY=true` stops after the `infraReady` hook and before any
Ignition Secret or machine is created. Useful for iterating on the provider and the hook
without paying for machines.

## 5. Approve the worker CSRs

**This step is manual and currently unavoidable.** See
[limitations.md](limitations.md#worker-admission-is-not-automatic).

```sh
oc get csr -o name | xargs oc adm certificate approve
```

Run it twice — once for the client CSR, once for the serving CSR that follows.

## 6. Tear it down

```sh
./openshift-install destroy cluster --dir=<install-dir>
```

Destroy needs three things the install left behind, and nothing else:

- `<install-dir>/metadata.json`, which records the provider artifact paths
- `<install-dir>/.clusterapi_output/*.yaml`, the objects with their resource IDs
- the provider artifacts themselves, still at the paths `metadata.json` names

**Verify afterwards.** A `preDestroy` hook that exits 0 has not necessarily removed anything
— see [hooks.md](hooks.md#hazard-a-hook-that-exits-0-is-not-a-hook-that-worked). Check at
minimum: DNS records in the public zone, instances, VPCs, load balancers, target groups,
private hosted zones, orphaned volumes and the bootstrap bucket.

## Handling secrets

The pilot's scripts are built around one rule: **the files a human or an agent edits never
contain a credential.**

- The install-config **template** carries `pullSecret: ""` and `sshKey: ""`. The real values
  live outside the working tree.
- The pull secret is injected into the **per-run copy** by a command that writes nothing to
  stdout, and is passed **by path, never interpolated into a command line** — so `set -x`
  cannot trace it either.
- Cloud credentials are referenced by `AWS_SHARED_CREDENTIALS_FILE`. The variable name and
  the path are not secrets; the file's contents are.

This is not a hypothetical precaution. A range `sed` over the template — intended to print
the `compute` stanza — printed the pull secret, because `pullSecret` happens to sit between
`compute:` and `networking:`. **No reading discipline survives an assumption about key
order; keeping the value out of the file does.**

## A known-good run, for comparison

| Stage | Observed |
| --- | --- |
| `postProvision` hook | 9m40s and 14m38s across two runs — budget 20 minutes |
| Cluster operators | 34 / 34 Available, 0 Degraded |
| `destroy cluster` | 5m23s and 6m8s, exit 0, `Uninstallation complete!` |
| Post-destroy census | zero records, instances, VPCs, load balancers, target groups, private zones, volumes, buckets |
