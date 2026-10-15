#!/usr/bin/env bash
#
# Print an installer log with secret material redacted.
#
# `openshift-install --log-level=debug` can echo install-config content, and
# the External path logs provider artifact paths. Neither should reach an agent
# transcript with values intact, so every read of a run log goes through here.
#
# Redaction is line-oriented and deliberately over-broad: a line that merely
# mentions a secret key is dropped whole rather than trimmed, because a partial
# secret is still a secret. Nothing here is a substitute for not writing the
# secret in the first place -- see AGENTS.md.
#
# Usage: safe-log.sh <logfile> [grep-pattern]

set -euo pipefail

LOG=${1:?usage: safe-log.sh <logfile> [grep-pattern]}
PATTERN=${2:-}

redact() {
	# Drop any line carrying a known secret key, then mask anything that looks
	# like a credential regardless of the key it appeared under.
	grep -viE '(pullsecret|pull_secret|sshkey|ssh_key|aws_secret_access_key|aws_access_key_id|aws_session_token|BEGIN [A-Z ]*PRIVATE KEY|"auths"|client_secret|password)' \
		| sed -E \
			-e 's/(AKIA|ASIA)[0-9A-Z]{8,}/[REDACTED-AWS-KEY-ID]/g' \
			-e 's/\bssh-(rsa|ed25519|dss)[[:space:]]+[A-Za-z0-9+\/=]+/[REDACTED-SSH-KEY]/g' \
			-e 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.?[A-Za-z0-9_-]*/[REDACTED-JWT]/g'
}

if [[ -n ${PATTERN} ]]; then
	redact <"${LOG}" | grep -E "${PATTERN}" || true
else
	redact <"${LOG}"
fi
