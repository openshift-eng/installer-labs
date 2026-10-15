#!/usr/bin/env bash
#
# Reference InfraReady / PostProvision / PreDestroy hook for
# `platform: external` with a Cluster API infrastructure provider.
#
# WHY THIS EXISTS
#
# On an integrated platform the installer creates the cluster's DNS itself,
# after CAPI reports the network ready. For AWS that is
# pkg/infrastructure/aws/clusterapi/aws.go:112 `InfraReady`, which creates the
# private hosted zone for the cluster domain and the `api` / `api-int` records
# pointing at the API load balancers.
#
# `platform: external` has no such code and must not grow any: the whole point
# is that the installer knows nothing about the provider's cloud. But the
# records still have to exist. A control-plane machine's pointer ignition aims
# at `https://api-int.<clusterDomain>:22623/config/master`, and the bootstrap
# node's own kubeconfig targets `https://api-int.<clusterDomain>:6443`. Without
# the record, bootkube fails at its `resolve-api-int-url` stage and the install
# dies after the full bootstrap timeout.
#
# So the seam is here: the installer calls out to a program the user supplies,
# at the same point in the flow where an integrated provider would run its own
# InfraReady, and hands it everything it can describe without knowing the
# provider's API.
#
# This script is the AWS *reference* implementation of that contract. AWS is
# the reference provider used to exercise the mechanism -- nothing here is
# installer code, and an OCI or other partner would write their own.
#
#
# THE CONTRACT
#
# The installer execs this program directly -- no shell -- with the
# environment below and with whatever arguments the install-config gave it.
# Working directory is the install directory.
#
# Output contract: exit 0 is success and any other exit is failure. On
# failure the installer aborts, and the last few lines this program wrote are
# quoted in the installer's own error, so the last thing said before exiting
# should be the reason. Everything written to stdout and stderr is streamed
# to the installer log as it arrives, prefixed with the hook kind.
#
# Environment is the half of the input the installer owns and every hook
# shares:
#
#   OPENSHIFT_INSTALL_HOOK            "infra-ready", "post-provision" or
#                                     "pre-destroy"
#   OPENSHIFT_INSTALL_INFRA_ID        e.g. mrb-ext10-knzjv
#   OPENSHIFT_INSTALL_CLUSTER_NAME    e.g. mrb-ext10
#   OPENSHIFT_INSTALL_BASE_DOMAIN     e.g. splat.devcluster.openshift.com
#   OPENSHIFT_INSTALL_CLUSTER_DOMAIN  <cluster name>.<base domain>
#   OPENSHIFT_INSTALL_PUBLISH         External | Internal
#   OPENSHIFT_INSTALL_DIR             the install directory
#   OPENSHIFT_INSTALL_MANIFEST_DIR    <install dir>/external-install
#   OPENSHIFT_INSTALL_STATE_DIR       writable; what is recorded here on
#                                     infra-ready is what pre-destroy reads
#   OPENSHIFT_INSTALL_CLUSTER_JSON    PATH of a file holding the core CAPI
#                                     Cluster object as JSON
#   OPENSHIFT_INSTALL_INFRA_JSON      PATH of a file holding the provider's
#                                     infrastructure object as JSON, verbatim
#                                     from the local control plane -- unset if
#                                     there is not exactly one. A path, not
#                                     the document: the reads below pass it to
#                                     jq as a FILE argument, which is the only
#                                     correct form.
#   OPENSHIFT_INSTALL_KUBECONFIG      the installed cluster's admin
#                                     kubeconfig. Set for every hook and
#                                     usable by none until the cluster's API
#                                     is serving, which at infra-ready it is
#                                     not and at post-provision it is
#
# Arguments are the other half, and are the partner's own: the installer
# passes them through verbatim from
# platform.external.clusterAPI.hooks.<hook>.args and does not read them. This
# script's post-provision half takes
#
#   --input-service <namespace>/<name>   the Service whose load balancer
#                                        address the ingress wildcard must
#                                        point at
#   --input-dns-zone <hostedZoneId>      the public hosted zone for the base
#                                        domain, where the wildcard is
#                                        published
#   --timeout-seconds <n>                how long to wait for that address
#                                        (default 1800)
#
# Flags rather than positional arguments or more environment variables,
# because this file is a script today and may be a compiled binary tomorrow,
# and because `--input-dns-zone Z123` can be copied out of the installer log
# and rerun by hand. The same three flags would be the binary's flags.
#
# Two of the environment entries deserve comment.
#
# OPENSHIFT_INSTALL_INFRA_JSON is the whole mechanism. The installer cannot
# read `status.networkStatus.apiServerElb.dnsName` off an AWSCluster, because
# it has no AWSCluster type and must not acquire one. It can copy the object
# out of its local control plane as JSON and let the hook dig. Every field this
# script reads below is CAPA's schema, not the installer's.
#
# OPENSHIFT_INSTALL_STATE_DIR is how destroy stays honest. Anything created
# here is outside CAPI's ownership, so nothing else will ever clean it up. The
# rule on this pilot is that each new resource ships with its teardown in the
# same change, and the state file is the link between the two directions.
#
#
# THE INGRESS WILDCARD, AND WHY IT IS NOT IN INFRA-READY
#
# `*.apps` cannot be created at infra-ready, and the reason is structural
# rather than a matter of ordering. At infra-ready nothing exists but what the
# infrastructure provider built, and on this platform the provider does not
# build an ingress load balancer for anyone.
#
# It cannot: CAPA's `reconcileLBAttachment` returns early for anything that is
# not a control-plane machine
# (cluster-api-provider-aws/controllers/awsmachine_controller.go:1040-1043) and
# registration adds a machine to *every* target group on the load balancer
# (pkg/cloud/services/elb/loadbalancer.go:1044-1056), so
# `controlPlaneLoadBalancer.additionalListeners` on 80/443 would register
# control-plane nodes into the ingress target groups and never a worker --
# worse than doing nothing. The field is named for and scoped to the control
# plane load balancer and it means it. This is not an argument against the
# field: ../cluster.yaml uses it correctly for port 22623, because the Machine
# Config Server runs on the control-plane nodes, which is exactly the set CAPA
# registers. It works for any control-plane-hosted service and fails for any
# worker-hosted one, and routers are worker-hosted.
#
# Nor does the ingress operator ask for one. On `platform: external` it selects
# `endpointPublishingStrategy.type: HostNetwork` -- verified on mrb-ext11 --
# so the routers bind 80 and 443 on the nodes and the only Service the operator
# creates is a ClusterIP.
#
# So the cluster asks for its own, and the only thing on this platform that can
# answer is the cloud controller manager the partner already had to supply.
# `../extra-manifests/99_external-03-ingress-nlb.yaml` is a
# `Service type=LoadBalancer` that the installer delivers as a day-0 manifest;
# the partner's CCM reconciles it into a real load balancer some minutes into
# bootstrap, and the address it gets is assigned then, at runtime, by the
# cloud. Nothing at infra-ready could have known it.
#
# post-provision is where it is knowable. It runs after the control-plane
# machines exist and before the installer waits for bootstrap to complete, so
# this half waits for that Service to be given an address and publishes the
# wildcard. Waiting here does not deadlock: the operators that need `*.apps`
# are authentication and console, and neither is required for bootstrap to
# complete.
#
#
# WHAT IT STILL DOES NOT DO
#
# Nothing here creates the Service. The installer delivers the manifest and
# the cluster applies it; this hook only reads the address the cluster's own
# CCM put on it. If no CCM is delivered, the Service stays Pending, this hook
# times out and says so, and that is the correct outcome -- the wildcard would
# otherwise point at nothing.

set -euo pipefail

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)] external-hook:" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- contract

: "${OPENSHIFT_INSTALL_HOOK:?}"
: "${OPENSHIFT_INSTALL_INFRA_ID:?}"
: "${OPENSHIFT_INSTALL_CLUSTER_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_BASE_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_STATE_DIR:?}"

PUBLISH=${OPENSHIFT_INSTALL_PUBLISH:-External}
INFRA_ID=${OPENSHIFT_INSTALL_INFRA_ID}
CLUSTER_DOMAIN=${OPENSHIFT_INSTALL_CLUSTER_DOMAIN}
BASE_DOMAIN=${OPENSHIFT_INSTALL_BASE_DOMAIN}
STATE=${OPENSHIFT_INSTALL_STATE_DIR}/dns.json
# The ingress half keeps its own file. It is written by a different hook
# invocation, minutes later, and either half can legitimately exist without
# the other -- an install that got as far as infra-ready and no further has
# the first and not the second, and pre-destroy has to clean up whichever it
# finds.
APPS_STATE=${OPENSHIFT_INSTALL_STATE_DIR}/apps-dns.json

# Provider-specific, and therefore this script's own business rather than the
# installer's. AWS_REGION is how the AWS CLI is configured everywhere else in
# this workspace; the hook inherits the installer's environment.
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}

for tool in aws jq; do
	command -v "${tool}" >/dev/null || die "${tool} is required and is not on PATH"
done

mkdir -p "${OPENSHIFT_INSTALL_STATE_DIR}"

# ------------------------------------------------------------- discovery

# vpc_id reads the VPC from the provider's own object, and falls back to the
# tag the provider sets. The fallback matters because CAPA only writes
# spec.network.vpc.id back for a VPC it created; a BYO VPC is named by filter.
vpc_id() {
	local id=""
	if [[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} && -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]]; then
		id=$(jq -r '.spec.network.vpc.id // empty' "${OPENSHIFT_INSTALL_INFRA_JSON}")
	fi
	if [[ -z ${id} ]]; then
		id=$(aws ec2 describe-vpcs --region "${REGION}" \
			--filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${INFRA_ID},Values=owned" \
			--output json 2>/dev/null | jq -r '.Vpcs[0].VpcId // empty')
	fi
	[[ -n ${id} ]] || die "could not determine the VPC for ${INFRA_ID}"
	printf '%s' "${id}"
}

# lb_dns reads a load balancer DNS name out of the provider's status.
# `apiServerElb` is the internal one and is what Cluster.spec.controlPlaneEndpoint
# also carries; `secondaryAPIServerELB` is the internet-facing one CAPA creates
# when the cluster is published externally.
lb_dns() {
	local field=$1
	[[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} && -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]] || return 0
	jq -r ".status.networkStatus.${field}.dnsName // empty" "${OPENSHIFT_INSTALL_INFRA_JSON}"
}

# alias_zone maps a load balancer's DNS name to the hosted zone ID a Route 53
# alias record has to name. This is not in the provider's status -- it is an
# AWS fact about the load balancer -- so it is looked up.
#
# Filtering happens in jq, not in `--query`, and that is not a style choice.
# The AWS CLI applies `--query` to each page of a paginated response and prints
# one result per page, so a filter that matches on page 1 of 2 emits the value
# followed by a line reading `None`. Captured into a shell variable that is a
# two-line string which then fails far away from its cause -- this cost a
# NoSuchHostedZone on a zone ID that plainly existed. `--output json` returns
# the pages already merged.
alias_zone() {
	local dns=$1
	aws elbv2 describe-load-balancers --region "${REGION}" --output json |
		jq -r --arg d "${dns}" '.LoadBalancers[] | select(.DNSName==$d) | .CanonicalHostedZoneId' | head -1
}

# upsert_alias writes one A-record alias. UPSERT rather than CREATE so that a
# re-run of the hook is not an error; the installer may legitimately call it
# again after a retried provisioning step.
upsert_alias() {
	local zone_id=$1 name=$2 target_dns=$3 target_zone=$4
	log "upsert ${name} -> ${target_dns} in ${zone_id}"
	aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" \
		--change-batch "$(jq -n --arg n "${name}" --arg d "${target_dns}" --arg z "${target_zone}" '{
			Changes: [{
				Action: "UPSERT",
				ResourceRecordSet: {
					Name: $n, Type: "A",
					AliasTarget: { DNSName: $d, HostedZoneId: $z, EvaluateTargetHealth: false }
				}
			}]
		}')" >/dev/null
}

# delete_alias_record removes one record by exact name and type, and only if
# it is there.
#
# By exact name, always. The public zone belongs to the base domain and holds
# every other cluster's records; a filter that matched more than intended
# would take out somebody else's cluster. Read-then-delete rather than a
# blind DELETE because Route 53 requires the full record in the change batch
# and errors if it does not match, which would turn an already-clean zone
# into a failed destroy.
delete_alias_record() {
	local zone=$1 name=$2 type=${3:-A}
	[[ -n ${zone} && -n ${name} ]] || return 0

	# Route 53 stores a wildcard label in its octal escape form: a record
	# created as `*.apps.x.` is returned as `\052.apps.x.`. Creation accepts
	# either spelling, so the asymmetry is invisible until something reads the
	# record back -- and then an exact match against the name as written never
	# fires, this function reports the record as already gone, and destroy
	# leaks it while exiting 0. That is exactly what happened to the `*.apps`
	# record of mrb-ext12, the first cluster taken down by this path.
	#
	# Match either spelling rather than picking one. The comparison moved from
	# JMESPath to jq because the escaped name contains a backslash, and
	# quoting that through --query correctly is harder to get right than to
	# pass as an argument.
	local escaped=${name/#\*./\\052.}
	local found
	found=$(aws route53 list-resource-record-sets --hosted-zone-id "${zone}" --output json |
		jq --arg n "${name}" --arg e "${escaped}" --arg t "${type}" \
			'[.ResourceRecordSets[] | select((.Name == $n or .Name == $e) and .Type == $t)]')
	if [[ $(jq 'length' <<<"${found}") -eq 0 ]]; then
		log "${name} is already gone from ${zone}"
		return 0
	fi
	log "deleting ${name} from zone ${zone}"
	aws route53 change-resource-record-sets --hosted-zone-id "${zone}" \
		--change-batch "$(jq -n --argjson r "$(jq '.[0]' <<<"${found}")" \
			'{Changes: [{Action: "DELETE", ResourceRecordSet: $r}]}')" >/dev/null
}

# ------------------------------------------------------------ infra-ready

infra_ready() {
	local vpc internal_dns external_dns internal_zone phz_id public_zone_id
	vpc=$(vpc_id)
	log "cluster domain ${CLUSTER_DOMAIN}, vpc ${vpc}, region ${REGION}, publish ${PUBLISH}"

	internal_dns=$(lb_dns apiServerElb)
	# Cluster.spec.controlPlaneEndpoint.host is the one endpoint in the *core*
	# CAPI contract, so it is the provider-agnostic fallback. CAPA fills it
	# with the internal API load balancer, which is exactly what api-int needs.
	if [[ -z ${internal_dns} ]]; then
		internal_dns=${OPENSHIFT_INSTALL_CONTROL_PLANE_ENDPOINT_HOST:-}
	fi
	[[ -n ${internal_dns} ]] || die "no internal API load balancer in the infrastructure object or the Cluster endpoint"
	internal_zone=$(alias_zone "${internal_dns}")
	[[ -n ${internal_zone} ]] || die "no alias hosted zone for ${internal_dns}"

	# --- private hosted zone for the cluster domain -----------------------
	#
	# Idempotent by name and VPC association, because CreateHostedZone with a
	# reused CallerReference fails rather than returning the existing zone.
	phz_id=$(aws route53 list-hosted-zones-by-vpc --vpc-id "${vpc}" --vpc-region "${REGION}" --output json |
		jq -r --arg n "${CLUSTER_DOMAIN}." '.HostedZoneSummaries[] | select(.Name==$n) | .HostedZoneId' | head -1)

	if [[ -z ${phz_id} ]]; then
		log "creating private hosted zone ${CLUSTER_DOMAIN}. in ${vpc}"
		phz_id=$(aws route53 create-hosted-zone \
			--name "${CLUSTER_DOMAIN}" \
			--caller-reference "${INFRA_ID}-$(date +%s)" \
			--vpc "VPCRegion=${REGION},VPCId=${vpc}" \
			--hosted-zone-config "Comment=Created by the openshift-install external InfraReady hook for ${INFRA_ID},PrivateZone=true" \
			--query 'HostedZone.Id' --output text)
		phz_id=${phz_id#/hostedzone/}
		# Tagged so the zone is attributable, the same way CAPA tags what it
		# creates. Nothing keys off this; it is for a human reading the console.
		aws route53 change-tags-for-resource --resource-type hostedzone --resource-id "${phz_id}" \
			--add-tags "Key=kubernetes.io/cluster/${INFRA_ID},Value=owned" >/dev/null
	else
		phz_id=${phz_id#/hostedzone/}
		log "reusing existing private hosted zone ${phz_id}"
	fi

	# Both names resolve to the internal load balancer inside the VPC. api-int
	# is what bootkube, the kubelet and the pointer ignition use; api is here
	# so that in-cluster clients using the external name do not hairpin out.
	upsert_alias "${phz_id}" "api-int.${CLUSTER_DOMAIN}." "${internal_dns}" "${internal_zone}"
	upsert_alias "${phz_id}" "api.${CLUSTER_DOMAIN}." "${internal_dns}" "${internal_zone}"

	# --- public api record ------------------------------------------------
	public_zone_id=""
	if [[ ${PUBLISH} == "External" ]]; then
		external_dns=$(lb_dns secondaryAPIServerELB)
		if [[ -z ${external_dns} ]]; then
			log "publish is External but the provider reports no internet-facing API load balancer; skipping the public record"
		else
			public_zone_id=$(aws route53 list-hosted-zones --output json |
				jq -r --arg n "${BASE_DOMAIN}." \
					'.HostedZones[] | select(.Name==$n and .Config.PrivateZone==false) | .Id' | head -1)
			[[ -n ${public_zone_id} ]] || die "no public hosted zone for ${BASE_DOMAIN}"
			public_zone_id=${public_zone_id#/hostedzone/}
			upsert_alias "${public_zone_id}" "api.${CLUSTER_DOMAIN}." \
				"${external_dns}" "$(alias_zone "${external_dns}")"
		fi
	fi

	# --- state for the teardown -------------------------------------------
	#
	# The private zone is deleted wholesale, so only its ID is needed. The
	# public record lives in a zone that is NOT ours and long outlives the
	# cluster, so it is recorded by name and target: pre-destroy must delete
	# exactly that record and nothing else in a shared zone.
	jq -n \
		--arg phz "${phz_id}" \
		--arg pub "${public_zone_id}" \
		--arg rec "api.${CLUSTER_DOMAIN}." \
		--arg dns "${external_dns:-}" \
		'{privateHostedZoneId: $phz, publicHostedZoneId: $pub, publicRecordName: $rec, publicRecordTarget: $dns}' \
		>"${STATE}"
	log "recorded state in ${STATE}"
	log "infra-ready complete"
}

# --------------------------------------------------------- post-provision

# parse_post_provision_args reads this hook's own contract off argv.
#
# Both `--flag value` and `--flag=value` are accepted because both are what
# people type, and an unknown flag is an error rather than something ignored:
# a misspelled --input-dns-zone that is silently dropped would publish the
# wildcard into no zone at all and report success.
INPUT_SERVICE=""
INPUT_DNS_ZONE=""
INPUT_TIMEOUT=1800

parse_post_provision_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--input-service=*) INPUT_SERVICE=${1#*=} ;;
		--input-service)
			INPUT_SERVICE=${2:-}
			shift
			;;
		--input-dns-zone=*) INPUT_DNS_ZONE=${1#*=} ;;
		--input-dns-zone)
			INPUT_DNS_ZONE=${2:-}
			shift
			;;
		--timeout-seconds=*) INPUT_TIMEOUT=${1#*=} ;;
		--timeout-seconds)
			INPUT_TIMEOUT=${2:-}
			shift
			;;
		*) die "unknown argument ${1}; this hook takes --input-service <namespace>/<name>, --input-dns-zone <hostedZoneId> and --timeout-seconds <n>" ;;
		esac
		shift
	done
}

# kube_cmd picks the client this hook will use. oc and kubectl are
# interchangeable for the one read below; whichever is on PATH is fine.
kube_cmd() {
	local c
	for c in oc kubectl; do
		if command -v "${c}" >/dev/null; then
			printf '%s' "${c}"
			return 0
		fi
	done
	die "oc or kubectl is required on PATH for the post-provision hook and neither is there"
}

# service_address polls until the cluster's own cloud controller manager has
# given the Service an address.
#
# hostname first and ip second, in one jsonpath, because which one a cloud
# fills in is a property of the cloud: AWS returns a hostname for an NLB, and
# other providers return an address. Only one is ever set, so concatenating
# them yields whichever exists.
service_address() {
	local kube=$1 kubeconfig=$2 ns=$3 name=$4 deadline=$5
	local address=""
	while :; do
		address=$("${kube}" --kubeconfig "${kubeconfig}" --request-timeout=30s \
			-n "${ns}" get service "${name}" \
			-o jsonpath='{.status.loadBalancer.ingress[0].hostname}{.status.loadBalancer.ingress[0].ip}' \
			2>/dev/null || true)
		if [[ -n ${address} ]]; then
			printf '%s' "${address}"
			return 0
		fi
		if [[ $(date +%s) -ge ${deadline} ]]; then
			return 1
		fi
		sleep 15
	done
}

post_provision() {
	parse_post_provision_args "$@"

	[[ -n ${INPUT_SERVICE} ]] || die "--input-service <namespace>/<name> is required"
	[[ ${INPUT_SERVICE} == */* ]] || die "--input-service must be namespace/name, got ${INPUT_SERVICE}"
	[[ ${INPUT_TIMEOUT} =~ ^[0-9]+$ ]] || die "--timeout-seconds must be a whole number, got ${INPUT_TIMEOUT}"
	local ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}

	local kubeconfig=${OPENSHIFT_INSTALL_KUBECONFIG:-${OPENSHIFT_INSTALL_DIR:-.}/auth/kubeconfig}
	[[ -f ${kubeconfig} ]] || die "no kubeconfig at ${kubeconfig}; this hook reads the Service from the cluster being installed"
	local kube
	kube=$(kube_cmd)

	# The wait is long on purpose. Between this hook starting and the Service
	# getting an address, the cluster has to finish applying its day-0
	# manifests, schedule the partner's cloud controller manager onto a
	# tainted master, have it clear node.cloudprovider.kubernetes.io/
	# uninitialized, and only then reconcile the Service into a real load
	# balancer. Twenty minutes is ordinary; the default of 30 leaves room.
	local deadline=$(($(date +%s) + INPUT_TIMEOUT))
	log "waiting up to ${INPUT_TIMEOUT}s for ${INPUT_SERVICE} to be given a load balancer address"
	local address
	if ! address=$(service_address "${kube}" "${kubeconfig}" "${ns}" "${name}" "${deadline}"); then
		die "${INPUT_SERVICE} still has no status.loadBalancer.ingress after ${INPUT_TIMEOUT}s. Nothing on this platform creates that address except the cloud controller manager the partner supplies, so either it is not running or it cannot reconcile the Service; check 'oc -n ${ns} describe service ${name}' and the CCM's logs"
	fi
	log "${INPUT_SERVICE} has address ${address}"

	local target_zone
	target_zone=$(alias_zone "${address}")
	[[ -n ${target_zone} ]] || die "no alias hosted zone for ${address}; it does not look like an ELBv2 load balancer in ${REGION}"

	local wildcard="*.apps.${CLUSTER_DOMAIN}."

	# The private zone first. Every in-cluster client that resolves a route --
	# the console reaching oauth, the authentication operator's own health
	# check -- does it from inside the VPC, and without this record they get
	# NXDOMAIN even when the public record is perfect.
	local phz=""
	if [[ -f ${STATE} ]]; then
		phz=$(jq -r '.privateHostedZoneId // empty' "${STATE}")
	fi
	if [[ -n ${phz} ]]; then
		upsert_alias "${phz}" "${wildcard}" "${address}" "${target_zone}"
	else
		log "WARNING: no private hosted zone in ${STATE}; in-cluster resolution of ${wildcard} will depend on the public record"
	fi

	local pub=""
	if [[ ${PUBLISH} == "External" ]]; then
		[[ -n ${INPUT_DNS_ZONE} ]] || die "--input-dns-zone <hostedZoneId> is required when publish is External, because the wildcard has to be created in the base domain's public zone"
		pub=${INPUT_DNS_ZONE#/hostedzone/}
		upsert_alias "${pub}" "${wildcard}" "${address}" "${target_zone}"
	else
		log "publish is ${PUBLISH}; not creating a public ${wildcard} record"
	fi

	# --- state for the teardown -------------------------------------------
	#
	# The load balancer is recorded as well as the records, and that is the
	# part worth explaining. While the cluster is alive the CCM owns it and
	# deleting the Service deletes it -- proven on mrb-ext11. But `destroy
	# cluster` does not delete the Service, it deletes the machines the
	# Service's controller was running on, so by the time anything notices,
	# there is nothing left to do the deleting. The load balancer would be
	# orphaned. Recording its ARN here is what lets pre-destroy remove it.
	local lb_arn
	lb_arn=$(aws elbv2 describe-load-balancers --region "${REGION}" --output json |
		jq -r --arg d "${address}" '.LoadBalancers[] | select(.DNSName==$d) | .LoadBalancerArn' | head -1)

	jq -n \
		--arg svc "${INPUT_SERVICE}" \
		--arg rec "${wildcard}" \
		--arg pub "${pub}" \
		--arg phz "${phz}" \
		--arg addr "${address}" \
		--arg arn "${lb_arn}" \
		'{service: $svc, recordName: $rec, publicHostedZoneId: $pub, privateHostedZoneId: $phz, address: $addr, loadBalancerArn: $arn}' \
		>"${APPS_STATE}"
	log "recorded state in ${APPS_STATE}"
	log "post-provision complete: ${wildcard} -> ${address}"
}

# ------------------------------------------------------------ pre-destroy

# delete_ingress_lb removes the load balancer the cluster's CCM built for the
# ingress Service.
#
# Nothing else will. While the cluster is alive the CCM owns this load
# balancer and deleting the Service deletes it, but `destroy cluster` never
# deletes the Service -- it deletes the nodes the controller ran on. The load
# balancer, its target groups and its listeners would survive the cluster
# that paid for them.
#
# The ARN is read from state rather than discovered, so this can only ever
# delete the one load balancer this hook recorded creating.
delete_ingress_lb() {
	local arn=$1
	[[ -n ${arn} ]] || return 0

	if ! aws elbv2 describe-load-balancers --region "${REGION}" --load-balancer-arns "${arn}" >/dev/null 2>&1; then
		log "ingress load balancer is already gone"
		return 0
	fi

	# Read the target groups before the delete: afterwards there is no load
	# balancer to list them from, and they are not deleted with it.
	local tgs
	tgs=$(aws elbv2 describe-target-groups --region "${REGION}" --load-balancer-arn "${arn}" --output json |
		jq -r '.TargetGroups[].TargetGroupArn')

	log "deleting the ingress load balancer ${arn}"
	aws elbv2 delete-load-balancer --region "${REGION}" --load-balancer-arn "${arn}"

	# A target group cannot be deleted while a load balancer still references
	# it, and the delete above is asynchronous.
	local waited=0
	while aws elbv2 describe-load-balancers --region "${REGION}" --load-balancer-arns "${arn}" >/dev/null 2>&1; do
		if [[ ${waited} -ge 300 ]]; then
			log "WARNING: the load balancer is still present after 300s; leaving its target groups in place rather than failing the destroy"
			return 0
		fi
		sleep 10
		waited=$((waited + 10))
	done

	local tg
	for tg in ${tgs}; do
		log "deleting target group ${tg}"
		aws elbv2 delete-target-group --region "${REGION}" --target-group-arn "${tg}" >/dev/null ||
			log "WARNING: could not delete target group ${tg}"
	done
}

# destroy_ingress removes what post-provision created: the wildcard records
# and the load balancer they point at.
#
# Records first, load balancer second, for the same reason infra-ready's
# teardown runs before the Cluster delete: an alias record is described in
# terms of the load balancer it names, and Route 53 is easier to reason about
# while that target still exists.
destroy_ingress() {
	if [[ ! -f ${APPS_STATE} ]]; then
		log "no ${APPS_STATE}; this hook created no ingress records or load balancer"
		return 0
	fi

	local pub rec arn
	pub=$(jq -r '.publicHostedZoneId // empty' "${APPS_STATE}")
	rec=$(jq -r '.recordName // empty' "${APPS_STATE}")
	arn=$(jq -r '.loadBalancerArn // empty' "${APPS_STATE}")

	# Only the public copy is deleted by name. The private copy lives in the
	# cluster's own hosted zone, which is emptied and deleted wholesale
	# below.
	delete_alias_record "${pub}" "${rec}" A

	delete_ingress_lb "${arn}"

	rm -f "${APPS_STATE}"
}

pre_destroy() {
	destroy_ingress

	if [[ ! -f ${STATE} ]]; then
		log "no ${STATE}; nothing else this hook created to remove"
		return 0
	fi

	local phz pub rec dns
	phz=$(jq -r '.privateHostedZoneId // empty' "${STATE}")
	pub=$(jq -r '.publicHostedZoneId // empty' "${STATE}")
	rec=$(jq -r '.publicRecordName // empty' "${STATE}")
	dns=$(jq -r '.publicRecordTarget // empty' "${STATE}")

	# The public record first, and by exact name. This zone belongs to the
	# base domain and holds other clusters' records; deleting anything not
	# named here would take out somebody else's cluster.
	if [[ -n ${pub} && -n ${rec} && -n ${dns} ]]; then
		delete_alias_record "${pub}" "${rec}" A
	fi

	# Then the private zone. Route 53 refuses to delete a zone that still has
	# records other than its own NS and SOA, so they go first.
	if [[ -n ${phz} ]]; then
		if ! aws route53 get-hosted-zone --id "${phz}" >/dev/null 2>&1; then
			log "private zone ${phz} is already gone"
		else
			local records
			records=$(aws route53 list-resource-record-sets --hosted-zone-id "${phz}" \
				--query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json)
			if [[ $(jq 'length' <<<"${records}") -gt 0 ]]; then
				log "deleting $(jq 'length' <<<"${records}") record(s) from ${phz}"
				aws route53 change-resource-record-sets --hosted-zone-id "${phz}" \
					--change-batch "$(jq -n --argjson rs "${records}" \
						'{Changes: [$rs[] | {Action: "DELETE", ResourceRecordSet: .}]}')" >/dev/null
			fi
			log "deleting private hosted zone ${phz}"
			aws route53 delete-hosted-zone --id "${phz}" >/dev/null
		fi
	fi

	rm -f "${STATE}"
	log "pre-destroy complete"
}

# The three halves are one file so that what a hook creates and what removes
# it can be read against each other. Only post-provision takes arguments;
# forwarding "$@" to it and to nothing else is deliberate, so that an
# argument sent to the wrong hook is an error rather than a no-op.
case ${OPENSHIFT_INSTALL_HOOK} in
infra-ready) infra_ready ;;
post-provision) post_provision "$@" ;;
pre-destroy) pre_destroy ;;
*) die "unknown hook ${OPENSHIFT_INSTALL_HOOK}" ;;
esac
