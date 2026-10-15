# Installing on `platform: external` with a Cluster API provider

## The problem

`platform: external` exists so that a cloud OpenShift does not integrate with can still run
it. It tells the cluster "there is a cloud here, but the OpenShift components should not try
to talk to it" — the Cloud Controller Manager comes from the partner, the Machine API is
switched off, and the installer provisions nothing.

That last part is the cost. The partner must stand up the network, the load balancers, DNS
and the machines themselves, around an installer that will only hand them Ignition configs.
In practice this means a bespoke harness per partner, and an install that is a sequence of
`create manifests` → edit → `create ignition-configs` → run-your-own-automation.

Meanwhile every partner already has, or wants, a **Cluster API infrastructure provider** —
that is the direction the ecosystem has gone, and the onboarding guide asks for one anyway.
And the installer already runs Cluster API internally: it starts a local control plane and
drives integrated platforms through CAPI controllers it was compiled against.

So the gap is narrow and specific: **the installer can run a CAPI provider, but only one it
was compiled against.**

## The idea

Let the installer run a CAPI provider it was *not* compiled against.

The partner supplies, by path in the install-config:

- a **controller binary** for their infrastructure provider, and
- its **CRDs and component manifests**.

The installer starts that binary against its own local control plane, applies the partner's
`Cluster` and infrastructure custom resources, waits for `Cluster.status.infrastructureReady`
the same way it does for any integrated platform, and carries on with bootstrap. At teardown
it starts the same provider again and deletes what it created.

Where the installer would normally need to know something cloud-specific — create the DNS
records, publish the API endpoint — it instead **execs a program the partner supplied**.

```
install-config.yaml           platform.external.clusterAPI -> binary + components
                              platform.external.hooks      -> programs to exec

<install-dir>/
  external-install/
    cluster.yaml              Cluster + infrastructure CR   (partner-authored)
    machines/                 Machine + infra Machine CRs   (partner-authored)
    extra-manifests/          day-0 cluster objects: CCM, MachineConfig, ...
    hooks/                    the programs the installer execs
```

## Two things this is not

**It is not an AWS integration.** The sample uses the Cluster API Provider AWS because it is
a mature, known-good CAPI provider to test the mechanism against. No AWS-specific code is
added to the installer, and the installer's existing `platform: aws` path is untouched and
unaffected. Everything AWS-shaped in the sample lives in partner-authored manifests and
hooks — exactly where a partner's own cloud-specific knowledge would live.

**It is not a replacement for integration.** A fully integrated platform gets Machine API,
day-2 machine management, automatic certificate approval and in-tree validation. This path
gets none of those. See [limitations.md](limitations.md).

## The flow, and where the partner's code runs

| Stage | Who does it |
| --- | --- |
| Asset generation, Ignition, manifests | installer |
| Start the local CAPI control plane | installer |
| Install the partner's CRDs, start the partner's controller | installer, from the paths in install-config |
| Create network, load balancers, security groups | **partner's CAPI provider** |
| `Cluster.status.infrastructureReady` | **partner's CAPI provider** sets it; installer waits on it |
| DNS records, publishing the API endpoint | **partner's `infraReady` hook** |
| Create bootstrap and control-plane machines | **partner's CAPI provider**, from partner-authored `Machine` manifests |
| Bootstrap, control plane comes up, operators roll out | installer and OpenShift |
| Anything the cloud needs after the cluster exists | **partner's `postProvision` hook** |
| Delete the machines and the infrastructure | **partner's CAPI provider** |
| Delete what CAPI cannot see — DNS, and anything created by a hook | **partner's `preDestroy` hook** |

The two seams are the **CAPI provider** and the **hooks**, and they are the only places
cloud-specific knowledge is allowed to exist.

## Where to go next

- To run it: [installing.md](installing.md)
- To write the manifests: [manifest-contract.md](manifest-contract.md)
- To write the hooks: [hooks.md](hooks.md)
- Before committing to it: [limitations.md](limitations.md)
