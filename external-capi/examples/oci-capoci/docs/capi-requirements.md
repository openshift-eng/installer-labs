# CAPI requirements for `platform: external` on OCI with CAPOCI

**Status: research, 2026-09-30. Nothing here has been run.** No OCI account was
available when this was written. Every claim is a code citation against a local
checkout, or it is marked unverified. Where something is unverified it says so;
that is more useful than a plausible sentence.

The question this answers is the one the pilot was set up to ask: *the installer's
`platform: external` + Cluster API path was proven against CAPA — what does a
second, genuinely non-integrated provider need before it works?* CAPA is the
reference provider the installer was tested with. CAPOCI is the first provider
nobody designed this path around, so it is the first honest measurement.

## Sources

| What | Where | Commit / version |
| --- | --- | --- |
| installer | `openshift/installer`, branch `pilot-platform-external-capi` | `6e028d5597` |
| CAPOCI | `oracle/cluster-api-provider-oci`, local clone | working tree, `cluster-api v1.12.3` in `go.mod:25` |
| Oracle's OpenShift-on-OCI assets | `oracle-quickstart/oci-openshift`, local clone | working tree |
| Ignition platform list | `coreos/ignition` `docs/supported-platforms.md` | fetched 2026-09-30 |
| OCI metadata size limit | Oracle docs, *Creating an Instance* | fetched 2026-09-30 |

## Summary — the scoreboard

Seven things were checked. Four are fine, one needs a wrapper script, and two are
real blockers that need a decision before any money is spent.

| # | Requirement | Verdict |
| --- | --- | --- |
| 1 | Provider treats bootstrap data as opaque (no Ignition feature gate) | **Fine** — better than CAPA |
| 2 | Provider accepts the installer's four controller flags | **One mismatch** — solved by a `#!/bin/sh` shim, no installer change |
| 3 | Provider credentials expressible in the local control plane | **Fine** — `identityRef`, symmetric with CAPA |
| 4 | Machine manifests expressible as selectors, not post-provisioning IDs | **Partial** — works by role-based defaulting, *not* by the name fields, which are ignored on the launch path |
| 5 | Infra object exposes provisioned IDs to the `infraReady` hook | **Fine** — CAPOCI writes OCIDs back into `spec` |
| 6 | A boot image exists that reads Ignition from OCI instance metadata | **Work item** — the capability ships, the image does not; see [boot-image.md](boot-image.md) |
| 7 | Bootstrap Ignition fits in the provider's user-data channel | **BLOCKER** — 32,000-byte cap; see [ignition-delivery.md](ignition-delivery.md) |

And one gap that is neither of the above, because it is a missing *field* rather
than a missing mechanism:

| # | Requirement | Verdict |
| --- | --- | --- |
| 8 | API load balancer can carry a second listener on 22623 (MCS) | **Gap in CAPOCI** — CAPA has `additionalListeners`; CAPOCI has one port. Workaround is a hook. |

The user's own framing — *"their CCM config requires the VCN ID, which exists only
in InfraReady"* — turns out to be the **easiest** of these, not the hardest. It is
requirement 5, and it is already satisfied. See §5.

---

## 1. Bootstrap data format — CAPOCI is better than CAPA here

CAPA refuses to accept Ignition at all unless the controller runs with
`--feature-gates=BootstrapFormatIgnition=true`; its validating webhook rejects
`AWSMachine.spec.ignition` and `AWSCluster.spec.s3Bucket` otherwise. The AWS
example therefore has to pass that gate through
`platform.external.clusterAPI.args`.

CAPOCI needs no equivalent, because it has no opinion about the format:

- `cloud/scope/machine.go:685-702` — `GetBootstrapData()` returns
  `secret.Data["value"]` verbatim.
- `cloud/scope/machine.go:353` —
  `metadata["user_data"] = base64.StdEncoding.EncodeToString([]byte(cloudInitData))`.
- `feature/feature.go` declares only `MachinePool` and `OKE`. There is no
  bootstrap-format gate to enable.
- There are zero occurrences of the string `ignition` in CAPOCI's Go source.

So the installer's `<infraID>-{bootstrap,master,worker}` Secrets flow through
unchanged and land base64-encoded in `metadata.user_data`. **Nothing to do** —
provided the instance can read them, which is requirements 6 and 7.

`OCIMachine.spec.metadata` (`api/v1beta2/ocimachine_types.go:118`) is merged into
the same map at `machine.go:351`, *before* `user_data` is assigned at `:353`, so a
user cannot accidentally shadow the bootstrap data. Good.

## 2. Controller flags — exactly one mismatch, and a shim fixes it

The installer passes a fixed, provider-agnostic argument list to any external
provider, at `pkg/clusterapi/external.go:153-158`:

```
-v=2
--health-addr={{suggestHealthHostPort}}
--webhook-port={{.WebhookPort}}
--webhook-cert-dir={{.WebhookCertDir}}
```

plus `--kubeconfig`, which `runController` appends. CAPOCI's flags are registered
in `main.go:99-167`:

| Installer passes | CAPOCI | Outcome |
| --- | --- | --- |
| `-v=2` | from `logs.AddFlags` / `logsV1.AddFlags` (`main.go:85-96`) | accepted |
| `--webhook-port` | `main.go:128` | accepted |
| `--webhook-cert-dir` | `main.go:133` | accepted |
| `--kubeconfig` | controller-runtime's `client/config` init | accepted |
| `--health-addr` | **not defined** — CAPOCI has `--health-probe-bind-address` (`main.go:100`) | **rejected** |

`pflag` errors on an unknown flag, so the controller exits immediately and the
installer reports a controller that never became healthy.

This cannot be fixed by adding `--health-probe-bind-address` to
`clusterAPI.args`: `--health-addr` is still passed and still rejected. The flag
also cannot be dropped, because the installer polls `/healthz` on that address
(`pkg/clusterapi/system.go:770`) and fails the controller if it does not answer.

**The fix needs no installer change,** and the installer's own code says so.
`pkg/clusterapi/artifacts.go:195-200`:

> *"Files that are not ELF at all — Mach-O on darwin, or a `#!/bin/sh` wrapper —
> are accepted without a check rather than rejected, so that the override stays
> usable on developer workstations."*

So `clusterAPI.binaryPath` may point at a wrapper script that rewrites the
argument and execs the real binary. See
[`scripts/capoci-shim.sh`](../scripts/capoci-shim.sh).

**This generalises, and it is the most reusable result in this document.** The
installer already carries per-platform argument lists that disagree with each
other — `pkg/clusterapi/system.go` passes `--health-addr` at :170, :196, :267,
:333, :345, :394, :418, :443 and `--health-probe-bind-address` at :381 and :407.
Flag divergence between providers is *normal*, and the integrated path handles it
by hardcoding a list per platform. The External path cannot do that, and does not
need to: the shim moves the per-provider knowledge out of the installer and into
an artifact the partner already supplies.

Whether the shim should stay a partner responsibility or become an installer
feature (a `argOverrides` map, say) is an open design question. For the pilot it
stays a shim, because that is the version that requires nothing from the
installer.

## 3. Credentials — clean, and symmetric with CAPA

`OCICluster.spec.identityRef` (`api/v1beta2/ocicluster_types.go:43-45`) points at
an `OCIClusterIdentity`, whose `spec.principalSecret` is a `SecretReference`
(`api/v1beta2/ociclusteridentity_types.go:25-44`). `cloud/util/util.go:118-163`
resolves it. For `PrincipalType: UserPrincipal` the Secret keys are exactly:

| Key | Constant | Required |
| --- | --- | --- |
| `tenancy` | `config.Tenancy` | yes |
| `user` | `config.User` | yes |
| `fingerprint` | `config.Fingerprint` | yes |
| `key` | `config.Key` — the PEM private key | yes |
| `passphrase` | `config.Passphrase` | only if the key has one |
| `region` | `config.Region` | optional; falls back to the cluster's region |

(`cloud/config/config.go:36-47` for the constant values,
`cloud/util/util.go:132-137` for the reads.)

Two consequences worth stating precisely, because this is where local and target
state are most often confused:

- **That Secret lives only in the installer's temporary local control plane**
  (envtest etcd + kube-apiserver). It is never delivered to the cluster being
  installed. The installed cluster's OCI access is a separate matter, and is
  `useInstancePrincipals: true` — see §6.
- The user must create it. The installer does not generate provider credentials
  for a platform it knows nothing about. In this example it is applied by the
  run script before `create cluster`, not placed in `external-install/`, so that
  a private key never sits in a directory that gets archived and handed around.

`cloud/util/util.go:331` enforces `IsClusterNamespaceAllowed` against
`OCIClusterIdentity.spec.allowedNamespaces`; the installer forces every object
into `openshift-cluster-api-guests`
(`pkg/infrastructure/clusterapi/clusterapi.go:183`), so either list that
namespace or leave the selector empty.

**Unverified:** whether `InstancePrincipal` works for the local control plane. It
would require the machine running `openshift-install` to itself be an OCI
instance in a matching dynamic group. Not tested, and not needed for the pilot.

## 4. Machine manifests — selectors, not post-provisioning IDs

This was the strongest result from the AWS pilot: every reference to provisioned
infrastructure in a machine manifest could be written *before* the infrastructure
existed, because CAPA accepts tag filters. The question was whether that was an
AWS accident.

It is not — but the mechanism is not the one the schema advertises, and the
difference cost a destroyed bootstrap machine before it was found.

`OCIMachine.spec.networkDetails` (`api/v1beta2/types.go:38-65`) appears to offer
both forms, `subnetId`/`subnetName` and `nsgIds`/`nsgNames`. **Only the ID forms
are read when an instance is launched.** `cloud/scope/machine.go:320-341`
consults `NetworkDetails.SubnetId` and `NetworkDetails.NSGIds`/`NSGId`, and when
they are nil it branches on `IsControlPlane()` into role-based selection:

| path | subnet by name? | NSG by name? |
| --- | --- | --- |
| worker | yes — but reads the **top-level** `spec.subnetName` (`ocimachine_types.go:142`), not the `networkDetails` one (`machine.go:1075`) | yes, `networkDetails.nsgNames` (`machine.go:1091`) |
| control-plane | **no** — first control-plane-role subnet, unconditionally (`machine.go:1043`) | **no** — all control-plane-role NSGs (`machine.go:1052`) |

So `networkDetails.subnetName` is read by nothing, anywhere, and
`spec.subnetName` is read only for workers. A manifest setting either is
accepted by the webhook, stored, and silently ignored.

**Requirement 4 is nevertheless met, for a weaker reason than it looks.** The
manifests can still be authored up front and need no edit after the VCN exists,
because role-based defaulting puts each machine where we wanted it anyway. That
equivalence holds only while **each role has exactly one subnet and one NSG**.
It breaks for a topology with two worker subnets, and it cannot be worked around
for control-plane machines at all, since no selector reaches that branch.

**Generalised, this is a `platform: external` requirement and not an OCI quirk.**
A provider must let a machine's placement be expressed by something stable at
manifest-authoring time. "A field exists for it" is not sufficient evidence that
it does — requirement 4 was marked *Fine* here on a reading of the type
definitions alone, and was wrong. Check the call site, not the struct.

Recorded as an upstream fix candidate: `getGetControlPlaneMachineSubnet` and
`getGetControlPlaneMachineNSGs` should honour a name the way their worker
counterparts do, and the two `subnetName` fields should be reconciled.

The one value that still cannot be written ahead of time is the same one as on
AWS, and it is not a cloud identifier — it is
`Machine.spec.bootstrap.dataSecretName`, which must be `<infraID>-<role>` because
the installer chooses that name
(`pkg/infrastructure/clusterapi/clusterapi.go`, `IgnitionSecret`). That forces the
same two-phase `create manifests` → substitute → `create cluster` workflow the AWS
example uses.

Plus, on OCI, `imageId` — see requirement 6.

## 5. The VCN ID, and why it is the easy one

The concern that prompted this research was that the OCI CCM's config needs the
VCN OCID, which does not exist until CAPI has built the network, so it cannot go
into a day-0 manifest the way the AWS CCM's config did.

That is correct, and it is already solved by the existing hook contract.

**What the CCM actually needs.** From
`oci-openshift/custom_manifests/manifests/01-oci-driver-configs.yml` and the
rendered form in `terraform-stacks/shared_modules/manifest/locals.tf`, the
`oci-cloud-controller-manager` Secret (and the identical `oci-volume-provisioner`
Secret for CSI) needs exactly four values:

| Field | Source | Known at `create manifests` time? |
| --- | --- | --- |
| `compartment` | user input, a compartment OCID | **yes** |
| `vcn` | the VCN CAPOCI creates | no |
| `loadBalancer.subnet1` | the service-lb subnet CAPOCI creates | no |
| `loadBalancer.securityLists.<subnet>` | that subnet's security list | no |

and `useInstancePrincipals: true`. **There are no credentials in it.** The OCI CCM
authenticates as the instance, through a dynamic group and policy created out of
band. That removes a whole class of problem the AWS example had.

**Where the three unknown OCIDs come from.** CAPOCI writes the identifiers of what
it creates back into the object's *spec*, not into a status block:

- `cloud/scope/vcn_reconciler.go:43` and `:51` —
  `s.OCIClusterAccessor.GetNetworkSpec().Vcn.ID = vcn.Id`.
- Subnets likewise populate `spec.networkSpec.vcn.subnets[].id`.

(`OCIClusterStatus` carries only `ready`, `failureDomains` and `conditions` —
`api/v1beta2/ocicluster_types.go:85-95`. Anyone looking for a `status.network`
block, as `AWSCluster` has, will not find one. That difference matters to a hook
author and to anyone writing the External contract.)

The installer serialises the live infrastructure object to
`$OPENSHIFT_INSTALL_INFRA_JSON` before running the `infraReady` hook, so the hook
reads:

```
.spec.networkSpec.vcn.id
.spec.networkSpec.vcn.subnets[] | select(.role=="service-lb") | .id
```

**Why `infraReady` is early enough.** From
`pkg/infrastructure/clusterapi/clusterapi.go`, the order is:

| Line | Step |
| --- | --- |
| :178 | `PreProvision` |
| — | infrastructure objects created; wait for `Cluster.status.infrastructureReady` |
| **:312** | **`InfraReady` hook** |
| :361 | `Ignition()` — the bootstrap/master/worker Secrets are built |
| :372 | those Secrets are created |
| — | Machines created |
| :457 | `PostProvision` hook |

`infraReady` runs **after the network exists and before any machine is created**.
The CCM Secret is consumed by a pod that starts during bootstrap, minutes later.
There is a lot of room.

**So: write the CCM Secret in the `infraReady` hook, not in `extra-manifests/`.**
Two ways, and the pilot should pick the first:

1. **Render it into `<install-dir>/openshift/`** from the hook. The hook runs with
   `OPENSHIFT_INSTALL_DIR` set and the manifest tree still on disk, so a file
   dropped there is picked up by the bootstrap machine-config server and served
   as part of the cluster's day-0 content — same as any other extra manifest,
   only written later. **Unverified:** that the installer has not already consumed
   and removed `openshift/` by the time `infraReady` runs. This must be checked
   against the asset store before it is relied on; if it has, use option 2.
2. **`oc apply` it from the `postProvision` hook**, using
   `$OPENSHIFT_INSTALL_KUBECONFIG`. That hook runs after the cluster's API is
   serving and before the installer waits for bootstrap to complete, so it is in
   time — but the CCM will have been crash-looping until then, and nodes stay
   `NotReady` with the `node.cloudprovider.kubernetes.io/uninitialized` taint
   meanwhile. It works; it is noisier.

The CSI Secret has the same shape and the same answer.

**A third option worth naming and rejecting:** pre-create the VCN, set
`OCICluster.spec.networkSpec.vcn.skip: true` with an explicit `id`, and write the
CCM config day-0 with the OCID already known. That works and is a legitimate
production pattern — but it moves the network out of CAPI's hands, which is
exactly the thing this pilot exists to test. Keep it as the BYO-network variant,
not as the pilot.

## 6. WORK ITEM — RHCOS can read OCI metadata; no image says so

> **Downgraded from BLOCKER on 2026-10-01.** The gating question — does the
> RHCOS we ship understand OCI at all? — is answered yes, by measurement on a
> running node of `mrb-ext14`: **Ignition `2.26.0-2.el10_2`**, with
> `internal/providers/oraclecloud`'s `init` and `fetchConfig` symbols present in
> the shipped binary, and `src/providers/oraclecloud/mod.rs` in Afterburn
> `5.10.0`. This is a **packaging gap, not a capability gap**, and the remaining
> work is image import plumbing.

Full detail in [boot-image.md](boot-image.md). The short version:

- No RHCOS or SCOS stream in the installer ships an OCI artifact. Checked all
  three (`data/data/coreos/coreos-rhel-9.json`, `coreos-rhel-10.json`,
  `scos.json`) across all four architectures: the artifact keys are `aws`,
  `azure`, `azurestack`, `gcp`, `ibmcloud`, `kubevirt`, `metal`,
  `nvidiabluefield`, `nutanix`, `openstack`, `powervs`, `qemu`, `qemu-secex`,
  `vmware`. No `oraclecloud`, no `oci`.
- Every supported OpenShift-on-OCI install today is Assisted Installer or
  Agent-based Installer, where Ignition is **embedded in the boot media** and the
  image is per-cluster. Oracle's terraform confirms it:
  `shared_modules/compute/main.tf:51` sets `user_data` to a *shell script*, not
  Ignition, and `shared_modules/image/main.tf` imports a QCOW2 the user built.
- Ignition supports OCI — `oraclecloud`, added in **Ignition 2.22.0
  (2025-07-08)** — and **our RHCOS carries it**: 2.26.0, verified by reading the
  provider's Go symbols out of the shipped binary rather than trusting the
  version number. So the mechanism exists upstream *and* downstream; it is only
  the published artifact list that does not target OCI.
- `OCIMachine.spec.imageId` is a bare OCID with no selector, so whatever image is
  used must be imported and its OCID pasted into the machine manifests.

**Route A — import the `qemu` QCOW2 and force
`ignition.platform.id=oraclecloud` — is now the plan, not a gamble.** The one
remaining unknown is whether the platform ID can be written into an imported
image: it is normally baked in at build time by `coreos-installer install
--platform`, and OCI has no kernel-arguments field on a custom image.
[boot-image.md](boot-image.md) has the step-by-step status table.

## 7. BLOCKER — bootstrap Ignition does not fit in OCI user-data

Full detail in [ignition-delivery.md](ignition-delivery.md). The short version:

- Oracle documents **"The total maximum size for user data and other metadata
  that you provide is 32,000 bytes"**. After base64 that is roughly 23,900 bytes
  of payload.
- Master and worker configs are *pointer* Ignition, about 1.6 KiB. They fit
  easily.
- The bootstrap config is the whole cluster's day-0 content and is hundreds of
  kilobytes. It does not fit, and it is not close.
- CAPA solves this itself: `AWSCluster.spec.s3Bucket` plus
  `AWSMachine.spec.ignition.storageType: ClusterObjectStore` makes CAPA upload the
  config to S3 and hand the instance a presigned URL. **CAPOCI has no equivalent.**
  There is no object-storage offload anywhere in it.
- The integrated GCP, Azure and IBM Cloud paths solve it in the *installer*, by
  building a pointer shim inside their `Ignition()` implementation
  (`pkg/infrastructure/gcp/clusterapi/clusterapi.go:158`,
  `pkg/infrastructure/azure/azure.go:1119`,
  `pkg/infrastructure/ibmcloud/clusterapi/clusterapi.go:464`). The External
  provider cannot: it has no cloud credentials, by design.

**The answer needs no installer change, and it is already how UPI works.**
`bootstrap.Bootstrap` is a `WritableAsset` with a `Load()` that reads
`bootstrap.ign` from the install directory
(`pkg/asset/ignition/bootstrap/bootstrap.go:18,39-41`), and it is in the
`IgnitionConfigs` target (`pkg/asset/targets/targets.go:56-64`). So:

1. `openshift-install create ignition-configs`
2. upload the real `bootstrap.ign` to OCI Object Storage, create a
   pre-authenticated request
3. **overwrite `bootstrap.ign` with a stub** that points at that URL
4. `openshift-install create cluster` — which loads the stub, puts *that* in the
   `<infraID>-bootstrap` Secret, and it is about 1 KiB

This extends the two-phase workflow the pilot already has to three phases. It is
implemented in [`scripts/run-create-command.sh`](../scripts/run-create-command.sh).

**It has a security property that must be stated, not buried.** A pre-authenticated
request is an unauthenticated HTTPS URL, and `bootstrap.ign` contains the
cluster's day-0 secrets. AWS has the same exposure via the presigned S3 URL, which
CAPA bounds with `presignedURLDuration: 1h`. The OCI PAR must be given a short
expiry and deleted by the `preDestroy` hook. Anyone productising this should
prefer an authenticated fetch.

## 8. Gap in CAPOCI — the API load balancer has one listener

Control-plane machines fetch their real config from
`https://api-int.<clusterDomain>:22623/config/master`. On the integrated AWS path
and in the CAPA example, port 22623 is a second listener on the internal NLB:
`AWSCluster.spec.controlPlaneLoadBalancer.additionalListeners`.

CAPOCI's API server load balancer is built from
`cloud/scope/load_balancer_reconciler.go`, and every port in it is
`s.APIServerPort()` — `:52`, `:69`, `:151`, `:158`. `LoadBalancer`
(`api/v1beta2/types.go:996`) exposes `name`, `loadBalancerId`, `loadBalancerType`,
`nlbSpec` and `networkVisibility`. **There is no field for a second listener, and
no additional-ports concept anywhere in the type.**

This is a genuine "CAPI requirement to be implemented" — the kind of thing this
research was asked to surface — and the right long-term answer is an upstream
CAPOCI feature matching CAPA's `additionalListeners`.

### An out-of-band listener does survive reconcile — verified

This started as a hope and is now a code-read result. Both load-balancer
reconcilers converge on a desired state that **mentions neither listeners nor
extra backend sets**, so there is nothing to prune a hook-created one.

Which reconciler runs is chosen at `controllers/ocicluster_controller.go:262-270`
on `spec.networkSpec.apiServerLoadBalancer.loadBalancerType`: `LB` takes the
LBaaS path, anything else (including the default empty value) takes the NLB path.

**NLB path** — the default, and what this example uses:

- `network_load_balancer_reconciler.go:301-320` `IsNLBEqual` compares the
  **display name** and the health checker of the single backend set named
  `apiserver-lb-backendset`. Nothing else.
- `network_load_balancer_reconciler.go:122-150` `UpdateNLB` sends an
  `UpdateNetworkLoadBalancerDetails` carrying **`DisplayName` only**, then updates
  that one backend set's health checker. It never enumerates listeners and never
  deletes one.

**LBaaS path**, for completeness:

- `load_balancer_reconciler.go:250-255` `IsLBEqual` compares the display name and
  returns true.
- `load_balancer_reconciler.go:122-135` `UpdateLB` sends `DisplayName`,
  `FreeformTags` and `DefinedTags` only.

So **adding a second listener and backend set on 22623 out of band is safe from
CAPOCI's reconcile loop** on either path. That is the workaround the example
uses, and it is the cheaper of the two options — the other being a wholly
separate NLB created and destroyed by the hooks, which is more to build and buys
nothing now that reconcile survival is established.

### The backends are the remaining problem, and they are a `postProvision` job

CAPOCI registers each control-plane machine as a backend itself, but **only in
`apiserver-lb-backendset`** — `cloud/scope/machine.go:835` (LBaaS) and `:874-895`
(NLB) both index `lb.BackendSets[APIServerLBBackendSetName]`, and the port is
always `APIServerPort()`. Nothing populates a second backend set.

At `infraReady` no machine exists yet, so the split is:

| Hook | Does |
| --- | --- |
| `infraReady` | create the 22623 listener and an empty `mcs-backendset` on the existing NLB |
| `postProvision` | add each control-plane instance to `mcs-backendset` on 22623 |

**This is still the least-tested part of the design.** Two specific unknowns: the
bootstrap machine also serves 22623 and must be a backend early — arguably
earlier than `postProvision` — and whether an empty backend set keeps the NLB in
a healthy state while it waits. Neither is answerable without an account.

## What this adds up to

The installer's External CAPI path holds up well. Nothing in requirements 1–5
needs an installer change, and the two that looked hardest going in — flags and
the VCN ID — are a shim and an existing hook.

The blockers are not in the installer and not really in CAPOCI either. They are
in the **platform's boot story**: OpenShift on OCI has never booted RHCOS from
cloud instance metadata, so there is no image that reads Ignition from user-data
and no channel sized for the bootstrap config. Both are solvable outside the
installer, and both must be solved before an OCI account is worth spending.

The one thing that is squarely a provider gap is requirement 8, and it should be
filed upstream against CAPOCI regardless of what this pilot does.

## Open questions

1. Which boot-image route? Gates everything. See [boot-image.md](boot-image.md).
2. Does `infraReady` still see a writable `<install-dir>/openshift/`, or must the
   CCM Secret go through `postProvision` and `oc apply`? One experiment settles it
   and it costs nothing.
3. ~~Does an out-of-band listener survive CAPOCI's LB reconcile?~~ **Answered
   while writing this: yes, on both the NLB and LBaaS paths.** See §8. What
   remains open is backend population for 22623, especially for the bootstrap
   machine.
4. Should the installer grow a generic per-provider argument-translation
   mechanism, or is the shim the right permanent answer?
5. Should the bootstrap-Ignition stub workflow be documented as the general
   External answer for any provider without object-storage offload? It is not
   OCI-specific.
6. CAPI core version skew: CAPOCI builds against `cluster-api v1.12.3`, the
   installer against `v1.13.4`. CAPOCI imports both `api/core/v1beta1` and
   `api/core/v1beta2`, and the example manifests use `v1beta1`, which v1.13 still
   serves — so this is *probably* fine. **Unverified.** It is the kind of thing
   that fails at the first reconcile, cheaply, so it does not need pre-work.
