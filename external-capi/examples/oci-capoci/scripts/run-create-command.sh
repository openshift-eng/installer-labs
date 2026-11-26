#!/usr/bin/env bash

#
# Drives a `platform: external` install on OCI with CAPOCI.
#
# ############################################################################
# # STATUS: EXECUTED, through to a complete cluster, over thirteen runs       #
# # between 2026-09-30 and 2026-10-01. Every correction those runs produced   #
# # is in this file and in external-install/.                                 #
# #                                                                           #
# # One caveat, and it is the important one: the run that produced a complete #
# # cluster needed hand-work partway through -- see the Phase 4 table in      #
# # ../README.md for exactly what and why. The fixes for all but one of those #
# # items are in this file set, and no run has yet been spent proving the     #
# # corrected set installs unattended. Treat an unattended run as untested.   #
# # The one item that is NOT fixed is worker CSR approval, which has no       #
# # machine-approver on `platform: external`.                                 #
# ############################################################################
#
#
# THREE PHASES, NOT TWO
#
# The AWS version of this script runs `create manifests`, substitutes the
# infrastructure ID, then `create cluster`. Two phases are enough there because
# CAPA uploads the oversized bootstrap ignition to S3 itself.
#
# CAPOCI cannot: it has no object-store offload of any kind -- no
# object-storage field in api/v1beta2/, no objectstorage client under
# cloud/services/ -- and OCI caps all instance metadata at 32,000 bytes, which
# the bootstrap ignition exceeds by two orders of magnitude.
#
# So a third phase sits between `create ignition-configs` and `create cluster`:
# upload bootstrap.ign, mint a pre-authenticated request over it, and replace
# the file on disk with a pointer config. The installer reloads it, because
# bootstrap.Bootstrap implements Load()
# (pkg/asset/ignition/bootstrap/bootstrap.go:39-41) and is in the
# IgnitionConfigs target (pkg/asset/targets/targets.go:56-64). No installer
# change -- see ../docs/ignition-delivery.md.
#
#   phase 1  create manifests        -> the infrastructure ID exists
#   phase 2  create ignition-configs -> bootstrap.ign exists, oversized
#   phase 3  create cluster          -> reads the stub this script wrote
#
#
# WHAT YOU NEED BEFORE THIS WILL RUN
#
#   oci, jq, python3 on PATH; ~/.oci/config configured
#   OCI_COMPARTMENT_ID       target compartment OCID
#   OCI_REGION               e.g. us-ashburn-1
#   OCI_IMAGE_ID             the RHCOS custom image OCID. NOTHING PROVIDES THIS
#                            YET -- see ../docs/boot-image.md. This is the one
#                            prerequisite that is not merely unconfigured but
#                            unsolved.
#   OCI_IGNITION_BUCKET      a private bucket for the bootstrap ignition
#   OCI_CREDENTIALS_FILE     a YAML Secret for CAPOCI's OCIClusterIdentity,
#                            outside this workspace. Never read by this script
#                            beyond handing its path to `oc apply`.
#   PULL_SECRET_FILE         default ~/.oci/pull-secret.json
#   CAPOCI_ARTIFACTS         default /tmp/capoci-artifacts, holding
#                            capoci-shim.sh, the cluster-api-provider-oci
#                            binary and oci-infrastructure-components.yaml
#
# Usage: run-create-command.sh <version> [infra-only]
#

set -eux

CLUSTER_VERSION=${1:-0}

if [[ ${CLUSTER_VERSION} -eq 0 ]]; then
	echo "A valid version must be provided. Got: ${CLUSTER_VERSION}"
	exit 1
fi

CLUSTER_NAME=mrb-oci${CLUSTER_VERSION}
INSTALL_DIR=install-dir-${CLUSTER_NAME}

: "${OCI_COMPARTMENT_ID:?set it to the target compartment OCID}"
: "${OCI_REGION:?set it to the target region, e.g. us-ashburn-1}"
: "${OCI_IGNITION_BUCKET:?set it to a private object storage bucket}"
: "${OCI_CREDENTIALS_FILE:?set it to the OCIClusterIdentity Secret manifest}"

# The oci CLI does not read OCI_REGION -- that is this project's variable. Left
# to itself the CLI uses the home region from its config file, and every
# command below then acts on the wrong region while looking like it worked:
# `oci os bucket get` answers BucketNotFound for a bucket that plainly exists.
# Found the first time this script was run for real, 2026-10-01. Make the one
# variable authoritative, and export it so the hooks inherit it too -- they run
# oci with no --region of their own.
export OCI_CLI_REGION="${OCI_REGION}"

# Checked separately so the failure says what is actually wrong. There is no
# RHCOS image for OCI today and this variable has nothing to point at until
# someone imports one.
if [[ -z ${OCI_IMAGE_ID:-} ]]; then
	echo "OCI_IMAGE_ID is unset. There is no published RHCOS artifact for OCI;"
	echo "read ../docs/boot-image.md and import one before running this."
	exit 1
fi

CAPOCI_ARTIFACTS=${CAPOCI_ARTIFACTS:-/tmp/capoci-artifacts}
for f in capoci-shim.sh cluster-api-provider-oci oci-infrastructure-components.yaml; do
	if [[ ! -e ${CAPOCI_ARTIFACTS}/${f} ]]; then
		echo "missing ${CAPOCI_ARTIFACTS}/${f}; see ./README.md for how to produce the artifacts"
		exit 1
	fi
done

for tool in oci jq python3; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "${tool} is not on PATH"; exit 1; }
done

# Must fail if the directory exists: a second run under the same version would
# install over the first run's state.
mkdir "${INSTALL_DIR}"

cp -v install-config.yaml "${INSTALL_DIR}/"
cp -rvf external-install/ "${INSTALL_DIR}/external-install/"

# CAPOCI's OCI API key, for the local control plane only.
#
# OCICluster.spec.identityRef points at an OCIClusterIdentity, which points at
# a Secret holding tenancy/user/fingerprint/key/region
# (cloud/util/util.go:118-163). The identity object is in
# external-install/cluster.yaml, in the clear, because it holds no secret. The
# Secret itself lives outside this workspace and is copied in by path, with no
# command printing its content.
#
# IT NEVER REACHES THE INSTALLED CLUSTER. The installer applies
# external-install/ to its TEMPORARY LOCAL control plane -- envtest etcd plus
# kube-apiserver on this host -- which is torn down when the install finishes.
# Nothing copies Secrets from there to the target.
#
# THAT USED TO BE THE WHOLE STORY AND IS NOT ANY MORE. With the pilot default
# OCI_CCM_AUTH=api-key, the infraReady hook reads these same six fields and
# renders them into a Secret for the in-cluster CCM and CSI driver, which IS
# delivered to the target cluster. The intended end state is still instance
# principals, which need no key in the cluster at all -- read the OCI_CCM_AUTH
# block in external-install/hooks/infra-hook.sh for what that costs and why the
# pilot does not do it yet.
if [[ ! -s ${OCI_CREDENTIALS_FILE} ]]; then
	echo "no OCIClusterIdentity Secret at ${OCI_CREDENTIALS_FILE}"
	exit 1
fi
cp "${OCI_CREDENTIALS_FILE}" "${INSTALL_DIR}/external-install/00_oci-credentials.yaml"
chmod 0600 "${INSTALL_DIR}/external-install/00_oci-credentials.yaml"

# ---------------------------------------------------------------------------
# Pre-provision identity check
#
# There is NO preProvision hook. The installer's external hook contract offers
# infraReady, postProvision and preDestroy only
# (pkg/infrastructure/external/hooks/hooks.go), and all three run after the
# provider has started creating things. So anything that should stop a run
# before it spends money has to live here, in the operator's own script.
#
# That is itself a finding about `platform: external` rather than a quirk of
# this example: every partner will want to validate credentials and quota
# before provisioning, and today every partner has to invent this step. See
# ../docs/capi-requirements.md.
#
# Four questions, all read-only. None of them mutates IAM, and none of them
# prints a credential.
# ---------------------------------------------------------------------------

# 1. Does the compartment exist, and is it usable? A deleted or deleting
#    compartment accepts a `get` and rejects every create, which surfaces much
#    later as an opaque reconcile failure on the first VCN.
compartment_state=$(oci iam compartment get --compartment-id "${OCI_COMPARTMENT_ID}" \
	--query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
if [[ ${compartment_state} != "ACTIVE" ]]; then
	echo "compartment ${OCI_COMPARTMENT_ID} is ${compartment_state:-unreachable}, not ACTIVE"
	exit 1
fi

# 2. Is the Secret CAPOCI will use the same identity the CLI is using?
#
#    Worth checking because everything else in this script is validated through
#    the CLI, and if the two diverge then every preflight below passes while the
#    provider authenticates as somebody else entirely. The failure mode is a
#    NotAuthorizedOrNotFound on the first create -- an error that reads like a
#    missing policy and is actually a mismatched user.
#
#    Compared inside python so that no value is ever printed: the output is
#    three booleans. The fields compared (user, tenancy, fingerprint) are OCIDs
#    and a public key hash, not the key itself, but they are handled this way
#    anyway because the file they come from also holds the private key.
python3 - "${INSTALL_DIR}/external-install/00_oci-credentials.yaml" \
	"${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}" "${OCI_CLI_PROFILE:-DEFAULT}" <<'PY'
import base64, configparser, sys, yaml

secret_path, config_path, profile = sys.argv[1:4]

fields = {}
for doc in yaml.safe_load_all(open(secret_path)):
    if not doc or doc.get("kind") != "Secret":
        continue
    fields.update(doc.get("stringData") or {})
    fields.update({k: base64.b64decode(v).decode()
                   for k, v in (doc.get("data") or {}).items()})

cfg = configparser.ConfigParser()
cfg.read(config_path)
if profile not in cfg:
    sys.exit("profile [%s] not found in %s" % (profile, config_path))

bad = []
for name in ("user", "tenancy", "fingerprint"):
    same = (fields.get(name) or "").strip() == (cfg[profile].get(name) or "").strip()
    print("  identity %-12s secret matches CLI profile: %s" % (name, same))
    if not same:
        bad.append(name)
if bad:
    sys.exit("the OCIClusterIdentity Secret and the OCI CLI profile disagree on: "
             + ", ".join(bad) + ". Every check below would validate the wrong "
             "identity. Reconcile them before running.")
PY

# 3. Can this identity read every service the install touches? These are the
#    cheapest possible calls against each API the provider and the CCM use. A
#    read grant does not prove a write grant, so this is a necessary-not-
#    sufficient check -- it catches the common case, which is a compartment the
#    user has no policy on at all.
for probe in \
	"network vcn list|virtual-network-family (CAPOCI builds the VCN)" \
	"nlb network-load-balancer list|load-balancers (the API server endpoint)" \
	"compute instance list|instance-family (machines)" \
	"bv volume list|volume-family (the CSI driver)"; do
	cmd=${probe%%|*}
	what=${probe##*|}
	# shellcheck disable=SC2086
	if ! oci ${cmd} --compartment-id "${OCI_COMPARTMENT_ID}" --limit 1 >/dev/null 2>&1; then
		echo "cannot list ${what} in ${OCI_COMPARTMENT_ID}"
		echo "the identity above lacks a policy on this compartment; the install will fail"
		exit 1
	fi
	echo "  can read ${what}"
done

# 4. Report, without failing, whether instance principals could be used. This
#    is the thing the pilot is NOT doing, and the reason is a tenancy-admin
#    action nobody can take from inside a script. Printing it here keeps the gap
#    visible at run time instead of only in a comment: a dynamic group matching
#    this compartment is the first of the four objects listed in
#    external-install/hooks/infra-hook.sh, and if one appears, that is the
#    signal to revisit OCI_CCM_AUTH.
dyn_groups=$(oci iam dynamic-group list --all \
	--query "length(data[?contains(\"matching-rule\", '${OCI_COMPARTMENT_ID}')])" \
	--raw-output 2>/dev/null || echo 0)
echo "  dynamic groups matching this compartment: ${dyn_groups:-0} (instance principals need >= 1)"
echo "  OCI_CCM_AUTH=${OCI_CCM_AUTH:-api-key} -- the in-cluster CCM credential model"

sed -i "s/^  name: CHANGE-ME$/  name: ${CLUSTER_NAME}/" "${INSTALL_DIR}/install-config.yaml"
sed -i "s/^baseDomain: CHANGE-ME$/baseDomain: ${BASE_DOMAIN:?set it to the DNS zone}/" \
	"${INSTALL_DIR}/install-config.yaml"

# Assert the substitution landed. On the AWS pilot a template placeholder
# drifted, every sed silently matched nothing, and three clusters in a row were
# named after the template instead of the version argument -- visible only as a
# wrong infrastructure ID, long after resources existed.
if [[ $(grep -c "^  name: ${CLUSTER_NAME}$" "${INSTALL_DIR}/install-config.yaml") -ne 1 ]]; then
	echo "install-config metadata.name is not ${CLUSTER_NAME}; the template placeholder has drifted"
	exit 1
fi
if grep -q 'CHANGE-ME' "${INSTALL_DIR}/install-config.yaml"; then
	echo "a CHANGE-ME placeholder survived in install-config.yaml"
	exit 1
fi

# The template carries `pullSecret: ""` and the real value lives outside this
# workspace, so the file a human or an agent may read and edit never holds a
# credential. Only this per-run copy does, and it is written by a command that
# emits nothing: the secret is passed BY PATH, never interpolated into a
# command line, so the `set -x` above cannot trace it either.
PULL_SECRET_FILE=${PULL_SECRET_FILE:-${HOME}/.oci/pull-secret.json}

if [[ ! -s ${PULL_SECRET_FILE} ]]; then
	echo "no pull secret at ${PULL_SECRET_FILE}; set PULL_SECRET_FILE to its location"
	exit 1
fi

python3 - "${INSTALL_DIR}/install-config.yaml" "${PULL_SECRET_FILE}" <<'PY'
import json, pathlib, sys
cfg, secret = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = cfg.read_text()
if 'pullSecret: ""' not in text:
    sys.exit("install-config has no pullSecret placeholder to fill")
# json.dumps emits a correctly escaped double-quoted scalar, valid YAML.
cfg.write_text(text.replace(
    'pullSecret: ""', "pullSecret: " + json.dumps(secret.read_text().strip()), 1))
PY

# Verify by the SHAPE of what should no longer be there, never by confirming
# the placeholder is present: an edit that lands fully and one that half-lands
# look identical from the placeholder's side.
if [[ $(grep -c '^pullSecret: ""$' "${INSTALL_DIR}/install-config.yaml") -ne 0 ]]; then
	echo "pull secret placeholder survived injection"
	exit 1
fi

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:5.1.0-ec.1-x86_64}"

# A MODE=dev build reads its data assets from disk rather than from the
# embedded copy, and resolves this path relative to the working directory --
# which is this one, not the clone. Without it `create manifests` cannot read
# the CoreOS stream metadata and dies before touching the cloud.
export OPENSHIFT_INSTALL_DATA=../installer/data/data

# Fail here, where the message is about the path, rather than several commands
# later where it is "open data/coreos/coreos-rhel-10.json: no such file or
# directory" and reads like a missing release artifact.
if [[ ! -d ${OPENSHIFT_INSTALL_DATA}/coreos ]]; then
	echo "OPENSHIFT_INSTALL_DATA=${OPENSHIFT_INSTALL_DATA} has no coreos/ -- it must"
	echo "point at the clone's data/data (note the doubled component)."
	exit 1
fi

# Every installer invocation below is ./openshift-install deliberately. A stale
# binary earlier on PATH answers for a different release and says nothing about
# it, which is worse than failing.
if [[ ! -x ./openshift-install ]]; then
	echo "no ./openshift-install here; copy or symlink the build you mean to test"
	exit 1
fi

# ----------------------------------------------------------------- phase one

./openshift-install create manifests --log-level=debug --dir="${INSTALL_DIR}"

# Infrastructure.status.infrastructureName, from a generated, non-secret file.
# grep -oE emits only the matched line, so nothing else in the manifest is
# printed -- which matters because the manifest tree as a whole is a credential
# store.
INFRA_ID=$(grep -oE '^  infrastructureName: .*' \
	"${INSTALL_DIR}/manifests/cluster-infrastructure-02-config.yml" | awk '{print $2}')

if [[ -z ${INFRA_ID} ]]; then
	echo "could not read infrastructureName from the generated manifests"
	exit 1
fi

CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

# An OCI VCN dnsLabel is not a domain name: alphanumeric only, must start with
# a letter, 15 characters maximum. The infrastructure ID has hyphens and can
# exceed that, so strip and truncate. Derived rather than fixed so two clusters
# in one compartment do not collide -- OCI requires the label to be unique
# there.
VCN_DNS_LABEL=$(printf '%s' "${INFRA_ID}" | tr -cd '[:alnum:]' | cut -c1-15)

# Starting with a digit is rejected, and nothing guarantees the infra ID does
# not. Cheap to guard, and the failure it prevents only appears minutes later
# as a VCN reconcile error.
if [[ ! ${VCN_DNS_LABEL} =~ ^[a-zA-Z] ]]; then
	VCN_DNS_LABEL="v${VCN_DNS_LABEL}"
	VCN_DNS_LABEL=${VCN_DNS_LABEL:0:15}
fi

# Every token in external-install/, in one place. Machine network references
# are subnetName/nsgNames selectors rather than OCIDs
# (api/v1beta2/types.go), so nothing here needs a second pass after CAPOCI
# builds the network.
sed -i \
	-e "s/CLUSTER_ID/${INFRA_ID}/g" \
	-e "s|COMPARTMENT_OCID|${OCI_COMPARTMENT_ID}|g" \
	-e "s|IMAGE_OCID|${OCI_IMAGE_ID}|g" \
	-e "s/REGION_ID/${OCI_REGION}/g" \
	-e "s/VCN_DNS_LABEL/${VCN_DNS_LABEL}/g" \
	-e "s/CLUSTER_DNS/${CLUSTER_DOMAIN}/g" \
	"${INSTALL_DIR}/external-install/cluster.yaml" \
	"${INSTALL_DIR}/external-install/00_oci-credentials.yaml" \
	"${INSTALL_DIR}"/external-install/machines/*.yaml

# Scoped to the files the sed above actually rewrites, and the scoping is the
# whole point. "Checking files that are not inputs to the substitution cannot
# detect a real drift, only invent one" -- that was already the comment here,
# and the check still walked the whole directory, so it went on inventing them.
#
# It cost two runs. First it failed on machines/README.md, which documents the
# placeholders by name; the --include filters above were added and the walk was
# left alone, which fixed that instance and not the bug. Then on 2026-10-01 it
# failed again, on extra-manifests/99_external-01-oci-hostname-master.yaml --
# a manifest that is not a substitution input, over the token appearing inside
# an explanatory COMMENT. The comment was reworded; the walk is now also
# narrowed to the exact file list, so the next legitimate mention of a
# placeholder does not stop an install.
#
# Keep this list and the sed's file list identical. They are two statements of
# the same fact and they drift silently.
SUBST_INPUTS=(
	"${INSTALL_DIR}/external-install/cluster.yaml"
	"${INSTALL_DIR}/external-install/00_oci-credentials.yaml"
	"${INSTALL_DIR}"/external-install/machines/*.yaml
)
if grep -qE \
	'CLUSTER_ID|COMPARTMENT_OCID|IMAGE_OCID|REGION_ID|CLUSTER_DNS|VCN_DNS_LABEL' \
	"${SUBST_INPUTS[@]}"; then
	echo "placeholders survived substitution under ${INSTALL_DIR}/external-install/"
	grep -lE \
		'CLUSTER_ID|COMPARTMENT_OCID|IMAGE_OCID|REGION_ID|CLUSTER_DNS|VCN_DNS_LABEL' \
		"${SUBST_INPUTS[@]}"
	exit 1
fi

# ----------------------------------------------------------------- phase two

./openshift-install create ignition-configs --log-level=debug --dir="${INSTALL_DIR}"

BOOTSTRAP_IGN="${INSTALL_DIR}/bootstrap.ign"
[[ -s ${BOOTSTRAP_IGN} ]] || { echo "no ${BOOTSTRAP_IGN} after create ignition-configs"; exit 1; }

# Size and hash only. The file is the cluster's day-0 secret material and is
# never printed, and the hash is the only durable record of which bytes were
# uploaded.
BOOTSTRAP_BYTES=$(wc -c <"${BOOTSTRAP_IGN}")
BOOTSTRAP_SHA=$(sha256sum "${BOOTSTRAP_IGN}" | cut -d' ' -f1)
echo "bootstrap.ign: ${BOOTSTRAP_BYTES} bytes, sha256 ${BOOTSTRAP_SHA}"

# --------------------------------------------------------------- phase two.5
#
# Offload. This is the part with no AWS equivalent.

OBJECT_NAME="${INFRA_ID}/bootstrap.ign"

oci os object put \
	--bucket-name "${OCI_IGNITION_BUCKET}" \
	--name "${OBJECT_NAME}" \
	--file "${BOOTSTRAP_IGN}" \
	--content-type application/json \
	--force >/dev/null

echo "uploaded ${OBJECT_NAME} to ${OCI_IGNITION_BUCKET}"

# The pre-authenticated request. Its URL is an UNAUTHENTICATED credential over
# everything in bootstrap.ign, so:
#   - it is never echoed, which is why the `set -x` is suspended around the
#     commands that touch it;
#   - it expires in two hours, enough for a bootstrap and no more;
#   - hooks/infra-hook.sh deletes it at pre-destroy, and the expiry is only a
#     backstop for when that does not run.
PAR_EXPIRY=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)

set +x   # nothing below this line may be traced until the URL is out of scope
PAR_JSON=$(oci os preauth-request create \
	--bucket-name "${OCI_IGNITION_BUCKET}" \
	--name "${INFRA_ID}-bootstrap" \
	--object-name "${OBJECT_NAME}" \
	--access-type ObjectRead \
	--time-expires "${PAR_EXPIRY}" 2>/dev/null)

PAR_ID=$(printf '%s' "${PAR_JSON}" | jq -r '.data.id')
PAR_PATH=$(printf '%s' "${PAR_JSON}" | jq -r '.data."access-uri"')
unset PAR_JSON

if [[ -z ${PAR_PATH} || ${PAR_PATH} == "null" ]]; then
	set -x
	echo "could not mint a pre-authenticated request for ${OBJECT_NAME}"
	exit 1
fi

PAR_URL="https://objectstorage.${OCI_REGION}.oraclecloud.com${PAR_PATH}"

# The pointer config. Roughly 300 bytes against OCI's 23,900-byte raw budget,
# so the thing that could not fit now fits with room to spare.
python3 - "${BOOTSTRAP_IGN}" <<PY
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "ignition": {
        "version": "3.2.0",
        "config": {"merge": [{"source": "${PAR_URL}"}]},
    }
}))
PY

unset PAR_URL PAR_PATH
set -x

STUB_BYTES=$(wc -c <"${BOOTSTRAP_IGN}")
echo "replaced bootstrap.ign with a ${STUB_BYTES}-byte pointer config"

if [[ ${STUB_BYTES} -gt 23900 ]]; then
	echo "the pointer config is larger than OCI's raw userdata budget; something is wrong"
	exit 1
fi

# Record what pre-destroy has to clean up. The hook reads this file; writing it
# here rather than in the hook is what keeps the two directions linked, and the
# PAR ID is an identifier, not the URL, so this file is not itself a credential.
mkdir -p "${INSTALL_DIR}/.external-hook-state"
jq -n \
	--arg bucket "${OCI_IGNITION_BUCKET}" \
	--arg object "${OBJECT_NAME}" \
	--arg par "${PAR_ID}" \
	--arg sha "${BOOTSTRAP_SHA}" \
	'{ignitionBucket:$bucket, ignitionObject:$object, ignitionParId:$par, ignitionSha256:$sha}' \
	>"${INSTALL_DIR}/.external-hook-state/bootstrap-ignition.json"

unset PAR_ID

# --------------------------------------------------------------- phase three

if [[ "${2:-}" == "infra-only" ]]; then
	# Stops after the InfraReady hook and before any ignition Secret or machine
	# is created -- which is also the cheapest way to test the hook's DNS,
	# 22623 listener and CCM Secret work without booting anything.
	export OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY=true
fi

./openshift-install create cluster --log-level=debug --dir="${INSTALL_DIR}"
