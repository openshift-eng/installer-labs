# Machines for `platform: external`

The installer reads `<install-dir>/external-install/*.yaml` as infrastructure
objects and `<install-dir>/external-install/machines/*.yaml` as machines, both
non-recursively. Neither is generated: `pkg/asset/machines/clusterapi.go`
returns nil for this platform, so every file here is hand-written.

Current scope: **bootstrap and control plane, demonstrated; workers, written
but not yet run.**

- `10_bootstrap.yaml` — demonstrated on `mrb-ext9` (2026-09-30): instance
  Running, ignition fetched from the presigned S3 URL, installer reported
  "Control-plane machines are ready", then destroyed clean.
- `20_master.yaml` — three control-plane machines. **Demonstrated end to end on
  `mrb-ext12` (2026-09-30):** `Install complete!` in 40m56s, 34/34 cluster
  operators Available, console reachable over `*.apps`.
- `30_worker.yaml` — two workers. **Written, not yet exercised on a cluster.**

## Workers, and why they need a file here at all

**Corrected 2026-09-30.** This README used to say workers could not be written
because the generic ignition path creates only `<infraID>-bootstrap` and
`<infraID>-master` (`pkg/infrastructure/clusterapi/clusterapi.go:367-369`),
leaving a worker machine with no `dataSecretName` to point at. That was
accurate, and it is no longer the constraint: the External provider now
implements `IgnitionProvider` in
`pkg/infrastructure/external/clusterapi/ignition.go` and publishes a third
Secret, `<infraID>-worker`, built from the `worker.ign` pointer config the
installer already generates for every platform.

The rest of that note was wrong in a way worth stating plainly, because it
reasoned from the integrated platforms. It said workers are created after
install by machine-api "on every platform", so their absence here was
consistent rather than a gap. It is a gap. Machine-api creates them through a
cloud-specific actuator, and a non-integrated provider ships none — the
installer generates no MachineSets either
(`pkg/asset/machines/worker.go:807` is an empty case). So on this platform
nothing ever creates a worker, and without `30_worker.yaml` the cluster is
permanently capped at its control plane.

Two things follow that do not apply anywhere else, both covered in detail in
`30_worker.yaml`:

- These machines provision **before** bootstrap, because the wait at
  `pkg/infrastructure/clusterapi/clusterapi.go:405` does not filter on the
  control-plane label. A worker that fails to come up fails the install.
- Nothing reconciles them afterwards. There is no MachineSet, no scaling and
  no replacement of a failed node. **Day-2 compute for non-integrated
  providers remains unsolved**; day-0 Machines only remove the size cap.

## The provider's feature gates are part of its artifact set

`spec.s3Bucket` on the `AWSCluster`, and `spec.ignition` on the `AWSMachine`,
are both rejected by CAPA's validating webhook unless the controller runs with
`BootstrapFormatIgnition=true`. That is a **controller flag**, not a manifest
field, and the installer's provider-agnostic argument list
(`pkg/clusterapi/external.go:153-158`) does not include it.

It goes in `platform.external.clusterAPI.args` in the install-config, which is
appended verbatim to the controller command line. No installer change was
needed. The pilot passes the same string the integrated path hardcodes at
`pkg/clusterapi/system.go:199`.

The rejection is worth knowing by shape: it comes from the provider's own
admission webhook in the local control plane, before any cloud call, and it
names the gate.

## Why this tree is named by infrastructure ID, not by cluster name

`Machine.spec.bootstrap.dataSecretName` must be `<infraID>-bootstrap`. The
installer creates that Secret itself, in its local control plane, from
`IgnitionSecret(ign, clusterID.InfraID, role)`; nothing lets a user choose the
name. `destroy bootstrap` likewise deletes exactly `<infraID>-bootstrap`.

The infrastructure ID is `<metadata.name>-<5 random chars>`, generated during
asset resolution, so it cannot be known when these files are written. That
forces a two-phase workflow, which `run-create-command.sh` implements:

1. `openshift-install create manifests`
2. read `status.infrastructureName` out of
   `manifests/cluster-infrastructure-02-config.yml` (a generated, non-secret
   file) and substitute it into this tree
3. `openshift-install create cluster`

Editing between the two commands is safe precisely because `external-install/`
is *not* an asset load path — that is the reason it exists rather than reusing
`cluster-api/`, which the asset store would discard and which the installer
also uses to unpack the CAPI binaries.

Because the substitution has to happen anyway, the pilot now names the whole
CAPI tree by infrastructure ID rather than by cluster name. That retires a
known departure from the integrated manifests: the `kubernetes.io/cluster/<id>`
tags, the load balancer names and the subnet names now all agree with the
in-cluster `Infrastructure.status.infrastructureName`, which is what CCM and
machine-api match on.

**Open contract question for the enhancement:** should the External machine
contract require the partner to know the infrastructure ID, or should the
installer adapt to the naming in the user's own manifests? Today it is the
former, by accident rather than by decision.

## The substitution contract

| Token | Replaced with | Known when | Where |
| --- | --- | --- | --- |
| `CLUSTER_ID` | the run's infrastructure ID, e.g. `example-cluster-knzjv` | after `create manifests` | here and `../cluster.yaml` |
| `ami-REPLACE` | the RHCOS AMI for the region | before the run — `coreos print-stream-json` | here only |

`CLUSTER_ID` is the infrastructure ID, **not** the cluster name. The cluster
name is a separate placeholder, `CHANGE-ME` in `../../install-config.yaml`,
substituted in a different file at a different time.

Both examples use the same `UPPER_SNAKE_CASE` spelling for this token — see
`../../../oci-capoci/external-install/machines/README.md`. The underscore is
deliberate: it is not legal in a Kubernetes object name or a DNS label, so a
token that survives substitution is rejected loudly rather than quietly
creating cloud resources literally named `CLUSTER_ID-subnet-private`. The
cluster-name placeholder stays hyphenated because `metadata.name` is a
DNS-1123 field the installer validates directly.

## What a partner has to get right, and what they get for free

From the bootstrap manifest, the whole of the CAPA-side contract is:

| Needed | How it is expressed | Post-provisioning edit? |
| --- | --- | --- |
| Subnet | `subnet.filters` on `tag:Name` | No — a selector |
| Security groups | not referenced; CAPA picks them by role | No |
| API load balancers | not referenced; CAPA registers control-plane machines | No |
| VPC, route tables, AZ | not referenced | No |
| Control-plane role | `cluster.x-k8s.io/control-plane` label on the **core** Machine | No |
| AMI | literal `ami-…` | No, but must be supplied — `pkg/asset/rhcos/image.go` returns `""` for this platform |
| IAM instance profile | omitted; optional in CAPA | No |
| `dataSecretName` | `<infraID>-bootstrap` | **Yes** — the one genuine gap |

Only one value in a machine manifest cannot be written ahead of time, and it is
not a cloud resource identifier — it is a name the installer chose. Everything
that refers to provisioned infrastructure is expressible as a selector. That is
the result worth carrying into the provider contract.

## Destroy coverage

Per the standing rule, the resources this increment adds are listed with what
removes them:

| Resource | Removed by | Covered |
| --- | --- | --- |
| EC2 instance, root EBS volume | CAPA, on `AWSMachine` delete | via `destroy cluster` cascade |
| S3 bucket | CAPA `DeleteBucket`, on `AWSCluster` delete | via `destroy cluster` |
| bootstrap ignition object in that bucket | CAPA `deleteIgnitionBootstrapDataFromS3`, on `AWSMachine` delete | via `destroy cluster` cascade |
| NLB target-group membership | CAPA, on `AWSMachine` delete | via `destroy cluster` cascade |

**The ordering was the risk. It is now proven** — `mrb-ext9`, 2026-09-30.
Superseded text kept, because the reasoning is still the reasoning:

> "The bucket delete happens on `AWSCluster` delete; the object delete happens
>  on `AWSMachine` delete. `bestEffortDeleteObjects` is false, so if the
>  machine were not deleted first the bucket would still hold the ignition
>  object and the bucket delete would fail — leaking a bucket that contains
>  cluster secrets. [...] **this has never been exercised**, since every run so
>  far stopped at infrastructure."

`destroy cluster` deletes the core `Cluster`; the core CAPI cluster controller
deletes descendant Machines before the infrastructure cluster, which produces
exactly the right order. That depends on the restored `Machine` carrying the
`cluster.x-k8s.io/cluster-name` label the controller lists by — applied by a
defaulting webhook at create time and therefore present in the collected
artifact. On a cluster that had reached a running bootstrap instance, destroy
took 6m23s and the post-destroy census below came back zero on every line,
including the bucket.

Scope limit: one bootstrap machine, one zone. Three control-plane machines in
target groups, and workers, are still untested.

**What `20_master.yaml` adds, and what removes it.** Nothing in it is a new
*kind* of resource, which is the point — three more EC2 instances, three more
root volumes, three more target-group memberships, all of them CAPA-owned and
all removed by the same `AWSMachine` delete cascade already proven for
bootstrap. The control-plane machines create nothing outside CAPI ownership
and so add nothing for the pre-destroy hook to clean up; the hook's state file
still describes only DNS.

Two things about the teardown are genuinely untested and should be watched on
the first run with masters:

| Untested | Why it might differ from bootstrap |
| --- | --- |
| Deregistration from **two** load balancers | Masters are registered with both the internal and the secondary internet-facing NLB, and with the 22623 target group as well as 6443. Bootstrap proved one machine leaving one set of target groups. |
| Four machines deleting concurrently | The core cluster controller deletes descendant Machines before the infrastructure cluster; with four it is the slowest, not the first, that gates the `AWSCluster` delete — and the S3 bucket delete is behind that. |

The post-destroy census commands below are unchanged and still the check that
matters: they count instances and volumes by tag, so three extra machines
either show up or they do not.

After any destroy, check the bucket explicitly:

```sh
aws s3api list-buckets --query "Buckets[?starts_with(Name, 'openshift-bootstrap-data-')].Name"
aws ec2 describe-instances --filters Name=tag-key,Values=kubernetes.io/cluster/<infraID> \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
```

## DNS, and why it is a hook

Control-plane machines get a *pointer* ignition config aimed at
`https://api-int.<cluster>.<baseDomain>:22623/config/master`. On the integrated
AWS path, the Route 53 private zone and that `api-int` record are created by the
provider's `InfraReady` hook. Nothing in CAPI does this for us:
`Cluster.spec.controlPlaneEndpoint` carries **one** host, which CAPA fills with
the load balancer's own AWS DNS name, and there is no contract field for an
internal endpoint. `platform: external` cannot reach the installer's
`ClusterHosted`/`UserProvisionedDNS` path either, because
`ExternalPlatformStatus` has exactly one field.

Without the record, masters launch and reach `Running` — `checkMachineReady`
only wants a phase and an address — but never fetch their ignition. Bootstrap
is unaffected, because its config arrives by presigned S3 URL, so the install
looks healthy for about forty minutes and then fails at bootkube stage
`resolve-api-int-url`.

**This is now solved by a hook, not by installer code.** The install-config
names a program the installer runs once the infrastructure is ready:

```yaml
platform:
  external:
    clusterAPI:
      hooks:
        infraReady: hooks/infra-hook.sh
        preDestroy: hooks/infra-hook.sh
```

Paths are relative to `external-install/` and must stay inside it. The hook
receives the cluster identity in `OPENSHIFT_INSTALL_*` environment variables
and, crucially, the **provider's own infrastructure object serialised to JSON**
at `$OPENSHIFT_INSTALL_INFRA_JSON` — which is how it reaches
`.status.networkStatus.apiServerElb.dnsName` without the installer needing a Go
type for `AWSCluster`. Whatever it creates it records under
`$OPENSHIFT_INSTALL_STATE_DIR`, which survives to `destroy cluster`, where
`preDestroy` runs before the `Cluster` delete and removes exactly that.

See [../hooks/infra-hook.sh](../hooks/infra-hook.sh) for the reference
implementation and the full environment contract. It is AWS-specific on
purpose: the hook boundary is precisely where cloud-specific knowledge becomes
legitimate.

An install with no `infraReady` hook is warned about, not refused — DNS created
some other way ahead of time, as the existing CloudFormation-based External CI
does, is a supported mode.
