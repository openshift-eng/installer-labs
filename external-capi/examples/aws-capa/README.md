# `aws-capa` — AWS via Cluster API Provider AWS

A complete, runnable `platform: external` install driven by
[CAPA](https://github.com/kubernetes-sigs/cluster-api-provider-aws) as the **reference
provider**.

**None of this is installer AWS integration code.** AWS is used here because CAPA is a
mature, known-good CAPI provider to exercise the mechanism against. Everything AWS-shaped
below lives in partner-authored manifests, hooks and scripts — exactly where a partner's own
cloud-specific knowledge belongs. The installer's `platform: aws` path is untouched and
uninvolved.

Start with [../../docs/installing.md](../../docs/installing.md) for the walkthrough and
[../../docs/limitations.md](../../docs/limitations.md) for what does not work.

## Contents

```
install-config.yaml                  the clusterAPI + hooks stanza, secrets blanked
external-install/
  cluster.yaml                       Cluster + AWSClusterControllerIdentity + AWSCluster
  machines/
    10_bootstrap.yaml                Machine + AWSMachine
    20_master.yaml                   3x Machine + AWSMachine
    30_worker.yaml                   2x Machine + AWSMachine  (day-0 workers)
    README.md                        the machine contract, in depth
  extra-manifests/                   day-0 cluster objects, ONE OBJECT PER FILE
    99_external-00-kubelet-providerid-master.yaml
    99_external-00-kubelet-providerid-worker.yaml
    99_external-01-ccm-credentials.yaml      credentials: "" placeholder
    99_external-02-ccm-aws.yaml              the AWS cloud controller manager
    99_external-03-ingress-nlb.yaml          the Service postProvision waits for
  hooks/
    infra-hook.sh                    reference infraReady/postProvision/preDestroy hook
scripts/
  run-create-command.sh              the two-phase create, with placeholder assertions
  run-destroy-command.sh             the teardown counterpart
  prepare-ccm.sh                     resolves the CCM image and injects its credentials
  safe-log.sh                        reads installer logs without emitting secrets
```

[`external-install/machines/README.md`](external-install/machines/README.md) and the header
of [`external-install/hooks/infra-hook.sh`](external-install/hooks/infra-hook.sh) are the two
most detailed documents here. Both explain *why*, not just *what*.

## Secrets

Nothing in this directory contains a credential, and it must stay that way.

| File | State |
| --- | --- |
| `install-config.yaml` | `pullSecret: ""` and `sshKey: ""` — both blanked |
| `extra-manifests/99_external-01-ccm-credentials.yaml` | `credentials: ""` placeholder |
| every script and the hook | reference secrets **by path or env var only** |

`scripts/run-create-command.sh` copies the whole tree into a per-run `install-dir-*/` and
injects the pull secret and cloud credentials into **that copy only**. The source tree is
never mutated, which is what makes it safe to version.

The design rule, and why it exists, is in
[../../docs/installing.md](../../docs/installing.md#handling-secrets).

## ⚠ Before this is published: values to generalise

The scripts and install-config are **copied verbatim from a working pilot environment** so
that the automation keeps working. They carry values specific to that environment which must
be parameterised before this ships to partners. None is a secret; all are wrong for anyone
else.

| File | Line | Value | Should become |
| --- | --- | --- | --- |
| ~~`install-config.yaml`~~ | ~~3~~ | ~~`name: mrb-ext0`~~ | **done** — now `CHANGE-ME`, matching `oci-capoci` |
| `install-config.yaml` | 4 | `baseDomain: splat.devcluster.openshift.com` | `<your base domain>` |
| `install-config.yaml` | 11–12 | `/tmp/capa-artifacts/...` | fine as a documented default; call it out |
| `install-config.yaml` | 41 | `--input-dns-zone=Z00517…` | `<your public hosted zone id>` |
| `install-config.yaml` | 63 | `compute[0].replicas: 0` | decide: compact by default, or 2 day-0 workers |
| `run-create-command.sh` | 33 | `CLUSTER_NAME=mrb-ext${VERSION}` | take a cluster name, not a personal version counter |
| `run-create-command.sh` | 68 | default `${HOME}/.aws/pull-secret.json` | keep the env var, drop the personal default |
| `run-create-command.sh` | 94 | release image pinned to `5.1.0-ec.1` | overridable, not hardcoded |
| `run-create-command.sh` | 95 | `${HOME}/.aws/credentials-splat` | respect a pre-set `AWS_SHARED_CREDENTIALS_FILE` |
| `run-create-command.sh` | 101 | `OPENSHIFT_INSTALL_DATA=../installer/data/data` | a `MODE=dev` convenience; document or drop |
| `run-create-command.sh` | 131, 134 | `us-east-1` hardcoded | read the region from the install-config |
| `run-destroy-command.sh` | 26, 49, 58 | same three as above | same |

### Repo gates

| Gate | State |
| --- | --- |
| `hack/yaml-lint.sh` | **green.** The sample YAML was reindented to this repo's `indent-sequences: false` rule; every file was verified to parse to an identical object before and after. |
| `hack/shellcheck.sh` | **17 `note`-level findings** in the three driver scripts, 16 of them `SC2086` (quote to prevent word splitting). Not a regression — the gate already exits non-zero on master for a pre-existing note in `data/data/bootstrap/files/usr/local/bin/konnectivity-certs.sh` — but worth clearing before review. |

> When clearing `SC2086`, note that `run-create-command.sh:142-143` and `:149` rely on
> **glob expansion** (`.../machines/*.yaml`). Quote the variable only —
> `"${INSTALL_DIR}"/external-install/machines/*.yaml` — not the whole word. A blanket
> quoting pass breaks those three lines.

Two more things to resolve, which are about audience rather than values:

- **`run-destroy-command.sh` cites internal divergence records** ("see divergence 053",
  `mrb-ext6`, `mrb-ext7`) in its header comments. Those are workspace artifacts and mean
  nothing to a partner. Rewrite the comment to state the *rule* — artifacts written before
  the `collectManifests` fix are Go struct dumps and cannot be loaded — without the record
  numbers.
- **The scripts assume the workspace layout**, running from a directory that has
  `./openshift-install` and `../installer/` beside it. A published sample should either state
  that assumption at the top or stop making it.

## Known-good for

| | |
| --- | --- |
| Release | `quay.io/openshift-release-dev/ocp-release:5.1.0-ec.1-x86_64` |
| Installer | branch `pilot-platform-external-capi` at `6e028d5597`, `MODE=dev` build |
| Region / AZ | `us-east-1`, **single AZ** |
| Topology | 3 masters; 0 or 2 day-0 workers |
| IAM | pre-existing credentials; **nothing created or modified** |
