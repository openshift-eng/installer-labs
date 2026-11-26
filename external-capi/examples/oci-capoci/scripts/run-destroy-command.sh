#!/usr/bin/env bash

#
# Counterpart to run-create-command.sh: removes what a pilot run created,
# through the provider that created it.
#
# STATUS: EXECUTED. See the banner in run-create-command.sh for the caveat
# that applies to the whole script set.
#
# `destroy cluster` restarts the local control plane, reapplies the objects
# recorded under <install-dir>/.clusterapi_output/, runs the preDestroy hook,
# and then deletes the Cluster so CAPOCI tears down what it owns. It needs
# three things the install left behind:
#
#   <install-dir>/metadata.json           the provider artifact paths
#   <install-dir>/.clusterapi_output/     the objects, with their OCIDs
#   the artifacts themselves, still at the paths metadata.json names
#
# WHAT CAPOCI DOES NOT OWN, and therefore what the preDestroy hook has to
# remove instead -- see external-install/hooks/infra-hook.sh:
#
#   the DNS zone and its records            created by infraReady
#   the 22623 listener and backend set      created by infraReady
#   the ingress load balancer               created by the cluster's own CCM
#   the bootstrap ignition object and its   created by run-create-command.sh
#     pre-authenticated request               before the installer ever ran
#
# The last of those is the one to care about if a destroy fails: it is an
# unauthenticated URL over the cluster's day-0 secrets. The pre-authenticated
# request expires in two hours regardless, but check it is gone.
#
# Usage: run-destroy-command.sh <version> [dir-suffix]
#

set -eux

CLUSTER_VERSION=${1:-0}

if [[ ${CLUSTER_VERSION} -eq 0 ]]; then
	echo "A valid version must be provided. Got: ${CLUSTER_VERSION}"
	exit 1
fi

CLUSTER_NAME=mrb-oci${CLUSTER_VERSION}
INSTALL_DIR=install-dir-${CLUSTER_NAME}${2:-}

if [[ ! -d ${INSTALL_DIR} ]]; then
	echo "No such install directory: ${INSTALL_DIR}"
	exit 1
fi

# The preDestroy hook runs oci commands with no --region of their own, so the
# region has to reach it through the environment. The oci CLI does not read
# OCI_REGION -- that is this project's variable -- and without this a teardown
# runs against the home region, finds nothing, and reports success while the
# DNS records, the 22623 listener and the bootstrap ignition object all
# survive. A silent no-op is the worst possible failure for a destroy path.
: "${OCI_REGION:?set it to the region the cluster was created in}"
export OCI_CLI_REGION="${OCI_REGION}"

# Fail early and legibly rather than part-way through a teardown.
if [[ ! -f ${INSTALL_DIR}/metadata.json ]]; then
	echo "${INSTALL_DIR}/metadata.json is missing; nothing identifies the cluster to remove"
	exit 1
fi
if ! compgen -G "${INSTALL_DIR}/.clusterapi_output/*.yaml" >/dev/null; then
	echo "${INSTALL_DIR}/.clusterapi_output holds no manifests; nothing identifies the infrastructure to remove"
	exit 1
fi

for tool in oci jq; do
	command -v "${tool}" >/dev/null 2>&1 || { echo "${tool} is not on PATH (the preDestroy hook needs it)"; exit 1; }
done

# ---------------------------------------------------------------------------
# Put CAPOCI's credential Secret back before the restore runs.
#
# `destroy cluster` rebuilds the local control plane from
# .clusterapi_output/, and collectManifests deliberately excludes Secrets from
# that directory (pkg/infrastructure/clusterapi/clusterapi.go:696-700) so no
# credential is written to disk by the installer. Correct, and it leaves this
# gap: the restored OCIClusterIdentity points at a Secret that is not there,
# CAPOCI cannot authenticate, the OCICluster finalizer never clears, and the
# delete hangs until deleteTimeout with nothing in the log naming the cause.
#
# loadArtifacts globs *.yaml and restores whatever it finds, and the restore's
# second phase -- everything that is neither the Namespace nor the core
# Cluster -- is where a Secret lands, which is before the Cluster that needs
# it. So dropping the manifest in is sufficient; nothing else has to change.
#
# The source is the per-run copy the install already made. It is copied by
# path with no command printing it, and it is removed again below so the
# install directory is left as it was found.
CAPI_OUT="${INSTALL_DIR}/.clusterapi_output"
RESTORED_SECRET="${CAPI_OUT}/00-restored-oci-credentials.yaml"
IDENTITY_SECRET="${INSTALL_DIR}/external-install/00_oci-credentials.yaml"

if [[ -s ${IDENTITY_SECRET} ]]; then
	cp "${IDENTITY_SECRET}" "${RESTORED_SECRET}"
	chmod 0600 "${RESTORED_SECRET}"
	trap 'rm -f "${RESTORED_SECRET}"' EXIT
	echo "staged CAPOCI's credential Secret into ${CAPI_OUT} for the restore"
else
	echo "WARNING: no ${IDENTITY_SECRET}; if this cluster used an"
	echo "OCIClusterIdentity the delete will hang waiting for an authentication"
	echo "that cannot succeed. Restore the Secret manifest and re-run."
fi

# The same override run-create-command.sh sets, and for the same reason: a
# MODE=dev build reads its data assets from disk rather than from the binary.
# Destroy needs them too -- it unpacks the envtest control plane and the
# embedded Cluster API components before it can restore anything.
export OPENSHIFT_INSTALL_DATA=../installer/data/data

./openshift-install destroy cluster --log-level=debug --dir="${INSTALL_DIR}"

# Independent check, because a preDestroy hook that silently did nothing and
# one that worked are indistinguishable from the installer's exit code.
IGNITION_STATE="${INSTALL_DIR}/.external-hook-state/bootstrap-ignition.json"
if [[ -f ${IGNITION_STATE} ]]; then
	BUCKET=$(jq -r '.ignitionBucket' "${IGNITION_STATE}")
	OBJECT=$(jq -r '.ignitionObject' "${IGNITION_STATE}")
	if oci os object head --bucket-name "${BUCKET}" --name "${OBJECT}" >/dev/null 2>&1; then
		echo "WARNING: ${OBJECT} is still in ${BUCKET}. It holds the cluster's"
		echo "day-0 secrets. Delete it, and any pre-authenticated request over it:"
		echo "  oci os object delete --bucket-name ${BUCKET} --object-name ${OBJECT} --force"
		exit 1
	fi
	echo "bootstrap ignition object is gone from ${BUCKET}"
fi
