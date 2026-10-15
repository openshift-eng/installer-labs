# The hook contract

A hook is a program the installer execs at a point in the flow where an integrated platform
would run its own code. It is the seam that lets a partner automate what Cluster API does not
cover, **without the installer gaining any knowledge of their cloud**.

Citations are against `openshift/installer` at commit `6e028d5597`, in
`pkg/types/external/platform.go`.

## Why hooks exist at all: DNS

Cluster API has no contract for DNS. The core `Cluster` carries a single
`spec.controlPlaneEndpoint` and **there is no field for an internal endpoint at all**.

But OpenShift needs both. A control-plane machine's pointer Ignition aims at
`https://api-int.<clusterDomain>:22623/config/master`, and the bootstrap node's own
kubeconfig targets `https://api-int.<clusterDomain>:6443`. Without the `api-int` record the
bootstrap node fails at its `resolve-api-int-url` stage and the install dies after the full
bootstrap timeout.

On an integrated platform the installer creates those records itself — for AWS at
`pkg/infrastructure/aws/clusterapi/aws.go:112`. On `platform: external` it cannot, and must
not grow the ability. So something else has to, and the hook is where that something lives.

## The three hooks

All three are optional. Leaving one unset is a **supported configuration** — the records may
be created out of band, which is what the existing non-CAPI External CI does with
CloudFormation. An absent hook is a warning naming the consequence, never an error.

| Hook | When | What it is for |
| --- | --- | --- |
| `infraReady` | once `Cluster.status.infrastructureReady` is true — after the network and load balancers exist, before any machine is created | **DNS.** The first moment the load balancer addresses exist, and the last moment DNS can be created in time for the bootstrap node to use it. |
| `postProvision` | after the control-plane machines are created, after the cluster's API has begun serving, before the installer waits for bootstrap to complete | Things that can only be named once the cluster is building them. The motivating case is `*.apps`. |
| `preDestroy` | during `destroy cluster`, after the local control plane is restored and **before** the `Cluster` is deleted | Removing what the other two created, which Cluster API cannot see. |

### Why `*.apps` is in `postProvision` and not `infraReady`

This is structural, not a matter of ordering. At `infraReady` nothing exists but what the
infrastructure provider built, and **the provider does not build an ingress load balancer for
anyone** — CAPA's `reconcileLBAttachment` returns early for anything that is not a
control-plane machine. On this platform the ingress load balancer is created by the
*cluster's own cloud controller manager*, in response to a `Service` the cluster applies to
itself. That cannot have happened before the cluster exists.

### Why `preDestroy` runs *before* the delete

A DNS alias record is described in terms of the load balancer it points at, so it is cheaper
to remove while that load balancer still exists.

## The input contract

The installer **execs the program directly, without a shell**. Working directory is the
install directory.

### Environment — the half the installer owns

Every hook gets the same set:

| Variable | Value |
| --- | --- |
| `OPENSHIFT_INSTALL_HOOK` | `infra-ready`, `post-provision` or `pre-destroy` |
| `OPENSHIFT_INSTALL_INFRA_ID` | the infrastructure ID |
| `OPENSHIFT_INSTALL_CLUSTER_NAME` | the cluster name |
| `OPENSHIFT_INSTALL_BASE_DOMAIN` | the base domain |
| `OPENSHIFT_INSTALL_CLUSTER_DOMAIN` | `<cluster name>.<base domain>` |
| `OPENSHIFT_INSTALL_PUBLISH` | `External` or `Internal` |
| `OPENSHIFT_INSTALL_DIR` | the install directory |
| `OPENSHIFT_INSTALL_MANIFEST_DIR` | `<install dir>/external-install` |
| `OPENSHIFT_INSTALL_STATE_DIR` | writable; what `infra-ready` records here is what `pre-destroy` reads |
| `OPENSHIFT_INSTALL_CLUSTER_JSON` | **path** of a file holding the core CAPI `Cluster` object as JSON |
| `OPENSHIFT_INSTALL_INFRA_JSON` | **path** of a file holding the provider's infrastructure object as JSON, verbatim from the local control plane — **unset if there is not exactly one** |
| `OPENSHIFT_INSTALL_KUBECONFIG` | the installed cluster's admin kubeconfig |

**The two `_JSON` variables carry a path, not a document.** The installer writes each object
to a file in a per-hook temporary directory and exports that file's path
(`pkg/infrastructure/external/hooks/hooks.go:200-216`). Read them as files:

```sh
jq -r '.spec.compartmentId' "${OPENSHIFT_INSTALL_INFRA_JSON}"
```

Piping the variable's own *value* into `jq` hands it a pathname and fails with
`jq: parse error: Invalid numeric literal at EOF at line 1, column <len+1>`. That is not a
hypothetical: this table previously read "the object, as JSON", and the `oci-capoci` hook was
written from it and did exactly that — the error surfaced as a missing `.spec.compartmentId`
rather than as a misread variable, which cost a cloud run to diagnose. The temporary
directory is removed when the hook returns, so copy anything that must outlive it into
`OPENSHIFT_INSTALL_STATE_DIR`.

Two deserve comment.

**`OPENSHIFT_INSTALL_INFRA_JSON` is the whole mechanism.** The installer cannot read
`status.networkStatus.apiServerElb.dnsName` off an `AWSCluster`, because it has no
`AWSCluster` type and must not acquire one. It *can* copy the object out of its local control
plane as JSON and let the hook dig. Every field the reference hook reads is CAPA's schema,
not the installer's.

**`OPENSHIFT_INSTALL_KUBECONFIG` is set for every hook and usable by none** until the
cluster's API is serving — which at `infra-ready` it is not, and at `post-provision` it is.

### Arguments — the half the partner owns

`platform.external.hooks.<hook>.args` is passed as argv, in order and verbatim. The installer
does not parse, expand, template or interpret any of it.

The split is deliberate and is about **who owns the contract**. The installer's own inputs —
cluster identity, install directory, the CAPI objects — are environment, because they are the
same for every hook and the installer knows what they mean. Everything specific to one
partner's automation is argv, because the installer does not know what it means and should
not have to.

Prefer **long flags with an explicit value** over positional arguments: a hook is a script
today and may be a compiled binary tomorrow, and a flag survives that change where a position
does not. It also means `--input-dns-zone Z123` can be copied out of the installer log and
rerun by hand, which is what makes a failed hook debuggable.

> **`args` are written to the installer log and recorded in `metadata.json`** so that
> `destroy cluster` can run the teardown half of the same automation.
> **Do not put a credential in one.**

`Hook.Program` is a path **relative to `external-install/`, and must stay inside it**. The
install directory is the unit a user copies, archives and hands to someone else; a hook
reaching outside it would run something that did not travel with it.

## The output contract

**Exit 0 is success. Any other exit is failure, and the installer aborts.**

Everything written to stdout and stderr is streamed to the installer log as it arrives,
prefixed with the hook kind. On failure the last few lines the program wrote are quoted in
the installer's own error — so **the last thing said before exiting should be the reason**.

## Hazard: a hook that exits 0 is not a hook that worked

This is the sharpest edge in the contract, and it was found the expensive way.

A teardown run **leaked a `*.apps` DNS record while reporting complete success**. Route 53
stores a wildcard label octal-escaped: a record created as `*.apps.x.` is returned as
`\052.apps.x.`. Creation accepts either spelling, so the asymmetry is invisible until
something reads the record back. The hook's exact-match filter never fired, it took its
"nothing to do" branch, and the hook, the destroy and the exit code were all successful.

Three generalisations, none of them AWS-specific:

1. **"Already gone" and "I failed to recognise it" are the same code path, and the second one
   exits 0.** A cleanup hook that cannot find a resource must not be assumed idempotent.
2. **Anything exiting 0 is trusted completely.** The installer's contract is exit status,
   which is the right contract — but it means the only check on a hook's teardown is the
   hook's own belief that it is done. **There is no post-destroy census in the product.**
3. **The leak is silent and cumulative**, which is exactly what fills a shared public DNS
   zone over dozens of CI runs.

The mitigation lives in the hook's design — **verify after delete**, or delete by a filter
that cannot silently match nothing — and in nothing the installer can add. Route 53 escaping
is cloud-specific, the hook boundary is where cloud-specific knowledge becomes legitimate,
and an installer that learned about octal escaping would re-acquire the coupling this
platform exists to remove.

## Practical guidance

- **Budget twenty minutes for a hook timeout, not ten.** Observed `postProvision` runtimes on
  the pilot were 9m40s and 14m38s. Both are the same shape — waiting for the cluster's CCM to
  create the ingress load balancer — but the spread is wide.
- **Record what you create in `OPENSHIFT_INSTALL_STATE_DIR`.** It is the only link between
  the create and destroy halves of your automation. The rule on this pilot is that each new
  resource ships with its teardown in the same change.
- **A hook exiting non-zero aborts the install.** This path has not yet been exercised on a
  real run; treat it as specified-but-untested.

## Reference implementation

[../examples/aws-capa/external-install/hooks/infra-hook.sh](../examples/aws-capa/external-install/hooks/infra-hook.sh)
implements all three phases for AWS, with the reasoning inline. It is a **reference**, not
installer code — an OCI or other partner writes their own.
