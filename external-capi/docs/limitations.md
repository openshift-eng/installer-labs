# Limitations

Read this before committing work to this path. Everything here is observed on real installs
unless labelled otherwise. Citations are against `openshift/installer` at commit
`6e028d5597`.

The honest summary: **the infrastructure half works end to end, and the machine-lifecycle
half does not exist.** A cluster installs, serves, rolls out all operators and tears itself
down cleanly. Getting worker nodes *admitted* needs a manual step, and there is no day-2
machine management at all.

---

## Worker admission is not automatic

**This is the most consequential limitation and the one least likely to be guessed.**

Day-0 workers are created, provisioned, booted, apply their Ignition and start their
kubelets — all verified. They then **fail to become `Node`s without a human**, because
`cluster-machine-approver` will not approve their first-join CSRs:

```
E csr_check.go:329] csr-72cnz: failed to find machine with InternalDNS matching ip-10-0-17-179, cannot approve
```

### Why, read from the approver's source

- A **client** CSR — the first-join CSR from
  `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper` — is matched to
  a machine-api `Machine` by `FindMatchingMachineFromInternalDNS`, which reads
  `machine.Status.Addresses`. `authorizeNodeClientCSR` requires a match **unconditionally**.
- There is **no** platform-aware, NoOp or empty-machine-list short-circuit on that path. The
  only configuration toggle, `NodeClientCert.Disabled`, makes it *reject*, not approve.
- The machine-less fallback (`"No machine found, using serving cert renewal"`) exists only on
  the **serving** path, and it requires an existing `Node` to read a current certificate
  from. A node that has never joined has none, so it cannot help a first join.

On `platform: external` there are no `Machine`s. Verified on a cluster:
`oc get machines.machine.openshift.io -A` returns `No resources found`, and the machine-api
operator reports `Cluster Machine API Operator is in NoOp mode`.

**So the approver requires an object this platform is defined never to have.** Over a whole
install it approved **zero** CSRs.

> These claims are read from `openshift/cluster-machine-approver`, which the installer does
> not vendor. They are cited by function name rather than `file:line` at a commit for that
> reason.

### What does not fix it

**Emitting spec-only MAPI `Machine` objects does not work**, and this is worth stating
because it is the obvious idea. The approver matches on `Status.Addresses`, which only an
actuator ever populates, and `status` is a subresource a day-0 manifest cannot set. A
`Machine` delivered as a manifest would be matched against and still fail.

**No arrangement of installer code opens this gate.** It is not in this repository.

### What to do today

**Approve the CSRs by hand.** This is not novel — it is the documented UPI behaviour, which
`platform: external` inherits, and it is what every non-integrated provider does today:

```sh
oc get csr -o name | xargs oc adm certificate approve
```

Workers register normally afterwards. Expect to run it twice: once for the client CSR, once
for the serving CSR that follows.

It remains a real limitation: **`create cluster` cannot report a fully-formed cluster**,
because admitting the workers happens after it exits.

### The intended direction, not scheduled

The likely answer is **an admission webhook or controller that evaluates a CSR against the
node it claims to be for and approves it without a human** — checking the requested identity
against observable facts about the instance rather than against a MAPI `Machine`. That
removes the human step without reintroducing the Machine API, and it would serve every
non-integrated provider, not just this one.

**This is recorded as a direction, not a commitment.** It is out of scope for the pilot and
is not being built now. Two alternatives were weighed and set aside:

| Option | Where the work lands | Why not now |
| --- | --- | --- |
| Accept manual approval | nowhere — status quo | what we are doing; the baseline |
| CSR-evaluating webhook / machine-less approver path | `cluster-machine-approver` or a new component | **the intended direction**, outside the installer, not scheduled |
| Ship a Machine API actuator | per-cloud, in-tree | reintroduces exactly the coupling this platform exists to remove |

---

## No day-2 machine management

There is no Machine API, no MachineSet, no autoscaler and no `oc scale`. The machine-api
operator runs in NoOp mode by design.

Every machine the cluster will ever have is created on **day 0**, from the manifests in
`external-install/machines/`. Adding or replacing a node later is a manual operation against
the partner's cloud plus a manual CSR approval.

This is a **separate limitation from worker admission above**, with a different cause and a
different owner. Day-0 machines do not close it.

---

## A failed worker fails the whole install

The pre-bootstrap machine wait has no control-plane filter — every machine the installer
created must provision before bootstrap begins, workers included, within a 15-minute
`provisionTimeout`.

On an integrated platform a worker that fails to provision is a degraded MachineSet. Here it
is a failed `create cluster`.

---

## One object per extra manifest

A file in `extra-manifests/` must hold exactly one Kubernetes object. Multi-document YAML is
refused at `create manifests`. The reason, and the cluster it cost, are in
[manifest-contract.md](manifest-contract.md#rule-1--one-object-per-file).

The guard is unit-tested but **has not been exercised on a cluster run**.

---

## A hook that exits 0 is trusted absolutely

There is no post-destroy census in the product. A cleanup hook that fails to recognise a
resource takes the same code path as one that finds nothing to do, and both exit 0. See
[hooks.md](hooks.md#hazard-a-hook-that-exits-0-is-not-a-hook-that-worked).

---

## Unknown-GVK handling is provisional

The installer accepts the partner's infrastructure CRs as unstructured objects because it has
no compiled-in type for them. This weakens a check that currently catches genuine typos in
manifests for integrated providers: today a misspelled `kind` fails loudly at `Scheme.New()`.

**This is an open design item, not a settled one.** It will be resolved one of three ways —
scoped to `platform: external` only, validated against the CRDs actually present in
`componentsPath`, or replaced by runtime scheme registration.

---

## Artifact references are local filesystem paths

`clusterAPI.binaryPath` and `clusterAPI.componentsPath` are paths on the machine running the
installer. There is no support yet for remote git references, image references, digest or
signature pinning, or an air-gapped flow. All are deferred until after the pilot.

The paths are recorded in `metadata.json` so that `destroy cluster` can start the same
provider — which means **the install directory is not portable between machines** unless the
artifacts exist at the same paths.

---

## Staging the bootstrap ignition is your problem, not the installer's

This one is structural, and it is the first thing a second provider ran into.

The bootstrap ignition is hundreds of kilobytes. Most clouds cap instance metadata well
below that — OCI's limit is 32,000 bytes for user data and metadata combined, roughly
23,900 once base64 inflation is accounted for. Master and worker ignition are pointer
configs of about 1.7 KiB and fit anywhere; the bootstrap config does not.

Integrated platforms solve this **inside the installer**, by uploading the bootstrap
ignition to the cloud's object storage before creating the machine —
`pkg/infrastructure/gcp/clusterapi/clusterapi.go:158`,
`pkg/infrastructure/azure/azure.go:1119`,
`pkg/infrastructure/ibmcloud/clusterapi/clusterapi.go:464`. **`platform: external` cannot
do that, by design: it has no cloud credentials.** That is the point of the platform, and
this is its price.

So it falls to one of two places:

- **The provider**, if it has an offload. CAPA does: `s3Bucket` plus
  `ignition.storageType: ClusterObjectStore`. Nothing is needed from you.
- **Your driver script**, if it does not. CAPOCI has no object-store support at all, so the
  OCI example inserts a phase between `create ignition-configs` and `create cluster`:
  upload `bootstrap.ign`, mint a time-limited URL, and overwrite the file on disk with a
  ~300-byte pointer config. The installer reloads it, because `bootstrap.Bootstrap`
  implements `Load()` (`pkg/asset/ignition/bootstrap/bootstrap.go:39-41`) and is in the
  IgnitionConfigs target (`pkg/asset/targets/targets.go:56-64`).

The second route works and needs no installer change, but it hands every partner the same
credential-handling hazard: **that URL grants unauthenticated read over the cluster's day-0
secrets** — certificates, keys, the kubeconfig. Give it the shortest workable expiry, never
log it, and delete it in `preDestroy`. See
[../examples/oci-capoci/docs/ignition-delivery.md](../examples/oci-capoci/docs/ignition-delivery.md).

Whether the installer should grow a first-class way to say *"the bootstrap ignition is
staged elsewhere, here is the pointer"* is an open design question. Leaving it to each
partner means each partner reimplements the same hazard.

---

## The controller argument list is fixed, and your provider may not accept it

The installer invokes an external provider with exactly
`-v=2 --health-addr=<addr> --webhook-port=<n> --webhook-cert-dir=<path>`
(`pkg/clusterapi/external.go:153-158`), plus `--kubeconfig`, plus whatever `clusterAPI.args`
adds. There is no way to remove or rename one. pflag exits non-zero on an unknown flag, so a
single divergence stops the install before anything is created.

This is not hypothetical: CAPOCI declares `--health-probe-bind-address`, not
`--health-addr`, and that one flag is its only incompatibility.

**The escape hatch is that `binaryPath` may be a wrapper script.** `validateHostArch` accepts
files that are not ELF — "Mach-O on darwin, or a `#!/bin/sh` wrapper" — rather than rejecting
them (`pkg/clusterapi/artifacts.go:195-200`). So a few lines of shell can translate the flag
and `exec` the real binary. [../examples/oci-capoci/scripts/capoci-shim.sh](../examples/oci-capoci/scripts/capoci-shim.sh)
is a worked example.

Translate, do not drop: the installer polls `/healthz` at exactly the address it passed
(`pkg/clusterapi/system.go:770`), so a dropped health flag leaves the controller listening
somewhere else and the installer waiting on a port nobody serves.

A generic fix belongs in the installer — it already hardcodes
`--health-probe-bind-address` for some integrated providers
(`pkg/clusterapi/system.go:381,407`), so this is a known class with no general handling.
Until then, the shim is the answer.

---

## What has never been exercised

Labelled honestly, because a labelled gap is worth more than a plausible-looking claim:

| Arm | Status |
| --- | --- |
| A hook exiting non-zero aborts the install | specified, never run |
| A worker whose provisioning fails aborts the install | specified, never run |
| `destroy cluster` re-run after a partial failure | never run |
| The legacy-string `metadata.json` compatibility branch | never entered |
| The multi-object extra-manifest guard, on a real cluster | unit-tested only |
| Any provider other than CAPA | never run. CAPOCI has been studied against the code in depth and a complete example written — [../examples/oci-capoci/](../examples/oci-capoci/) — but nothing has been executed |
| More than one availability zone | never run |
| Any IAM configuration | never touched |

The last two matter for scope: every pilot install used a single AZ and pre-existing
credentials.

---

## Not a supported path

This is pilot output. It is not a supported OpenShift installation method, there is no CI
job gating it, and the directory name `external-install/` is explicitly provisional
(`pkg/types/external/doc.go:22`).
