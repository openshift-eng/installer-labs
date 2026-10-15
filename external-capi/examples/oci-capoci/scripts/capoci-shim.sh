#!/bin/sh
# capoci-shim.sh -- argument-translating wrapper for the CAPOCI controller.
#
# Point platform.external.clusterAPI.binaryPath at this script rather than at
# the CAPOCI binary itself.
#
# WHY THIS EXISTS
#
# The installer passes a fixed, provider-agnostic argument list to every
# external CAPI provider (pkg/clusterapi/external.go:153-158):
#
#     -v=2  --health-addr=HOST:PORT  --webhook-port=N  --webhook-cert-dir=DIR
#
# plus --kubeconfig, appended by runController.
#
# CAPOCI accepts all of those except --health-addr. Its equivalent flag is
# --health-probe-bind-address (cluster-api-provider-oci/main.go:100), and pflag
# exits non-zero on an unrecognised flag, so the controller never starts.
#
# The flag cannot simply be dropped: the installer polls /healthz at that
# address (pkg/clusterapi/system.go:770) and fails the controller if nothing
# answers. So it has to be TRANSLATED, which is what this does.
#
# WHY A SHELL SCRIPT IS A LEGAL binaryPath
#
# pkg/clusterapi/artifacts.go:195-200, verbatim:
#
#   "Files that are not ELF at all -- Mach-O on darwin, or a #!/bin/sh wrapper
#    -- are accepted without a check rather than rejected, so that the override
#    stays usable on developer workstations."
#
# validateHostArch reads the ELF magic and returns nil when the file is not an
# ELF binary, so a wrapper is accepted deliberately rather than by accident.
#
# The shim must be executable, and it must exec the real binary so the
# installer's process supervision sees the controller's exit status rather than
# the shell's.
#
# CONFIGURATION
#
#   CAPOCI_BINARY   path to the real CAPOCI manager binary.
#                   Defaults to ./cluster-api-provider-oci next to this script.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
: "${CAPOCI_BINARY:=${SCRIPT_DIR}/cluster-api-provider-oci}"

if [ ! -x "${CAPOCI_BINARY}" ]; then
    echo "capoci-shim: CAPOCI_BINARY is not executable: ${CAPOCI_BINARY}" >&2
    exit 1
fi

# Rewrite --health-addr to --health-probe-bind-address, in both the
# "--flag=value" and "--flag value" spellings. Everything else is forwarded
# untouched: this is a translation, not a filter, so an argument neither side
# expects still reaches the controller and still fails loudly.
#
# The rotation idiom below is POSIX sh with no arrays: each iteration shifts one
# original argument off the front and appends its translation to the back. After
# exactly $# iterations only translations remain.
remaining=$#
pending_health=0

while [ "${remaining}" -gt 0 ]; do
    arg=$1
    shift
    remaining=$((remaining - 1))

    if [ "${pending_health}" -eq 1 ]; then
        set -- "$@" "--health-probe-bind-address=${arg}"
        pending_health=0
        continue
    fi

    case "${arg}" in
        --health-addr=*)
            set -- "$@" "--health-probe-bind-address=${arg#--health-addr=}"
            ;;
        --health-addr)
            pending_health=1
            ;;
        *)
            set -- "$@" "${arg}"
            ;;
    esac
done

if [ "${pending_health}" -eq 1 ]; then
    echo "capoci-shim: --health-addr given with no value" >&2
    exit 1
fi

exec "${CAPOCI_BINARY}" "$@"
