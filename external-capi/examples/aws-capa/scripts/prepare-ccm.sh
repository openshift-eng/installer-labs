#!/usr/bin/env bash

#
# Fill in the two per-run values in external-install/extra-manifests/ that
# cannot be committed: the cloud controller manager image, which depends on the
# release being installed, and the cloud credentials, which are a secret.
#
# Usage: prepare-ccm.sh <install-dir>
#
# Run this after the install directory has been staged and BEFORE
# `create manifests`, because the installer folds extra-manifests/ into the
# openshift manifests while generating them, and because the pull secret this
# script reads lives in install-config.yaml, which `create manifests` consumes.
#
#
# NOTHING HERE PRINTS A SECRET
#
# That is a constraint, not a nicety: this workspace is driven by agents whose
# transcripts are retained, so a credential echoed once is a credential
# compromised. Every step that touches the pull secret or the AWS credentials
# happens inside a python heredoc that reads a file and writes a file. The
# shell never holds the value in a variable, so `set -x` cannot trace it and a
# failure part-way through cannot dump it. Callers run with `set -eux`; that is
# safe precisely because the values never become shell words.
#

set -euo pipefail

INSTALL_DIR=${1:?usage: prepare-ccm.sh <install-dir>}
EXTRA_DIR=${INSTALL_DIR}/external-install/extra-manifests

CCM_MANIFEST=${EXTRA_DIR}/99_external-02-ccm-aws.yaml
CRED_MANIFEST=${EXTRA_DIR}/99_external-01-ccm-credentials.yaml

: "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:?the release image must be set so the CCM image can be resolved from it}"
: "${AWS_SHARED_CREDENTIALS_FILE:?the AWS credentials file must be set}"

for f in "${CCM_MANIFEST}" "${CRED_MANIFEST}"; do
	test -f "${f}" || { echo "missing ${f}"; exit 1; }
done

# ------------------------------------------------------------ registry auth

# oc needs an auth file and there is not one on this machine; the pull secret
# exists only inside install-config.yaml. Extract it to a private temporary
# file, use it, and delete it.
AUTH_FILE=$(mktemp -t ccm-auth-XXXXXX)
trap 'rm -f "${AUTH_FILE}"' EXIT
chmod 600 "${AUTH_FILE}"

python3 - "${INSTALL_DIR}/install-config.yaml" "${AUTH_FILE}" <<'PY'
import json, pathlib, sys

cfg = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])

# Deliberately not a YAML parse: importing a YAML library to read one scalar
# would put the whole install-config, pull secret included, into a parsed
# object for no gain. The field is a single-line scalar in every file this
# workspace generates.
for line in cfg.splitlines():
    if line.startswith("pullSecret:"):
        value = line[len("pullSecret:"):].strip()
        if value[:1] in ("'", '"'):
            value = json.loads(value) if value[0] == '"' else value[1:-1]
        out.write_text(value)
        break
else:
    sys.exit("no pullSecret found in " + sys.argv[1])
PY

echo "Resolving the cloud controller manager image from the release payload"

CCM_IMAGE=$(oc adm release info -a "${AUTH_FILE}" \
	"${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
	--image-for=aws-cloud-controller-manager)

if [[ -z ${CCM_IMAGE} ]]; then
	echo "could not resolve aws-cloud-controller-manager from ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
	exit 1
fi

# An image pullspec is not a secret, and seeing it is how a mismatched release
# gets noticed.
echo "Using CCM image ${CCM_IMAGE}"

sed -i "s|\${CCM_IMAGE}|${CCM_IMAGE}|g" "${CCM_MANIFEST}"

if grep -q '${CCM_IMAGE}' "${CCM_MANIFEST}"; then
	echo "the CCM image placeholder survived substitution in ${CCM_MANIFEST}"
	exit 1
fi

# ------------------------------------------------------- cloud credentials

echo "Injecting cloud credentials into ${CRED_MANIFEST}"

python3 - "${CRED_MANIFEST}" "${AWS_SHARED_CREDENTIALS_FILE}" <<'PY'
import base64, configparser, io, pathlib, sys

manifest = pathlib.Path(sys.argv[1])
creds = pathlib.Path(sys.argv[2])

# The AWS SDK inside the CCM reads the [default] profile, and the file this
# workspace uses need not have one -- it is a per-environment credentials file
# that may name its profile anything. Rewriting the first profile to [default]
# is the smallest thing that makes the mount work without asking the human to
# maintain a second file.
#
# configparser is used rather than a regex so that a file which already has a
# [default] profile is passed through untouched rather than mangled.
parser = configparser.ConfigParser()
parser.read_string(creds.read_text())

if not parser.sections():
    sys.exit("no profiles found in the AWS credentials file")

if "default" not in parser:
    first = parser.sections()[0]
    parser["default"] = dict(parser[first])

rendered = io.StringIO()
parser.write(rendered)

encoded = base64.b64encode(rendered.getvalue().encode()).decode()

text = manifest.read_text()
placeholder = 'credentials: ""'
if placeholder not in text:
    sys.exit("the credentials placeholder is not in " + str(manifest) +
             "; refusing to overwrite an already-populated Secret")

manifest.write_text(text.replace(placeholder, "credentials: " + encoded, 1))
PY

# Presence and shape only. `grep -c` cannot emit the value.
if [[ $(grep -c '^  credentials: [A-Za-z0-9+/=]\{40,\}$' "${CRED_MANIFEST}") -ne 1 ]]; then
	echo "the credentials Secret in ${CRED_MANIFEST} was not populated"
	exit 1
fi

echo "extra-manifests prepared in ${EXTRA_DIR}"
