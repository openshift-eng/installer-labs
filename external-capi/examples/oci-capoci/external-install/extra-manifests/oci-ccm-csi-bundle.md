# Oracle's CCM and CSI bundles, as `platform: external` extra manifests

The eighteen `99_external-02-oci-ccm-*` and `99_external-03-oci-csi-*` files are
a **mechanical copy**, split one object per file, with **two deltas** and
nothing else.

## Upstream, and how to check this copy against it

| | |
| --- | --- |
| Repository | <https://github.com/oracle-quickstart/oci-openshift> |
| Commit | `4944984e3895198405b512f610fe665a9976db28` |
| Ref | tag `v1.6.1`, committed 2026-08-12 |
| Directory | `custom_manifests/oci-ccm-csi-drivers/v1.34.0/` |

| Source file | SHA-256 | Objects |
| --- | --- | --- |
| `01-oci-ccm.yml` | `8a585cef8cb2d34834b30784cab277ca5fc80caa0bbc40e720516ae466a1fdc3` | 5 |
| `01-oci-csi.yml` | `f3af5c329e11a2272836856d29f3cc6f0af852ec0e84c79850b3c6538a858803` | 13 |

It is `oracle-quickstart/oci-openshift`, **not** `oracle/oci-openshift`; the
latter does not exist and earlier revisions of these notes named it.

A permalink to the exact bytes is the repository URL, then `/blob/`, then the
commit, then the directory and file — for example
`…/blob/4944984e3895198405b512f610fe665a9976db28/custom_manifests/oci-ccm-csi-drivers/v1.34.0/01-oci-ccm.yml`.

To check for upstream drift:

```sh
git -C oci-openshift fetch origin
git -C oci-openshift show \
  origin/main:custom_manifests/oci-ccm-csi-drivers/v1.34.0/01-oci-ccm.yml | sha256sum
```

If the hash differs from the table above, upstream has moved. Re-run the
generator against the new checkout rather than merging by hand: the headers
carry these same three facts per file, so a hand edit makes every recorded
SHA-256 a lie and destroys the only property that makes this copy auditable.

The files are produced by `tools/oci-capoci/gen-ccm-csi.py` at the workspace
root, which proves the split is lossless by parsing every object before and
after and requiring equality. **Do not hand-edit them.**

## Why one object per file

`extra-manifests/` files are copied into `<install-dir>/openshift/`, and
**the bootstrap node applies that directory one object per file.** Every
document after the first in a multi-document file is silently ignored. The
installer refuses such a file at `create manifests` time —
`pkg/asset/manifests/openshift.go`, `countManifestDocuments`.

This is not theoretical. **Measured 2026-10-01, run 13.** An earlier revision of
the generator emitted each bundle as one multi-document file. The run used an
`openshift-install` binary built *before* that guard was committed, so nothing
rejected them, and the cluster came up with:

- `oci-cloud-controller-manager` Namespace — document 1 of the CCM file ✓
- `oci-csi` Namespace — document 1 of the CSI file ✓
- **none of the other sixteen objects**

No DaemonSet, no RBAC, no CSI driver, no StorageClass. The hook's two Secrets
applied cleanly into the two empty namespaces, so nothing anywhere said
"missing". The only symptom was three masters that registered, got correct
provider IDs, and never left `NotReady`.

Two lessons, and the second is the larger one:

1. A partner bundle is almost always a multi-document file. Pouring one into
   `extra-manifests/` produces a cluster that fails with no message naming the
   cause. The guard now catches it, but only at `create manifests`.
2. **A stale binary silently disabled a guard that existed.** The clone had the
   check; the binary predated it by 55 minutes. Rebuild before a pilot run.

## Why these are day-0 and their config is not

The CCM's *config* needs the VCN and service-lb subnet OCIDs, which do not
exist until CAPI has built the network, so `../hooks/infra-hook.sh` writes the
two Secrets at `postProvision`. The *deployments* need nothing unknown at day 0
and have to exist early: the CCM is what removes
`node.cloudprovider.kubernetes.io/uninitialized`, so until it runs every node
stays `NotReady`.

Shipping the deployments here and the Secrets later means a DaemonSet waits a
few minutes on a missing Secret, rather than the whole cluster waiting on a
missing CCM.

This split is the most instructive thing in the example. **A partner bundle
that assumes both halves ship together does not work on this platform, and
nothing tells them.**

## Delta 1 — the CCM image, and it is not cosmetic

Upstream v1.34.0 points the CCM DaemonSet at

```
ghcr.io/nikhisin3001/cloud-provider-oci:v1.34.0
```

— an individual's personal GHCR namespace, not Oracle's. It appears to be an
accident: the CSI bundle in the same directory uses `ghcr.io/oracle/`, and so
does every other version in that tree (v1.30.0, v1.32.0, v1.32.2, v1.33.1).
v1.34.0's CCM is the only one that does not.

We substitute the Oracle-namespaced tag. Verified 2026-10-01 that it exists:

| ref | digest |
| --- | --- |
| `ghcr.io/oracle/cloud-provider-oci:v1.34.0` | `sha256:1cdcf085913af3c9cd0143999b858e77445eabdbeaebb1025ece3f3162ead57f` |
| `ghcr.io/nikhisin3001/cloud-provider-oci:v1.34.0` | `sha256:c4d32380c386c2cc60e5b1a132b615bb7e7cca4fdd0adc6b036f250f07aca983` |

**The digests differ**, so this is a different image and not a rename. We have
not established that the two are functionally equivalent. Preferring the vendor
namespace over an individual account is a supply-chain judgement, taken
deliberately; it is not a verified no-op. Worth reporting upstream to
`oracle-quickstart/oci-openshift`.

Run 13 completed its control plane on the Oracle-namespaced image, so the
substitution is no longer merely plausible — it works.

### Generalised: the partner-manifest supply chain

A non-integrated provider's in-cluster components come from registries the
installer has never heard of — here `ghcr.io` and `registry.k8s.io`. Neither is
in the release payload, neither is covered by any ImageContentSourcePolicy the
installer generates, nothing verifies either, and a disconnected install fails
at image pull. **`platform: external` has no story at all for partner-manifest
provenance, mirroring or disconnected support.** The personal-namespace image
above is the concrete proof that nothing catches a mistake there.

## Delta 2 — VolumeSnapshotClass is day-2

`VolumeSnapshotClass/oci-snapshot` ships as

```
99_external-03-oci-csi-12-volumesnapshotclass-oci-snapshot.yaml.day2
```

The `.day2` extension is load-bearing: the installer only reads `.yaml`, `.yml`
and `.json` from this directory (`manifestFileExtensions`), so the file is
skipped at install time, while `oc apply -f` works on it unchanged afterwards.
It replaces an earlier approach that commented the object out line by line,
which left it unusable without an edit.

It cannot be day-0. **Measured:**

```
no matches for kind "VolumeSnapshotClass" in version "snapshot.storage.k8s.io/v1"
```

The CRD is not missing from the cluster, it is merely not there *yet* — it
arrives with cluster-storage-operator, well after extra manifests are applied.
The object is correct; only its timing is wrong.

**Deferring the object is not the whole of that problem.** The Deployment in
this bundle also carries a `csi-snapshotter` sidecar watching the same CRDs:

```
Failed to watch *v1.VolumeSnapshotContent: ... the server could not find the
requested resource (get volumesnapshotcontents.snapshot.storage.k8s.io)
F leader_election.go:182] stopped leading
```

It crash-loops until those CRDs exist and is expected to recover on its own.
**Not observed recovering** — reasoning about the mechanism, not a measurement.

Separately, and also not diagnosed: `csi-attacher`, `csi-resizer` and
`csi-volume-provisioner` failed with `dial tcp 172.30.0.1:443: i/o timeout` on
a cluster that had one node and most operators degraded. The likeliest
explanation is the broken cluster rather than these manifests. Recorded because
it was seen, not because it is understood.

### Generalised: there is no day-0/day-1 sequencing primitive

This is the clearest evidence in the pilot that a partner's component bundle
cannot simply be poured into `extra-manifests/`: part of it is day-0 and part
depends on operators that do not exist until day-1. `platform: external` offers
no way to express "apply this once that CRD exists", so the partner must split
their own bundle by hand and get the split right — exactly the judgement an
integration is supposed to remove.

## Why every file carries `# yamllint disable rule:indentation rule:brackets`

This repository's `.yamllint` sets `indent-sequences: false` and the default
`brackets` rule. Oracle's bundle indents its sequences and writes `[ "x" ]`, so
an unmodified copy produced **90 yamllint errors** in a tree that has zero, and
AGENTS.md is explicit that material copied into this clone must pass the
clone's gates.

Three ways to satisfy that:

- **Reformat.** Tried, and it broke. An automated reindenter driven by
  yamllint's own reports produced a file that no longer parsed —
  `expected <block end>, but found '-'` in the DaemonSet's volumes list. It was
  caught only because the fix was required to prove itself by parsing before
  and after and comparing objects. Reformatting also destroys the
  line-for-line correspondence that makes re-copying a future version
  mechanical.
- **Add the paths to `.yamllint`'s `ignore:` list.** Precedented — that list
  already carries `data/data/cluster-api/`, which is third-party provider
  manifests, exactly this category. Rejected because it hides the exemption in
  a shared config file where nobody reading these files would find it.
- **Disable the two cosmetic rules in the files they apply to, next to the
  reason.** This one.

Scope is deliberately narrow: two purely stylistic rules on vendored files.
Nothing here suppresses a rule that could hide a defect.

## Re-copying a newer Oracle version

1. Point `SRC` in `tools/oci-capoci/gen-ccm-csi.py` at the new version
   directory.
2. Re-check whether delta 1 is still needed — if Oracle has fixed the image
   namespace, drop it and say so here.
3. Re-check whether `VolumeSnapshotClass` is still the only day-1 object.
4. Run the generator. It refuses to finish unless every object round-trips
   equal to the source.
5. Run the clone's gates: `cd installer && hack/yaml-lint.sh && hack/shellcheck.sh`.

## Still open

- **Which CCM version tracks which OpenShift release.** v1.34.0 was chosen as
  the newest in Oracle's tree. Nothing here checks that against the cluster's
  Kubernetes version, and nothing would catch a skew.
- **Instance principals.** Both Secrets are written with an API key because the
  target compartment had zero dynamic groups. See `README.md`.
