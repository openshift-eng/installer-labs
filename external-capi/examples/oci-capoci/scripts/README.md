# scripts

**Status: executed, through to a complete cluster.** Written 2026-09-30 with no
OCI account available, then corrected over thirteen runs on 2026-10-01. The
warning this paragraph used to carry — *"expect `oci` CLI flag names and JSON
shapes to need correction on first contact"* — was accurate, and the
corrections are in the scripts. A sample of what first contact cost:

| Guessed | Actual |
| --- | --- |
| `oci nlb network-load-balancer update --network-security-group-ids` | `... update-network-security-groups`, and it needs `--force` |
| `oci nlb backend-health list-backend-set-health` | `oci nlb backend-health get` |
| jmespath ``protocol==`6` `` | `protocol=='6'` — the field is a string |

**Run 13 was salvaged by hand**, so these scripts have not yet driven an
unattended install end to end: the CCM and CSI manifests were applied
manually, four CSRs were approved manually, and the ingress Service and its
NSG were created manually. Every one of those has since been written into the
example — but the clean run that would prove it has not been spent.

| Script | What it does |
| --- | --- |
| `capoci-shim.sh` | translates one controller flag the installer sends and CAPOCI does not accept |
| `run-create-command.sh` | the three-phase install driver |
| `run-destroy-command.sh` | teardown, plus an independent check that the bootstrap ignition object is gone |

## `capoci-shim.sh` — the one flag incompatibility

This is the smallest piece here and the most useful finding in the whole
example, because it is what keeps the installer unchanged.

The installer builds every external provider's command line at
`pkg/clusterapi/external.go:153-158`:

```
-v=2  --health-addr=<host:port>  --webhook-port=<n>  --webhook-cert-dir=<path>
```

plus `--kubeconfig`, appended by `runController`, plus whatever
`clusterAPI.args` adds. Each was checked against CAPOCI individually:

| Flag | CAPOCI | Where |
| --- | --- | --- |
| `-v` | yes | `logsV1.AddFlags` → component-base `logs/api/v1/options.go:367` |
| `--webhook-port` | yes | `main.go:128` |
| `--webhook-cert-dir` | yes | `main.go:133` |
| `--kubeconfig` | yes | controller-runtime `pkg/client/config/config.go:56`, merged in at `main.go:178` |
| `--health-addr` | **no** | CAPOCI declares `--health-probe-bind-address` at `main.go:100` |

pflag exits non-zero on an unknown flag, so one mismatch is fatal. The shim
**translates** rather than drops it: the installer polls `/healthz` at exactly
the address it passed (`pkg/clusterapi/system.go:770`), so a dropped flag would
leave CAPOCI listening on its own default `:8081` and the installer waiting on
a port nobody serves.

### A wrapper script is a legal `binaryPath` on purpose

`clusterAPI.binaryPath` goes through `validateHostArch`, which says so in as
many words (`pkg/clusterapi/artifacts.go:195-200`):

> Files that are not ELF at all -- Mach-O on darwin, or a `#!/bin/sh` wrapper
> -- are accepted without a check rather than rejected, so that the override
> stays usable on developer workstations.

That sentence is why this example needs no installer change.

### It is a workaround, and the generic fix belongs in the installer

The installer already hardcodes `--health-probe-bind-address` for some
integrated providers (`pkg/clusterapi/system.go:381,407`), so this is a known
class of divergence that simply has no generic handling. A per-provider flag
mapping, or letting `clusterAPI.args` override a default, would remove the need
for a shim. Raised as an open question in `../docs/capi-requirements.md`.

### Using it

```sh
export CAPOCI_BINARY=/path/to/cluster-api-provider-oci
# or just drop the binary next to the shim under the same directory
```

Tested against a fake binary across six cases — `--flag=value` (what the
installer actually sends), `--flag value`, no health flag, no arguments, an
argument containing spaces, and a dangling `--health-addr` with no value. Order
and quoting are preserved; the dangling case exits 1. That is the only thing in
this directory that has been run at all.

## `run-create-command.sh` — why three phases

AWS needs two: `create manifests`, substitute the infrastructure ID, `create
cluster`. CAPA uploads the oversized bootstrap ignition to S3 itself.

CAPOCI cannot. It has no object-store offload — no object-storage field in
`api/v1beta2/`, no `objectstorage` client under `cloud/services/` — and OCI
caps all instance metadata at 32,000 bytes, roughly 23,900 raw after base64
inflation. The bootstrap ignition is hundreds of KiB.

So a phase is inserted between `create ignition-configs` and `create cluster`:
upload `bootstrap.ign`, mint a pre-authenticated request, and overwrite the
file with a ~300-byte pointer config. The installer reloads it, because
`bootstrap.Bootstrap` implements `Load()`
(`pkg/asset/ignition/bootstrap/bootstrap.go:39-41`) and sits in the
IgnitionConfigs target (`pkg/asset/targets/targets.go:56-64`).

This is the standard UPI pattern and it needs no installer code. Whether it
should *stay* outside the installer is an open design question — it is likely
the general answer for any non-integrated provider whose cloud has a metadata
size limit, which is most of them. See `../docs/ignition-delivery.md`.

### The pre-authenticated request is a credential

Its URL grants unauthenticated read over everything in `bootstrap.ign`:
certificates, keys, the kubeconfig. The script treats it accordingly —
`set +x` around every command that touches it, two-hour expiry, never written
to any file, and the state file records the PAR's **ID**, which is an
identifier, not its URL, which is the credential. `run-destroy-command.sh`
re-checks that the object is gone and fails loudly if it is not.

## Environment

| Variable | Default | Notes |
| --- | --- | --- |
| `OCI_COMPARTMENT_ID` | — | target compartment OCID |
| `OCI_REGION` | — | e.g. `us-ashburn-1` |
| `BASE_DOMAIN` | — | the DNS zone |
| `OCI_IMAGE_ID` | — | the imported RHCOS custom image OCID. **No RHCOS artifact for OCI is published**; the pilot imports the OpenStack QCOW2 and boots it with `ignition.platform.id=openstack`. That is a workaround with a visible cost — see below and `../docs/boot-image.md` |
| `OCI_IGNITION_BUCKET` | — | private bucket, created once, reused |
| `OCI_CREDENTIALS_FILE` | — | the `OCIClusterIdentity` Secret manifest, outside this workspace |
| `PULL_SECRET_FILE` | `~/.oci/pull-secret.json` | passed by path, never read into a variable |
| `CAPOCI_ARTIFACTS` | `/tmp/capoci-artifacts` | shim, binary and components |
| `RELEASE_IMAGE` | a 5.1.0-ec.1 pullspec | |

`PULL_SECRET_FILE` and `OCI_CREDENTIALS_FILE` are handled by path throughout.
No command interpolates either value into a command line, so the `set -x` in
these scripts cannot trace them. That is deliberate and structural rather than
a matter of discipline: on the AWS pilot a range `sed` over the install-config
template, written to print the compute stanza, printed the pull secret instead,
because the pull secret happened to sit between the two keys bounding the
range. Keeping the value out of the file is what fixed it.

## Producing the artifacts

```sh
cd cluster-api-provider-oci
make manager                      # -> bin/manager
make release-manifests            # -> out/infrastructure-components.yaml

mkdir -p /tmp/capoci-artifacts
cp bin/manager /tmp/capoci-artifacts/cluster-api-provider-oci
cp out/infrastructure-components.yaml /tmp/capoci-artifacts/oci-infrastructure-components.yaml
cp .../oci-capoci/scripts/capoci-shim.sh /tmp/capoci-artifacts/
```

Local extraction is the pilot approach, matching what aws-capa did. Pulling the
provider from a release image is the eventual answer and is out of scope here.

CAPOCI pins `sigs.k8s.io/cluster-api v1.12.3` (`go.mod:25`) against the
installer's `v1.13.4` (`go.mod:126`). This was carried as "probably fine but
unverified". **It is now verified by use**: thirteen runs, machines
reconciled, `Cluster.Status.InfrastructureReady` observed by the installer.
One version of skew in the core CAPI API is tolerated in practice. That is
evidence, not a guarantee — nothing checks the skew and nothing would warn
about a wider one.

## Before publishing this example

These scripts are the pilot's working copy and carry its fingerprints. Each of
these is cosmetic, none affects behaviour, and all of them should go before a
partner reads this:

- `run-create-command.sh:68` builds the cluster name as `mrb-oci${N}`. A
  partner needs `CLUSTER_NAME` as an input, not a hardcoded prefix and a
  version counter.
- `BASE_DOMAIN` is documented, but the install-config template and several
  examples still show `splat.devcluster.openshift.com`.
- The default `RELEASE_IMAGE` pins `5.1.0-ec.1`.

The scripts are also written for a workspace where the installer clone sits at
`../installer` (`OPENSHIFT_INSTALL_DATA` at `run-create-command.sh:300`), which
will not hold for anyone else.
