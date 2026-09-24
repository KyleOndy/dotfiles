# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/forge/default.nix).
#
# forge -- Declarative local Kind cluster environment manager. `forge --help`
# is the description of it that has to stay correct.

CONFIG="${FORGE_CONFIG:-${XDG_CONFIG_HOME:-${HOME}/.config}/forge/forge.yaml}"

# Window of host ports the forge VM forwards to kind API servers, substituted
# from nix/pkgs/forge/default.nix so this and the VM's portForwards cannot
# drift apart.
readonly API_PORT_BASE=@apiPortBase@
readonly API_PORT_SPAN=@apiPortSpan@

# The lima instance forge's docker daemon runs in, and the store path of the
# config it gets created from, substituted from nix/pkgs/forge/default.nix.
readonly VM_NAME=forge
readonly VM_CONFIG=@vmConfig@

# Where lima forwards that instance's docker socket: vm.nix asks for
# {{.Dir}}/sock, and .Dir is $LIMA_HOME/<name>. Every command below talks to
# this daemon and never to whatever DOCKER_HOST names, because a kind node is a
# privileged container, so the daemon forge uses is the one whose mounts and
# port forwards decide what a cluster can reach on this mac.
readonly VM_SOCKET="${LIMA_HOME:-${HOME}/.lima}/${VM_NAME}/sock/docker.sock"
export DOCKER_HOST="unix://${VM_SOCKET}"

# lima copies the config into the instance directory at creation and reads that
# copy for the life of the instance, so this is the definition the VM is
# actually running.
readonly VM_LIVE_CONFIG="${LIMA_HOME:-${HOME}/.lima}/${VM_NAME}/lima.yaml"

# A failing lima probe (vm.nix declares one) makes lima retry rather than give
# up, so without a timeout a guest that never gets dockerd up hangs forge
# instead of failing it. Long enough for a first start, which copies and
# resizes the guest image before booting it.
readonly VM_TIMEOUT=10m

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo ">>> $*"; }
info() { echo "    $*"; }
ok() { echo "    [ok] $*"; }
warn() { echo "    [warn] $*" >&2; }

die() {
	echo "ERROR: $*" >&2
	exit 1
}

yq_get() {
	yq e "$1" "${CONFIG}"
}

# ─── Prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
	log "Checking prerequisites"
	docker info &>/dev/null ||
		die "no docker daemon at ${DOCKER_HOST} ('forge up' creates the VM)"
	ok "Docker daemon in VM '${VM_NAME}'"
}

# ─── Config readers ───────────────────────────────────────────────────────────

get_network() {
	yq_get '.network'
}

# FORGE_KUBECONFIG overrides the config, which is how a caller puts the file
# somewhere its own sandbox is allowed to read without editing shared config.
get_kubeconfig() {
	local raw
	raw="${FORGE_KUBECONFIG:-$(yq_get '.kubeconfig // ""')}"
	[[ -n ${raw} ]] || die "no 'kubeconfig' in ${CONFIG} (override with FORGE_KUBECONFIG)"
	echo "${raw/#\~/$HOME}"
}

get_mirror_names() {
	yq_get '.mirrors[].name'
}

get_mirror_upstream() {
	local name="$1"
	yq_get ".mirrors[] | select(.name == \"${name}\") | .upstream"
}

get_mgmt_name() {
	yq_get '.management.name'
}

get_argocd_version() {
	yq_get '.management.argocd.version'
}

get_mgmt_nodes() {
	yq_get '.management.nodes[].role'
}

get_cluster_names() {
	yq_get '.clusters[].name'
}

get_cluster_nodes() {
	local cluster="$1"
	yq_get ".clusters[] | select(.name == \"${cluster}\") | .nodes[].role"
}

# kind picks a random host port for a cluster's API server unless told
# otherwise, and the VM forwards only API_PORT_BASE..+SPAN, denying the rest.
# A random port would leave the kubeconfig kind writes pointing at something
# that never reaches the guest. Ports are assigned by position in forge.yaml:
# the management cluster takes the base, workload clusters follow in order.
api_port_for() {
	local name="$1"
	local mgmt idx=0
	mgmt="$(get_mgmt_name)"
	if [[ ${name} == "${mgmt}" ]]; then
		echo "${API_PORT_BASE}"
		return
	fi
	while IFS= read -r cname; do
		idx=$((idx + 1))
		if [[ ${cname} == "${name}" ]]; then
			echo $((API_PORT_BASE + idx))
			return
		fi
	done < <(get_cluster_names)
	die "cluster '${name}' is not declared in ${CONFIG}"
}

# Checked once up front because api_port_for runs inside a command
# substitution, where a die would exit only the subshell and leave the caller
# with an empty port.
check_api_port_window() {
	local count
	count="$(get_cluster_names | wc -l | tr -d ' ')"
	if ((count + 1 > API_PORT_SPAN)); then
		die "${CONFIG} declares $((count + 1)) clusters, more than the ${API_PORT_SPAN} API ports the VM forwards from ${API_PORT_BASE}"
	fi
}

# ─── Docker network ───────────────────────────────────────────────────────────

ensure_network() {
	local network
	network="$(get_network)"
	log "Ensuring Docker network: ${network}"
	if docker network inspect "${network}" &>/dev/null; then
		ok "Network '${network}' already exists"
	else
		docker network create "${network}"
		ok "Created network '${network}'"
	fi
}

# ─── Pull-through mirrors ──────────────────────────────────────────────────────

mirror_container_name() {
	echo "forge-mirror-$1"
}

mirror_volume_name() {
	echo "forge-mirror-$1-data"
}

ensure_mirror() {
	local name="$1"
	local upstream
	upstream="$(get_mirror_upstream "${name}")"
	local container
	container="$(mirror_container_name "${name}")"
	local volume
	volume="$(mirror_volume_name "${name}")"
	local network
	network="$(get_network)"

	local state
	state="$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "absent")"
	state="${state//$'\n'/}"

	case "${state}" in
	running)
		ok "Mirror '${container}' already running"
		;;
	exited | created | paused)
		docker start "${container}"
		ok "Started mirror '${container}'"
		;;
	absent)
		docker run -d \
			--name "${container}" \
			--network "${network}" \
			--restart=always \
			-v "${volume}:/var/lib/registry" \
			-e "REGISTRY_PROXY_REMOTEURL=${upstream}" \
			registry:2
		ok "Created mirror '${container}' → ${upstream}"
		;;
	*)
		die "Unknown container state '${state}' for ${container}"
		;;
	esac
}

ensure_mirrors() {
	log "Ensuring pull-through mirrors"
	while IFS= read -r name; do
		ensure_mirror "${name}"
	done < <(get_mirror_names)
}

# ─── forge VM ─────────────────────────────────────────────────────────────────

# Empty for an instance that does not exist: limactl exits 1 and logs
# "unmatched instances" for a name it does not know.
vm_status() {
	limactl list "${VM_NAME}" --format '{{.Status}}' 2>/dev/null || true
}

# An instance that exists keeps the definition it was created with, so a new
# guest image or a wider API port window in vm.nix does not reach it. Rolling
# it forward means deleting it, which takes the clusters inside with it, so
# drift is reported and left to the operator. Reading the instance's own copy
# rather than a note forge writes at creation time also catches a config edited
# underneath it, a mount added by hand being the case that matters. Compared as
# sorted JSON because lima is free to reformat what it persists (it does not
# today: on 2.2.0 the copy is byte-identical).
canonical_config() {
	yq -o=json -I=0 'sort_keys(..)' "$1" 2>/dev/null
}

check_vm_generation() {
	[[ "$(canonical_config "${VM_CONFIG}")" == "$(canonical_config "${VM_LIVE_CONFIG}")" ]] && return
	warn "VM '${VM_NAME}' is not running ${VM_CONFIG}."
	warn "'forge nuke && forge up' rebuilds it from the current definition."
}

ensure_vm() {
	log "Ensuring VM '${VM_NAME}'"
	local status
	status="$(vm_status)"
	case "${status}" in
	Running)
		ok "Already running"
		;;
	"")
		info "Creating from ${VM_CONFIG}"
		limactl start --name="${VM_NAME}" --tty=false --timeout="${VM_TIMEOUT}" \
			"${VM_CONFIG}"
		ok "Created, and its docker socket is at ${VM_SOCKET}"
		;;
	*)
		info "Status is ${status}, starting it"
		limactl start --tty=false --timeout="${VM_TIMEOUT}" "${VM_NAME}"
		ok "Started"
		;;
	esac
	check_vm_generation
}

remove_vm() {
	if [[ -z "$(vm_status)" ]]; then
		ok "No VM '${VM_NAME}' to remove"
		return
	fi
	log "Deleting VM '${VM_NAME}'"
	limactl delete --force "${VM_NAME}"
	ok "Deleted the VM, and with it every cluster, mirror, volume and network"
}

# ─── Kind cluster creation ────────────────────────────────────────────────────

# Build a kind Cluster manifest for the given cluster name and node roles.
# Roles is a newline-separated list of "control-plane" or "worker".
build_kind_config() {
	local roles="$1"
	local api_port="$2"

	echo "kind: Cluster"
	echo "apiVersion: kind.x-k8s.io/v1alpha4"
	echo "networking:"
	echo "  apiServerPort: ${api_port}"
	echo "nodes:"
	while IFS= read -r role; do
		echo "  - role: ${role}"
	done <<<"${roles}"
	cat <<'EOF'
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
EOF
}

cluster_exists() {
	kind get clusters 2>/dev/null | grep -qx "$1"
}

create_cluster() {
	local name="$1"
	local roles="$2"
	local network
	network="$(get_network)"
	local kubeconfig
	kubeconfig="$(get_kubeconfig)"

	if cluster_exists "${name}"; then
		ok "Cluster '${name}' already exists"
		return
	fi

	local tmpconfig
	# --tmpdir rather than a literal /tmp so TMPDIR is honoured: under an
	# agent sandbox that grants writes by path, /tmp is not one of them.
	tmpconfig="$(mktemp --tmpdir forge-kind-XXXXXX.yaml)"
	local api_port
	api_port="$(api_port_for "${name}")"
	build_kind_config "${roles}" "${api_port}" >"${tmpconfig}"

	# --kubeconfig is what keeps kind out of ~/.kube/config, which it creates and
	# merges into otherwise. Parallel creates share this file safely: kind holds a
	# lock across the read-modify-write.
	mkdir -p "$(dirname "${kubeconfig}")"
	KIND_EXPERIMENTAL_DOCKER_NETWORK="${network}" \
		kind create cluster --name "${name}" --config "${tmpconfig}" \
		--kubeconfig "${kubeconfig}"

	rm -f "${tmpconfig}"

	ok "Added context kind-${name} → ${kubeconfig}"
}

# kind writes a context only when it creates a cluster, so one that predates
# the kubeconfig, or outlived a deleted copy of it, gets its context back here.
export_kubeconfig() {
	local kubeconfig
	kubeconfig="$(get_kubeconfig)"
	mkdir -p "$(dirname "${kubeconfig}")"
	kind export kubeconfig --name "$1" --kubeconfig "${kubeconfig}"
}

create_clusters_parallel() {
	local pids=()
	local names=()
	local logs=()

	# Management cluster
	local mgmt
	mgmt="$(get_mgmt_name)"
	local mgmt_roles
	mgmt_roles="$(get_mgmt_nodes)"

	if ! cluster_exists "${mgmt}"; then
		log "Creating management cluster '${mgmt}'"
		local errlog
		errlog="$(mktemp --tmpdir forge-cluster-XXXXXX.err)"
		create_cluster "${mgmt}" "${mgmt_roles}" 2>"${errlog}" &
		pids+=($!)
		names+=("${mgmt}")
		logs+=("${errlog}")
	else
		ok "Management cluster '${mgmt}' already exists"
		export_kubeconfig "${mgmt}"
	fi

	# Workload clusters
	while IFS= read -r cname; do
		local roles
		roles="$(get_cluster_nodes "${cname}")"
		if ! cluster_exists "${cname}"; then
			log "Creating workload cluster '${cname}'"
			local errlog
			errlog="$(mktemp --tmpdir forge-cluster-XXXXXX.err)"
			create_cluster "${cname}" "${roles}" 2>"${errlog}" &
			pids+=($!)
			names+=("${cname}")
			logs+=("${errlog}")
		else
			ok "Workload cluster '${cname}' already exists"
			export_kubeconfig "${cname}"
		fi
	done < <(get_cluster_names)

	# Every create is waited on before dying, so none is left running and every
	# failure's stderr is shown.
	local i=0
	local failed=()
	for pid in "${pids[@]}"; do
		if ! wait "${pid}"; then
			echo "    --- stderr from ${names[$i]} ---" >&2
			sed 's/^/    /' "${logs[$i]}" >&2
			failed+=("${names[$i]}")
		fi
		rm -f "${logs[$i]}"
		i=$((i + 1))
	done
	[[ ${#failed[@]} -eq 0 ]] || die "Failed to create cluster(s): ${failed[*]}"
}

delete_cluster() {
	local name="$1"
	local kubeconfig
	kubeconfig="$(get_kubeconfig)"

	if cluster_exists "${name}"; then
		kind delete cluster --name "${name}" --kubeconfig "${kubeconfig}"
		ok "Deleted cluster '${name}'"
	fi
}

delete_all_clusters() {
	log "Deleting clusters"
	local mgmt
	mgmt="$(get_mgmt_name)"
	delete_cluster "${mgmt}"

	while IFS= read -r cname; do
		delete_cluster "${cname}"
	done < <(get_cluster_names)
}

# ─── Configure containerd mirrors on nodes ────────────────────────────────────

hosts_toml_for() {
	local mirror_url="$1"
	cat <<EOF
server = "${mirror_url}"

[host."${mirror_url}"]
  capabilities = ["pull", "resolve"]
EOF
}

configure_mirrors_on_node() {
	local node="$1"

	while IFS= read -r mirror_name; do
		local container
		container="$(mirror_container_name "${mirror_name}")"
		local mirror_url="http://${container}:5000"

		# Determine the registry hostname this mirror fronts
		local upstream
		upstream="$(get_mirror_upstream "${mirror_name}")"
		# Strip https:// prefix and trailing /
		local registry_host
		registry_host="${upstream#https://}"
		registry_host="${registry_host#http://}"
		registry_host="${registry_host%%/*}"
		# docker.io upstream is registry-1.docker.io but kind needs docker.io
		if [[ ${registry_host} == "registry-1.docker.io" ]]; then
			registry_host="docker.io"
		fi

		local dir="/etc/containerd/certs.d/${registry_host}"
		docker exec "${node}" mkdir -p "${dir}"
		hosts_toml_for "${mirror_url}" |
			docker exec -i "${node}" tee "${dir}/hosts.toml" >/dev/null
		ok "  ${node}: configured mirror for ${registry_host} → ${mirror_url}"
	done < <(get_mirror_names)
}

configure_mirrors_on_cluster() {
	local cluster_name="$1"
	local nodes
	nodes="$(docker ps --filter "name=^${cluster_name}-" --format '{{.Names}}')"

	while IFS= read -r node; do
		configure_mirrors_on_node "${node}"
	done <<<"${nodes}"
}

configure_all_mirrors() {
	log "Configuring containerd mirrors on all nodes"
	local mgmt
	mgmt="$(get_mgmt_name)"
	configure_mirrors_on_cluster "${mgmt}"

	while IFS= read -r cname; do
		configure_mirrors_on_cluster "${cname}"
	done < <(get_cluster_names)
}

# ─── ArgoCD ───────────────────────────────────────────────────────────────────

install_argocd() {
	local mgmt
	mgmt="$(get_mgmt_name)"
	local version
	version="$(get_argocd_version)"
	local context="kind-${mgmt}"
	local chart_ref="${FORGE_ARGOCD_CHART:-argo/argo-cd}"

	log "Installing ArgoCD ${version} on ${mgmt}"

	# FORGE_ARGOCD_CHART installs from a local/OCI chart ref and skips the
	# upstream repo add + pinned --version. Needed where the chart tgz CDN
	# (release-assets.githubusercontent.com) is unreachable.
	if [[ ${chart_ref} == "argo/argo-cd" ]]; then
		if ! helm repo list 2>/dev/null | grep -q '^argo\s'; then
			helm repo add argo https://argoproj.github.io/argo-helm
			helm repo update argo
		fi
	else
		log "Using chart override: ${chart_ref}"
	fi

	# Check if already installed
	if helm --kube-context "${context}" -n argocd status argocd &>/dev/null; then
		ok "ArgoCD already installed"
		return
	fi

	local version_flags=()
	if [[ ${chart_ref} == "argo/argo-cd" ]]; then
		version_flags=(--version "${version}")
	fi

	helm install argocd "${chart_ref}" \
		--kube-context "${context}" \
		--namespace argocd \
		--create-namespace \
		"${version_flags[@]}" \
		--set configs.params."server\.insecure"=true \
		--wait

	ok "ArgoCD installed"
}

register_workload_clusters() {
	local mgmt
	mgmt="$(get_mgmt_name)"
	local mgmt_context="kind-${mgmt}"

	log "Registering workload clusters with ArgoCD"

	while IFS= read -r cname; do
		register_cluster_with_argocd "${cname}" "${mgmt_context}"
	done < <(get_cluster_names)
}

register_cluster_with_argocd() {
	local cluster_name="$1"
	local mgmt_context="$2"
	local work_context="kind-${cluster_name}"

	# The secret holds a bearer token for a service account that lives in the
	# workload cluster, so checking only the secret calls a cluster recreated
	# underneath it registered while ArgoCD holds a credential for an account
	# that no longer exists. Both ends have to be present.
	local secret_name="argocd-cluster-${cluster_name}"
	if kubectl --context "${mgmt_context}" -n argocd \
		get secret "${secret_name}" &>/dev/null &&
		kubectl --context "${work_context}" -n kube-system \
			get serviceaccount argocd-manager &>/dev/null; then
		ok "Cluster '${cluster_name}' already registered"
		return
	fi

	# Get the internal Docker-network API server address for this cluster
	local api_server="https://${cluster_name}-control-plane:6443"

	# Create a service account in the workload cluster for ArgoCD
	kubectl --context "${work_context}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
EOF

	# Wait for token secret to be populated
	local attempts=0
	local token=""
	while [[ -z ${token} && ${attempts} -lt 20 ]]; do
		token="$(kubectl --context "${work_context}" -n kube-system \
			get secret argocd-manager-token \
			-o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
		attempts=$((attempts + 1))
		[[ -z ${token} ]] && sleep 2
	done
	[[ -z ${token} ]] && die "Failed to get token for cluster '${cluster_name}'"

	local ca_data
	ca_data="$(kubectl --context "${work_context}" -n kube-system \
		get secret argocd-manager-token \
		-o jsonpath='{.data.ca\.crt}')"

	# Create ArgoCD cluster secret on the management cluster
	kubectl --context "${mgmt_context}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${secret_name}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${cluster_name}
  server: ${api_server}
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca_data}"
      }
    }
EOF

	ok "Registered cluster '${cluster_name}' → ${api_server}"
}

# ─── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
	local network
	network="$(get_network)"
	local mgmt
	mgmt="$(get_mgmt_name)"

	echo ""
	echo "=== Forge Status ==="
	echo ""

	local vm_state
	vm_state="$(vm_status)"
	echo "VM:"
	printf "  %-30s %-10s %s\n" "${VM_NAME}" "${vm_state:-absent}" "${DOCKER_HOST}"
	echo ""

	echo "Kubeconfig:"
	printf "  %s\n" "${KUBECONFIG}"
	echo ""

	echo "Mirrors:"
	while IFS= read -r name; do
		local container
		container="$(mirror_container_name "${name}")"
		local state
		state="$(docker inspect --format '{{.State.Status}}' "${container}" 2>/dev/null || echo "absent")"
		state="${state//$'\n'/}"
		printf "  %-30s %s\n" "${container}" "${state}"
	done < <(get_mirror_names)

	echo ""
	echo "Management:"
	local mgmt_state
	if cluster_exists "${mgmt}"; then
		mgmt_state="running"
	else
		mgmt_state="absent"
	fi
	printf "  %-30s %-10s context=kind-%s api=127.0.0.1:%s\n" \
		"${mgmt}" "${mgmt_state}" "${mgmt}" "$(api_port_for "${mgmt}")"
	echo "  ArgoCD: kubectl --context kind-${mgmt} port-forward svc/argocd-server -n argocd 8080:80"

	echo ""
	echo "Clusters:"
	while IFS= read -r cname; do
		local state
		if cluster_exists "${cname}"; then
			state="running"
		else
			state="absent"
		fi
		printf "  %-30s %-10s context=kind-%s api=127.0.0.1:%s\n" \
			"${cname}" "${state}" "${cname}" "$(api_port_for "${cname}")"
	done < <(get_cluster_names)

	echo ""
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_up() {
	ensure_vm
	check_prerequisites
	ensure_network
	ensure_mirrors
	log "Creating clusters"
	create_clusters_parallel
	configure_all_mirrors
	install_argocd
	register_workload_clusters
	log "Done. Run 'forge status' for details."
}

# Leaves the VM running: it holds the mirrors and their pulled layers, and a
# stopped instance costs a full boot to get them back.
cmd_down() {
	check_prerequisites
	delete_all_clusters
	log "Mirrors, volumes and the VM preserved. Run 'forge nuke' to remove everything."
}

# Deleting the VM is the whole teardown: the clusters, mirrors, cache volumes,
# network and every image kind and the mirrors pulled all live inside it.
cmd_nuke() {
	remove_vm
	log "Everything removed."
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────

usage() {
	cat <<EOF
forge -- declarative local Kind cluster environment, run inside a lima VM

Usage:
  forge <command>

Commands:
  up      Create the VM if absent, then converge to the config: Docker network,
          pull-through registry mirrors, Kind clusters, ArgoCD on the
          management cluster, and registration of every workload cluster with
          it. Idempotent, so it is also how a config edit gets applied.
  down    Delete every cluster and its kubeconfig context. The VM, the mirrors
          and their cache volumes survive, so the next 'up' reuses pulled
          layers.
  status  Print the VM, the mirrors, and every cluster with its context and
          API port. Reads state, changes nothing.
  nuke    Delete the VM, and with it every cluster, mirror, volume and network.

Config: ${CONFIG}
  Declares the Docker network, the mirrors, the management cluster and its
  ArgoCD chart version, the workload clusters and their node roles, and the
  kubeconfig path. 'forge up' creates what is declared and missing; it never
  deletes a cluster dropped from the config, so retiring one takes
  'kind delete cluster --name <name>' or a full 'forge down'.

Environment:
  FORGE_CONFIG        Config path, overriding the default above.
  FORGE_ARGOCD_CHART  ArgoCD chart ref, default argo/argo-cd. Point it at a
                      local or OCI chart when the upstream chart CDN is
                      unreachable. The version pinned in the config applies
                      only to the default ref; an override brings its own.
  FORGE_KUBECONFIG    Kubeconfig path, overriding the config's. Point it
                      somewhere a sandboxed caller is allowed to read.

Reaching a cluster:
  Every cluster shares one kubeconfig, at the path the config names and never
  under ~/.kube. 'forge status' prints it. Point KUBECONFIG at it and address
  clusters by context:
    export KUBECONFIG=<the path 'forge status' prints>
    kubectl --context kind-<name> get nodes
  API servers listen on 127.0.0.1 from port ${API_PORT_BASE} upward in config order, ${API_PORT_SPAN}
  ports wide, one per cluster. Nothing else inside a cluster is reachable from
  the host, because the VM forwards only that window and the Docker socket, so
  anything else, ArgoCD's own UI included, needs
  'kubectl --context kind-<name> port-forward'.

Docker:
  Every command talks to the daemon in the lima VM '${VM_NAME}', never to
  whatever DOCKER_HOST names on the host. That socket, which is also the
  DOCKER_HOST a docker command needs to see forge's containers:
    unix://${VM_SOCKET}
  'limactl shell ${VM_NAME}' gets a shell in the VM itself.
EOF
}

# cmd_status does not run check_prerequisites, so the config guards belong here
# rather than there: without them a missing config surfaces as a raw yq error.
case "${1:-}" in
up | down | status | nuke)
	[[ -f ${CONFIG} ]] || die "no config at ${CONFIG} (override with FORGE_CONFIG)"
	check_api_port_window
	# Every kubectl, helm and kind call below addresses clusters by context, and
	# resolves them against this file alone. Without it they would fall back to
	# ~/.kube/config, which forge neither writes nor requires to exist.
	KUBECONFIG="$(get_kubeconfig)"
	export KUBECONFIG
	"cmd_$1"
	;;
help | -h | --help)
	usage
	;;
*)
	if [[ -n ${1:-} ]]; then
		echo "ERROR: unknown command '$1'" >&2
	fi
	usage >&2
	exit 1
	;;
esac
