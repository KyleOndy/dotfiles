# shellcheck shell=bash
# Pi sandbox wrapper. Placeholders @realPiBin@ etc. are substituted at build
# time. writeShellApplication injects `set -euo pipefail` automatically.

default_domains=(@defaultDomains@)
default_write_paths=(@defaultWritePaths@)
default_read_paths=(@defaultReadPaths@)
system_read_paths=(@systemReadPaths@)
credential_masks=(@credentialMasks@)
default_pi_args=(@defaultPiArgs@)
real_pi="${PI_REAL_BIN:-@realPiBin@}"

# Re-export so the pi process we're about to run (and extensions inside it,
# e.g. the task subagent extension) can see the resolved real-binary path.
# A subagent spawns $PI_REAL_BIN directly instead of re-invoking this `pi`
# wrapper, which would otherwise try to open a second, redundant srt/bwrap/
# sandbox-exec layer. It doesn't need one: OS-level sandboxes confine the
# whole process tree, so a plain child process of the already-sandboxed pi
# stays inside the same confinement for free.
export PI_REAL_BIN="$real_pi"
[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_REAL_BIN: %s\n' "$real_pi"

extra_domains=()
extra_write_paths=()
extra_read_paths=()
grants=()
web_mode=false
no_sandbox=false
allow_loopback=@defaultAllowLoopback@
allow_trustd=@defaultAllowTrustd@
allow_nix=@defaultAllowNix@
allow_forge=@defaultAllowForge@
forge_instance=""
forge_domains=(@forgeDomains@)
coord_broker="@coordinatorBroker@"
coord_role=""
coord_id=""
coord_agent=""
allow_ssh_agent=@defaultAllowSshAgent@
git_write_mode=@gitWriteMode@
protected_branches=(@protectedBranches@)
git_write_granted=false

# nix talks to the daemon over this socket, and srt blocks unix sockets by
# default on both platforms (sandbox-runtime README, Unix Socket Settings).
# Only added to the policy under --allow-nix.
#
# This grant is not the narrow thing its name suggests. The daemon decides a
# client is trusted by peer uid, so where the invoking user is covered by
# nix.conf's trusted-users (`root @admin` on a mac where the human is an
# admin), the client may override daemon settings. Overriding
# build-users-group to empty makes the daemon build as itself, and a builder
# is arbitrary code: measured on a darwin host whose human is an admin, a
# build launched from inside srt reported uid=0 user=root and read a path
# this policy's denyRead covers, which the same build as _nixbld1 could not.
# Turning nix's own sandbox on does not help, since a trusted client can turn
# it back off. Against an untrusted client the daemon refuses those overrides
# and the builder runs as _nixbld, still outside this policy but not root, so
# __pi_warn_nix_trust asks the daemon which of the two this is rather than
# always announcing the worse one.
#
# Determinate Nix on darwin ships the well-known path as a symlink to
# /var/run/nix-daemon.socket, and seatbelt matches the target, so granting the
# link alone is a silent no-op: nix still fails with "cannot connect to socket
# ... Operation not permitted" while the grant sits in allowUnixSockets. Both
# go in, since which one a caller connects through is not ours to pin.
nix_daemon_socket="/nix/var/nix/daemon-socket/socket"
nix_daemon_socket_real=$(readlink -f "$nix_daemon_socket" 2>/dev/null || true)

# The docker CLI reaches forge's daemon over its VM's socket, blocked by the
# same default-deny on unix sockets. Only added to the policy under
# --allow-forge.
#
# Anything that can reach this socket can run a privileged container, so the
# grant is bounded by what the daemon's VM can see and not by this policy: a
# container on a VM with $HOME mounted reads and writes all of it, which is
# what denyRead exists to prevent. So the socket is one forge instance's, and
# __pi_assert_forge_vm checks that instance still declares the properties
# that bound the grant.
#
# Read from neither DOCKER_HOST, LIMA_HOME, FORGE_KUBECONFIG nor the forge
# config: these paths become filesystem.allowRead and allowUnixSockets
# entries, so taking them from the environment would let a checkout's .envrc
# choose what the sandbox grants. The names follow forge's Instance section
# (nix/pkgs/forge/forge.sh). The kubeconfig holds admin credentials for every
# cluster in the instance.
forge_lima_dir=""
forge_socket=""
forge_vm_config=""
forge_kubeconfig=""
# Set for a named instance only: the directory forge keeps its kubeconfig and
# config copy in, granted read-write so `forge up` inside the session can
# write both.
forge_instance_dir=""

# The unnamed instance's kubeconfig, matching `kubeconfig` in
# nix/pkgs/forge/forge.yaml.
forge_default_kubeconfig="@forgeKubeconfig@"
forge_default_kubeconfig="${forge_default_kubeconfig/#\~/$HOME}"

# Outside ~/.pi because every sandboxed session can write ~/.pi, and srt
# resolves a write deny over any allow, so nothing under it could be granted
# to one session and withheld from another.
coord_root="$HOME/.local/state/pi-coord"
coord_dir=""

# The ssh-agent's socket, blocked by the same default-deny on unix sockets.
# Only added to the policy under --allow-ssh-agent.
#
# This is the one grant that makes the policy stricter rather than looser. The
# alternative is re-allowing ~/.ssh so ssh can read a private key, which hands
# the agent every key in the directory and still does not authenticate: a
# passphrase-protected key gets as far as the server accepting the public half
# and then has no way to prompt. Through the agent the signing happens outside
# the sandbox and only the public half is ever readable, so the read grants
# below deliberately name files rather than the directory.
#
# Read from the environment because the path is per-login-session (launchd
# allocates it on darwin), so no static value can name it. That is safe here in
# a way it is not for the docker socket: this path is only ever granted when
# the invocation asks for it, and a checkout's .envrc cannot ask.
ssh_auth_sock="${SSH_AUTH_SOCK:-}"

# Toolchain caches are redirected under here (already inside allowWrite/allowRead
# via ~/.pi) so default-deny reads/writes don't break compilers without widening
# the policy. Tradeoff: cold caches. See __pi_set_hardening_env.
pi_cache_root="$HOME/.pi/sandbox-cache"

# Subagent transcripts (extensions/task.ts). Inside ~/.pi so it stays writable,
# but named in denyRead below so the agent can write its own fan-out record and
# never read one back, its own included. Reading them is a job for the human,
# outside the sandbox.
pi_task_log_dir="$HOME/.pi/agent/task-logs"
pi_task_log_keep_days=30

# Env vars kept through the secret-suffix scrub even though their names look
# secret-bearing. Anything the wrapper injects via envFromCommands/envVars is
# added dynamically; this is the base set of provider keys that may legitimately
# arrive from the caller's shell. See __pi_scrub_secret_env.
pi_keep_env=(
	ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY
	GEMINI_API_KEY GOOGLE_API_KEY GROQ_API_KEY
	GH_TOKEN GITHUB_TOKEN
)

# Scope agent commit attribution to a non-human identity. Exported on every
# invocation regardless of sandbox mode, so attribution holds even under
# --no-sandbox. GIT_{AUTHOR,COMMITTER}_* override any repo/global config
# without mutating it (see gitenvironment(7)). GIT_CONFIG_COUNT layers these
# keys (highest precedence, repo/global/system can't override) on top of the
# user's normal config:
#   commit.gpgsign / tag.gpgsign = false  → agent commits never carry the
#     user's signature, so `git log --show-signature` makes the source obvious.
#   core.hooksPath = /dev/null            → a malicious or unreviewed repo's
#     .git/hooks never execute under the agent's git (a hostile hook would
#     otherwise run with the agent's privileges the moment it commits/checks out).
#   core.fsmonitor = false                → no fsmonitor daemon spawned.
#   core.sshCommand = false               → neuters a repo-config sshCommand
#     injection (arbitrary code at fetch/push time). It also stops git over ssh
#     under --web and --no-sandbox; in strict mode srt's own GIT_SSH_COMMAND
#     takes precedence and fails at the SOCKS handshake instead, so git over
#     ssh works in no mode, --allow-ssh-agent included.
# Override any of these per-host via sandbox.envVars if a workflow needs them.
export GIT_AUTHOR_NAME=@gitAuthorName@
export GIT_AUTHOR_EMAIL=@gitAuthorEmail@
export GIT_COMMITTER_NAME=@gitAuthorName@
export GIT_COMMITTER_EMAIL=@gitAuthorEmail@
export GIT_CONFIG_COUNT=5
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign
export GIT_CONFIG_VALUE_1=false
export GIT_CONFIG_KEY_2=core.hooksPath
export GIT_CONFIG_VALUE_2=/dev/null
export GIT_CONFIG_KEY_3=core.fsmonitor
export GIT_CONFIG_VALUE_3=false
export GIT_CONFIG_KEY_4=core.sshCommand
export GIT_CONFIG_VALUE_4=false
if [[ ${PI_DEBUG:-} == "plan" ]]; then
	printf 'PI_PLAN_GIT: author=%s <%s> sign=false hooksPath=/dev/null\n' \
		"$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL"
fi

# Resolve the repo's real git directories. $PWD/.git is a pointer file in a
# worktree layout, so both dirs sit outside the workspace, where the blanket
# $HOME deny hides them and every git command fails with "not a git
# repository". --path-format=absolute has to precede the queried options
# (git-rev-parse(1)). Empty when git is absent or $PWD is not a repo.
git_dir=""
git_common_dir=""
git_branch=""

__pi_resolve_git_dirs() {
	local dirs
	command -v git >/dev/null 2>&1 || return 0
	dirs=$(git -C "$PWD" rev-parse --path-format=absolute --git-dir --git-common-dir 2>/dev/null) || return 0
	git_dir=${dirs%%$'\n'*}
	git_common_dir=${dirs#*$'\n'}
	[[ -n $git_common_dir ]] || git_common_dir="$git_dir"
	git_branch=$(git -C "$PWD" symbolic-ref --short HEAD 2>/dev/null) || git_branch=""
}

# Whether the agent may write the git dirs, which is what lets it commit. The
# same access lets it move any ref in the repo, so branch-gated (the default)
# grants it only off a protected branch; a detached HEAD has no branch to
# commit onto and is treated as protected.
__pi_git_write_allowed() {
	local b
	[[ -n $git_common_dir ]] || return 1
	case "$git_write_mode" in
	off) return 1 ;;
	always) return 0 ;;
	branch-gated) ;;
	*)
		echo "pi: unknown git write mode: $git_write_mode (want branch-gated|always|off)" >&2
		exit 1
		;;
	esac
	[[ -n $git_branch ]] || return 1
	for b in "${protected_branches[@]}"; do
		if [[ $git_branch == "$b" ]]; then
			return 1
		fi
	done
	return 0
}

# Resolve a secret outside the sandbox and export it into pi's env. Driven
# by a tab-separated VAR<TAB>cmd file generated at build time (see
# envResolversFile in default.nix), which keeps the resolver list out of this
# script so the substitution surface is just one path. Under PI_DEBUG=plan
# the resolver prints intent and skips execution, so the flake check never
# invokes real Keychain / kubectl / etc. Hard-fail on resolver error so a
# stale credential surfaces immediately instead of as an opaque auth error
# from pi later.
pi_env_resolvers_file="@envResolversFile@"

__pi_resolve() {
	local var="$1" cmd="$2" val
	if [[ ${PI_DEBUG:-} == "plan" ]]; then
		printf 'PI_PLAN_ENV: %s=%s\n' "$var" "$cmd"
		return 0
	fi
	if ! val=$(eval "$cmd"); then
		echo "pi: resolver failed for \$$var (cmd: $cmd)" >&2
		exit 1
	fi
	export "$var=$val"
}

__pi_resolve_all() {
	[[ -s $pi_env_resolvers_file ]] || return 0
	local var cmd
	while IFS=$'\t' read -r var cmd; do
		[[ -n $var ]] && __pi_resolve "$var" "$cmd"
	done <"$pi_env_resolvers_file"
}

# Static env vars exported before sandbox dispatch. Tab-separated
# VAR<TAB>value sidecar; values get bash double-quote expansion at runtime
# so $PWD/$HOME resolve to the user's CWD-at-invocation and home dir.
# Trust model matches __pi_resolve_all, values come from user-authored
# nix config. Under PI_DEBUG=plan, prints intent and still exports so
# subsequent dispatch can observe the resolved values if it wants to.
pi_env_vars_file="@envVarsFile@"

__pi_apply_env_vars() {
	[[ -s $pi_env_vars_file ]] || return 0
	local var raw expanded
	while IFS=$'\t' read -r var raw; do
		[[ -z $var ]] && continue
		expanded=$(eval "printf '%s' \"$raw\"")
		if [[ ${PI_DEBUG:-} == "plan" ]]; then
			printf 'PI_PLAN_EXPORTED: %s=%s\n' "$var" "$expanded"
		fi
		export "$var=$expanded"
	done <"$pi_env_vars_file"
}

# Supply-chain + cache hardening defaults, exported BEFORE user env so
# sandbox.envVars can override any of them. Two jobs:
#  - npm/yarn lifecycle-script blocking: postinstall hooks are the top
#    supply-chain vector. Off by default; a package with native build steps
#    needs the user to re-enable via sandbox.envVars (npm_config_ignore_scripts="").
#  - cache redirection: point toolchain caches under ~/.pi/sandbox-cache (already
#    writable+readable) so default-deny FS doesn't break compilers. Cold caches
#    are the tradeoff; for warm caches add the real dir to allowedReadPaths +
#    allowedWritePaths instead.
__pi_set_hardening_env() {
	local kv hardening=(
		"npm_config_ignore_scripts=true"
		"YARN_ENABLE_SCRIPTS=false"
		"GOCACHE=$pi_cache_root/go-build"
		"GOMODCACHE=$pi_cache_root/go-mod"
		"CARGO_HOME=$pi_cache_root/cargo"
		"npm_config_cache=$pi_cache_root/npm"
		"PIP_CACHE_DIR=$pi_cache_root/pip"
		"UV_CACHE_DIR=$pi_cache_root/uv"
		"XDG_CACHE_HOME=$pi_cache_root/xdg"
		# Neither /tmp nor macOS's per-user $TMPDIR is in allowWrite, so a
		# tool reaching for a temp file gets EPERM unless TMPDIR points
		# somewhere granted. Programs that hardcode /tmp still fail.
		"TMPDIR=$pi_cache_root/tmp"
		# srt overwrites TMPDIR in the child whenever a write policy is set,
		# preferring CLAUDE_CODE_TMPDIR and falling back to /tmp/claude, which
		# it also force-adds to allowWrite (sandbox-runtime,
		# dist/sandbox/sandbox-utils.js: generateProxyEnvVars,
		# getDefaultWritePaths). Setting it is what keeps the line above from
		# being discarded, and keeps pi's jiti-compiled extensions out of a
		# 1777 directory it loads them back from.
		"CLAUDE_CODE_TMPDIR=$pi_cache_root/tmp"
		# HotSpot on darwin takes java.io.tmpdir from the Darwin per-user temp
		# dir and ignores TMPDIR, so the line above does not reach it. Left
		# alone, a jar that unpacks a native library (sqlite-jdbc) fails with
		# "Operation not permitted" on the .lck file. JAVA_TOOL_OPTIONS rather
		# than JDK_JAVA_OPTIONS because it also reaches a JVM started through
		# JNI rather than the java launcher.
		#
		# headless because AWT initialisation reaches the window server over
		# XPC, which no sandbox profile here grants: the call does not fail, it
		# hangs, so an ImageIO test that would pass sits there until something
		# kills it. There is no display in a sandboxed session to lose.
		#
		# preferIPv4Stack because loopback binding here is IPv4-only, while
		# `localhost` resolves to ::1 first: a JVM test server and the client
		# fetching from it end up on different stacks and the fetch fails with
		# the server sitting right there. Same ::1 trap the ssh ProxyCommand in
		# nix/profiles/common/ssh-hosts.nix answers with -4. Nothing is lost,
		# since external egress leaves through an IPv4 proxy either way.
		"JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=$pi_cache_root/tmp -Djava.awt.headless=true -Djava.net.preferIPv4Stack=true"
		# The CLI reads config.json from here. Redirected because ~/.docker
		# holds registry credentials, which is why credentialMasks covers it:
		# the agent gets a daemon, not the tokens to pull private images with.
		"DOCKER_CONFIG=$pi_cache_root/docker"
	)
	# Whatever DOCKER_HOST the caller had names a daemon this policy does not
	# grant, so point the CLI at the one it does.
	#
	# kubectl resolves --context against KUBECONFIG, and caches discovery under
	# $HOME/.kube/cache, which the $HOME deny makes unwritable. Redirected rather
	# than granted: ~/.kube is a credentialMasks entry holding real cluster
	# credentials, and forge's clusters are not in it.
	if "$allow_forge"; then
		hardening+=(
			"DOCKER_HOST=unix://$forge_socket"
			"KUBECONFIG=$forge_kubeconfig"
			"KUBECACHEDIR=$pi_cache_root/kube"
		)
		[[ -z $forge_instance ]] || hardening+=("FORGE_INSTANCE=$forge_instance")
	fi
	if [[ -n $coord_role ]]; then
		hardening+=("PI_COORD_ROLE=$coord_role" "PI_COORD_DIR=$coord_dir")
	fi
	for kv in "${hardening[@]}"; do
		export "${kv%%=*}=${kv#*=}"
		[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_HARDENING: %s\n' "$kv"
	done
	[[ ${PI_DEBUG:-} == "plan" ]] || mkdir -p "$pi_cache_root" "$pi_cache_root/tmp" 2>/dev/null || true

	# task.ts appends here and hands the path to itself through this var. The
	# directory has to be made out here because denyRead blocks the stat that
	# mkdir -p does inside, and pruned out here because nothing under the deny
	# can enumerate what it wrote.
	export PI_TASK_LOG_DIR="$pi_task_log_dir"
	if [[ ${PI_DEBUG:-} != "plan" ]]; then
		mkdir -p "$pi_task_log_dir" 2>/dev/null || true
		find "$pi_task_log_dir" -type f -mtime +"$pi_task_log_keep_days" -delete 2>/dev/null || true
	fi
}

# Strip secret-bearing env vars (matched by name suffix) that leaked in from the
# caller's shell, so a stray FOO_TOKEN never rides into pi. Vars the wrapper
# explicitly injected (envFromCommands / envVars) and the pi_keep_env provider
# keys survive. Runs AFTER resolution so injected secrets are protected.
__pi_scrub_secret_env() {
	local v u k
	declare -A keep=()
	for k in "${pi_keep_env[@]}"; do keep[$k]=1; done
	[[ -s $pi_env_resolvers_file ]] && while IFS=$'\t' read -r k _; do
		[[ -n $k ]] && keep[$k]=1
	done <"$pi_env_resolvers_file"
	[[ -s $pi_env_vars_file ]] && while IFS=$'\t' read -r k _; do
		[[ -n $k ]] && keep[$k]=1
	done <"$pi_env_vars_file"
	# jq's $ENV lists exported var names portably (compgen isn't a reliable
	# builtin under writeShellApplication's bash).
	while IFS= read -r v; do
		[[ -z $v ]] && continue
		[[ -n ${keep[$v]+x} ]] && continue
		u=${v^^}
		case "$u" in
		*_TOKEN | *_SECRET | *_PASSWORD | *_PASSWD | *_CREDENTIALS | *_API_KEY | *_APIKEY | *_ACCESS_KEY | *_SECRET_KEY | *_PRIVATE_KEY)
			[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_SCRUBBED: %s\n' "$v"
			unset "$v"
			;;
		esac
	done < <(jq -rn '$ENV | keys[]')
}

# Strip code-injection directives from an inherited NODE_OPTIONS so a poisoned
# parent env can't preload arbitrary modules into pi (or any node child).
# Benign flags like --max-old-space-size pass through.
__pi_scrub_node_options() {
	[[ -n ${NODE_OPTIONS:-} ]] || return 0
	local tok skip=false out=() toks=()
	read -ra toks <<<"$NODE_OPTIONS"
	for tok in "${toks[@]}"; do
		if $skip; then
			skip=false
			continue
		fi
		case "$tok" in
		--require | --import | --loader | --experimental-loader | -r)
			skip=true
			;; # value is the next token; drop both
		--require=* | --import=* | --loader=* | --experimental-loader=* | --inspect | --inspect=* | --inspect-brk*) ;;
		*) out+=("$tok") ;;
		esac
	done
	[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_NODE_OPTIONS: %s\n' "${out[*]:-}"
	if [[ ${#out[@]} -gt 0 ]]; then
		export NODE_OPTIONS="${out[*]}"
	else
		unset NODE_OPTIONS
	fi
}

# Named bundles for the --allow-<name> CLI flags. Each is a trustd bool plus
# three space-joined lists: network hosts, read paths and write paths. TSV
# sidecar comes from default.nix; empty when no bundles are configured. The
# catch-all --allow-* arg-parser case looks bundles up by name, extends the
# domain and path lists, and ORs trustd into the wrapper's allow_trustd flag.
#
# Space-joined means a path containing a space is not representable. No
# toolchain cache dir has needed one.
pi_network_bundles_file="@networkBundlesFile@"
declare -A bundle_domains=()
declare -A bundle_trustd=()
declare -A bundle_reads=()
declare -A bundle_writes=()
if [[ -s $pi_network_bundles_file ]]; then
	while IFS=$'\t' read -r __bname __btrustd __bdomains __breads __bwrites; do
		[[ -n $__bname ]] || continue
		bundle_domains[$__bname]="$__bdomains"
		bundle_trustd[$__bname]="$__btrustd"
		bundle_reads[$__bname]="$__breads"
		bundle_writes[$__bname]="$__bwrites"
	done <"$pi_network_bundles_file"
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
	--allow)
		extra_domains+=("$2")
		shift 2
		;;
	--allow=*)
		extra_domains+=("${1#--allow=}")
		shift
		;;
	--allow-write)
		extra_write_paths+=("$2")
		shift 2
		;;
	--allow-write=*)
		extra_write_paths+=("${1#--allow-write=}")
		shift
		;;
	--allow-read)
		extra_read_paths+=("$2")
		shift 2
		;;
	--allow-read=*)
		extra_read_paths+=("${1#--allow-read=}")
		shift
		;;
	--web)
		web_mode=true
		shift
		;;
	--no-sandbox)
		no_sandbox=true
		shift
		;;
	--allow-loopback)
		allow_loopback=true
		shift
		;;
	--allow-trustd)
		allow_trustd=true
		shift
		;;
	--allow-git-write)
		git_write_mode=always
		shift
		;;
	--no-git-write)
		git_write_mode=off
		shift
		;;
	--allow-nix)
		# Exact-match case: it shadows any network bundle named "nix".
		allow_nix=true
		shift
		;;
	--allow-ssh-agent)
		# Exact-match case: it shadows any network bundle named "ssh-agent".
		allow_ssh_agent=true
		shift
		;;
	--allow-forge | --allow-forge=*)
		# Exact-match case: it shadows any network bundle named "forge".
		allow_forge=true
		if [[ $1 == --allow-forge=* ]]; then
			forge_instance=${1#--allow-forge=}
			if [[ ! $forge_instance =~ ^[1-9][0-9]?$ ]] || ((forge_instance > 15)); then
				echo "pi: --allow-forge=<n> takes a forge instance 1-15, got '$forge_instance'" >&2
				exit 1
			fi
		fi
		shift
		;;
	--coordinator | --coordinator=*)
		coord_role=coordinator
		coord_id=""
		[[ $1 == --coordinator=* ]] && coord_id=${1#--coordinator=}
		grants+=("coordinator")
		shift
		;;
	--coord-child=*)
		coord_role=child
		coord_id=${1#--coord-child=}
		coord_agent=${coord_id#*/}
		coord_id=${coord_id%%/*}
		grants+=("coord-child")
		shift
		;;
	--allow-*)
		# Bundle lookup. Resolves to a curated set of network hosts and an
		# optional trustd flip. Unknown bundle names hard-fail so typos
		# surface immediately instead of being silently treated as
		# unrecognised args and passed to pi.
		bundle_name="${1#--allow-}"
		if [[ -n ${bundle_domains[$bundle_name]+x} ]]; then
			# shellcheck disable=SC2206  # intentional word-split of host list
			extra_domains+=(${bundle_domains[$bundle_name]})
			# shellcheck disable=SC2206  # same, for the two path lists
			extra_read_paths+=(${bundle_reads[$bundle_name]})
			# shellcheck disable=SC2206
			extra_write_paths+=(${bundle_writes[$bundle_name]})
			if [[ ${bundle_trustd[$bundle_name]} == "true" ]]; then
				allow_trustd=true
			fi
			grants+=("$bundle_name")
			shift
		else
			known=$(printf '%s ' "${!bundle_domains[@]}")
			echo "pi: unknown bundle: --allow-$bundle_name (known: ${known% })" >&2
			exit 1
		fi
		;;
	--)
		shift
		break
		;;
	*) break ;;
	esac
done

# From the final values rather than the case arms, so a grant a host turns
# on through defaultAllow* is recorded like one given on the command line.
flag_grants=()
for grant in nix ssh-agent forge; do
	allowed="allow_${grant//-/_}"
	if "${!allowed}"; then
		flag_grants+=("$grant")
	fi
done
grants=("${flag_grants[@]}" "${grants[@]}")

# Record which grants this invocation carries, so the prompt can match the
# policy. extensions/grants.ts reads PI_GRANTS and appends each granted
# name's guidance from ~/.pi/agent/grants/<name>.md to the system prompt,
# which is the only place the agent learns what a grant costs (a nix build
# runs outside this sandbox; ssh-agent authenticates as the human). Exported
# rather than written into the prompt here, so the prose stays in the
# reloadable tree and subagents, which task.ts spawns as $PI_REAL_BIN
# children, inherit the same record through the environment.
if [[ ${#grants[@]} -gt 0 ]]; then
	PI_GRANTS=$(
		IFS=,
		printf '%s' "${grants[*]}"
	)
	export PI_GRANTS
	[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_GRANTS: %s\n' "$PI_GRANTS"
fi

# The full grant catalog this wrapper can carry: the four built-in flags
# plus every configured network bundle. Exported even when nothing is
# carried, so that session still learns what it could ask for;
# extensions/grants.ts subtracts PI_GRANTS from it and lists the rest in
# the prompt, each as a --allow-<name> flag the human can restart with.
# Not under --no-sandbox, where no flag is missing and no refusal is the
# sandbox's.
if ! "$no_sandbox"; then
	available_grants=(nix ssh-agent forge)
	if [[ ${#bundle_domains[@]} -gt 0 ]]; then
		available_grants+=("${!bundle_domains[@]}")
	fi
	PI_AVAILABLE_GRANTS=$(printf '%s\n' "${available_grants[@]}" | LC_ALL=C sort -u | paste -sd, -)
	export PI_AVAILABLE_GRANTS
	[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_AVAILABLE_GRANTS: %s\n' "$PI_AVAILABLE_GRANTS"
fi

__pi_resolve_forge() {
	if [[ -n $forge_instance ]]; then
		forge_lima_dir="$HOME/.lima/forge-$forge_instance"
		forge_instance_dir="$HOME/.local/state/forge/$forge_instance"
		forge_kubeconfig="$forge_instance_dir/kubeconfig.yaml"
	else
		forge_lima_dir="$HOME/.lima/forge"
		forge_kubeconfig="$forge_default_kubeconfig"
	fi
	forge_socket="$forge_lima_dir/sock/docker.sock"
	# lima copies the config here at creation and reads this copy for the life
	# of the instance, so it describes the VM that is running rather than what
	# some store path intended.
	forge_vm_config="$forge_lima_dir/lima.yaml"
}

# The VM is the boundary for everything reachable through the docker socket, so
# refuse the grant unless the instance still declares what bounds it: no host
# path mounted, and a port-forward list whose tail denies (lima appends its own
# forward-everything fallback after the last rule, so omitting is not denying).
# nix/pkgs/forge/vm.nix declares both, and nix/checks/forge-vm.nix asserts them
# on the config in the store; this asserts them on the instance that exists.
# The kubeconfig is bounded by the same VM: cluster-admin on a cluster inside it
# is a privileged pod away from root in a node container, so a host path the VM
# mounted would be reachable that way too.
#
# yq reads lima.yaml whether lima persisted it as JSON (as forge creates it) or
# as YAML (as `limactl edit`, which `forge resize` runs, may rewrite it).
__pi_assert_forge_vm() {
	local flag="--allow-forge${forge_instance:+=$forge_instance}"
	if [[ ! -f $forge_vm_config ]]; then
		echo "pi: $flag: no lima instance at $forge_lima_dir" >&2
		echo "pi:          '${forge_instance:+FORGE_INSTANCE=$forge_instance }forge up' creates it. Refusing the grant." >&2
		exit 1
	fi
	if ! yq -e '(.mounts // []) | length == 0' "$forge_vm_config" >/dev/null 2>&1; then
		echo "pi: $flag: instance $forge_lima_dir mounts a host path," >&2
		echo "pi:          so a privileged container would reach it. Refusing the grant." >&2
		exit 1
	fi
	if ! yq -e '[.portForwards[] | select(.ignore == true and .proto == "any")] | length >= 2' \
		"$forge_vm_config" >/dev/null 2>&1; then
		echo "pi: $flag: instance $forge_lima_dir does not deny the port" >&2
		echo "pi:          forwards it leaves unnamed. Refusing the grant." >&2
		exit 1
	fi
}

# The id and agent name become path components of grants, so they are held to
# a shape that cannot climb out of coord_root.
__pi_resolve_coord() {
	local id_re='^[a-z0-9][a-z0-9-]{0,39}$' agent_re='^[a-z0-9][a-z0-9._-]{0,63}$'
	if [[ $coord_role == coordinator && -z $coord_id ]]; then
		coord_id="$(date +%m%d-%H%M)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
	fi
	if [[ ! $coord_id =~ $id_re ]]; then
		echo "pi: coordinator id must match $id_re, got '$coord_id'" >&2
		exit 1
	fi
	coord_dir="$coord_root/$coord_id"
	if [[ $coord_role == child ]]; then
		if [[ ! $coord_agent =~ $agent_re ]]; then
			echo "pi: --coord-child=<id>/<agent>: agent must match $agent_re, got '$coord_agent'" >&2
			exit 1
		fi
		coord_dir="$coord_dir/agents/$coord_agent"
		if [[ ! -d $coord_dir && ${PI_DEBUG:-} != "plan" ]]; then
			echo "pi: --coord-child: no agent directory at $coord_dir; pi-broker makes it." >&2
			exit 1
		fi
		return
	fi
	if [[ -z $coord_broker ]]; then
		echo "pi: --coordinator: this build has no pi-broker to spawn agents with." >&2
		exit 1
	fi
	# pid is the broker's, written by the broker itself.
	local pid
	pid=$(cat "$coord_dir/broker.pid" 2>/dev/null || true)
	if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
		echo "pi: coordinator $coord_id already has a broker (pid $pid)." >&2
		exit 1
	fi
}

# The broker watches this pid, which srt keeps by exec, and exits once it is
# gone. $0 is how it starts children, so they get this same build of the
# policy.
__pi_start_broker() {
	if [[ ${PI_DEBUG:-} == "plan" ]]; then
		printf 'PI_PLAN_BROKER: %s %s %s %s %s\n' "$coord_broker" "$coord_dir" "$$" "$PWD" "$0"
		printf 'PI_PLAN_BROKER_TMUX: %s\n' "$pi_caller_tmux"
		return
	fi
	mkdir -p "$coord_dir/requests" "$coord_dir/agents"
	TMUX=$pi_caller_tmux nohup "$coord_broker" "$coord_dir" "$$" "$PWD" "$0" >>"$coord_dir/broker.log" 2>&1 </dev/null &
	echo "pi: coordinator $coord_id, broker log at $coord_dir/broker.log" >&2
}

# Nothing to grant without an agent, and continuing would defer the failure to
# an opaque "Permission denied (publickey)" from ssh much later.
__pi_assert_ssh_agent() {
	if [[ -z $ssh_auth_sock ]]; then
		echo "pi: --allow-ssh-agent: SSH_AUTH_SOCK is unset, there is no agent to grant." >&2
		echo "pi:          Run from a session that has one. Refusing the grant." >&2
		exit 1
	fi
}

# What --allow-nix costs turns on one bit the daemon owns: whether it treats
# this uid as trusted. Trusted means the build-users-group override above is
# available and the session is effectively unsandboxed. Untrusted means a
# builder still escapes this policy, but only as _nixbld. Ask the daemon
# rather than assume, and read an unanswerable question as the worse case: a
# missing nix or an older daemon is not reassurance.
__pi_warn_nix_trust() {
	local trusted
	trusted=$(nix store info --json 2>/dev/null |
		jq -r 'if has("trusted") then (.trusted | tostring) else "unknown" end' 2>/dev/null) ||
		trusted="unknown"
	case "$trusted" in
	false | 0)
		echo "pi: --allow-nix grants the nix daemon socket. The daemon reports this client" >&2
		echo "pi:          untrusted, so a build cannot become root. It still runs outside" >&2
		echo "pi:          this sandbox as _nixbld." >&2
		;;
	true | 1)
		echo "pi: WARNING: --allow-nix grants the nix daemon socket, and the daemon reports" >&2
		echo "pi:          this client trusted. It can build as root outside this sandbox:" >&2
		echo "pi:          treat the session as unsandboxed." >&2
		;;
	*)
		echo "pi: WARNING: --allow-nix grants the nix daemon socket, and the daemon did not" >&2
		echo "pi:          say whether this client is trusted. A trusted one builds as root" >&2
		echo "pi:          outside this sandbox: treat the session as unsandboxed." >&2
		;;
	esac
}

if "$allow_forge"; then
	__pi_resolve_forge
	__pi_assert_forge_vm
fi

if [[ -n $coord_role ]]; then
	__pi_resolve_coord
fi

if "$allow_ssh_agent"; then
	__pi_assert_ssh_agent
fi

__pi_set_hardening_env
__pi_resolve_all
# The broker opens agent windows in the caller's tmux session, and a host may
# blank TMUX in envVars to keep pi's own tmux probe from running under srt
# (nix/profiles/common/development.nix), so the broker gets the value from
# before envVars.
pi_caller_tmux=${TMUX:-}
__pi_apply_env_vars
__pi_scrub_secret_env
__pi_scrub_node_options

__pi_resolve_git_dirs
if [[ -n $git_common_dir ]]; then
	extra_read_paths+=("$git_common_dir")
	if [[ $git_dir != "$git_common_dir" ]]; then
		extra_read_paths+=("$git_dir")
	fi
	if __pi_git_write_allowed; then
		extra_write_paths+=("$git_common_dir")
		git_write_granted=true
	fi
fi

# nix stats the channel search path even for a flake-only evaluation, and
# ~/.nix-defexpr/channels is a symlink into ~/.local/state/nix, so both the
# link and its target need re-allowing. The store is outside $HOME and already
# readable; the flake's own git+file:// input is covered by the git dirs above.
#
# ~/.nix-profile because opening a remote store makes nix stat every $PATH
# entry looking for ssh, and that one sits under the $HOME deny. ~/.cache/nix
# needs write and not just read: it holds the fetcher locks, and eval aborts
# on `opening lock file ".../fetcher-locks/<hash>.lock": Operation not
# permitted` before it reaches the first derivation.
if "$allow_nix"; then
	extra_read_paths+=(
		"$HOME/.nix-defexpr"
		"$HOME/.local/state/nix"
		"$HOME/.nix-profile"
		"$HOME/.cache/nix"
	)
	extra_write_paths+=("$HOME/.cache/nix")
fi

# The socket needs a read grant as well as an allowUnixSockets entry: the
# $HOME deny covers the path it lives at, and srt gates connect() at the VFS
# layer. ~/.docker is not granted with it, so the credential mask over it
# holds and DOCKER_CONFIG points the CLI at a sandbox-local config instead.
# The domains are where `forge up` fetches the argo-cd chart. Images need
# none: the daemon pulls them inside the VM, where srt's proxy never sees them.
#
# The kubeconfig names API servers on 127.0.0.1, and srt gates loopback egress
# behind allowLocalBinding, not the domain allowlist. Measured against srt
# 0.0.73: with the file readable and the flag off, curl to the API port returns
# 000, and 200 with it on, while adding 127.0.0.1 to allowedDomains changes
# nothing. Granting the file alone would ship a flag that reads a context it
# cannot reach.
#
# The unnamed instance's kubeconfig is the human's and stays read-only. A named
# instance's directory holds only that instance's kubeconfig and config, so it
# is read-write and `forge up` works inside the session.
if "$allow_forge"; then
	extra_read_paths+=("$forge_socket" "$forge_kubeconfig")
	extra_domains+=("${forge_domains[@]}")
	allow_loopback=true
	if [[ -n $forge_instance_dir ]]; then
		extra_read_paths+=("$forge_instance_dir")
		extra_write_paths+=("$forge_instance_dir")
		[[ ${PI_DEBUG:-} == "plan" ]] || mkdir -p "$forge_instance_dir"
	fi
fi

# The coordinator writes only requests, which the broker reads, and reads
# everything its children write. A child reads and writes only its own
# directory, so it can neither queue a spawn nor read a sibling.
case "$coord_role" in
coordinator)
	extra_read_paths+=("$coord_dir")
	extra_write_paths+=("$coord_dir/requests")
	__pi_start_broker
	;;
child)
	extra_read_paths+=("$coord_dir")
	extra_write_paths+=("$coord_dir")
	;;
esac

# Enough for ssh to run, and no more. config and known_hosts because ssh aborts
# without them under the $HOME deny; the public keys because `IdentitiesOnly
# yes` selects which agent key to offer by matching against them. No private
# key and no directory grant, which is the point of routing through the agent.
# known_hosts stays read-only: recording a new host key is a decision for the
# human, and an unknown host fails loudly instead of being trusted silently.
if "$allow_ssh_agent"; then
	extra_read_paths+=("$ssh_auth_sock" "$HOME/.ssh/config" "$HOME/.ssh/known_hosts")
	for pub in "$HOME"/.ssh/*.pub; do
		[[ -e $pub ]] && extra_read_paths+=("$pub")
	done
fi

if [[ ${PI_DEBUG:-} == "plan" ]]; then
	printf 'PI_PLAN_GIT_DIRS: dir=%s common=%s branch=%s write=%s mode=%s nix=%s ssh_agent=%s forge=%s\n' \
		"${git_dir:-none}" "${git_common_dir:-none}" "${git_branch:-none}" \
		"$git_write_granted" "$git_write_mode" "$allow_nix" "$allow_ssh_agent" "$allow_forge"
fi

# Prepend the build-time default pi args before any user-supplied args. Pi
# uses last-wins for repeated flags (e.g. --model), so the user can still
# override on the command line.
set -- "${default_pi_args[@]}" "$@"

resolved_extra_writes=()
for p in "${default_write_paths[@]}" "${extra_write_paths[@]}"; do
	resolved_extra_writes+=("${p/#\~/$HOME}")
done

resolved_extra_reads=()
for p in "${default_read_paths[@]}" "${extra_read_paths[@]}"; do
	resolved_extra_reads+=("${p/#\~/$HOME}")
done

# The one read allowlist, shared by strict mode and --web so that widening the
# network never widens the filesystem. Both deny reads from "/" down and
# re-allow only these: the workspace, pi's own config dir, git's two global
# config locations, the per-platform system paths from defaultSystemReadPaths,
# and whatever the operator or the invocation added.
#
# An allowlist because a denylist here is unbounded: denying $HOME alone leaves
# /private/tmp, the per-user /private/var/folders trees, /Volumes and
# /Users/Shared readable, and those routinely hold copies of $HOME content
# (another agent's scratchpad, a tool's spill file, a mounted backup disk).
# What this toolchain reads is knowable; where macOS puts user data next
# release is not.
#
# git reads its global config on every invocation, including read-only ones,
# and aborts with "unable to access ... Operation not permitted" when the deny
# hides it. Both standard locations are listed since git checks XDG first and
# ~/.gitconfig second (git-config(1), FILES).
#
# Caveat: re-allowing ~/.pi also re-allows ~/.pi/agent/auth.json. Keep pi's
# provider key out of the sandbox via envFromCommands (resolve from Keychain
# outside the sandbox, reference with "!printenv" in models.json) rather than
# on disk if that read matters in your threat model.
read_paths=(
	"$PWD"
	"$HOME/.pi"
	"$HOME/.config/git"
	"$HOME/.gitconfig"
	"${system_read_paths[@]}"
	"${resolved_extra_reads[@]}"
)

# Either exec the final command or, under PI_DEBUG=plan, print it and exit.
# The PI_DEBUG path is for the flake check; humans never set it.
dispatch() {
	if [[ ${PI_DEBUG:-} == "plan" ]]; then
		printf 'PI_PLAN_EXEC:'
		printf ' %s' "$@"
		printf '\n'
		exit 0
	fi
	exec "$@"
}

run_no_sandbox() {
	echo "pi: WARNING: running without sandbox" >&2
	dispatch "$real_pi" "$@"
}

run_web_linux() {
	local nixos_binds=() home_masks=() bwrap_args=()
	[[ -e /run/current-system ]] && nixos_binds+=(--ro-bind /run/current-system /run/current-system)
	[[ -e /run/wrappers ]] && nixos_binds+=(--ro-bind /run/wrappers /run/wrappers)
	[[ -d /run/systemd/resolve ]] && nixos_binds+=(--ro-bind /run/systemd/resolve /run/systemd/resolve)

	for sub in "${credential_masks[@]}"; do
		[[ -e "$HOME/$sub" ]] && home_masks+=(--tmpfs "$HOME/$sub")
	done

	bwrap_args=(
		--ro-bind /nix /nix
		--ro-bind /etc /etc
		--proc /proc
		--dev /dev
		--tmpfs /tmp
		--tmpfs /run/user
		"${nixos_binds[@]}"
		"${home_masks[@]}"
		--bind "$PWD" "$PWD"
		--chdir "$PWD"
	)
	for p in "$HOME/.pi" "${resolved_extra_writes[@]}"; do
		bwrap_args+=(--bind "$p" "$p")
	done
	bwrap_args+=(
		--unshare-user
		--uid "$(id -u)"
		--gid "$(id -g)"
		--unshare-pid
		--unshare-ipc
		--unshare-uts
		--die-with-parent
		--
		"$real_pi"
		"$@"
	)
	dispatch bwrap "${bwrap_args[@]}"
}

run_web_macos() {
	local profile_file
	profile_file=$(mktemp /tmp/pi-sandbox-XXXXXX.sb)
	# shellcheck disable=SC2064 # expand $profile_file now, not at trap time
	trap "rm -f '$profile_file'" EXIT
	{
		echo '(version 1)'
		echo '(deny default)'
		echo '(allow process-fork process-exec signal process-info*)'
		echo '(allow mach* ipc* sysctl* system*)'
		echo '(allow network*)'
		# file-ioctl is its own SBPL operation, covered by neither
		# file-read* nor file-write*. Without it the TUI's tcsetattr on
		# the tty fails: "setRawMode failed with errno: 1".
		echo '(allow file-ioctl (subpath "/dev"))'
		# Bun.spawn wires a child's unused stdio to /dev/null and opens it
		# O_RDWR, so a plain `pi` subprocess dies with EPERM on posix_spawn
		# unless the null device is writable.
		echo '(allow file-write* (literal "/dev/null"))'
		# Reads are the same allowlist strict mode uses. --web buys the
		# network, not the filesystem: (deny default) above is the root deny,
		# and nothing here re-opens it.
		for p in "${read_paths[@]}"; do
			echo "(allow file-read* (subpath \"$p\"))"
		done
		# The root inode itself, which no subpath above covers and dyld reads
		# before exec (sandbox-runtime 0.0.73, macos-sandbox-utils.js
		# generateReadRules, #190). Exposes the dirent names in `ls /` and no
		# subtree contents.
		echo '(allow file-read* (literal "/"))'
		# realpath() lstats every intermediate component, so resolving a
		# symlink into an allowed path fails without metadata on the denied
		# directories along the way. Directories only: no readdir, no file
		# contents.
		echo '(allow file-read-metadata (vnode-type DIRECTORY))'
		# Subsumed by the root deny unless $PWD is $HOME itself, which is the
		# one case where the workspace grant covers them.
		for sub in "${credential_masks[@]}"; do
			[[ -e "$HOME/$sub" ]] && echo "(deny file-read* (subpath \"$HOME/$sub\"))"
		done
		echo "(allow file-write* (subpath \"$PWD\"))"
		echo "(allow file-write* (subpath \"$HOME/.pi\"))"
		for p in "${resolved_extra_writes[@]}"; do
			echo "(allow file-write* (subpath \"$p\"))"
		done
	} >"$profile_file"

	if [[ ${PI_DEBUG:-} == "plan" ]]; then
		printf 'PI_PLAN_PROFILE: %s\n' "$(tr '\n' ' ' <"$profile_file")"
	fi
	dispatch sandbox-exec -f "$profile_file" "$real_pi" "$@"
}

run_strict() {
	local settings_file all_domains allowed_json write_paths write_json
	local deny_read_json allow_read_json deny_write_paths deny_write_json
	local unix_sockets_json unix_sockets b
	settings_file=$(mktemp /tmp/pi-srt-XXXXXX.json)
	# shellcheck disable=SC2064 # expand $settings_file now, not at trap time
	trap "rm -f '$settings_file'" EXIT

	all_domains=("${default_domains[@]}" "${extra_domains[@]}")
	if [[ ${#all_domains[@]} -gt 0 ]]; then
		allowed_json=$(printf '%s\n' "${all_domains[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')
	else
		allowed_json='[]'
	fi

	write_paths=("$PWD" "$HOME/.pi" "${resolved_extra_writes[@]}")
	write_json=$(printf '%s\n' "${write_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')

	# Persistence traps: deny writing the agent could use to plant code that
	# runs UNSANDBOXED on the user's next git invocation, even though $PWD is
	# otherwise writable. srt's denyWrite takes precedence over allowWrite, so
	# these win inside the project dir. (.git/hooks scripts, a .git/config that
	# injects core.hooksPath/sshCommand, .gitmodules pointing at hostile URLs.)
	deny_write_paths=(
		"$PWD/.git/hooks"
		"$PWD/.git/config"
		"$PWD/.gitmodules"
	)
	# The $PWD/.git entries above match nothing in a worktree layout, where
	# that path is a pointer file and the hooks and config that actually run
	# live in the common dir. config.worktree is the per-worktree config
	# extension (git-config(1), extensions.worktreeConfig).
	if [[ -n $git_common_dir ]]; then
		deny_write_paths+=("$git_common_dir/hooks" "$git_common_dir/config")
		if [[ $git_dir != "$git_common_dir" ]]; then
			deny_write_paths+=("$git_dir/config.worktree")
		fi
	fi
	if "$git_write_granted"; then
		# Committing on the agent's own branch must not imply moving anyone
		# else's. Not airtight: a packed-refs rewrite (git pack-refs, git gc)
		# still reaches these refs, but update-ref, commit and branch -f stop
		# here.
		for b in "${protected_branches[@]}"; do
			deny_write_paths+=("$git_common_dir/refs/heads/$b" "$git_common_dir/logs/refs/heads/$b")
		done
	else
		# Withholding the grant is not enough when the git dir sits inside
		# $PWD: the workspace grant already covers it, so the gate has to deny
		# it outright. Read-only git needs no writes there.
		deny_write_paths+=("$git_dir" "$git_common_dir")
	fi
	deny_write_json=$(printf '%s\n' "${deny_write_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")] | unique')

	# srt names this shape "denyAllExcept". Rules resolve by longest matching
	# prefix, so allowing "$HOME/.pi" re-opens what denying "/" hid, and denying
	# the transcript dir under it closes that one back up. Verified against
	# sandbox-runtime 0.0.73: a sibling file under ~/.pi stayed readable while
	# the denied subdirectory refused open, stat, rename and readdir.
	# credential_masks is not consulted here, the root deny subsumes it.
	deny_read_paths=("/" "$pi_task_log_dir")
	deny_read_json=$(printf '%s\n' "${deny_read_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')
	allow_read_json=$(printf '%s\n' "${read_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')

	unix_sockets=()
	if "$allow_nix"; then
		unix_sockets+=("$nix_daemon_socket")
		if [[ -n $nix_daemon_socket_real && $nix_daemon_socket_real != "$nix_daemon_socket" ]]; then
			unix_sockets+=("$nix_daemon_socket_real")
		fi
		__pi_warn_nix_trust
	fi
	if "$allow_forge"; then
		unix_sockets+=("$forge_socket")
	fi
	if "$allow_ssh_agent"; then
		unix_sockets+=("$ssh_auth_sock")
	fi
	if [[ ${#unix_sockets[@]} -gt 0 ]]; then
		unix_sockets_json=$(printf '%s\n' "${unix_sockets[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')
	else
		unix_sockets_json='[]'
	fi

	# allowPty=true is macOS-only (lets `pi`'s interactive TUI call setRawMode
	# through sandbox-exec). Linux's bwrap ignores unknown keys.
	# allowLocalBinding=true tells srt to emit (allow network-bind (local ip "*:*"))
	# rules so httptest et al. can bind 127.0.0.1; external bind stays blocked.
	# enableWeakerNetworkIsolation=true permits com.apple.trustd.agent mach
	# lookups so Go on macOS can verify TLS through Security framework; the
	# tradeoff is a wider egress surface (LDAP / OCSP responder URLs).
	# bwrap on Linux ignores unknown top-level keys.
	jq -n \
		--argjson allowed "$allowed_json" \
		--argjson write "$write_json" \
		--argjson allowRead "$allow_read_json" \
		--argjson denyRead "$deny_read_json" \
		--argjson denyWrite "$deny_write_json" \
		--argjson allowLoopback "$allow_loopback" \
		--argjson allowTrustd "$allow_trustd" \
		--argjson unixSockets "$unix_sockets_json" \
		'{
            "network": {
              "allowedDomains": $allowed,
              "deniedDomains": [],
              "allowLocalBinding": $allowLoopback,
              "allowUnixSockets": $unixSockets
            },
            "filesystem": {"allowRead": $allowRead, "allowWrite": $write, "denyRead": $denyRead, "denyWrite": $denyWrite},
            "allowPty": true,
            "enableWeakerNetworkIsolation": $allowTrustd
          }' >"$settings_file"

	if [[ ${PI_DEBUG:-} == "plan" ]]; then
		printf 'PI_PLAN_SETTINGS: %s\n' "$(jq -c . <"$settings_file")"
	fi
	dispatch srt --settings "$settings_file" -- "$real_pi" "$@"
}

if "$no_sandbox"; then
	run_no_sandbox "$@"
elif "$web_mode"; then
	if [[ "$(uname)" == "Linux" ]]; then
		run_web_linux "$@"
	else
		run_web_macos "$@"
	fi
else
	run_strict "$@"
fi
