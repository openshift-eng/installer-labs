#!/usr/bin/env bash
#
# Reference InfraReady / PostProvision / PreDestroy hook for
# `platform: external` with CAPOCI.
#
# ############################################################################
# # STATUS: NEVER EXECUTED. Written 2026-09-30 with no OCI account available. #
# # Every `oci` CLI invocation below is from the published command reference, #
# # not from a run. The aws-capa sibling of this file was developed against a #
# # live account over several installs; this one was not. Expect flag names   #
# # and JSON shapes to need correction on first contact.                      #
# ############################################################################
#
#
# WHY THIS EXISTS
#
# On an integrated platform the installer creates the cluster's DNS itself
# after CAPI reports the network ready -- for AWS that is
# pkg/infrastructure/aws/clusterapi/aws.go:112. `platform: external` has no
# such code and must not grow any: the point is that the installer knows
# nothing about the provider's cloud. But the records still have to exist,
# because a control-plane machine's pointer ignition aims at
# https://api-int.<clusterDomain>:22623/config/master.
#
# So the seam is here. The installer calls a program the user supplies, at the
# same point an integrated provider would run its own InfraReady, and hands it
# everything it can describe without knowing the provider's API.
#
#
# WHAT THIS HOOK DOES THAT THE AWS ONE DOES NOT
#
# Three things, and the second is the one with no AWS equivalent at all.
#
# 1. DNS, in OCI DNS rather than Route 53. Same job.
#
# 2. ADDS A 22623 LISTENER TO THE API LOAD BALANCER. CAPOCI's network load
#    balancer has exactly one listener, on 6443: every port in
#    cloud/scope/network_load_balancer_reconciler.go is APIServerPort()
#    (:55, :72, :187). There is no equivalent of CAPA's
#    controlPlaneLoadBalancer.additionalListeners. Masters fetch their real
#    config from api-int:22623, so without this they boot with no OS config
#    and the install dies after the full bootstrap timeout.
#
#    This is safe from CAPOCI's reconcile loop, which was checked rather than
#    assumed: IsNLBEqual compares only the display name and the health checker
#    of the single backend set named apiserver-lb-backendset (:301-320), and
#    UpdateNLB sends only DisplayName plus that health checker (:122-150).
#    Neither enumerates listeners, so one added here is not pruned.
#
#    The BACKENDS are a separate problem. CAPOCI registers control-plane
#    machines into apiserver-lb-backendset only (cloud/scope/machine.go:874),
#    and at infra-ready no machine exists yet. So the listener and an empty
#    backend set are created here, and post-provision populates them.
#
# 3. WRITES THE OCI CCM AND CSI CONFIG SECRETS. These need the VCN,
#    service-lb subnet and security list OCIDs, none of which exist before
#    CAPI builds the network -- so they cannot be day-0 manifests. See
#    ../extra-manifests/README.md.
#
#
# THE CONTRACT
#
# The installer execs this program directly -- no shell -- with the
# environment below and whatever arguments install-config gave it. Working
# directory is the install directory.
#
# Exit 0 is success; any other exit aborts the install, and the last few lines
# written are quoted in the installer's error, so the last thing said before
# exiting should be the reason.
#
#   OPENSHIFT_INSTALL_HOOK            "infra-ready", "post-provision" or
#                                     "pre-destroy"
#   OPENSHIFT_INSTALL_INFRA_ID        e.g. mrb-oci1-knzjv
#   OPENSHIFT_INSTALL_CLUSTER_NAME
#   OPENSHIFT_INSTALL_BASE_DOMAIN
#   OPENSHIFT_INSTALL_CLUSTER_DOMAIN  <cluster name>.<base domain>
#   OPENSHIFT_INSTALL_PUBLISH         External | Internal
#   OPENSHIFT_INSTALL_DIR             the install directory
#   OPENSHIFT_INSTALL_MANIFEST_DIR    <install dir>/external-install
#   OPENSHIFT_INSTALL_STATE_DIR       writable; what infra-ready records here
#                                     is what pre-destroy reads
#   OPENSHIFT_INSTALL_CLUSTER_JSON    PATH of a file holding the core CAPI
#                                     Cluster object as JSON
#   OPENSHIFT_INSTALL_INFRA_JSON      PATH of a file holding the OCICluster as
#                                     JSON, verbatim from the local control
#                                     plane. A path, not the document: read it
#                                     with `jq -r ... "${VAR}"`, never pipe the
#                                     variable's own value into jq.
#   OPENSHIFT_INSTALL_KUBECONFIG      the installed cluster's admin kubeconfig.
#                                     Set for every hook and usable by none
#                                     until the cluster's API is serving.
#
# OPENSHIFT_INSTALL_INFRA_JSON is the whole mechanism. The installer cannot
# read .spec.networkSpec.vcn.id off an OCICluster, because it has no OCICluster
# type and must not acquire one. It can copy the object out of its local
# control plane as JSON and let the hook dig. Every path read below is
# CAPOCI's schema, not the installer's.
#
# Note those are SPEC paths, not status. CAPOCI writes the OCIDs of what it
# creates back into the spec -- cloud/scope/vcn_reconciler.go:43,51 for the VCN
# and cloud/scope/subnet_reconciler.go for subnets. OCIClusterStatus has no
# network block at all (api/v1beta2/ocicluster_types.go:85-95).
#
# OPENSHIFT_INSTALL_STATE_DIR is how destroy stays honest. Anything created
# here is outside CAPI's ownership, so nothing else will ever clean it up. The
# rule on this pilot is that each new resource ships with its teardown in the
# same change, and the state file links the two directions.
#
#
# REQUIREMENTS
#
#   oci   the OCI CLI, configured. Uses the same tenancy/user/key as the
#         OCIClusterIdentity Secret, but reads them from ~/.oci/config -- this
#         hook runs on the installer host, not in the cluster.
#   jq
#   oc    only for post-provision and pre-destroy.
#
# The hook never prints a credential, an OCID of a Secret, or the contents of
# any file it writes. Pre-authenticated request URLs in particular are
# credentials: see ../../docs/ignition-delivery.md.

set -euo pipefail

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)] oci-hook:" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for tool in oci jq; do
	command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not on PATH"
done

: "${OPENSHIFT_INSTALL_HOOK:?not set -- this program is run by the installer}"
: "${OPENSHIFT_INSTALL_INFRA_ID:?}"
: "${OPENSHIFT_INSTALL_CLUSTER_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_BASE_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_STATE_DIR:?}"

INFRA_ID=${OPENSHIFT_INSTALL_INFRA_ID}
CLUSTER_DOMAIN=${OPENSHIFT_INSTALL_CLUSTER_DOMAIN}
BASE_DOMAIN=${OPENSHIFT_INSTALL_BASE_DOMAIN}
PUBLISH=${OPENSHIFT_INSTALL_PUBLISH:-External}

STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-hook-state.json"
APPS_STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-hook-apps.json"
CCM_STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-ccm-secrets.yaml"

# Written by ../../scripts/run-create-command.sh BEFORE the installer starts,
# recording the bootstrap ignition object and the pre-authenticated request
# over it. The hook cannot discover these -- the offload happens between
# `create ignition-configs` and `create cluster`, with no hook in between --
# so the script hands them over through a file at a path both sides agree on.
# It holds the PAR's ID, not its URL: the ID is an identifier, the URL is a
# credential.
IGNITION_STATE="${OPENSHIFT_INSTALL_DIR:-.}/.external-hook-state/bootstrap-ignition.json"

# The CCM annotation that places a load balancer in a network security group.
# The doubled `oci-` is correct and is not a typo; see nsg_by_role for what the
# other spelling costs.
NSG_ANNOTATION="oci-network-load-balancer.oraclecloud.com/oci-network-security-groups"

# The second listener. Named, not numbered, because OCI addresses listeners
# and backend sets by name and pre-destroy has to find them again.
MCS_PORT=22623
MCS_LISTENER="mcs-listener"
MCS_BACKENDSET="mcs-backendset"

# The OCIClusterIdentity Secret, staged into the install directory by
# ../../scripts/run-create-command.sh. Two unrelated things read it: pre-destroy
# puts it back into the local control plane so CAPOCI can authenticate to tear
# down, and -- when OCI_CCM_AUTH=api-key -- infra-ready reads the same six
# fields to build the in-cluster CCM config. Those are the same credential by
# construction, which is the point: the pilot does not introduce a second one.
PROVIDER_CREDENTIALS="${OPENSHIFT_INSTALL_MANIFEST_DIR:-${OPENSHIFT_INSTALL_DIR:-.}/external-install}/00_oci-credentials.yaml"

# How the in-cluster CCM and CSI driver authenticate to OCI.
#
#   instance-principal  the intended end state. The node authenticates as
#                       itself, no credential is stored in the cluster, and
#                       OCI's control plane mints short-lived tokens.
#   api-key             a user API signing key, copied into a cluster Secret.
#
# THE DEFAULT IS THE WEAKER ONE, DELIBERATELY, AND IT IS A PILOT EXPEDIENT.
# Instance principals are not something the installer or CAPOCI can turn on.
# They need four IAM objects that only a tenancy administrator can create:
#
#   1. a tag namespace with an `instance-role` key;
#   2. a DEFINED tag of that key on every instance -- a dynamic group cannot
#      match a freeform tag, so the freeform tags CAPOCI applies by default
#      are not enough (oci-openshift/terraform-stacks/shared_modules/iam/
#      dynamic_group.tf:5);
#   3. a dynamic group whose matching rule is
#        all {instance.compartment.id='<compartment>',
#             tag.<ns>.instance-role.value='control_plane'}
#   4. policies granting that group manage volume-family, instance-family,
#      security-lists, virtual-network-family, load-balancers and objects in
#      the compartment, plus `use tag-namespaces in tenancy`
#      (.../iam/policy.tf).
#
# So an operator who has not run Oracle's terraform has none of it, and on
# `platform: external` there is no Oracle terraform. That is a real finding
# about this platform rather than a local inconvenience: the CCM a partner
# ships may need IAM that no CAPI provider creates, and the installer has
# nowhere to say so. See ../../docs/capi-requirements.md.
#
# api-key is what makes a pilot run possible today. Its cost is stated here
# rather than buried: the Secret holds a USER's signing key, so the CCM runs
# with that user's permissions across the whole tenancy, not with a dynamic
# group's permissions scoped to one compartment. That is strictly worse than
# what we are replacing it with, and it is acceptable only because this
# compartment is disposable. Do not ship it.
: "${OCI_CCM_AUTH:=api-key}"
case ${OCI_CCM_AUTH} in
api-key | instance-principal) ;;
*) die "OCI_CCM_AUTH must be api-key or instance-principal, not ${OCI_CCM_AUTH}" ;;
esac

# ---------------------------------------------------------------------------
# Reading the infrastructure object
# ---------------------------------------------------------------------------

infra_json() {
	[[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} ]] ||
		die "OPENSHIFT_INSTALL_INFRA_JSON is unset -- the installer sets it only when exactly one infrastructure object exists"
	# A PATH, not the JSON. The installer writes the object to a file in a
	# per-hook temporary directory and exports that file's path
	# (pkg/infrastructure/external/hooks/hooks.go:200-216, `env = append(env,
	# obj.envVar+"="+path)`). This function used to `printf '%s'` the variable
	# itself, which fed jq a 57-character pathname and produced
	# `jq: parse error: Invalid numeric literal at EOF at line 1, column 58`
	# -- column 58 being one past the end of the path. Every lookup below then
	# failed, and the first one to report was the compartment OCID, which made
	# it read like a missing field rather than a misread variable. Found on the
	# first real run of this hook, 2026-10-01. The aws-capa sibling always had
	# this right because it was written against runs.
	[[ -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]] ||
		die "OPENSHIFT_INSTALL_INFRA_JSON=${OPENSHIFT_INSTALL_INFRA_JSON} is not a file -- the installer exports the path of a file holding the object, not the object"
	cat "${OPENSHIFT_INSTALL_INFRA_JSON}"
}

# jq against the OCICluster, failing loudly on an empty result rather than
# letting an empty string flow into an OCI CLI call.
infra_get() {
	local path=$1 desc=$2 value
	value=$(infra_json | jq -r "${path} // empty")
	[[ -n ${value} ]] || die "${desc} not found at ${path} in the OCICluster"
	printf '%s' "${value}"
}

vcn_id()        { infra_get '.spec.networkSpec.vcn.id' 'VCN OCID'; }
compartment()   { infra_get '.spec.compartmentId' 'compartment OCID'; }
nlb_id()        { infra_get '.spec.networkSpec.apiServerLoadBalancer.loadBalancerId' 'API server NLB OCID'; }
api_endpoint()  { infra_get '.spec.controlPlaneEndpoint.host' 'control plane endpoint host'; }

subnet_by_role() {
	infra_get ".spec.networkSpec.vcn.subnets[] | select(.role==\"$1\") | .id" "$1 subnet OCID"
}

# OPTIONAL, AND NORMALLY ABSENT. CAPOCI secures subnets with NETWORK SECURITY
# GROUPS, not with per-subnet security lists: a subnet it created carries only
# cidr, id, name, role and type, with no `securityList` key at all. Measured on
# the recorded OCICluster of a real run, 2026-10-01 -- all four subnets, same
# shape.
#
# This used to call infra_get, which dies on an empty result, so infra-ready
# aborted at the very first thing it needed after the network existed. Oracle's
# own CCM config has a security list because their *terraform* creates subnets
# with one; CAPOCI's does not, and copying the config shape without copying the
# network shape is what produced the mismatch.
#
# Left as an accessor rather than deleted because a partner who supplies their
# own pre-existing subnets CAN set it, and then the CCM should be told about
# it. Returns empty instead of dying; render_ccm_secrets decides what that
# means.
seclist_by_role() {
	infra_json | jq -r \
		".spec.networkSpec.vcn.subnets[] | select(.role==\"$1\") | .securityList.id // empty"
}

# What CAPOCI actually creates. Recorded in state so post-provision can annotate
# the ingress Service with it -- see annotate_ingress_nsg, which is the only
# consumer.
#
# THE ANNOTATION KEY DEPENDS ON THE LOAD BALANCER TYPE AND THE TWO DIFFER BY ONE
# WORD. For an NLB -- which is what this example uses -- it is
#
#   oci-network-load-balancer.oraclecloud.com/oci-network-security-groups
#
# note the doubled `oci-`. The LBaaS spelling is
# `oci.oraclecloud.com/oci-network-security-groups`. An earlier revision of this
# comment named the LBaaS key, and following it cost four attempts on a live
# cluster: a wrong key is not rejected, not logged and not defaulted. It is
# ignored, the load balancer comes up with no NSG, every health check passes,
# and the only symptom is that traffic from outside the VCN is dropped.
#
# The authoritative list is in the CCM binary and can be read from a running
# cluster, which is how this one was finally settled:
#
#   oc exec -n oci-cloud-controller-manager <pod> -- grep -aoE \
#     'oci[a-z0-9.-]*\.oraclecloud\.com/[a-zA-Z0-9_-]+' \
#     /usr/local/bin/oci-cloud-controller-manager | sort -u
nsg_by_role() {
	infra_json | jq -r \
		".spec.networkSpec.vcn.networkSecurityGroup.list[]? | select(.role==\"$1\") | .id // empty"
}

# ---------------------------------------------------------------------------
# DNS
#
# OCI DNS rather than Route 53, and the shape differs in one way worth
# knowing: OCI has no alias-record concept, so api/api-int are A records
# pointing at the NLB's IP address rather than aliases pointing at the load
# balancer itself.
#
# Which means we have to choose an address, and a public NLB has two. The
# public zone's `api` gets .spec.controlPlaneEndpoint.host, which CAPOCI set to
# the public one. The private zone's `api` and `api-int` get the private one,
# looked up by nlb_private_ip -- read that function before changing either.
# ---------------------------------------------------------------------------

create_private_zone() {
	local compartment_id=$1 vcn=$2 existing

	existing=$(oci dns zone list --compartment-id "${compartment_id}" \
		--name "${CLUSTER_DOMAIN}" --scope PRIVATE \
		--query 'data[0].id' --raw-output 2>/dev/null || true)
	if [[ -n ${existing} && ${existing} != "null" ]]; then
		log "private zone ${CLUSTER_DOMAIN} already exists"
		printf '%s' "${existing}"
		return 0
	fi

	# A private zone needs a view, and each VCN has a default one. Looking it
	# up by VCN rather than by name because the default view's name is not
	# documented as stable.
	local view_id
	view_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].\"default-view-id\"" \
		--raw-output)
	[[ -n ${view_id} && ${view_id} != "null" ]] ||
		die "no default private DNS view for VCN ${vcn}"

	log "creating private zone ${CLUSTER_DOMAIN}"
	oci dns zone create --compartment-id "${compartment_id}" \
		--name "${CLUSTER_DOMAIN}" --zone-type PRIMARY --scope PRIVATE \
		--view-id "${view_id}" \
		--query 'data.id' --raw-output
}

# Make the private zone's view actually answer queries from inside the VCN.
#
# CREATING A PRIVATE ZONE IS NOT ENOUGH, and this is the single most expensive
# thing learned in this example so far. A zone created in a VCN resolver's
# DEFAULT view looks completely correct from the outside: the zone exists, the
# records are right, `oci dns record rrset get` returns them. And no instance
# in the VCN can resolve any of it.
#
# MEASURED. On the run that found this, the resolver attached to the cluster's
# VCN reported:
#
#     attached-views: []
#
# while the private zone holding api-int sat in that resolver's default view.
# Every master booted, ran Ignition, and failed identically:
#
#     Ignition: user-provided config was applied
#     Ignition: fetching configuration for <api-int URL>
#       unable to fetch resource in time
#
# There is no fallback to hide it, either: the public zone publishes `api` but
# deliberately NOT `api-int`, so a master that cannot see the private zone has
# no second place to look. The install then fails somewhere else entirely --
# "failed to provision control-plane machines", or a post-provision hook timing
# out against a cluster with no nodes -- and none of those errors mentions DNS.
#
# Attaching the view explicitly fixed it: a master resolved api-int, fetched
# its config and registered within about ninety seconds.
#
# HONEST LIMIT ON THAT CLAIM. The fix was applied to a live cluster and the
# recovery observed, but re-reading the resolver afterwards to confirm the
# final attached-views list was not possible in that session. The causal link
# rests on the before-state, the failure mode and the timing of the recovery,
# which agree -- not on a direct read of the after-state. Treat the mechanism
# as established and the exact OCI semantics of "default view" versus "attached
# view" as worth confirming once.
#
# Idempotent: the current list is read first and the view appended only if it
# is missing, so a re-run neither duplicates nor detaches anything.
ensure_view_attached() {
	local compartment_id=$1 vcn=$2 resolver_id view_id attached payload

	resolver_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].id" \
		--raw-output)
	view_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].\"default-view-id\"" \
		--raw-output)
	[[ -n ${resolver_id} && ${resolver_id} != "null" ]] ||
		die "no private DNS resolver for VCN ${vcn}; nothing in the VCN could resolve api-int"
	[[ -n ${view_id} && ${view_id} != "null" ]] ||
		die "no default private DNS view for VCN ${vcn}"

	attached=$(oci dns resolver get --resolver-id "${resolver_id}" --scope PRIVATE \
		--query 'data."attached-views"' --output json 2>/dev/null || echo '[]')
	[[ -n ${attached} && ${attached} != "null" ]] || attached='[]'

	if jq -e --arg v "${view_id}" 'any(.[]?; .["view-id"] == $v or .viewId == $v)' \
		<<<"${attached}" >/dev/null 2>&1; then
		log "private DNS view already attached to the VCN resolver"
		return 0
	fi

	# Append rather than replace. The resolver may legitimately carry views for
	# other zones; sending only ours would silently detach them.
	payload=$(jq -c --arg v "${view_id}" \
		'[.[]? | {viewId: (.["view-id"] // .viewId)}] + [{viewId: $v}]' <<<"${attached}")

	log "attaching private DNS view to the VCN resolver"
	oci dns resolver update --resolver-id "${resolver_id}" --scope PRIVATE \
		--attached-views "${payload}" --force >/dev/null ||
		die "could not attach the private DNS view; masters will not resolve api-int"
}

upsert_a_record() {
	local zone_id=$1 fqdn=$2 ip=$3 scope=$4
	log "upserting A ${fqdn} -> ${ip}"
	oci dns record rrset update --zone-name-or-id "${zone_id}" \
		--domain "${fqdn}" --rtype A --scope "${scope}" \
		--items "$(jq -n --arg d "${fqdn}" --arg r "${ip}" \
			'[{domain:$d, rtype:"A", ttl:60, rdata:$r}]')" \
		--force >/dev/null
}

# Wait until a record is visible on the zone's own nameservers, WITHOUT ever
# asking this host's resolver.
#
# MEASURED 2026-10-01, run 13 (mrb-oci3). The public `api` record was upserted
# at 23:14:55. `oc` resolved it for the first time at 23:17:16 -- 2m21s later
# -- and got NXDOMAIN, and the install died there. OCI publishes a zone change
# to its public nameservers asynchronously; 2m21s was not enough.
#
# The failed lookup is not the damage. The recursive resolver CACHES that
# NXDOMAIN for the zone's SOA minimum, which is 1800s here, so every later
# attempt in the same run fails too -- long after the record is genuinely
# live. Confirmed both ways: a direct query to the authoritative nameserver
# returned the address while the system resolver still said NXDOMAIN, and
# `resolvectl flush-caches` made it resolve immediately.
#
# **A fresh cluster name per run does not prevent this**, which is what the
# earlier mitigation assumed. The poisoning query happens inside the same run,
# against a name that has never existed before. Negative caching is not a
# name-reuse problem; it is an ordering problem.
#
# Hence: poll the AUTHORITATIVE servers. A query addressed to them directly
# cannot put anything in the local cache, so the first recursive lookup -- the
# one `oc` makes -- happens only once there is a positive answer to find.
authoritative_ns() {
	# Learned from the delegation of the base domain, which has existed since
	# long before this install, so it cannot itself be the unpublished thing.
	dig +short NS "${BASE_DOMAIN}" 2>/dev/null | sed 's/\.$//' | grep . || true
}

wait_dns_published() {
	local fqdn=$1 deadline ns answer found
	local -a servers=()

	if ! command -v dig >/dev/null 2>&1; then
		log "dig is not on PATH; cannot wait for ${fqdn} to publish"
		return 0
	fi

	mapfile -t servers < <(authoritative_ns)
	if [[ ${#servers[@]} -eq 0 ]]; then
		log "no nameservers found for ${BASE_DOMAIN}; not waiting on ${fqdn}"
		return 0
	fi

	log "waiting for ${fqdn} on ${#servers[@]} authoritative nameserver(s)"
	deadline=$((SECONDS + 600))
	while ((SECONDS < deadline)); do
		# Every one of them, not the first to answer: a partial publish still
		# lets the recursive resolver pick a server that says NXDOMAIN.
		found=yes
		for ns in "${servers[@]}"; do
			answer=$(dig +short +time=3 +tries=1 "@${ns}" "${fqdn}" A 2>/dev/null | grep . || true)
			[[ -n ${answer} ]] || {
				found=no
				break
			}
		done
		if [[ ${found} == yes ]]; then
			log "${fqdn} is published on every authoritative nameserver"
			# Only now is it safe to let the recursive resolver see this name.
			[[ -n $(getent hosts "${fqdn}" 2>/dev/null || true) ]] && return 0
			log "${fqdn} answers authoritatively but not through this host's resolver."
			log "  A negative answer for it is cached locally; it will expire on"
			log "  its own in up to the zone's SOA minimum. To clear it now:"
			log "      resolvectl flush-caches"
			die "local resolver has a stale NXDOMAIN for ${fqdn}"
		fi
		sleep 10
	done
	die "${fqdn} did not publish on its authoritative nameservers within 10m"
}

delete_rrset() {
	local zone_id=$1 fqdn=$2 rtype=$3 scope=$4
	if oci dns record rrset delete --zone-name-or-id "${zone_id}" \
		--domain "${fqdn}" --rtype "${rtype}" --scope "${scope}" \
		--force >/dev/null 2>&1; then
		log "deleted ${rtype} ${fqdn}"
	else
		log "${rtype} ${fqdn} already gone"
	fi
}

# ---------------------------------------------------------------------------
# The 22623 listener
#
# The CLI service group is `oci nlb`, NOT `oci network-load-balancer` --
# `network-load-balancer` is a *subcommand* of it, alongside backend-set,
# listener and backend. So the load balancer itself is
# `oci nlb network-load-balancer get` while its listeners are
# `oci nlb listener ...`, which reads like a typo and is not. Every call here
# was originally written with the long form and failed with
# `Error: No such command 'network-load-balancer'` the first time infra-ready
# got this far (2026-10-01). The LBaaS product is the one with the long group
# name, `oci lb`, and these two load-balancer products having near-identical
# CLI vocabularies is the trap.
# ---------------------------------------------------------------------------

# Wait until the load balancer will accept another change.
#
# `--wait-for-state SUCCEEDED` waits on the WORK REQUEST, and a work request
# can succeed while the load balancer itself is still Updating. The next
# mutation then fails:
#
#   "code": "Conflict", "status": 409, "message": "NLB in Updating state",
#   "operation_name": "create_listener"
#
# -- measured 2026-10-01, creating the 22623 listener one second after the
# backend set's work request reported SUCCEEDED. The backend set really was
# created; only the follow-up was rejected.
#
# So every mutation is gated on the LOAD BALANCER's own lifecycle state rather
# than on the preceding work request. This is not a sleep: it polls.
#
# Called only from nlb_mutate, which is where the gate is paired with a retry
# of the call itself -- read that function for why the gate alone is not
# enough. Returns a status rather than dying, because what a timeout means
# differs between the create and destroy paths and only the caller knows
# which it is on.
nlb_wait_active() {
	local nlb=$1 state="" i
	for ((i = 0; i < 60; i++)); do
		state=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
			--query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
		[[ ${state} == "ACTIVE" ]] && return 0
		sleep 5
	done
	log "network load balancer ${nlb} never returned to ACTIVE (last state: ${state:-unknown})"
	return 1
}

# The load balancer's PRIVATE address, which is what api-int must resolve to.
#
# WHY THIS IS NOT .spec.controlPlaneEndpoint.host. CAPOCI fills that field from
# getNetworkLoadbalancerIp (cloud/scope/network_load_balancer_reconciler.go:279-297),
# which returns IpAddresses[0] when the load balancer is private and otherwise
# the first address with IsPublic true. This cluster's NLB is
# `networkVisibility: Public`, so controlPlaneEndpoint.host is the PUBLIC IP --
# correct for the public `api` record and wrong for everything else.
#
# An OCI public network load balancer has both addresses. Pointing api-int at
# the public one still WORKS, which is what makes it dangerous: the masters sit
# in a private subnet, so every api-int request would leave through the NAT
# gateway and come back in through the internet gateway. It would have installed
# a cluster whose control-plane-to-control-plane traffic hairpins through the
# public internet, and nothing in the install would have complained.
#
# It also forecloses the security property the NSG block in cluster.yaml depends
# on: 22623 is permitted from the VCN CIDR only, on the grounds that every
# legitimate machine-config-server client is inside the VCN. That is true only
# while api-int is the private address. These two decisions have to move
# together -- if this function ever returns a public address, that rule must be
# widened, and a cluster's day-0 Ignition secrets become internet-reachable.
#
# Dies rather than falling back to the public address. A silent fallback here
# would reintroduce exactly the configuration this exists to prevent.
nlb_private_ip() {
	local nlb=$1 ip
	# The single quotes and the backticks are both deliberate: this is a
	# JMESPath expression, where `false` is a literal and "..." quotes an
	# identifier containing a hyphen. Nothing here is shell syntax, so nothing
	# should expand.
	# shellcheck disable=SC2016
	ip=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
		--query 'data."ip-addresses"[?"is-public"==`false`]|[0]."ip-address"' \
		--raw-output 2>/dev/null || true)
	[[ -n ${ip} && ${ip} != "null" ]] ||
		die "no private IP on network load balancer ${nlb}; api-int cannot be published"
	printf '%s' "${ip}"
}

# The public address of an NLB, for the one record that needs it.
#
# WHY THIS EXISTS RATHER THAN `.status.loadBalancer.ingress[0].ip`. An OCI NLB
# in a public subnet has TWO addresses, and the Service status reports only one
# of them. Measured 2026-10-01 on run 13's ingress load balancer:
#
#   ip-addresses: [ {is-public: true,  129.213.x.x},
#                   {is-public: false, 10.0.32.20 } ]
#   Service .status.loadBalancer.ingress[0].ip -> 10.0.32.20
#
# The CCM reported the PRIVATE one. Publishing that into the public zone gives
# a `*.apps` record that resolves, from the internet, to an address inside the
# VCN -- so every Route times out while DNS, the load balancer, the Service and
# the routers are all individually correct. This is the same trap as
# getNetworkLoadbalancerIp returning the public address where api-int needs the
# private one (see nlb_private_ip above), with the polarity reversed: in both
# cases the convenient field is the wrong one, in opposite directions.
#
# So neither zone is served from the Service status. The status is used only as
# a readiness signal; the addresses come from the load balancer itself.
nlb_public_ip() {
	local nlb=$1 ip
	# shellcheck disable=SC2016
	ip=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
		--query 'data."ip-addresses"[?"is-public"==`true`]|[0]."ip-address"' \
		--raw-output 2>/dev/null || true)
	[[ -n ${ip} && ${ip} != "null" ]] || return 1
	printf '%s' "${ip}"
}

# Run one NLB mutation, retrying while the load balancer is busy.
#
# THE STATE GATE ABOVE IS NECESSARY AND NOT SUFFICIENT, and this is the part
# that took two runs to see. Gating alone assumes we are the only writer. We
# are not: at infra-ready CAPOCI has just reported the network ready and is
# still reconciling the same load balancer -- it attaches its own 6443 backend
# set and listener in the same window. So the sequence is
#
#   nlb_wait_active -> ACTIVE          our check, honestly passed
#   CAPOCI issues its own update       the NLB goes Updating
#   our create lands                   409
#
# and the error says so almost in words: "Invalid State Transition of NLB
# lifeCycle state from Updating to Updating" (run 7, 2026-10-01, one second
# after the gate passed). A longer wait cannot fix a race whose other party is
# a controller; only retrying the losing call can.
#
# Retries ONLY on conflict. Any other failure is returned immediately with its
# output, because "already exists" and "no such backend set" are answers, not
# congestion, and retrying them for five minutes would hide them.
#
# Returns non-zero rather than dying, so the destroy path can carry on -- see
# nlb_wait_active for why that distinction matters there.
nlb_mutate() {
	local nlb=$1 what=$2
	shift 2
	local i out=""
	for ((i = 1; i <= 30; i++)); do
		nlb_wait_active "${nlb}" || true
		if out=$("$@" 2>&1); then
			return 0
		fi
		if ! grep -qE 'Invalid State Transition|in Updating state|in Creating state' <<<"${out}"; then
			printf '%s\n' "${out}" >&2
			return 1
		fi
		log "${what}: the load balancer is busy (attempt ${i}/30); retrying"
		sleep 10
	done
	printf '%s\n' "${out}" >&2
	log "${what}: the load balancer stayed busy across 30 attempts"
	return 1
}

add_mcs_listener() {
	local nlb=$1

	if oci nlb backend-set get --network-load-balancer-id "${nlb}" \
		--backend-set-name "${MCS_BACKENDSET}" >/dev/null 2>&1; then
		log "${MCS_BACKENDSET} already exists"
	else
		log "creating backend set ${MCS_BACKENDSET} for port ${MCS_PORT}"
		# Created EMPTY. No machine exists yet at infra-ready; post-provision
		# fills it, and an empty backend set is survivable: Ignition retries a
		# refused connection indefinitely (coreos/ignition
		# internal/resource/http.go -- `for attempt := 1; ; attempt++` with
		# defaultHttpTotalTimeout = 0). What is NOT survivable is a listener
		# that answers 4xx, which shouldRetryHttp treats as final. So an empty
		# backend set here is the safe state, not a race.
		#
		# FIVE_TUPLE is the OCI NLB default and the only sensible choice of the
		# three on offer (TWO_TUPLE, THREE_TUPLE, FIVE_TUPLE) -- there is no
		# round-robin or source-IP policy on this product, unlike LBaaS. An
		# earlier version of this comment claimed SOURCE_IP_ADDRESS, which is
		# not a value this API accepts and never matched the code below it.
		nlb_mutate "${nlb}" "backend set ${MCS_BACKENDSET}" \
			oci nlb backend-set create \
			--network-load-balancer-id "${nlb}" \
			--name "${MCS_BACKENDSET}" \
			--policy FIVE_TUPLE \
			--is-preserve-source false \
			--health-checker "$(jq -n --argjson p "${MCS_PORT}" \
				'{protocol:"HTTPS", port:$p, urlPath:"/healthz",
				  returnCode:200, intervalInMillis:10000,
				  timeoutInMillis:3000, retries:3}')" \
			--wait-for-state SUCCEEDED ||
			die "could not create backend set ${MCS_BACKENDSET} on ${nlb}"
	fi

	if oci nlb listener get --network-load-balancer-id "${nlb}" \
		--listener-name "${MCS_LISTENER}" >/dev/null 2>&1; then
		log "${MCS_LISTENER} already exists"
	else
		# This is the call that found the race: our own backend-set create
		# above left the load balancer busy, and CAPOCI's concurrent
		# reconcile kept it that way. Both are handled by nlb_mutate.
		log "creating listener ${MCS_LISTENER} on port ${MCS_PORT}"
		nlb_mutate "${nlb}" "listener ${MCS_LISTENER}" \
			oci nlb listener create \
			--network-load-balancer-id "${nlb}" \
			--name "${MCS_LISTENER}" \
			--default-backend-set-name "${MCS_BACKENDSET}" \
			--port "${MCS_PORT}" --protocol TCP \
			--wait-for-state SUCCEEDED ||
			die "could not create listener ${MCS_LISTENER} on ${nlb}"
	fi
}

# ---------------------------------------------------------------------------
# The CCM and CSI config Secrets
#
# Shapes copied from oci-openshift/custom_manifests/manifests/
# 01-oci-driver-configs.yml, and the field names verified against the CCM's own
# config struct rather than against that example, because the example only ever
# shows the instance-principal case:
#
#   AuthConfig  pkg/cloudprovider/providers/oci/config/config.go:48-56
#               region, tenancy, user, key, fingerprint, passphrase
#   Config      :151-175  -- useInstancePrincipals is TOP LEVEL
#
# Two things that reading the example alone would get wrong:
#
#   * `auth.useInstancePrincipals` is DEPRECATED. config.go:224-227 copies it
#     up to the top level and logs a warning. Oracle's own manifests still set
#     the deprecated one; this hook sets the top-level field.
#   * when useInstancePrincipals is false, config_validate.go:29-34 requires
#     ALL of region, tenancy, user, key and fingerprint. A partially-filled
#     auth block does not degrade -- the CCM refuses to start.
#
# The six credential fields are read from the OCIClusterIdentity Secret rather
# than from the installer host's ~/.oci/config, because that Secret is the one
# thing guaranteed to be present (the install cannot have got this far without
# it) and because CAPOCI's key names and the CCM's yaml field names are the
# same six words -- both come from the OCI SDK's vocabulary. CAPOCI's side:
# cloud/config/config.go:39-46, read at cloud/util/util.go:133-138.
# ---------------------------------------------------------------------------

render_ccm_secrets() {
	local compartment_id=$1 vcn=$2 lb_subnet=$3 lb_seclist=$4

	# securityListManagementMode decides whether the CCM edits security lists
	# when it creates a load balancer.
	#
	#   Frontend  the CCM manages ingress rules on the named security list.
	#             Needs a security list OCID, which is what Oracle's terraform
	#             provides and CAPOCI does not.
	#   None      the CCM touches no security list. The network must already
	#             permit traffic to the load balancer.
	#
	# With CAPOCI there is no per-subnet security list to name, so the mode
	# follows the network rather than being asserted. Choosing Frontend anyway
	# and pointing it at the VCN's DEFAULT security list would be the obvious
	# shortcut and is deliberately not taken: that list is attached to every
	# subnet in the VCN, so the CCM would be editing rules for the control
	# plane and workers as a side effect of creating an ingress load balancer.
	#
	# The cost of None is explicit and belongs in the open items rather than in
	# a comment nobody reads: *nothing here opens 80/443 to the ingress load
	# balancer.* CAPOCI's service-lb NSG rules are what must permit it, and
	# whether its defaults do is NOT yet verified end to end -- no ingress load
	# balancer has been created by a cluster's own CCM on OCI in this pilot.
	# An `if`, not `[[ ... ]] && lb_mode=Frontend`: under `set -e` an AND-list
	# whose test fails returns 1 and takes the whole hook with it.
	local lb_mode="None"
	if [[ -n ${lb_seclist} ]]; then
		lb_mode="Frontend"
	fi

	# regionKey is the three-letter airport code (iad, phx, fra). config.go:230-240
	# falls back to instance metadata for it and only WARNS when that fails, so
	# an unset regionKey is survivable -- but the fallback runs on the node, and
	# we already know the answer here. Looked up rather than hardcoded or parsed
	# out of the region name, because the mapping is not derivable.
	local region region_key
	region=${OCI_CLI_REGION:?set it to the region the cluster is being created in}
	region_key=$(oci iam region list \
		--query "data[?name=='${region}'].key | [0]" --raw-output 2>/dev/null || true)

	if [[ ${OCI_CCM_AUTH} == "api-key" && ! -f ${PROVIDER_CREDENTIALS} ]]; then
		die "OCI_CCM_AUTH=api-key but there is no credential Secret at ${PROVIDER_CREDENTIALS}"
	fi

	# Rendered by python rather than by a heredoc, for one reason: with
	# OCI_CCM_AUTH=api-key the document embeds a PEM private key, and a shell
	# heredoc indents it with `sed 's/^/    /'`. A multi-line secret pushed
	# through line-oriented text munging is exactly the construct that produced
	# the dangling-sshKey bug recorded in the workspace AGENTS.md -- an edit that
	# lands halfway looks identical to one that lands, from the placeholder's
	# side. A YAML emitter cannot indent a block scalar wrongly.
	#
	# It also writes nothing to stdout. Every value handled here is a
	# credential; the only thing that leaves this function is a byte count.
	python3 - "${CCM_STATE}" "${OCI_CCM_AUTH}" "${PROVIDER_CREDENTIALS}" \
		"${compartment_id}" "${vcn}" "${lb_subnet}" "${lb_mode}" "${lb_seclist}" \
		"${region}" "${region_key}" <<-'PY'
		import base64, pathlib, sys, yaml

		# Emit multi-line strings as `|` blocks instead of as one long
		# double-quoted line with \n escapes. Purely for the human who has to
		# read this file while debugging a CCM that will not start -- the
		# default dump is correct and unreadable.
		#
		# Guarded, and the guard is the point: a `|` block cannot represent a
		# line with trailing whitespace, and PyYAML silently falls back to
		# quoting if asked, but being explicit about WHY it is safe is cheaper
		# than trusting it. Verified by round-tripping the PEM through both YAML
		# layers in the test below the fold.
		def block(dumper, data):
		    style = "|" if "\n" in data and not any(
		        line != line.rstrip() for line in data.split("\n")) else None
		    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)
		yaml.SafeDumper.add_representer(str, block)

		(state, mode, credpath, compartment, vcn,
		 lb_subnet, lb_mode, lb_seclist, region, region_key) = sys.argv[1:11]

		cfg = {
		    "useInstancePrincipals": mode == "instance-principal",
		    "compartment": compartment,
		    "vcn": vcn,
		    "loadBalancer": {
		        "subnet1": lb_subnet,
		        "securityListManagementMode": lb_mode,
		    },
		    "rateLimiter": {
		        "rateLimitQPSRead": 20.0,
		        "rateLimitBucketRead": 5,
		        "rateLimitQPSWrite": 20.0,
		        "rateLimitBucketWrite": 5,
		    },
		}
		if region_key:
		    cfg["regionKey"] = region_key
		if lb_seclist:
		    cfg["loadBalancer"]["securityLists"] = {lb_subnet: lb_seclist}

		if mode == "api-key":
		    # Both spellings, because the Secret is hand-authored by the operator
		    # and either is valid Kubernetes.
		    fields = {}
		    for doc in yaml.safe_load_all(pathlib.Path(credpath).read_text()):
		        if not doc or doc.get("kind") != "Secret":
		            continue
		        fields.update(doc.get("stringData") or {})
		        fields.update({k: base64.b64decode(v).decode()
		                       for k, v in (doc.get("data") or {}).items()})

		    auth = {"region": region}
		    for name in ("tenancy", "user", "key", "fingerprint"):
		        value = fields.get(name) or ""
		        # .strip() on the key too: a trailing newline is harmless but a
		        # leading one breaks the PEM parser, and operators paste these.
		        value = value.strip()
		        if not value:
		            # The NAME, never the value, and never a length -- a length is
		            # a fact about a secret.
		            sys.exit("%s has no '%s'; the CCM requires it when "
		                     "useInstancePrincipals is false "
		                     "(config_validate.go:29-34)" % (credpath, name))
		        auth[name] = value
		    # Optional, and empty is normal -- an unencrypted key has none.
		    auth["passphrase"] = (fields.get("passphrase") or "").strip()

		    if "PRIVATE KEY" not in auth["key"]:
		        sys.exit("the 'key' field of %s is not a PEM private key" % credpath)
		    cfg["auth"] = auth

		docs = [
		    ("oci-cloud-controller-manager", "oci-cloud-controller-manager",
		     "cloud-provider.yaml"),
		    ("oci-volume-provisioner", "oci-csi", "config.yaml"),
		]
		# Both Secrets carry the same document under different keys in different
		# namespaces, which is how Oracle ships it.
		body = yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)
		out = pathlib.Path(state)
		out.write_text(yaml.safe_dump_all([
		    {"apiVersion": "v1", "kind": "Secret",
		     "metadata": {"name": name, "namespace": ns},
		     "stringData": {key: body}}
		    for name, ns, key in docs
		], default_flow_style=False, sort_keys=False, explicit_start=True))
		out.chmod(0o600)
	PY

	log "rendered CCM/CSI config with ${OCI_CCM_AUTH} auth ($(wc -c <"${CCM_STATE}") bytes)"
	if [[ ${OCI_CCM_AUTH} == "api-key" ]]; then
		log "WARNING: that config carries a user API signing key. It is a pilot"
		log "WARNING: expedient; instance principals are the intended end state."
	fi
}

# Try to land the Secrets as day-0 content. Whether <install-dir>/openshift
# still exists and is still consumed at infra-ready is UNVERIFIED -- see
# ../extra-manifests/README.md. If it does not, post-provision applies them
# instead, at the cost of the CCM crash-looping until then.
place_ccm_secrets() {
	local openshift_dir="${OPENSHIFT_INSTALL_DIR:-.}/openshift"
	if [[ -d ${openshift_dir} ]]; then
		cp "${CCM_STATE}" "${openshift_dir}/99_external-01-oci-ccm-config.yaml"
		log "placed CCM/CSI config in ${openshift_dir} as day-0 content"
		printf 'day0'
	else
		log "no ${openshift_dir}; CCM/CSI config will be applied at post-provision"
		printf 'post-provision'
	fi
}

# ---------------------------------------------------------------------------
# infra-ready
# ---------------------------------------------------------------------------

infra_ready() {
	local compartment_id vcn nlb api_ip internal_ip lb_subnet lb_seclist lb_nsg zone_id ccm_mode

	compartment_id=$(compartment)
	vcn=$(vcn_id)
	nlb=$(nlb_id)
	# TWO addresses, and which one goes where is load-bearing -- see
	# nlb_private_ip for why the public one must not reach api-int.
	api_ip=$(api_endpoint)
	internal_ip=$(nlb_private_ip "${nlb}")
	lb_subnet=$(subnet_by_role service-lb)
	# Both optional, and with CAPOCI it is always the NSG that is present.
	lb_seclist=$(seclist_by_role service-lb)
	lb_nsg=$(nsg_by_role service-lb)

	log "VCN ${vcn}, NLB ${nlb}, API endpoint ${api_ip} (public) / ${internal_ip} (private)"
	log "service-lb subnet ${lb_subnet}, security list ${lb_seclist:-<none>}, NSG ${lb_nsg:-<none>}"

	# 1. The 22623 listener, before DNS -- if this fails there is no point
	#    publishing a name that cannot serve the machine config server.
	add_mcs_listener "${nlb}"

	# 2. Private DNS, on the PRIVATE address. api-int is what the pointer
	#    ignition and the bootstrap kubeconfig resolve, and both are fetched
	#    from inside the VCN; `api` in the private zone shadows the public
	#    record for in-VCN clients, which is the same intent.
	zone_id=$(create_private_zone "${compartment_id}" "${vcn}")
	# Before any record is written, not after: a zone whose view is not
	# attached resolves for nobody inside the VCN, and the records would be
	# correct and useless. See ensure_view_attached.
	ensure_view_attached "${compartment_id}" "${vcn}"
	upsert_a_record "${zone_id}" "api-int.${CLUSTER_DOMAIN}" "${internal_ip}" PRIVATE
	upsert_a_record "${zone_id}" "api.${CLUSTER_DOMAIN}" "${internal_ip}" PRIVATE

	# 3. Public api, when the cluster is published externally. The public zone
	#    for the base domain is assumed to exist and to be managed by OCI DNS;
	#    a partner using another DNS provider replaces this one call.
	local public_zone=""
	if [[ ${PUBLISH} == "External" ]]; then
		public_zone=$(oci dns zone list --compartment-id "${compartment_id}" \
			--name "${BASE_DOMAIN}" --scope GLOBAL \
			--query 'data[0].id' --raw-output 2>/dev/null || true)
		if [[ -n ${public_zone} && ${public_zone} != "null" ]]; then
			upsert_a_record "${public_zone}" "api.${CLUSTER_DOMAIN}" "${api_ip}" GLOBAL
		else
			public_zone=""
			log "no public zone for ${BASE_DOMAIN}; skipping the public api record"
		fi
	fi

	# 4. The CCM and CSI config.
	render_ccm_secrets "${compartment_id}" "${vcn}" "${lb_subnet}" "${lb_seclist}"
	ccm_mode=$(place_ccm_secrets)

	# 5. Record everything created, for pre-destroy. Nothing here is owned by
	#    Cluster API, so nothing else will remove it.
	jq -n \
		--arg zone "${zone_id}" \
		--arg public_zone "${public_zone}" \
		--arg nlb "${nlb}" \
		--arg compartment "${compartment_id}" \
		--arg vcn "${vcn}" \
		--arg ccm_mode "${ccm_mode}" \
		--arg lb_subnet "${lb_subnet}" \
		--arg lb_nsg "${lb_nsg}" \
		'{privateZoneId:$zone, publicZoneId:$public_zone, nlbId:$nlb,
		  compartmentId:$compartment, vcnId:$vcn, ccmMode:$ccm_mode,
		  serviceLbSubnetId:$lb_subnet, serviceLbNsgId:$lb_nsg}' >"${STATE}"

	log "infra-ready complete"
}

# ---------------------------------------------------------------------------
# post-provision
# ---------------------------------------------------------------------------

INPUT_SERVICE=""
TIMEOUT_SECONDS=1800

parse_post_provision_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--input-service=*) INPUT_SERVICE=${1#*=} ;;
		--input-service) INPUT_SERVICE=${2:?--input-service needs a value}; shift ;;
		--timeout-seconds=*) TIMEOUT_SECONDS=${1#*=} ;;
		--timeout-seconds) TIMEOUT_SECONDS=${2:?--timeout-seconds needs a value}; shift ;;
		*) die "unknown argument $1" ;;
		esac
		shift
	done
	[[ -n ${INPUT_SERVICE} ]] || die "--input-service is required for post-provision"
}

kube() {
	oc --kubeconfig "${OPENSHIFT_INSTALL_KUBECONFIG:?}" "$@"
}

# Add every control-plane instance to the 22623 backend set.
#
# CAPOCI does this itself for apiserver-lb-backendset
# (cloud/scope/machine.go:874-895) and only for that one, so the second
# backend set is ours to populate.
#
# The bootstrap machine serves 22623 too, and arguably needs to be a backend
# EARLIER than this -- masters fetch their config on first boot, which is
# before post-provision runs. This is the least-settled part of the design and
# is called out in ../../docs/capi-requirements.md.
populate_mcs_backends() {
	local nlb=$1 compartment_id=$2 instances ocid ip count=0

	instances=$(oci compute instance list --compartment-id "${compartment_id}" \
		--lifecycle-state RUNNING \
		--query "data[?\"freeform-tags\".\"openshift-cluster-id\"=='${INFRA_ID}' &&
		          (\"freeform-tags\".\"openshift-machine-role\"=='master' ||
		           \"freeform-tags\".\"openshift-machine-role\"=='bootstrap')].id" \
		--raw-output | jq -r '.[]? // empty')

	[[ -n ${instances} ]] || { log "no control-plane instances tagged for ${INFRA_ID} yet"; return 0; }

	while read -r ocid; do
		[[ -n ${ocid} ]] || continue
		ip=$(oci compute instance list-vnics --instance-id "${ocid}" \
			--query 'data[0]."private-ip"' --raw-output)
		[[ -n ${ip} && ${ip} != "null" ]] || { log "no private IP for ${ocid}; skipping"; continue; }

		# Through nlb_mutate, and the loop is why it matters most here: each
		# successful create leaves the load balancer busy, so the second
		# master is the one that would get the 409. The else branch below
		# would then call it "already a backend" and that master would never
		# serve 22623 -- a silently half-populated backend set, which is worse
		# than a failure because the install goes on to time out somewhere
		# else entirely.
		if nlb_mutate "${nlb}" "backend ${ip}:${MCS_PORT}" \
			oci nlb backend create \
			--network-load-balancer-id "${nlb}" \
			--backend-set-name "${MCS_BACKENDSET}" \
			--ip-address "${ip}" --port "${MCS_PORT}" \
			--wait-for-state SUCCEEDED 2>/dev/null; then
			log "added ${ip}:${MCS_PORT} to ${MCS_BACKENDSET}"
			count=$((count + 1))
		else
			log "${ip}:${MCS_PORT} already a backend, or could not be added"
		fi
	done <<<"${instances}"

	log "${count} backend(s) added to ${MCS_BACKENDSET}"
}

# Wait for the ingress Service to get a load balancer address. That load
# balancer is built by the cluster's OWN cloud controller manager, minutes
# into bootstrap, which is why the *.apps wildcard cannot be created at
# infra-ready: at that point nothing has built it and nothing will.
service_address() {
	local ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local deadline=$(( $(date +%s) + TIMEOUT_SECONDS )) addr=""

	log "waiting up to ${TIMEOUT_SECONDS}s for ${ns}/${name} to get an address"
	while [[ $(date +%s) -lt ${deadline} ]]; do
		addr=$(kube -n "${ns}" get service "${name}" \
			-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
		[[ -n ${addr} ]] && { printf '%s' "${addr}"; return 0; }
		sleep 15
	done
	die "${ns}/${name} had no load balancer address after ${TIMEOUT_SECONDS}s"
}

# Put the service-lb NSG's OCID on the ingress Service, before the CCM has
# built anything.
#
# THIS IS DIVERGENCE 077's DEFECT 1 IN A SECOND COMPONENT: PLACEMENT EXPRESSIBLE
# ONLY BY OCID. CAPOCI builds a correctly-ruled service-lb NSG -- 80 and 443
# from 0.0.0.0/0 -- and the cluster's own CCM never uses it, because the CCM
# attaches an NSG only when the Service names one, and names it by OCID. That
# OCID does not exist when the Service manifest is written: it is created by
# CAPOCI minutes later. So the day-0 manifest CANNOT carry it and a hook is the
# only place the two ends can be joined. The same shape as CAPOCI's machine
# subnets, in a different controller, which is why it is worth naming as a
# class rather than fixing twice: a provider that expresses placement only by
# generated identifier forces an out-of-band step on anyone composing it with
# day-0 manifests.
#
# Why it is not enough to leave this to the subnet's security list: CAPOCI puts
# the service-lb subnet on the VCN's DEFAULT security list, whose ingress is
# SSH and ICMP only. There is no per-subnet list to point
# `securityListManagementMode: Frontend` at -- which is why render_ccm_secrets
# chooses None -- so with no NSG there is nothing anywhere permitting 80/443 to
# the load balancer.
#
# Best-effort by design. A cluster whose ingress is fronted out of band, or
# whose operator has already annotated the Service by hand, is not an error.
annotate_ingress_nsg() {
	local nsg=$1 ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local deadline=$(( $(date +%s) + 300 )) current

	if [[ -z ${nsg} || ${nsg} == "null" ]]; then
		log "WARNING: no service-lb NSG recorded; the ingress load balancer will"
		log "WARNING: be created without one. Unless something else permits 80 and"
		log "WARNING: 443 to it, *.apps will resolve and then time out."
		return 0
	fi

	# Wait for the Service to exist at all. It is a day-0 extra manifest, so it
	# is applied during bootstrap -- which may or may not have reached it by the
	# time post-provision starts. Annotating BEFORE the CCM first reconciles is
	# what makes the load balancer come up with the group already attached,
	# rather than coming up wrong and being corrected.
	while [[ $(date +%s) -lt ${deadline} ]]; do
		kube -n "${ns}" get service "${name}" >/dev/null 2>&1 && break
		sleep 10
	done
	if ! kube -n "${ns}" get service "${name}" >/dev/null 2>&1; then
		log "WARNING: ${ns}/${name} does not exist; cannot annotate it with the"
		log "WARNING: service-lb NSG. Is 99_external-04-ingress-nlb.yaml in"
		log "WARNING: extra-manifests?"
		return 0
	fi

	current=$(kube -n "${ns}" get service "${name}" \
		-o "jsonpath={.metadata.annotations.${NSG_ANNOTATION//./\\.}}" 2>/dev/null || true)
	if [[ ${current} == "${nsg}" ]]; then
		log "ingress Service already carries the service-lb NSG"
		return 0
	fi

	if kube -n "${ns}" annotate service "${name}" \
		"${NSG_ANNOTATION}=${nsg}" --overwrite >/dev/null 2>&1; then
		log "annotated ${ns}/${name} with the service-lb NSG"
	else
		log "WARNING: could not annotate ${ns}/${name} with the service-lb NSG"
	fi
}

# The OCID of the load balancer the CCM built for the ingress Service.
#
# RECORDED BECAUSE THERE IS NO OTHER HANDLE ON IT. Measured 2026-10-01 on run
# 13: the CCM names the load balancer
#
#   openshift-ingress/router-external-default/<service-uid>
#
# and tags it with NOTHING -- `freeform-tags: {}`, only Oracle's own
# `Oracle-Tags` namespace. So at destroy time, with the cluster API already
# gone, there is no tag to sweep on and the display name contains neither the
# cluster name nor the infrastructure ID. Worse, the obvious repair -- sweeping
# NLBs whose display name contains the infrastructure ID -- MATCHES
# `<infra-id>-apiserver`, which is CAPOCI's, and would delete the cluster's API
# load balancer out from under the provider that owns it.
#
# The only safe handle is the OCID, captured here while the API still answers.
ingress_nlb_id() {
	local compartment_id=$1 ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local uid id

	uid=$(kube -n "${ns}" get service "${name}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
	[[ -n ${uid} ]] || return 1

	# Matched on the UID suffix, not on a substring of the cluster name: the
	# UID is unique to this Service and cannot collide with the apiserver NLB.
	id=$(oci nlb network-load-balancer list --compartment-id "${compartment_id}" --all \
		--query "data.items[?ends_with(\"display-name\", '${uid}')]|[0].id" \
		--raw-output 2>/dev/null || true)
	[[ -n ${id} && ${id} != "null" ]] || return 1
	printf '%s' "${id}"
}

post_provision() {
	parse_post_provision_args "$@"

	[[ -f ${STATE} ]] || die "no ${STATE}; infra-ready did not run or did not complete"

	local nlb compartment_id zone_id public_zone ccm_mode apps_ip
	local lb_nsg apps_nlb apps_private apps_public
	nlb=$(jq -r '.nlbId' "${STATE}")
	compartment_id=$(jq -r '.compartmentId' "${STATE}")
	zone_id=$(jq -r '.privateZoneId' "${STATE}")
	public_zone=$(jq -r '.publicZoneId // empty' "${STATE}")
	ccm_mode=$(jq -r '.ccmMode' "${STATE}")
	lb_nsg=$(jq -r '.serviceLbNsgId // empty' "${STATE}")

	# 1. Backends for 22623, first -- everything downstream needs the machine
	#    config server reachable.
	populate_mcs_backends "${nlb}" "${compartment_id}"

	# 2. The first use of the API endpoint in this hook, and therefore the
	#    first DNS lookup of the public api record. See wait_dns_published for
	#    why that lookup must not be made speculatively.
	if [[ -n ${public_zone} ]]; then
		wait_dns_published "api.${CLUSTER_DOMAIN}"
	fi

	# 3. The CCM config, if it could not be day-0 content.
	if [[ ${ccm_mode} != "day0" ]]; then
		log "applying CCM/CSI config"
		kube apply -f "${CCM_STATE}" >/dev/null
	fi

	# 4. The ingress load balancer's network security group, BEFORE waiting for
	#    an address. Annotating first means the CCM builds the load balancer
	#    with the group already attached instead of building it wrong and being
	#    corrected -- and the correction is not free: the CCM resets
	#    network-security-group-ids to whatever the annotation says on every
	#    reconcile, so a group attached out of band is wiped on the next pass.
	#    Measured 2026-10-01: attached with `oci nlb ... update-network-security-
	#    groups`, gone within the minute. Whatever the CCM reconciles must come
	#    from the Service, which is the same contract CAPOCI imposes for NSG
	#    rules (see cluster.yaml) seen from the other side.
	annotate_ingress_nsg "${lb_nsg}"

	# 5. The ingress wildcard.
	apps_ip=$(service_address)
	log "ingress Service has an address; resolving the load balancer behind it"

	# The Service status is a readiness signal, not an address source. Resolve
	# the load balancer and read both of its addresses -- see nlb_public_ip for
	# why the status field alone publishes the wrong one into the public zone.
	apps_private=${apps_ip}
	apps_public=${apps_ip}
	if apps_nlb=$(ingress_nlb_id "${compartment_id}"); then
		apps_private=$(nlb_private_ip "${apps_nlb}")
		apps_public=$(nlb_public_ip "${apps_nlb}") || apps_public=${apps_private}
		log "ingress load balancer ${apps_public} (public) / ${apps_private} (private)"
	else
		# Not fatal: a single-address load balancer, or an installation whose
		# CCM names things differently, still has a usable status field. Say
		# which address is about to be published rather than implying both were
		# resolved.
		apps_nlb=""
		log "WARNING: could not resolve the ingress load balancer's OCID;"
		log "WARNING: publishing ${apps_ip} from the Service status into both"
		log "WARNING: zones, and pre-destroy will have no handle on it."
	fi

	upsert_a_record "${zone_id}" "*.apps.${CLUSTER_DOMAIN}" "${apps_private}" PRIVATE
	if [[ -n ${public_zone} ]]; then
		if [[ ${apps_public} == "${apps_private}" && -n ${apps_nlb} ]]; then
			log "WARNING: the ingress load balancer has no public address, so the"
			log "WARNING: public *.apps record points inside the VCN. Routes will"
			log "WARNING: resolve from the internet and then time out."
		fi
		upsert_a_record "${public_zone}" "*.apps.${CLUSTER_DOMAIN}" "${apps_public}" GLOBAL
	fi

	# The OCID is the point of this file. See ingress_nlb_id.
	jq -n \
		--arg ip "${apps_public}" \
		--arg private "${apps_private}" \
		--arg nlb "${apps_nlb}" \
		'{appsAddress:$ip, appsPrivateAddress:$private, appsNlbId:$nlb}' >"${APPS_STATE}"
	log "post-provision complete"
}

# ---------------------------------------------------------------------------
# pre-destroy
# ---------------------------------------------------------------------------

# The load balancer the cluster's CCM built for the ingress Service is not a
# Cluster API resource and deleting the Cluster will not touch it. Deleting the
# Service makes the CCM remove its own load balancer, which is both tidier and
# more correct than deleting the load balancer behind the CCM's back. If the
# API is already gone, fall back to deleting by tag.
destroy_ingress() {
	local ns name
	ns=${INPUT_SERVICE%%/*}
	name=${INPUT_SERVICE##*/}

	if [[ -z ${INPUT_SERVICE} ]]; then
		# pre-destroy takes no arguments, so recover the Service from the
		# install-config's post-provision args if they are reachable; failing
		# that, fall through to the tag sweep.
		ns=openshift-ingress
		name=router-external-default
	fi

	if [[ -n ${OPENSHIFT_INSTALL_KUBECONFIG:-} ]] &&
		kube -n "${ns}" get service "${name}" >/dev/null 2>&1; then
		log "deleting service ${ns}/${name} so the CCM removes its load balancer"
		kube -n "${ns}" delete service "${name}" --wait=true --timeout=5m >/dev/null || true
		return 0
	fi

	# THE FALLBACK IS BY OCID AND BY NOTHING ELSE, and the two things it does
	# not do are both bugs this path had.
	#
	# 1. It used to call `oci lb load-balancer delete`. That is LBaaS; the CCM
	#    builds a NETWORK load balancer (`load-balancer-type: nlb`, set by the
	#    Service annotation). The LBaaS list is empty on this cluster, so the
	#    sweep found nothing and returned 0 -- "already gone" and "I looked in
	#    the wrong service" being the same code path, which is precisely the
	#    hazard ../../docs/hooks.md names.
	#
	# 2. It used to match on `contains(display-name, INFRA_ID)`. The CCM's
	#    display name is `<namespace>/<name>/<service-uid>` and contains the
	#    infrastructure ID NOWHERE, so that predicate could never match the
	#    load balancer it was aimed at -- while `<infra-id>-apiserver`, which
	#    is CAPOCI's and must not be touched by this hook, matches it exactly.
	#    A sweep that cannot find its target but can find its neighbour is
	#    worse than no sweep.
	#
	# Both measured 2026-10-01 against run 13's live cluster, along with the
	# reason there is no third option: the CCM tags the load balancer with
	# nothing at all (`freeform-tags: {}`).
	local apps_nlb
	apps_nlb=$(jq -r '.appsNlbId // empty' "${APPS_STATE}" 2>/dev/null || true)
	if [[ -z ${apps_nlb} ]]; then
		log "WARNING: the cluster API is unreachable and no ingress load balancer"
		log "WARNING: OCID was recorded, so there is no safe way to find it: the"
		log "WARNING: CCM tags it with nothing and its name carries neither the"
		log "WARNING: cluster name nor the infrastructure ID. If post-provision"
		log "WARNING: ever ran, look for a network load balancer named"
		log "WARNING: ${ns}/${name}/<uid> in this compartment and delete it by hand."
		return 0
	fi

	if ! oci nlb network-load-balancer get --network-load-balancer-id "${apps_nlb}" \
		>/dev/null 2>&1; then
		log "ingress load balancer is already gone"
		return 0
	fi
	log "cluster API not reachable; deleting the recorded ingress load balancer"
	if oci nlb network-load-balancer delete --network-load-balancer-id "${apps_nlb}" \
		--force --wait-for-state SUCCEEDED >/dev/null 2>&1; then
		log "deleted the ingress load balancer"
	else
		log "WARNING: could not delete ingress load balancer ${apps_nlb}; remove it by hand"
	fi
}

# The bootstrap ignition object and its pre-authenticated request.
#
# The PAR is an unauthenticated URL over the cluster's day-0 secrets. Its
# expiry is a backstop; this is the cleanup. Never log the URL -- it IS the
# credential. Log the object name only.
destroy_bootstrap_ignition() {
	local bucket object par_id

	if [[ ! -f ${IGNITION_STATE} ]]; then
		log "no ${IGNITION_STATE}; no bootstrap ignition object was offloaded"
		return 0
	fi

	bucket=$(jq -r '.ignitionBucket // empty' "${IGNITION_STATE}")
	object=$(jq -r '.ignitionObject // empty' "${IGNITION_STATE}")
	par_id=$(jq -r '.ignitionParId // empty' "${IGNITION_STATE}")

	[[ -n ${bucket} ]] || { log "no bucket recorded in ${IGNITION_STATE}"; return 0; }

	if [[ -n ${par_id} ]]; then
		log "deleting the pre-authenticated request over ${object}"
		oci os preauth-request delete --bucket-name "${bucket}" \
			--par-id "${par_id}" --force >/dev/null 2>&1 ||
			log "pre-authenticated request already gone"
	fi
	if [[ -n ${object} ]]; then
		log "deleting object ${object} from ${bucket}"
		oci os object delete --bucket-name "${bucket}" \
			--object-name "${object}" --force >/dev/null 2>&1 ||
			log "object already gone"
	fi
}

# The listener and backend set added at infra-ready. Normally moot, because
# CAPOCI deletes the whole NLB when the Cluster goes -- but a destroy re-run
# after a partial failure may find the NLB still there, and the standing rule
# is that whatever this hook creates, it removes.
destroy_mcs_listener() {
	local nlb
	nlb=$(jq -r '.nlbId // empty' "${STATE}" 2>/dev/null || true)
	[[ -n ${nlb} ]] || return 0

	oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" >/dev/null 2>&1 || {
		log "NLB ${nlb} is already gone"
		return 0
	}

	# Listener before backend set: OCI refuses to delete a backend set that a
	# listener still points at.
	#
	# Both go through nlb_mutate, and on this path the conflict retry matters
	# more than on the create path. A 409 here would land in an `else` reading
	# "already gone" -- precisely the hazard ../../docs/hooks.md names:
	# "already gone" and "I failed to recognise it" are the same code path and
	# the second one exits 0. The listener delete leaves the load balancer
	# busy, so without the retry the backend-set delete below it would report
	# success having deleted nothing.
	#
	# Stderr is NOT suppressed on either, and the else branches say what they
	# actually know. A teardown that cannot tell "gone" from "refused" is how
	# the *.apps record leaked on the AWS pilot.
	if nlb_mutate "${nlb}" "delete listener ${MCS_LISTENER}" \
		oci nlb listener delete --network-load-balancer-id "${nlb}" \
		--listener-name "${MCS_LISTENER}" --force; then
		log "deleted listener ${MCS_LISTENER}"
	else
		log "listener ${MCS_LISTENER} is already gone, or could not be deleted (see above)"
	fi

	if nlb_mutate "${nlb}" "delete backend set ${MCS_BACKENDSET}" \
		oci nlb backend-set delete --network-load-balancer-id "${nlb}" \
		--backend-set-name "${MCS_BACKENDSET}" --force; then
		log "deleted backend set ${MCS_BACKENDSET}"
	else
		log "backend set ${MCS_BACKENDSET} is already gone, or could not be deleted (see above)"
	fi
}

# Put CAPOCI's credential Secret back into the local control plane before the
# Cluster is deleted.
#
# THIS IS NOT A TIDINESS STEP -- WITHOUT IT THE TEARDOWN CANNOT COMPLETE AND
# THE WHOLE NETWORK LEAKS.
#
# `destroy cluster` rebuilds the local control plane and re-applies the objects
# recorded under <install-dir>/.clusterapi_output/. That recording deliberately
# excludes Secrets:
#
#   // pkg/infrastructure/clusterapi/clusterapi.go:696-700
#   // Skip secrets to avoid writing sensitive data to disk.
#   if gvk.Kind == "Secret" { ... continue }
#
# which is the right call -- an OCI API signing key must not be written into an
# install directory that ends up in a support bundle. But OCIClusterIdentity
# resolves its credentials through a Secret (cloud/util/util.go:118-163), so on
# the destroy path CAPOCI finds nothing, cannot build an OCI client, and the
# OCICluster finalizer is never cleared:
#
#   "Reconciler error" err="Unable to fetch ClientSecret:
#       Secret \"<infra-id>-oci-credentials\" not found" controllerKind="OCICluster"
#   "Cluster still has descendants - waiting for infrastructure cluster deletion"
#
# It spins there forever. Measured 2026-10-01: ten minutes of that loop with
# the VCN, four subnets, two gateways and the NLB all still AVAILABLE.
#
# CAPA never shows this because it authenticates from the controller process's
# own environment, not from a Secret -- so this is a gap the reference provider
# structurally cannot expose, and the first genuinely external provider hits it
# on its first teardown. See ../../docs/capi-requirements.md.
#
# The hook can repair it because pre-destroy runs BEFORE the delete
# (pkg/destroy/external/external.go:118, ahead of deleteCluster at :121) and
# the local control plane is already up by then. Its kubeconfig is not in the
# hook contract; it is at a fixed path under the install directory
# (pkg/clusterapi/system.go:63, ArtifactsDir = ".clusterapi_output"). Relying
# on an internal path is a wart, and it is recorded as a requirement rather
# than hidden: the contract should hand the hook this kubeconfig.
restore_provider_credentials() {
	local kubeconfig secret
	kubeconfig="${OPENSHIFT_INSTALL_DIR:-.}/.clusterapi_output/envtest.kubeconfig"
	secret="${PROVIDER_CREDENTIALS}"

	if [[ ! -f ${kubeconfig} ]]; then
		log "WARNING: no local control plane kubeconfig at ${kubeconfig};"
		log "WARNING: if CAPOCI cannot find its credential Secret the delete will hang"
		return 0
	fi
	if [[ ! -f ${secret} ]]; then
		log "WARNING: no provider credential Secret at ${secret}."
		log "WARNING: CAPOCI will not be able to authenticate and the OCICluster"
		log "WARNING: finalizer will never clear -- the VCN, subnets, gateways and"
		log "WARNING: NLB will be left behind and must be removed by hand."
		return 0
	fi

	# apply, not create: a re-run of a failed destroy must not fail here.
	# Output is the object reference only; `oc apply` never echoes Secret data.
	if oc --kubeconfig "${kubeconfig}" apply -f "${secret}" >/dev/null 2>&1; then
		log "restored the CAPOCI credential Secret into the local control plane"
	else
		log "WARNING: could not apply ${secret} to the local control plane;"
		log "WARNING: the delete below will probably hang on the OCICluster finalizer"
	fi
}

pre_destroy() {
	# First, because everything after it depends on CAPOCI being able to talk
	# to OCI at all.
	restore_provider_credentials

	# The bootstrap ignition object is next, and unconditional -- ahead of the
	# STATE check below rather than after it. It is
	# recorded in a different file, written by the create script before the
	# installer ever started, so an install that failed before infra-ready can
	# still have left an unauthenticated URL over the cluster's day-0 secrets
	# sitting in object storage. That is exactly the case where an early
	# return would be worst.
	destroy_bootstrap_ignition

	if [[ ! -f ${STATE} ]]; then
		log "no ${STATE}; infra-ready left nothing else to remove"
		return 0
	fi

	destroy_ingress
	destroy_mcs_listener

	local zone_id public_zone
	zone_id=$(jq -r '.privateZoneId // empty' "${STATE}")
	public_zone=$(jq -r '.publicZoneId // empty' "${STATE}")

	# The public records first, and by exact name. That zone belongs to the
	# base domain and holds other clusters' records; deleting anything not
	# named here would take out somebody else's cluster.
	if [[ -n ${public_zone} ]]; then
		delete_rrset "${public_zone}" "api.${CLUSTER_DOMAIN}" A GLOBAL
		delete_rrset "${public_zone}" "*.apps.${CLUSTER_DOMAIN}" A GLOBAL
	fi

	# Then the private zone, whole. It was created for this cluster and holds
	# nothing else, so it goes rather than being emptied record by record.
	if [[ -n ${zone_id} ]]; then
		if oci dns zone get --zone-name-or-id "${zone_id}" --scope PRIVATE >/dev/null 2>&1; then
			log "deleting private zone ${CLUSTER_DOMAIN}"
			oci dns zone delete --zone-name-or-id "${zone_id}" --scope PRIVATE \
				--force >/dev/null
		else
			log "private zone is already gone"
		fi
	fi

	rm -f "${STATE}" "${APPS_STATE}" "${CCM_STATE}"
	log "pre-destroy complete"
}

# The three halves are one file so that what a hook creates and what removes it
# can be read against each other. Only post-provision takes arguments;
# forwarding "$@" to it and to nothing else is deliberate, so that an argument
# sent to the wrong hook is an error rather than a no-op.
case ${OPENSHIFT_INSTALL_HOOK} in
infra-ready) infra_ready ;;
post-provision) post_provision "$@" ;;
pre-destroy) pre_destroy ;;
*) die "unknown hook ${OPENSHIFT_INSTALL_HOOK}" ;;
esac
