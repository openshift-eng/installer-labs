# Machine manifests — the three-phase workflow

**Status: has run.** Written 2026-09-30 against `cluster-api-provider-oci`
with no OCI account available; corrected through 2026-10-01 over thirteen
runs, the last of which produced a complete cluster — five Ready nodes, 34/34
cluster operators Available. Every "Before the first run" item below has now
been hit at least once, and each is annotated with what actually happened.

## Why this directory exists at all

On an integrated platform the installer generates machine manifests itself —
`pkg/asset/machines/clusterapi.go` builds the `Machine` and infrastructure
machine objects from the install-config's `controlPlane` and `compute` pools.
For `platform: external` it generates nothing, by design: the installer has no
`OCIMachine` type and must never acquire one.

So the machines are supplied. These files are copied into
`<install-dir>/external-install/` before `create cluster`, the installer loads
them as unstructured objects and applies them to its local control plane, and
CAPOCI reconciles them into OCI instances.

| File | Objects | Required? |
| --- | --- | --- |
| `10_bootstrap.yaml` | 1 `Machine` + 1 `OCIMachine` | yes |
| `20_master.yaml` | 3 `Machine` + 3 `OCIMachine` | yes |
| `30_worker.yaml` | 2 `Machine` + 2 `OCIMachine` | no — delete for a compact cluster |

## The substitution contract

Every placeholder in this example is `UPPER_SNAKE_CASE`, the same convention the
`aws-capa` example uses. That spelling is deliberate: an underscore is **not**
legal in a Kubernetes object name or a DNS label, so a token that survives
substitution is rejected loudly by the API server or by CAPOCI instead of
quietly creating cloud resources literally named `CLUSTER_ID-vcn`.

`../../scripts/run-create-command.sh` rewrites all of them; nothing else does.
Three appear in this directory; five appear in `../cluster.yaml`.

| Token | Replaced with | Known when | Where |
| --- | --- | --- | --- |
| `CLUSTER_ID` | the run's infrastructure ID, e.g. `mrb-oci1-knzjv` | after `create manifests` — read from `metadata.json` | here and `../cluster.yaml` |
| `COMPARTMENT_OCID` | `$OCI_COMPARTMENT_ID` | before the run | here and `../cluster.yaml` |
| `IMAGE_OCID` | the imported RHCOS custom image OCID | before the run, once — see `../../docs/boot-image.md` | here only |
| `REGION_ID` | `$OCI_REGION`, e.g. `us-ashburn-1` | before the run | `../cluster.yaml` only |
| `CLUSTER_DNS` | `<cluster name>.<base domain>` | before the run | `../cluster.yaml` only |
| `VCN_DNS_LABEL` | the infrastructure ID reduced to ≤15 alphanumerics | derived from `CLUSTER_ID` | `../cluster.yaml` only |

The cluster **name** is a separate placeholder, `CHANGE-ME` in
`../../install-config.yaml`. It is hyphenated rather than `UPPER_SNAKE` because
it is a DNS-1123 field the installer validates directly, so an underscore there
would fail at `create install-config` before the example could be read.

`CLUSTER_ID` is the infrastructure ID, **not** the cluster name. The installer
appends a five-character random suffix at `create manifests` time, and the
`Cluster` object's name must match it or the `Machine` objects' `clusterName`
will not resolve.

There is deliberately **no token for a subnet or NSG OCID**, and nothing in
this directory needs rewriting after the network exists — which is why there is
no fourth phase. But the reason is not the one the schema suggests.

> **Correction, after a run destroyed a machine.** An earlier version of this
> paragraph said `OCIMachine.networkDetails` accepts `subnetName` and
> `nsgNames` alongside `subnetId` and `nsgIds`, so machines reference the
> network by name. The fields exist; **CAPOCI does not read them on the launch
> path.** Placement is decided by `IsControlPlane()` and the resource's *role*,
> and only the worker branch honours a name — and even then it reads the
> top-level `spec.subnetName`, not the `networkDetails` one.
>
> | path | subnet by name? | NSG by name? |
> | --- | --- | --- |
> | worker | yes, `spec.subnetName` (`machine.go:1075`) | yes, `nsgNames` (`machine.go:1091`) |
> | control-plane | **no** (`machine.go:1043`) | **no** (`machine.go:1052`) |
>
> So the OCIDs are genuinely not needed, but because **role-based defaulting
> lands on the right subnet by itself**, not because the names steer anything.
> This holds only while each role has exactly one subnet. A topology with two
> worker subnets cannot be expressed for control-plane machines at all.
> `10_bootstrap.yaml` carries the full account and the error it produced.

## The three phases

This is the part with no aws-capa equivalent. On AWS the whole install is
`create manifests` then `create cluster`, because CAPA uploads the oversized
bootstrap ignition to S3 itself (`s3Bucket` plus
`ignition.storageType: ClusterObjectStore`). **CAPOCI has no object-store
offload at all** — no object-storage field in `api/v1beta2/`, no `objectstorage`
client under `cloud/services/` — and OCI caps instance metadata at 32,000 bytes
total, which the bootstrap ignition exceeds by two orders of magnitude.

So the offload is done outside the installer, in the gap between two existing
commands:

```
  1. openshift-install create manifests
         → metadata.json exists; CLUSTER_ID is now known
  2. substitute tokens; copy this directory into <install-dir>/external-install/
  3. openshift-install create ignition-configs
         → bootstrap.ign (hundreds of KiB), master.ign, worker.ign (~1.7 KiB)
  4. upload bootstrap.ign to OCI Object Storage; mint a pre-authenticated
     request over it
  5. OVERWRITE <install-dir>/bootstrap.ign with a ~300-byte pointer config
     aimed at that URL
  6. openshift-install create cluster
         → the installer RELOADS bootstrap.ign from disk and publishes the
           stub as the bootstrap machine's ignition Secret
```

Step 5 works because `bootstrap.Bootstrap` is a `WritableAsset` that implements
`Load()` for `bootstrap.ign`
(`pkg/asset/ignition/bootstrap/bootstrap.go:10,18,39-41`) and sits in the
IgnitionConfigs target (`pkg/asset/targets/targets.go:56-64`). The installer
prefers what is on disk over what it would regenerate. **No installer change.**

Full reasoning, the pointer config's exact content, and the security properties
of a pre-authenticated request are in `../../docs/ignition-delivery.md`. Read
that before running step 4 — the URL is an unauthenticated credential over the
cluster's day-0 secrets and must never be logged.

## What creates the ignition Secrets

Not these files. The installer publishes exactly three Secrets into
`openshift-cluster-api-guests`, named `<infraID>-bootstrap`, `<infraID>-master`
and `<infraID>-worker`, from
`pkg/infrastructure/external/clusterapi/ignition.go`, after `InfraReady` and
before the machines are created (`pkg/infrastructure/clusterapi/clusterapi.go`
— `Ignition()` at :361, Secrets created at :372).

Ignition Secrets are **per role, not per machine**. The three master machines
share `CLUSTER_ID-master`; there is no per-machine variant and no way to ask for
one. CAPOCI reads whichever Secret the `Machine` names, verbatim:
`GetBootstrapData()` returns `secret.Data["value"]` unchanged
(`cloud/scope/machine.go:685-702`), then base64-encodes it into
`metadata["user_data"]` (`:353`). It has no opinion about the format — the
string "ignition" does not appear anywhere in CAPOCI's Go source, and unlike
CAPA there is no feature gate to enable.

One consequence worth knowing: `metadata["user_data"]` is **overwritten**, not
merged. A `metadata:` map on the `OCIMachine` is merged first (`:351`) and then
`user_data` is replaced, so there is no way to smuggle extra userdata past the
bootstrap Secret. That is why every machine here carries `metadata: {}`.

## Destroy coverage

The standing rule on this pilot is that every resource created ships with its
teardown in the same change. For this directory:

| Created | Removed by |
| --- | --- |
| the OCI instances | CAPOCI, on `Cluster` deletion — `destroy cluster` |
| the bootstrap ignition object and its pre-authenticated request | `../hooks/infra-hook.sh`, `pre-destroy` |
| the DNS records the hooks publish, and the ingress load balancer the CCM built | `../hooks/infra-hook.sh`, `pre-destroy` |
| the object storage bucket | **not** removed — reused across runs, created once |

The bucket is deliberately long-lived and deliberately private. Only the object
and the pre-authenticated request over it are per-cluster.

The ingress load balancer is in that table because `destroy cluster` does not
delete the `Service` that caused it, so the CCM never tears it down. It is
removed **by OCID recorded at post-provision**, which is not a stylistic
choice: the CCM tags its load balancer with nothing at all (`freeform-tags:
{}`, measured), and a name-contains sweep on the infra ID would match
`<infra-id>-apiserver` — CAPOCI's API load balancer — while never matching the
ingress one. See `../extra-manifests/99_external-04-ingress-nlb.yaml`.

## What each "before the first run" item turned out to be

Kept in the original order, with the outcome of thirteen runs against each.

1. **The boot image. Still the largest unresolved item, and the pilot's one
   real workaround.** No RHCOS image for OCI is published. The pilot boots the
   **OpenStack** QCOW2 with `ignition.platform.id=openstack`, imported as a
   custom image. It works, and it is not acceptable as a product answer:
   - it makes OCI consume another platform's artifact, which no partner can be
     asked to do and which no release process guarantees will keep working;
   - afterburn then queries an OpenStack metadata API that OCI does not serve,
     so **the node hostname is never set** — every node registers as
     `localhost.localdomain` and three masters contend for one `Node` object.
     That is the whole reason
     `../extra-manifests/99_external-01-oci-hostname-{master,worker}.yaml`
     exist.

   The underlying blocker is IMDSv2: OCI serves only v2, and the generic path
   needs OpenShift components that can speak it. The enhancement proposal
   carries this as a product requirement rather than an example-level fix,
   because the answer has to be **generic, multi-tenant images supported by the
   cloud provider** — not a per-customer image and not a per-provider
   exception. `OPENSHIFT_INSTALL_RHCOS_ARTIFACTS_JSON` is the shape the
   override should take. `../../docs/boot-image.md` has the measurements.

2. **22623 has no listener until the hook adds one — confirmed, and the hook
   handles it.** The out-of-band listener survives CAPOCI reconcile as
   predicted. The backends are populated in time; the masters' first boot
   reaches the machine config server. `../cluster.yaml` explains why CAPOCI
   cannot express it.

3. **Worker CSRs need manual approval — confirmed.** Four CSRs were approved by
   hand on run 13 before the workers went Ready. This is the same behaviour as
   every other provider without the machine-approver's cloud-specific checks,
   and it is deliberately **not** automated here: a webhook that compares a CSR
   against the instance it claims to come from is the right fix and is a
   separate piece of work. For now, approve them by hand:

   ```sh
   oc get csr -o name | xargs -r oc adm certificate approve
   ```

4. **The subnet CIDRs here are wider than CAPOCI's defaults — confirmed
   necessary.** The default control-plane subnet is a `/29`: five usable
   addresses for three masters plus bootstrap. `../cluster.yaml` widens it.

5. **New, found by running it: the node NSGs need 80 and 443 from inside the
   VCN.** Not a machine-manifest concern, but it stops the cluster at 29/34
   operators with every node Ready, so it belongs on this list.
   `../extra-manifests/99_external-04-ingress-nlb.yaml` has the mechanism and
   the measurement.
