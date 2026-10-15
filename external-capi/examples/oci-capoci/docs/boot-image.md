# Blocker 1 — the RHCOS boot image for OCI

**Status: downgraded from blocker to work item, 2026-10-01.** The question that
gated everything — *does our RHCOS understand OCI at all?* — is answered **yes**,
by measurement. What remains is publishing and import plumbing, which is work
rather than a dead end.

## The problem in one paragraph

`platform: external` + CAPI provisions instances and hands them Ignition through
the cloud's instance-metadata channel. That requires a boot image whose Ignition
knows how to read OCI's metadata service. **No such RHCOS image is published** —
there is no `oci` artifact in any stream — and every supported
OpenShift-on-OCI install today avoids the question entirely by baking Ignition
into the boot media.

The capability, though, is already in the bits we ship. The RHCOS in the current
release payload carries Ignition 2.26.0 with the `oraclecloud` provider compiled
in, and Afterburn knows OCI too. So this is a **packaging gap, not a capability
gap**: the software can read OCI metadata, nobody has published an image that
says so. See the measurement below.

## Evidence

### No OCI artifact in any RHCOS or SCOS stream

The installer's boot-image metadata lives in `data/data/coreos/`. All three
streams were checked across all architectures:

| File | Stream |
| --- | --- |
| `data/data/coreos/coreos-rhel-9.json` | RHCOS 9.x |
| `data/data/coreos/coreos-rhel-10.json` | RHCOS 10.x |
| `data/data/coreos/scos.json` | CentOS Stream CoreOS |

The `architectures.<arch>.artifacts` keys present are: `aws`, `azure`,
`azurestack`, `gcp`, `ibmcloud`, `kubevirt`, `metal`, `nutanix`,
`nvidiabluefield`, `openstack`, `powervs`, `qemu`, `qemu-secex`, `vmware`.

There is no `oci` and no `oraclecloud` key, on any architecture, in any stream.

### Today's OpenShift on OCI is Assisted/Agent-based, so it never needed one

Oracle's own automation confirms this directly:

- `oci-openshift/terraform-stacks/shared_modules/image/main.tf` imports a QCOW2
  from a URL the user supplies (`openshift_image_source_uri`). That image is the
  **ABI/Assisted discovery ISO converted to a disk image, with the cluster's
  Ignition already embedded**. It is per-cluster, not a generic RHCOS.
- `oci-openshift/terraform-stacks/shared_modules/locals.tf:2` —
  `is_abi = var.installation_method == "Agent-based"`.
- `oci-openshift/terraform-stacks/shared_modules/compute/main.tf:51-53,100-102`
  sets `metadata.user_data` to a **base64 bash script**, not Ignition.

So the `user_data` channel on OCI, as Oracle uses it today, is consumed by
cloud-init-style scripting that the already-provisioned OS runs — see
`custom_manifests/butane/oci-eval-user-data-master.bu`, which installs a
systemd unit that curls
`http://169.254.169.254/opc/v2/instance/metadata/user_data` with
`Authorization: Bearer Oracle`, base64-decodes it and runs it as bash.

That butane file is strong evidence about the IMDS shape and the auth header,
and it is *not* evidence that Ignition itself reads OCI metadata.

### Ignition does support OCI, upstream, recently

From `coreos/ignition` `docs/supported-platforms.md` and `docs/release-notes.md`
(fetched 2026-09-30):

- Platform ID **`oraclecloud`**, "Oracle Cloud Infrastructure", config fetched
  from the **instance userdata**.
- Added in **Ignition 2.22.0, released 2025-07-08**. A follow-up fix landed in
  **2.23.0, 2025-09-10**.

So the mechanism exists. The question is whether it exists *in the RHCOS build
for the target OpenShift version*.

## ANSWERED 2026-10-01 — the RHCOS we ship already supports OCI

> **Does the RHCOS image for the target OCP release ship Ignition ≥ 2.22.0?**
>
> **Yes — Ignition 2.26.0, four minor versions past the one that added
> `oraclecloud`.** Routes A and B are open; the pilot does not need route C.

Measured on a running node of `mrb-ext14`, an AWS `platform: external` cluster
installed from the same release payload the OCI pilot will use:

| | |
| --- | --- |
| RHCOS build | `10.2.20260918-0` (Coughlan), kernel `6.12.0-211.56.1.el10_2` |
| Ignition | **`ignition-2.26.0-2.el10_2.x86_64`** |
| Afterburn | `afterburn-5.10.0-1.el10.x86_64` |

The version number alone is not proof that the provider was compiled in, so the
shipped binary was checked directly rather than inferred:

```sh
oc debug node/<node> -- chroot /host bash -c \
  'grep -ao "....................oraclecloud...................." \
     /usr/lib/dracut/modules.d/30ignition/ignition'
```

which returns, among others:

```
/internal/providers/oraclecloud.init.0.github.com/c
/internal/providers/oraclecloud.fetchConfig.github.
/internal/providers/oraclecloud/oraclecloud.go./bui
oraclecloud/phone-home
```

Those are Go symbols: the provider package's `init` — which is what registers it
in Ignition's platform table — and its `fetchConfig`. The provider is present and
wired up, not merely referenced in a string.

**Afterburn supports it too**, which is a separate question and matters for
hostnames: `src/providers/oraclecloud/mod.rs` appears in `/usr/bin/afterburn`.
Afterburn is what normally sets a node's hostname from cloud metadata, so OCI
nodes should get one without Oracle's `oci-hostname-update.service`. Not
verified end to end — the string proves the provider is compiled in, not that
the hostname it derives is the one the CCM expects.

### One caveat, stated rather than smoothed over

The build measured above, `10.2.20260918-0`, comes from the **release payload**.
The `qemu` artifact that route A imports comes from the installer's **stream
metadata**, which for this binary is `10.2.20260423-0` — five months older.

Ignition 2.22.0 shipped 2025-07-08, so an April 2026 build is still nine months
past it, and it is very unlikely to be below 2.22.0. But that is an inference,
not a measurement. **Check the imported image once, the first time it is built**,
the same way:

```sh
# after importing, on a first booted instance
rpm -q ignition          # must be >= 2.22.0
```

## Three candidate routes

### Route A — import the QCOW2 and force `ignition.platform.id=oraclecloud`

Take the published `qemu` artifact (which every stream has), import it to OCI as
a custom image, and set the kernel command line so Ignition selects the OCI
provider.

**Getting the artifact URL — and the trap in doing it.** The installer prints its
own stream metadata, but a `MODE=dev` build reads its data assets from disk
relative to the working directory, so the obvious command fails:

```console
$ ./openshift-install coreos print-stream-json
FATAL ... failed to read embedded CoreOS stream metadata:
      open data/coreos/coreos-rhel-10.json: no such file or directory
```

`OPENSHIFT_INSTALL_DATA` points at the clone's `data/data`
(`data/assets.go:16-22`, which defaults to the relative path `data`):

```sh
OPENSHIFT_INSTALL_DATA=../installer/data/data ./openshift-install \
  coreos print-stream-json |
  jq -r '.architectures.x86_64.artifacts.qemu.formats["qcow2.gz"].disk.location'
```

Use `./openshift-install`, not whatever is on `$PATH` — a stale binary on the
path will answer, and it will answer about a different release.

As of this writing that resolves to RHCOS `10.2.20260423-0`:

```
https://rhcos.mirror.openshift.com/art/storage/prod/streams/rhel-10.2/builds/
  10.2.20260423-0/x86_64/rhcos-10.2.20260423-0-qemu.x86_64.qcow2.gz
sha256 f63172f2be871b99a9250138715a829be55015fb70068258959efbeeadd071f2
```

The stream carries a `sha256` for the compressed file and an
`uncompressed-sha256` for the QCOW2 inside it. **Check both** — the second is the
only thing that verifies what actually gets uploaded, since the upload happens
after decompression.

- **Pro:** uses a real, signed, published RHCOS. Generic — one image per release,
  not one per cluster. Exactly what an integrated provider would do.
- **Con:** the platform ID is normally baked into the image at build time by
  `coreos-installer install --platform`, not set at import. Changing the GRUB
  cmdline of an imported QCOW2 means either modifying the image before upload or
  relying on OCI honouring a cmdline the image itself does not carry — OCI has no
  "kernel arguments" field on an imported custom image.
- **Realistic shape:** mount the QCOW2 locally, run `coreos-installer` or edit
  `/boot/loader/entries/*.conf` to add `ignition.platform.id=oraclecloud`,
  re-upload. Needs `PARAVIRTUALIZED` launch mode and the right firmware settings,
  which `oci-openshift/terraform-stacks/shared_modules/image/main.tf` already
  demonstrates for its own image.
- **Unverified:** everything after "mount the QCOW2". This has not been tried.

### Route B — ask for an official OCI artifact in the RHCOS build

The correct long-term answer. The platform exists in Ignition; what is missing is
a build target in RHCOS/CoreOS assembler and a publication step.

- **Pro:** the only route that ends with OpenShift on OCI being a normal cloud.
- **Con:** not a pilot activity. Months, and a different set of people.
- Worth filing regardless of what the pilot does, because routes A and C are both
  workarounds for its absence.

### Route C — keep Oracle's per-cluster embedded-Ignition image

Build the image the way Oracle does today, with the cluster's Ignition baked in,
and have CAPOCI launch *that*.

- **Pro:** known to work; it is what every supported OCI install does.
- **Con:** it defeats a large part of the point. A per-cluster boot image means
  the image depends on `create ignition-configs` output, which means the image
  must be built between two installer phases, which pushes substantial work into
  the hook scripts. It also makes the bootstrap/master/worker configs *different
  images*, not different user-data.
- **Would still prove something:** that CAPOCI can be driven by the installer's
  External path at all — the controller, the hooks, the manifests, the teardown.
  It would not prove the Ignition delivery path.

## Recommendation

**Route A.** The gating question is answered: the Ignition in the RHCOS this
project ships has the `oraclecloud` provider compiled in, so route A is a real
test of the External mechanism rather than a hope. Route C is no longer the
fallback it was written to be, and should only be revisited if route A fails for
a reason specific to *importing* an image — not for anything to do with Ignition
support.

What is still unproven in route A is narrower than it was, and it is all
mechanical:

| Step | Status |
| --- | --- |
| RHCOS supports `oraclecloud` | **verified** — Ignition 2.26.0, provider symbols present |
| the `qemu` QCOW2 is fetchable and checksummed | **verified** — stream carries both hashes |
| the platform ID can be set on an imported image | **unverified** — the real question |
| OCI boots a `PARAVIRTUALIZED` imported QCOW2 of RHCOS | **unverified**, but Oracle's own `shared_modules/image/main.tf` does exactly this shape |
| Ignition fetches from OCI instance userdata on first boot | **unverified** — the thing the pilot exists to prove |

The platform ID is the one to attack first. It is normally baked in at build time
by `coreos-installer install --platform`, and OCI has no "kernel arguments" field
on a custom image — so it has to be written into the image before upload, by
editing `/boot/loader/entries/*.conf` in the mounted QCOW2 or by running
`coreos-installer` against it. If that turns out to be impossible, route A fails
for an image-plumbing reason and route C becomes relevant again.

Route B should be opened upstream either way: every route other than B is a
workaround for OCI not being a published RHCOS target.

## Consequence for the machine manifests

`OCIMachine.spec.imageId` (`api/v1beta2/ocimachine_types.go`) is a bare OCID.
There is no selector form — no `imageLookup`, no filter by name or tag, as CAPA
has. So whichever route is taken, the resulting image's OCID must be substituted
into every machine manifest, alongside the `<infraID>` substitution the AWS
example already does. The example's `scripts/` handle both in one pass.
