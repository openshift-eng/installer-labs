#!/usr/bin/env bash

#
# Counterpart to run-create-command.sh: removes the infrastructure a pilot run
# created, through the provider that created it.
#
# This needs three things the install left behind and nothing else:
#   - <install-dir>/metadata.json, which records the provider artifact paths
#   - <install-dir>/.clusterapi_output/*.yaml, the objects with their resource IDs
#   - the provider artifacts themselves, still at the paths metadata.json names
#
# Artifacts written before the collectManifests fix are Go struct dumps rather
# than manifests and cannot be loaded; see divergence 053. Clusters mrb-ext6 and
# mrb-ext7 are in that state.
#

set -eux

CLUSTER_VERSION=${1:-0}

if [[ ${CLUSTER_VERSION} -eq 0 ]]; then
	echo "A valid version must be provided. Got: $CLUSTER_VERSION"
	exit 1
fi

CLUSTER_NAME=mrb-ext${CLUSTER_VERSION}

# An optional directory suffix, so a recovered copy of an install directory can
# be destroyed without touching the original. See divergence 053: the artifacts
# of mrb-ext6 and mrb-ext7 were Go struct dumps and had to be converted into
# real manifests first, which was done into install-dir-<name>-recovered/.
INSTALL_DIR=install-dir-${CLUSTER_NAME}${2:-}

if [[ ! -d ${INSTALL_DIR} ]]; then
	echo "No such install directory: ${INSTALL_DIR}"
	exit 1
fi

# Fail early and legibly rather than part-way through a teardown.
if [[ ! -f ${INSTALL_DIR}/metadata.json ]]; then
	echo "${INSTALL_DIR}/metadata.json is missing; nothing identifies the cluster to remove"
	exit 1
fi
if ! compgen -G "${INSTALL_DIR}/.clusterapi_output/*.yaml" >/dev/null; then
	echo "${INSTALL_DIR}/.clusterapi_output holds no manifests; nothing identifies the infrastructure to remove"
	exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE=${HOME}/.aws/credentials-splat

# The same override run-create-command.sh sets, and for the same reason: a
# MODE=dev build reads its data assets from disk rather than from the binary.
# Destroy needs them too -- it unpacks the envtest control plane and the
# embedded Cluster API components before it can restore anything -- and without
# this it dies with `open data/cluster-api: no such file or directory` after
# having already started etcd. Omitting it here was why the first destroy of
# mrb-ext11 failed.
export OPENSHIFT_INSTALL_DATA=../installer/data/data

./openshift-install destroy cluster --log-level=debug --dir=${INSTALL_DIR}
