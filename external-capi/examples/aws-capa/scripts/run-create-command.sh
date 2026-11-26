#!/usr/bin/env bash

#
# Script to test create installer command versioning with template files.
# Make sure you already have extracted CAPI by running:
# $ ./openshift-install extract cluster-api aws --dest-dir=/tmp/capa-artifacts
#
# This runs in two phases. `create manifests` first, so the infrastructure ID
# becomes readable, then the CAPI manifests under external-install/ are
# rewritten to use it, then `create cluster`. The reason is in
# external-install/machines/README.md: Machine.spec.bootstrap.dataSecretName
# must be "<infraID>-bootstrap", the installer picks that name itself, and the
# infrastructure ID does not exist until asset resolution has run.
#
# Editing between the two commands is safe because external-install/ is not an
# asset load path.
#
# Usage: run-create-command.sh <version> [infra-only]
#   infra-only   stop at Cluster.status.infrastructureReady, creating no
#                machines. This is what every run before the bootstrap
#                increment did.
#

set -eux

CLUSTER_VERSION=${1:-0}

if [[ ${CLUSTER_VERSION} -eq 0 ]]; then
	echo "A valid version must be provided. Got: $CLUSTER_VERSION"
	exit 1
fi

CLUSTER_NAME=mrb-ext${CLUSTER_VERSION}
INSTALL_DIR=install-dir-${CLUSTER_NAME}

# must return error if dir exists, which means install already created with this version
mkdir ${INSTALL_DIR}

cp -v install-config.yaml ${INSTALL_DIR}/

cp -rvf external-install/ ${INSTALL_DIR}/external-install/

# The cluster name is the DNS name and belongs in install-config. It is a
# DIFFERENT placeholder from CLUSTER_ID below: that one is the infrastructure
# ID, which the installer derives from this name plus a random suffix and
# which does not exist yet at this point. This runs before the pull secret is
# injected below, so the copy being edited here still holds no credential.
sed -i "s/^  name: CHANGE-ME$/  name: ${CLUSTER_NAME}/" ${INSTALL_DIR}/install-config.yaml

# Assert the substitution landed. An earlier template carried `name: mrb-ext`
# rather than the placeholder, so this sed matched nothing and every cluster
# was silently named `mrb-ext` regardless of the version argument -- visible
# only as an infrastructure ID of `mrb-ext-xxxxx`.
# A no-op sed is indistinguishable from a successful one without this check.
if [[ $(grep -c "^  name: ${CLUSTER_NAME}$" ${INSTALL_DIR}/install-config.yaml) -ne 1 ]]; then
	echo "install-config metadata.name is not ${CLUSTER_NAME}; the template placeholder has drifted"
	exit 1
fi

# The template carries `pullSecret: ""` and the real value lives outside this
# workspace, so the file an agent may read and edit never holds a credential.
# Only this per-run copy does, and it is written by a command that emits
# nothing: the secret is passed by path, never interpolated into a command
# line, so `set -x` cannot trace it either.
#
# This is not a hypothetical. A range `sed` over the template -- intended to
# print the compute stanza -- printed the pullSecret, because pullSecret sits
# between `compute:` and `networking:`. No reading discipline survives an
# assumption about key order; keeping the value out of the file does.
PULL_SECRET_FILE=${PULL_SECRET_FILE:-${HOME}/.aws/pull-secret.json}

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

# Assert the injection landed without printing what landed. An empty pull
# secret reaches `create manifests` as a validation error, but an install that
# got that far has already made the cluster name unusable for a retry.
if [[ $(grep -c '^pullSecret: ""$' ${INSTALL_DIR}/install-config.yaml) -ne 0 ]]; then
	echo "pull secret placeholder survived injection"
	exit 1
fi

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="quay.io/openshift-release-dev/ocp-release:5.1.0-ec.1-x86_64"
export AWS_SHARED_CREDENTIALS_FILE=${HOME}/.aws/credentials-splat

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

# Fill in the cloud controller manager image and its credentials. This has to
# happen before `create manifests`, for two reasons: the installer folds
# external-install/extra-manifests/ into the openshift manifests as it
# generates them, and the pull secret the script needs to resolve the CCM image
# lives in install-config.yaml, which `create manifests` consumes.
#
# Without this the install reaches a healthy API server and three registered
# masters and then stops, because nothing ever removes
# node.cloudprovider.kubernetes.io/uninitialized. That is what mrb-ext11 did.
./prepare-ccm.sh ${INSTALL_DIR}

# ---------------------------------------------------------------- phase one

./openshift-install create manifests --log-level=debug --dir=${INSTALL_DIR}

# Infrastructure.status.infrastructureName, from a generated, non-secret file.
# grep -oE emits only the value, so nothing else in the manifest is printed.
INFRA_ID=$(grep -oE '^  infrastructureName: .*' \
	${INSTALL_DIR}/manifests/cluster-infrastructure-02-config.yml | awk '{print $2}')

if [[ -z ${INFRA_ID} ]]; then
	echo "could not read infrastructureName from the generated manifests"
	exit 1
fi

# pkg/asset/rhcos/image.go returns "" for platform: external, so the AMI has to
# come from somewhere. This is the same source the CI jobs use.
RHCOS_AMI=$(./openshift-install coreos print-stream-json |
	jq -r '.architectures.x86_64.images.aws.regions["us-east-1"].image')

if [[ -z ${RHCOS_AMI} || ${RHCOS_AMI} == "null" ]]; then
	echo "could not resolve an RHCOS AMI for us-east-1"
	exit 1
fi

# The whole CAPI tree is named by infrastructure ID, so the resource tags, the
# load balancer names and the subnet names all agree with what the installed
# cluster will call itself.
sed -i "s/CLUSTER_ID/${INFRA_ID}/g" ${INSTALL_DIR}/external-install/cluster.yaml
sed -i "s/CLUSTER_ID/${INFRA_ID}/g" ${INSTALL_DIR}/external-install/machines/*.yaml
sed -i "s/ami-REPLACE/${RHCOS_AMI}/g" ${INSTALL_DIR}/external-install/machines/*.yaml

# Same reasoning as the install-config guard: an unsubstituted placeholder
# reaches the cloud as a literal and is only noticed once resources exist.
if grep -rqE 'CLUSTER_ID|ami-REPLACE' ${INSTALL_DIR}/external-install/; then
	echo "placeholders survived substitution under ${INSTALL_DIR}/external-install/"
	grep -rlE 'CLUSTER_ID|ami-REPLACE' ${INSTALL_DIR}/external-install/
	exit 1
fi

# ---------------------------------------------------------------- phase two

if [[ "${2:-}" == "infra-only" ]]; then
	# The stop point sits after the InfraReady hook and before any ignition
	# Secret or machine is created.
	export OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY=true
fi

./openshift-install create cluster --log-level=debug --dir=${INSTALL_DIR}
