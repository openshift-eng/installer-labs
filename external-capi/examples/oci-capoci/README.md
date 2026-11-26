# `platform: external` with CAPOCI — the second pilot

Installing OpenShift on Oracle Cloud Infrastructure with `platform: external`,
driving infrastructure through the **Cluster API Provider for OCI** (CAPOCI)
from the installer's own local control plane.

> **STATUS: this has run, to a complete cluster — with hand-work in the
> middle.**
>
> Written 2026-09-30 from reading, with no OCI account. Run thirteen times on
> 2026-10-01. Run 13 produced **five Ready nodes and 34/34 cluster operators
> Available**, with console and oauth answering 200 from the internet, on
> `platform: external` with CAPOCI and **no installer changes**.
>
> **It was salvaged by hand.** The CCM and CSI manifests were applied
> manually, four worker CSRs were approved manually, and the ingress Service
> and its security group were created manually. Each of those causes has since
> been written into the files here, so a fresh run should not hit them — but
> **no clean end-to-end run on the corrected set has been spent**. Treat the
> status as "every piece is proven, the whole is not".
>
> Claims about CAPOCI, Oracle's assets and the installer are cited to
> `file:line` against the local clones. Claims that come from a measurement on
> a live cluster say so and carry the date. Where something is still inferred,
> it is labelled.
>
> The [aws-capa](../aws-capa/) sibling of this directory came out of a dozen
> installs. The structure here is deliberately identical so the differences are
> the interesting part — and the differences turned out to be the whole point.

## Why a second provider

The first pilot proved the installer can drive a Cluster API provider it was
never compiled against, using CAPA as the reference. One provider does not
establish a contract. CAPOCI is the test of whether the seams — the artifact
override, the unknown-GVK path, the three hooks, the ignition Secrets — are
actually provider-agnostic or merely CAPA-shaped.

The constraint set by the user: **avoid installer changes.** Where CAPOCI needs
something specific, use the existing hooks. That constraint held, with one
caveat covered below.

## The short version

| Question | Answer |
| --- | --- |
| Does the installer need changes? | **No — and this is now measured, not argued.** A full cluster was installed with an unmodified installer. One controller flag mismatch, solved by a wrapper script the installer's own validator explicitly sanctions. |
| Does CAPOCI accept Ignition? | **Yes, with no feature gate** — better than CAPA, which needs `BootstrapFormatIgnition=true`. |
| The VCN-ID problem the user raised? | **The easy one.** Four values, three from `infraReady`, no credentials at all. Worked first time. |
| So what actually blocks it? | **One thing, and it is not CAPI: the boot image.** The pilot boots the OpenStack QCOW2 with `ignition.platform.id=openstack` — a workaround, not a product answer, and the cause of the hostname problem below. The 32,000-byte metadata cap turned out to be routine: offload to object storage, no installer change. |
| Anything missing in CAPOCI itself? | **Three gaps.** Its API load balancer has exactly one listener, on 6443, and OpenShift needs 22623. It ignores every name selector on the control-plane machine path, so placement is expressible only by OCID or by role defaulting. And it has no concept of a second load balancer, so ingress has to come from the CCM. |
| What stopped the cluster at 29/34 operators? | **Ingress, and the cause is generic.** `platform: external` publishes routers with `HostNetwork`, so nothing ever asks the cloud for an external address — and when one was asked for, the node security groups had no 80/443 rule for the node-to-node hop OVN makes. Both fixed in the files here. |

## Read in this order

| | |
| --- | --- |
| **[docs/capi-requirements.md](docs/capi-requirements.md)** | **start here.** Eight requirements a CAPI provider must meet to drive a `platform: external` install, each scored against CAPOCI with citations. |
| [docs/boot-image.md](docs/boot-image.md) | work item 1: no RHCOS artifact for OCI is *published*, though Ignition 2.26.0 in our RHCOS has the `oraclecloud` provider compiled in. Three routes, and why route A is now the plan. |
| [docs/ignition-delivery.md](docs/ignition-delivery.md) | blocker 2: the bootstrap ignition does not fit in OCI instance metadata, and CAPOCI has no object-store offload. |
| [scripts/README.md](scripts/README.md) | the flag shim, the three-phase workflow, how to build the artifacts. |
| [external-install/machines/README.md](external-install/machines/README.md) | the substitution contract and destroy coverage. |
| [external-install/extra-manifests/README.md](external-install/extra-manifests/README.md) | the CCM and CSI config, why it cannot be a day-0 manifest, the ingress load balancer, and the four corrections that each cost a run. |

## Layout

```
install-config.yaml              platformName: oci, the clusterAPI block, the three hooks
external-install/
  cluster.yaml                   Cluster + OCIClusterIdentity + OCICluster
  machines/
    10_bootstrap.yaml            1 Machine + OCIMachine
    20_master.yaml               3 Machine + OCIMachine
    30_worker.yaml               2 Machine + OCIMachine  (optional)
  extra-manifests/               day-0: kubelet providerID and hostname
                                 MachineConfigs, the CCM and CSI bundles split
                                 one object per file, and the ingress Service
  hooks/
    infra-hook.sh                infraReady / postProvision / preDestroy
scripts/
  capoci-shim.sh                 the one flag translation
  run-create-command.sh          three-phase driver
  run-destroy-command.sh         teardown + an independent secret-cleanup check
docs/
```

## The two hard problems

Neither is about Cluster API, and neither was the thing anyone expected to be
hard. The first was written as a blocker and was **downgraded to a work item on
2026-10-01**, by measurement.

### 1. No RHCOS boot image for OCI is published — but the capability is there

`data/data/coreos/coreos-rhel-9.json`, `coreos-rhel-10.json` and `scos.json`
list artifacts for aws, azure, azurestack, gcp, ibmcloud, kubevirt, metal,
nvidiabluefield, nutanix, openstack, powervs, qemu, qemu-secex and vmware.
**There is no `oci` key on any architecture in any stream.**
`OCIMachine.spec.imageId` is a bare OCID — unlike CAPA there is no
`imageLookup` filter — so something has to put an image in the tenancy first.

Today's OpenShift-on-OCI is Agent-based or Assisted, with the ignition baked
into a per-cluster boot image
(`oci-openshift/terraform-stacks/shared_modules/compute/main.tf:51-53` sets
`metadata.user_data` to a *bash script*, not an Ignition config). That route
proves nothing about Ignition delivery, which is precisely the thing this pilot
is testing.

**The question that gated everything is answered: yes.** Measured on a running
node of the `mrb-ext14` AWS `platform: external` cluster, built from the same
release payload: RHCOS `10.2.20260918-0` ships **Ignition 2.26.0**, four minor
versions past the 2.22.0 that added `oraclecloud`, and the provider's `init`
and `fetchConfig` Go symbols are present in the shipped binary — so it is
registered, not merely referenced. Afterburn 5.10.0 knows OCI too.

So this is a **packaging gap, not a capability gap**.

> **What the pilot actually did, and why it is not the answer.** It imported
> the published **OpenStack** QCOW2 and booted it with
> `ignition.platform.id=openstack`. That works — Ignition fetches its config
> from the user data OCI serves — and it is a workaround with a visible,
> compounding cost:
>
> - **It makes one cloud consume another cloud's artifact.** No partner can be
>   asked to do that, and nothing in the release process guarantees the
>   OpenStack image keeps booting on OCI.
> - **Afterburn then looks for an OpenStack metadata service that OCI does not
>   serve, so the node hostname is never set.** Every node registers as
>   `localhost.localdomain`; three masters contend for a single `Node` object
>   and the control plane never forms. That is the sole reason
>   `external-install/extra-manifests/99_external-01-oci-hostname-*.yaml`
>   exist. A workaround at one layer grew a workaround at another.
>
> The real blocker underneath is **IMDSv2**: OCI serves only v2, and the
> generic path needs the OpenShift components that read instance metadata to
> speak it. The enhancement proposal carries this as a **product requirement**,
> not an example-level fix, and it carries it generically: the answer must be
> **generic, multi-tenant, cloud-provider-supported images**, never a
> per-customer image and never a per-provider exception. `platform: external`
> exists to fit any provider; an OCI carve-out invites the next partner to ask
> for theirs.
>
> `OPENSHIFT_INSTALL_RHCOS_ARTIFACTS_JSON` is the agreed shape for the override
> that lets a provider name its own artifacts without an installer change.

Route A — import the published `qemu` QCOW2 and force
`ignition.platform.id=oraclecloud` — remains the right destination. The narrow
thing still unproven is *writing* that platform ID into an imported image: it
is normally baked in at build time by `coreos-installer install --platform`,
and OCI has no kernel-arguments field on a custom image. Details, the
measurement recipe and the artifact URL are in
[docs/boot-image.md](docs/boot-image.md).

### 2. The bootstrap ignition does not fit

OCI caps user data and other metadata at **32,000 bytes total**, about 23,900
raw once base64 inflation is accounted for. Master and worker ignition are
pointer configs of roughly 1.7 KiB and fit easily. The bootstrap ignition is
hundreds of KiB and does not.

Integrated platforms solve this inside the installer — GCP
(`pkg/infrastructure/gcp/clusterapi/clusterapi.go:158`), Azure
(`pkg/infrastructure/azure/azure.go:1119`) and IBM Cloud
(`pkg/infrastructure/ibmcloud/clusterapi/clusterapi.go:464`) all stage the
bootstrap ignition in their own object storage. CAPA solves it in the provider,
with `s3Bucket` plus `ignition.storageType: ClusterObjectStore`. **CAPOCI does
neither** — there is no object-storage field in `api/v1beta2/` and no
`objectstorage` client under `cloud/services/`.

`platform: external` structurally cannot adopt the installer-side answer: it
has no cloud credentials, by design.

The answer that needs no installer change: between `create ignition-configs`
and `create cluster`, upload `bootstrap.ign` to OCI Object Storage, mint a
pre-authenticated request, and overwrite the file on disk with a ~300-byte
pointer config. The installer reloads it, because `bootstrap.Bootstrap`
implements `Load()` and sits in the IgnitionConfigs target. This is the
ordinary UPI pattern. See [docs/ignition-delivery.md](docs/ignition-delivery.md)
— including why the pre-authenticated request URL is itself a credential and
must never be logged.

## The CAPOCI gap: one listener

CAPOCI's API-server load balancer serves exactly one port. Every port in both
reconcilers is `s.APIServerPort()` —
`cloud/scope/network_load_balancer_reconciler.go:55,72,187` and
`cloud/scope/load_balancer_reconciler.go:52,69,151,158` — and there is no
equivalent of CAPA's `controlPlaneLoadBalancer.additionalListeners`. OpenShift
masters fetch their real configuration from `api-int:22623`.

The `infraReady` hook adds a second listener out of band, and that was checked
rather than assumed: `IsNLBEqual` compares only the display name and the health
checker of the single `apiserver-lb-backendset` (`:301-320`), and `UpdateNLB`
sends only `DisplayName` plus that health checker (`:122-150`). The LBaaS path
is weaker still — `IsLBEqual` compares the display name alone (`:250-255`).
Neither enumerates or prunes listeners, so one added by the hook survives.

Backend population was the open question, and it is now settled by running it.
CAPOCI registers control-plane machines into `apiserver-lb-backendset` only
(`cloud/scope/machine.go:874-895`), so the hook populates the 22623 backend set
itself. The worry was timing: the masters want that port during their first
boot, which is before `postProvision` runs. **It is not a problem in practice**
— the masters retry the machine config server until it answers, and bootstrap
completed in 26 minutes on run 13. It remains a race the design does not
*prevent*, only survives, and [docs/capi-requirements.md](docs/capi-requirements.md)
§8 keeps it on the record as such.

The right long-term fix is upstream in CAPOCI: an `additionalListeners` field
on `apiServerLoadBalancer`, matching what CAPA already has.

## What the hooks do

The installer calls a user-supplied program at three points
(`pkg/infrastructure/clusterapi/clusterapi.go`): `InfraReady` at :312, after
the network exists and before any machine; `PostProvision` at :457, after the
machines; `PreDestroy` during teardown. There is no `preProvision` hook —
`pkg/types/external/platform.go`'s `Hooks` has only those three.

| Hook | Does |
| --- | --- |
| `infraReady` | adds the 22623 listener and an empty backend set; creates the api/api-int DNS; writes the CCM and CSI config Secrets |
| `postProvision` | populates the 22623 backend set; attaches the service-lb NSG to the ingress Service by OCID; publishes the `*.apps` wildcard once the ingress load balancer has an address |
| `preDestroy` | removes all of the above, plus the ingress load balancer by recorded OCID, plus the bootstrap ignition object and its pre-authenticated request |

Everything in that table is outside Cluster API's ownership, so deleting the
`Cluster` removes none of it. The standing rule on this pilot is that each
created resource ships with its teardown in the same change.

Two things in that table are the interesting ones, because neither could be
expressed in a manifest and both are generic rather than OCI-shaped:

- **The NSG attach.** The CCM attaches a network security group to the load
  balancer it builds only when the `Service` names that group **by OCID** —
  and the OCID is generated by CAPOCI minutes after the manifest was written.
  This is divergence 077's defect 1, *placement expressible only by OCID*,
  recurring in a second controller. It is the clearest single argument that a
  day-0 manifest set cannot be sufficient on a non-integrated provider, and
  that the hooks are load-bearing rather than convenient.
- **The ingress load balancer teardown.** It must go by an OCID captured at
  post-provision, because the CCM tags what it creates with **nothing**
  (`freeform-tags: {}`, measured on the live NLB) and the obvious name-based
  sweep matches CAPOCI's *API* load balancer instead. A CCM that tagged its
  resources would close this; that is an upstream ask.

The `postProvision` ordering was verified in code rather than assumed:
`pkg/infrastructure/external/clusterapi/postprovision.go:41`, called from
`pkg/infrastructure/clusterapi/clusterapi.go:449` once the control-plane
machines exist — after the cluster's own API is serving, and before
`wait-for bootstrap-complete`.

## The CCM config — the question the user raised

> *"their CCM config/secret requires the VCN ID, which exists only in
> InfraReady, so we may not be possible to inject it in initial ignitions, but
> can apply in infraready phase"*

Correct, and it turns out to be the **easiest** of the problems here, not the
hardest. The OCI CCM and CSI read two Secrets
(`oci-openshift/custom_manifests/manifests/01-oci-driver-configs.yml`) holding
four values between them:

| Field | Source | Day-0? |
| --- | --- | --- |
| `compartment` | user input | yes |
| `vcn` | CAPOCI | no |
| `loadBalancer.subnet1` | CAPOCI | no |
| `loadBalancer.securityLists.<subnet>` | CAPOCI | no |

The three unknowns are all readable at `infraReady` from
`$OPENSHIFT_INSTALL_INFRA_JSON` — the whole `OCICluster` object, handed to the
hook as JSON precisely so the installer never needs a CAPOCI type. Note they
are **spec** paths: CAPOCI writes the OCIDs of what it creates back into the
spec (`cloud/scope/vcn_reconciler.go:43,51`), and `OCIClusterStatus` has no
network block at all.

And **no credential is involved**. Both Secrets set
`useInstancePrincipals: true`; the in-cluster components authenticate as the
instance. No OCI API key ever reaches the installed cluster — a genuine
improvement on the AWS example, which ships CCM credentials as a day-0 Secret.
The API key CAPOCI itself uses lives only in the installer's temporary local
control plane and is destroyed with it.

> **Settled by running it: `infraReady` cannot write into
> `<install-dir>/openshift/`.** The installer has consumed and removed that
> tree by the time the hook fires, so the Secrets are `oc apply`-ed from
> `postProvision` against `$OPENSHIFT_INSTALL_KUBECONFIG`. The consequence
> predicted here was right — the CCM has no config until then — and the
> mitigation is that the DaemonSet ships as a day-0 manifest, so the gap is a
> DaemonSet waiting on a Secret rather than a cluster waiting on a DaemonSet.

> **Also measured, and it undercuts the "no credential" claim for now.** The
> target compartment had **zero dynamic groups**, so instance principals could
> not actually be used and the pilot fell back to an API key in the CCM
> config. The paragraph above describes the correct configuration; it is not
> yet what the pilot runs. A dynamic group cannot match a freeform tag
> (`oci-openshift/terraform-stacks/shared_modules/iam/dynamic_group.tf:5`), so
> switching to instance principals also means switching the machine manifests
> from `freeformTags` to `definedTags`
> (`api/v1beta2/ocimachine_types.go:133`) and creating a tag namespace. All of
> that is IAM, which this pilot does not touch.

## Before touching an Oracle account

1. **Build the image.** Fetch the QCOW2 the installer's own stream metadata
   names, write a usable `ignition.platform.id` into it, import it as a custom
   image, boot one instance and confirm `rpm -q ignition` is ≥ 2.22.0 on *that*
   build — the measurement above was taken on the release payload, which is
   newer than the stream artifact. The pilot used the **OpenStack** artifact
   and accepted the hostname cost; see the boxed note above and
   [docs/boot-image.md](docs/boot-image.md).
2. Build the CAPOCI artifacts and the shim — [scripts/README.md](scripts/README.md).
3. Create the private object storage bucket.
4. Set up the dynamic group and IAM policy for instance principals; the CCM
   needs them and nothing here creates them. **The pilot had none and fell back
   to an API key** — see the boxed note in the CCM section.
5. Paste the imported image's OCID into `OCI_IMAGE_ID`.
6. Run `run-create-command.sh <n> infra-only` first. It stops after
   `infraReady`, creating no machines, which exercises the DNS, the 22623
   listener and the CCM Secrets for the price of a VCN and a load balancer. If
   the hook is wrong, that is where it will show, cheaply.

## Reproducing it manually

`scripts/run-create-command.sh` is the whole thing in one command. What follows
is what it does, so the steps can be run by hand — which is the only way to
understand where the seams are.

```sh
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..…
export OCI_REGION=us-ashburn-1
export BASE_DOMAIN=example.com          # a zone you control, in OCI DNS
export OCI_IMAGE_ID=ocid1.image.oc1.…   # from step 1 above
export OCI_IGNITION_BUCKET=…            # private, created once, reused
export OCI_CREDENTIALS_FILE=…           # the OCIClusterIdentity Secret manifest
export OCI_CLI_CONFIG_FILE=…            # your oci CLI config
export PULL_SECRET_FILE=…               # passed by path, never read into a var
```

**Phase 1 — manifests, then substitution.**

```sh
./openshift-install create manifests --dir="${INSTALL_DIR}"
```

Read the infrastructure ID out of
`manifests/cluster-infrastructure-02-config.yml` — it is the cluster name plus
a five-character random suffix, and the `Cluster` object's name **must** match
it. Then substitute `CLUSTER_ID`, `COMPARTMENT_OCID`, `IMAGE_OCID`, `REGION_ID`
and `CLUSTER_DNS` through `external-install/` and copy the result into
`<install-dir>/external-install/`.

> The generated manifest tree is a credential store — it holds TLS and CA
> private keys, the pull secret and the kubeadmin password hash. Read it by
> filename, never by content. `grep -oE '^  infrastructureName: .*'` is safe
> because its output is bounded by the pattern; a range `sed` is not.

**Phase 2 — ignition, then the offload that has no AWS equivalent.**

```sh
./openshift-install create ignition-configs --dir="${INSTALL_DIR}"
```

`bootstrap.ign` is hundreds of KiB; OCI caps all instance metadata at 32,000
bytes. So upload it to the bucket, mint a pre-authenticated request over it,
and **overwrite `<install-dir>/bootstrap.ign` with a ~300-byte pointer config**
aimed at that URL. The installer reloads the file from disk, because
`bootstrap.Bootstrap` implements `Load()`
(`pkg/asset/ignition/bootstrap/bootstrap.go:39-41`) and sits in the
IgnitionConfigs target (`pkg/asset/targets/targets.go:56-64`). No installer
change.

> **That URL is a credential.** It grants unauthenticated read over every
> secret in `bootstrap.ign`. Never log it, never paste it, and redact it out of
> any serial-console output before reading it:
> `sed -E 's|https?://[^ ")]*|<URL-REDACTED>|g'`.

**Phase 3 — install.**

```sh
./openshift-install create cluster --dir="${INSTALL_DIR}"
```

The hooks fire inside this. Watch for the three points in the table above.

**Phase 4 — the hand-work run 13 still needed, and why it should not be
needed again.**

| What was done by hand | Why | Should now be automatic |
| --- | --- | --- |
| applied the CCM and CSI manifests | the bundles were multi-document, and only the first document of an extra manifest is applied | yes — they are one object per file now |
| approved four worker CSRs | no cloud-specific machine-approver on `platform: external` | **no — still manual.** `oc get csr -o name \| xargs -r oc adm certificate approve` |
| created the ingress `Service` | nothing asks the cloud for an external address | yes — `99_external-04-ingress-nlb.yaml` |
| added 80/443 to the node NSGs | the node-to-node hop OVN makes for `HostNetwork` routers | yes — in `external-install/cluster.yaml` |

**Teardown.** `scripts/run-destroy-command.sh`. It runs the `preDestroy` hook,
then `destroy cluster`, then independently re-checks that the bootstrap
ignition object and its pre-authenticated request are gone — a check rather
than a trust, because that URL outliving the cluster is the worst failure here.

Note that `destroy cluster` deliberately excludes Secrets from
`.clusterapi_output/` (`pkg/infrastructure/clusterapi/clusterapi.go:696-700`),
so the destroy path must put CAPOCI's credential Secret back before the
`OCICluster` finalizer can clear. The script does this.

## What is next

In the order a reader is most likely to care:

1. **Spend one clean run.** Everything below matters less than finding out
   whether the corrected files install a cluster unattended. That run has not
   been spent.
2. **The boot image, generically.** IMDSv2 support in the OpenShift components
   that read instance metadata, and a published artifact set per provider,
   with `OPENSHIFT_INSTALL_RHCOS_ARTIFACTS_JSON` as the override shape. This
   is the one remaining item that is a product change rather than an example
   change, and it is deliberately not solved with an OCI exception.
3. **Multi-document extra manifests.** One object per file is a workaround for
   `countManifestDocuments` (`pkg/asset/manifests/openshift.go:426`). Every
   partner bundle in the world is multi-document; this should be fixed in the
   installer or stated as a contract.
4. **Placement by name, not by OCID.** Two controllers now — CAPOCI's
   control-plane machine path and the OCI CCM — require an OCID that does not
   exist when the manifest is written. Both are upstream asks; both are the
   reason the hooks exist.
5. **CSR approval.** A webhook that compares a CSR against the instance it
   claims to come from would remove the last manual step. Every provider has
   this problem; nothing here is OCI-specific.
6. **`additionalListeners` upstream in CAPOCI**, matching CAPA, so the 22623
   listener stops being an out-of-band edit.
7. **Report `ghcr.io/nikhisin3001`** to `oracle-quickstart/oci-openshift`: upstream
   v1.34.0 ships its CCM image from an individual's personal namespace, and
   the digest differs from `ghcr.io/oracle/cloud-provider-oci:v1.34.0`. That
   is a substitution, not a rename.

## A note on this directory's name

The convention is `<cloud>-<capi-provider-short-name>`: `aws-capa`,
`oci-capoci`, and `azure-capz` if it ever exists. The request named this
`oracle-capoci`; the convention gives `oci-capoci`, matching the `oci` that
Oracle's own automation puts in `platform.external.platformName`
(`oci-openshift/terraform-stacks/shared_modules/manifest/locals.tf`) and the
`oci` the installer already uses in every CoreOS and cloud identifier.
**Reversible with one `git mv`** — say the word.
