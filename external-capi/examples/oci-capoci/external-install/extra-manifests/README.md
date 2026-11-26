# extra-manifests — what a non-integrated provider has to ship by hand

**Status: has run, to a complete cluster.** Written 2026-09-30 against the
CAPOCI and oci-openshift clones with no OCI account; corrected 2026-10-01 after
the first run that booted machines, and again after run 13 reached **34/34
cluster operators Available with console and oauth answering from the
internet**. Four of this file's original claims were wrong and each is
corrected below rather than deleted — see "Corrections" at the end.

**Run 13 was salvaged by hand** (CCM/CSI applied manually, four CSRs approved
manually, the ingress Service and its NSG created manually). It is proof every
piece works. It is not proof the files in this directory produce it unaided —
no clean run on the corrected set has been spent.

Files in this directory are copied by the installer into the openshift manifest
directory (`pkg/asset/manifests/openshift.go`, `externalExtraManifests`),
collected by bootkube
(`data/data/bootstrap/files/usr/local/bin/bootkube.sh.template:78`), and applied
by cluster-bootstrap to the bootstrap control plane before it waits for the
required pods. That is the only moment at which a CCM is useful: it runs while
every node is still `NotReady` and carries
`node.cloudprovider.kubernetes.io/uninitialized`.

## What is here

| File(s) | Purpose | Run? |
| --- | --- | --- |
| `99_external-00-kubelet-providerid-{master,worker}.yaml` | sets `KUBELET_PROVIDERID=oci://<instance OCID>` before kubelet starts | yes, both |
| `99_external-01-oci-hostname-{master,worker}.yaml` | sets the node hostname from the OCI metadata service | yes, both |
| `99_external-02-oci-ccm-0{0..4}-*.yaml` (5 files) | the OCI cloud controller manager, namespace through DaemonSet | applied live; day-0 not yet proven |
| `99_external-03-oci-csi-{00..11}-*.yaml` (12 files) | the OCI CSI driver, block volume and FSS | applied live; day-0 not yet proven |
| `99_external-03-oci-csi-12-volumesnapshotclass-oci-snapshot.yaml.day2` | the one object that **cannot** be applied at day 0 | deliberately not applied |
| `99_external-04-ingress-nlb.yaml` | asks the CCM for an external load balancer for the ingress routers | applied by hand on run 13; day-0 not yet proven |

**One object per file, and that is not a style choice.** The CCM and CSI
bundles were originally two multi-document files. Only the **first** YAML
document of an extra manifest is ever applied — `countManifestDocuments` at
`pkg/asset/manifests/openshift.go:426` — so a 12-object bundle silently
delivered one object. See Correction 4. The split is mechanical and
reversible; `oci-ccm-csi-bundle.md` records the provenance of every file,
including each one's upstream SHA-256, so a re-copy from a newer Oracle
release is a diff rather than a judgement call.

The `.day2` suffix on the `VolumeSnapshotClass` is the same mechanism used
deliberately: `manifestFileExtensions` at `pkg/asset/manifests/openshift.go:453`
is `.yaml`, `.yml`, `.json`, so a file ending in anything else is copied but
never applied. Its CRD arrives with cluster-storage-operator, long after extra
manifests are applied. Apply it by hand once the cluster is up.

The `-00-` files are adapted from Oracle's
`oci-openshift/custom_manifests/butane/oci-kubelet-providerid-{master,worker}.bu`,
which is in production use for Agent-based OCI installs. The script is hardened
relative to Oracle's in two ways, both noted in the file: it retries the
metadata fetch and fails loudly on an empty OCID, and it creates the kubelet
drop-in directory if it does not exist.

The `-02-`/`-03-` files are **copied line-for-line** from
`oci-openshift/custom_manifests/oci-ccm-csi-drivers/v1.34.0/`, with the deltas
recorded in their headers alongside the upstream SHA-256. One of those deltas
is a supply-chain substitution, not a cosmetic one — read the header of
`99_external-02-oci-ccm-04-daemonset-oci-cloud-controller-manager.yaml` before
assuming the bundle is upstream-identical.

`99_external-04-ingress-nlb.yaml` is the only file here that is not adapted
from Oracle. It exists because `platform: external` gives the cluster no
external address for `*.apps` at all — see the next section.

## The three things a node needs, and none of them come free

An integrated platform gives a node its name, its provider ID and its cloud
controller without anyone thinking about it. On `platform: external` all three
are the example's problem, and the cluster fails differently for each:

| Missing | Symptom | Supplied by |
| --- | --- | --- |
| hostname | every node registers as `localhost.localdomain`; three masters contend for one Node object and the control plane never forms | `99_external-01-*` |
| provider ID | the CCM cannot match a Node to an instance; the node keeps its `uninitialized` taint | `99_external-00-*` |
| the CCM itself | nothing ever removes `node.cloudprovider.kubernetes.io/uninitialized`; every node stays `NotReady` | `99_external-02-*` |

The first of those was not understood until it was measured. See Correction 2.

## And the fourth thing, which is the cluster's not the node's: ingress

Ready nodes are not a finished cluster. Run 13 reached **29 of 34 operators
Available** with every node Ready, and stopped there: `authentication` and
`console` were both blocked on ingress, and nothing in this directory or in
`../cluster.yaml` was going to unblock them.

On `platform: external` the ingress operator selects
`endpointPublishingStrategy.type: HostNetwork`. The routers bind 80 and 443 on
the nodes, the only Service the operator creates is `router-internal-default`
(a ClusterIP), **nothing asks the cloud for an external address**, and so
nothing creates one. CAPOCI cannot supply it either — an `OCICluster` has
exactly one load balancer, the API server's, and no concept of a second.

So the cluster asks for its own, through the CCM the partner already had to
supply. That is `99_external-04-ingress-nlb.yaml`. Two things it deliberately
does **not** carry, and both are structural rather than oversights:

| Not in the file | Why | Where it is instead |
| --- | --- | --- |
| the NSG annotation | the CCM attaches an NSG only when the Service names it **by OCID**, and CAPOCI generates that OCID minutes after this file is written | `annotate_ingress_nsg` in `../hooks/infra-hook.sh`, at post-provision |
| the `*.apps` DNS records | the address does not exist until the CCM has built the load balancer | the same hook's post-provision step, told the Service by `--input-service=openshift-ingress/router-external-default` |

The NSG one is **divergence 077's defect 1 — placement expressible only by
OCID — recurring in a second controller**, and it is the generic reason a
day-0 manifest set is not sufficient on a non-integrated provider. It is worth
more attention than the ingress bug that surfaced it.

Two further traps, both measured, both now written into the files:

- **The two NSG rules that make it work are not here either.** They are on the
  control-plane and worker NSGs in `../cluster.yaml`, not on the load
  balancer's. Because the endpoints are *node* addresses, OVN balances a
  request arriving at node A to a router on node B, so node A opens a
  connection to node B's `:443`. CAPOCI's node NSGs open 30000-32767 but not
  80/443, so that hop was dropped — with the load balancer healthy, the
  Service correct and the routers serving. Both rules are sourced from the VCN
  CIDR, never `0.0.0.0/0`.
- **The annotation prefix differs between the two OCI load balancer
  services.** For an NLB it is
  `oci-network-load-balancer.oraclecloud.com/...` — note the doubled `oci-`.
  The LBaaS spelling is `oci.oraclecloud.com/...`. A wrong prefix is not
  rejected, not logged and not defaulted; the annotation is silently ignored
  and the only symptom is dropped traffic. Two plausible keys were guessed and
  both did nothing before the authoritative list was taken from the CCM binary
  itself:

  ```sh
  oc exec -n oci-cloud-controller-manager <pod> -- \
    grep -aoE 'oci[a-z0-9.-]*\.oraclecloud\.com/[a-zA-Z0-9_-]+' \
    /usr/local/bin/oci-cloud-controller-manager | sort -u
  ```

With all of that in place run 13 reached 34/34, with console and oauth
answering 200 from the internet. Divergence 078 has the full measurement.

### Teardown is this directory's problem too

`destroy cluster` deletes neither this Service nor the load balancer the CCM
built for it, so both outlive the cluster. The hook's `pre-destroy` path
removes it, and it has to work from an **OCID captured at post-provision**,
because neither of the two obvious handles exists:

- the CCM tags its load balancer with **nothing** — `freeform-tags: {}`,
  measured on the live NLB — so a tag sweep cannot find it;
- a name-contains sweep on the infra ID can never match it (the CCM names the
  LB `<ns>/<name>/<service-uid>`) but **does** match `<infra-id>-apiserver`,
  which is CAPOCI's API load balancer. The obvious repair deletes the wrong
  thing.

## The CCM config is still not here, and that part was always right

**The aws-capa example ships the CCM config as a day-0 manifest. This one
cannot, and that difference is the most instructive thing in this example.**

The OCI cloud controller manager and CSI driver read their configuration from
two Secrets:

| Secret | Namespace | Key |
| --- | --- | --- |
| `oci-cloud-controller-manager` | `oci-cloud-controller-manager` | `cloud-provider.yaml` |
| `oci-volume-provisioner` | `oci-csi` | `config.yaml` |

Both contain the same four values:

| Field | Source | Known at `create manifests` time? |
| --- | --- | --- |
| `compartment` | user input | **yes** |
| `vcn` | the VCN CAPOCI creates | **no** |
| `loadBalancer.subnet1` | the service-lb subnet CAPOCI creates | **no** |
| `loadBalancer.securityLists.<subnet>` | that subnet's security list | **no** |

Three of the four do not exist until CAPI has built the network, which happens
after manifests are rendered. So there is no day-0 manifest that could carry
them, and writing one with placeholders would produce a CCM that starts, fails
to find its VCN and crash-loops.

**`../hooks/infra-hook.sh` writes both Secrets instead**, reading the OCIDs out
of `$OPENSHIFT_INSTALL_INFRA_JSON`:

```
.spec.networkSpec.vcn.id
.spec.networkSpec.vcn.subnets[] | select(.role=="service-lb") | .id
.spec.networkSpec.vcn.subnets[] | select(.role=="service-lb") | .securityList.id
```

Those are in the **spec**, not the status, because CAPOCI writes the OCIDs of
what it creates back into the spec — `cloud/scope/vcn_reconciler.go:43,51` for
the VCN and `cloud/scope/subnet_reconciler.go` (`desiredSubnet.ID = subnet.Id`)
for subnets and their security lists. `OCIClusterStatus` has no network block at
all (`api/v1beta2/ocicluster_types.go:85-95`), so anyone looking for the
`AWSCluster.status.network` equivalent will not find one.

**This is the deployment/config split that defines the example.** The
deployments are day-0 because they need nothing unknown and are needed early;
the config is hook-applied because it cannot exist until CAPI has run. A
partner bundle that assumes both halves ship together will not work here.

### There are no credentials in either Secret

Both set `useInstancePrincipals: true`. The in-cluster OCI components
authenticate as the instance, through a dynamic group and an IAM policy created
out of band. **No OCI API key reaches the installed cluster.** That is a real
advantage over the AWS example, which ships
`99_external-01-ccm-credentials.yaml`.

> **Caveat measured 2026-10-01.** The target compartment had **zero dynamic
> groups**, so instance principals could not actually be used and the pilot
> fell back to an API key in the CCM config. The statement above describes the
> intended and correct configuration; it is not yet what the pilot runs. A
> dynamic group cannot match a freeform tag
> (`oci-openshift/terraform-stacks/shared_modules/iam/dynamic_group.tf:5`), so
> switching to instance principals also means switching the machine manifests
> from `freeformTags` to `definedTags`
> (`api/v1beta2/ocimachine_types.go:133`) and creating a tag namespace. All of
> that is IAM, which this pilot does not touch.

The OCI API key that CAPOCI itself uses is a different thing entirely: it lives
only in the installer's temporary local control plane and is never delivered
anywhere. See `../cluster.yaml`.

## Corrections

Kept visible rather than edited away, because each one cost a run.

**Correction 1 — "Can the `infraReady` hook still write into
`<install-dir>/openshift/`?"** This was listed as an open question that "one
experiment settles and it costs nothing". The experiment was run. **It cannot.**
The installer has consumed and removed that tree by the time `infraReady`
fires, so the Secrets are `oc apply`-ed from `postProvision` against
`$OPENSHIFT_INSTALL_KUBECONFIG`. The consequence predicted here was right: the
CCM has no config until then. The mitigation is that the DaemonSet now exists
from day 0, so the gap is a DaemonSet waiting on a Secret rather than a cluster
waiting on a DaemonSet.

**Correction 2 — "Does the node name match the OCI instance display name?"**
This was framed as a nicety: "with `providerID` set explicitly the CCM should
not need a name match — but 'should not' is not 'does not'." The framing was
wrong in a way the hedge did not cover. The question is not whether the CCM
matches names; it is that **there is no name at all**. With
`ignition.platform.id=openstack`, afterburn queries an OpenStack metadata API
that OCI does not serve, so the hostname is never set:

```
NAME                    STATUS     ROLES                  AGE   VERSION
localhost.localdomain   NotReady   control-plane,master   88s   v1.36.3
```

Three masters cannot share one Node object. This is a hard blocker, not a
lookup detail, and it is why `99_external-01-oci-hostname-*.yaml` now exists.

**Correction 3 — "The CCM deployment itself ... not shipped here either, and
that is a scope decision rather than a technical constraint ... copy them in
when the pilot gets far enough to need a Ready node."** The reasoning given was
that "shipping a twelve-manifest bundle that nobody has executed would overstate
how much of this is understood". Defensible at the time, but the cost landed on
a later run as a misleading error: the hook's Secret apply failed with
`namespaces "oci-cloud-controller-manager" not found`, which reads as a hook
bug and is not one. The bundle is now shipped, minus the one object that
genuinely cannot be applied at day 0.

**Correction 4 — the bundle was shipped as two multi-document files, and
eleven of its twelve objects were silently discarded.** The CCM bundle was
written as one file holding namespace, ServiceAccount, ClusterRole,
ClusterRoleBinding and DaemonSet; the CSI bundle likewise. Both are valid
multi-document YAML and both parse cleanly. **The installer applies only the
first document of an extra manifest** — `countManifestDocuments` at
`pkg/asset/manifests/openshift.go:426` — so what reached the cluster was a
namespace and nothing else. Nothing warns. The failure then presents as the
CCM never starting, which looks like a CCM problem.

This is a property of `platform: external`'s extra-manifest mechanism, not of
OCI, and every partner bundle hits it: upstream Kubernetes components are
published as multi-document YAML almost without exception. The files here are
now one object each (`oci-ccm-csi-bundle.md` records the split), but the
mechanism is worth raising rather than working around for ever.

## Still open

1. **The partner-manifest supply chain.** These files pull from `ghcr.io` and
   `registry.k8s.io`. Neither is in the release payload, neither is covered by
   any ImageContentSourcePolicy the installer generates, and nothing verifies
   either. A disconnected install of this example fails at image pull. See the
   header of `99_external-02-oci-ccm-04-daemonset-oci-cloud-controller-manager.yaml`
   for the concrete instance — upstream v1.34.0 shipped its CCM from an
   individual's personal namespace and nothing caught it.
2. **Day-0 versus day-1 sequencing.** `VolumeSnapshotClass` ships as
   `...-12-volumesnapshotclass-oci-snapshot.yaml.day2` because its CRD arrives
   with cluster-storage-operator, long after extra manifests are applied.
   `platform: external` offers no way to express "apply this once that CRD
   exists", so the partner has to split their own bundle by hand and apply the
   remainder themselves. The `.day2` suffix is a convention invented here, not
   an installer feature — the installer simply ignores the file because its
   extension is not in `manifestFileExtensions`.
3. **Only the first document of an extra manifest is applied.** See Correction
   4. One object per file is a workaround; the generic fix belongs in the
   installer or in a documented partner-bundle contract.
4. **Which CCM version tracks which OpenShift release.** v1.34.0 was chosen as
   the newest in Oracle's tree. Nothing in this example checks that choice
   against the cluster's Kubernetes version, and nothing would catch a skew.
5. **The ingress load balancer has no handle but an OCID.** The CCM tags it
   with nothing, so teardown depends on the hook having recorded its OCID at
   post-provision. If post-provision never ran — a failed install, a run
   abandoned mid-flight — the load balancer is orphaned and has to be found by
   hand. A CCM that tagged what it created would close this; that is an
   upstream ask, not something this example can fix.
6. **None of this has been proven day 0.** Every file here has been applied to
   a live cluster and works. No clean `create cluster` has yet run with the
   corrected set in place, so "applied live" in the table above is exactly what
   it says.
