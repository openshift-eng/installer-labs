# `platform: external` with a Cluster API infrastructure provider

This directory holds the supporting material for installing OpenShift on
`platform: external` where infrastructure is provisioned by a **partner-supplied Cluster API
infrastructure provider** rather than by in-tree installer code.

It is the output of a pilot, not a supported product path. Read
[docs/limitations.md](docs/limitations.md) before you plan work against it.

## What this changes

Today a partner bringing a new cloud to OpenShift has two options, and both are unsatisfying:

- **Write an in-tree installer provider.** Hundreds of files, an OWNERS review, a release
  cadence tied to OpenShift's, and a permanent maintenance obligation on the installer team.
- **Use `platform: external` as it stands.** The installer provisions nothing. The partner
  scripts the whole infrastructure themselves, runs `create manifests`, edits, runs
  `create ignition-configs`, and glues the rest together outside the installer.

This work is a third option: `openshift-install create cluster` drives the partner's **own**
CAPI provider — its controller binary and its CRDs — through fixed hook points, and tears the
same infrastructure down again with `destroy cluster`. **No cloud-specific code enters the
installer.**

AWS and the Cluster API Provider AWS (CAPA) are used here as a **reference provider**: a
known-good CAPI provider to exercise the mechanism against. Nothing in
[examples/aws-capa/](examples/aws-capa/) is installer AWS integration code, and none of the
installer's existing `platform: aws` behaviour is involved or changed.

## Layout

| Path | What it is |
| --- | --- |
| [docs/](docs/) | the supporting documents, written to be attachable to the onboarding guide |
| [examples/aws-capa/](examples/aws-capa/) | a complete, runnable sample: install-config, CAPI manifests, extra manifests, a reference hook and the driver scripts |
| [examples/oci-capoci/](examples/oci-capoci/) | the same structure for OCI and CAPOCI, **never executed** — a feasibility study with a working skeleton, plus the clearest statement of what a CAPI provider must supply |

### Documents

| Document | Read it when |
| --- | --- |
| [docs/index.md](docs/index.md) | you want the overview and the mental model |
| [docs/installing.md](docs/installing.md) | you want to run the pilot end to end |
| [docs/manifest-contract.md](docs/manifest-contract.md) | you are writing the manifests the installer will consume |
| [docs/hooks.md](docs/hooks.md) | you are writing the hook programs |
| [docs/limitations.md](docs/limitations.md) | **before committing to this path** |

### Example naming convention

Examples are named `<cloud>-<capi-provider-short-name>`:

| Directory | Cloud | Provider |
| --- | --- | --- |
| `aws-capa` | AWS | [Cluster API Provider AWS](https://github.com/kubernetes-sigs/cluster-api-provider-aws) |
| `oci-capoci` | OCI | [Cluster API Provider OCI](https://github.com/oracle/cluster-api-provider-oci) |
| `azure-capz` *(not yet written)* | Azure | Cluster API Provider Azure |

Cloud first, because that is what a partner searches for and it matches the sibling
`upi/aws`, `upi/gcp` directories. The provider suffix is always present, even where a cloud
has only one known provider, because **the provider is the thing that actually varies** — it
names the controller binary you must build and the CRDs the sample depends on. A rule with no
exceptions is easier to follow than one with a special case.

## Status

The pilot has installed and destroyed clusters end to end. What works, what does not, and
what has never been exercised are all stated in [docs/limitations.md](docs/limitations.md)
rather than implied here.
