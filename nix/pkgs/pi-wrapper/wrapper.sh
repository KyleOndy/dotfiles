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
web_mode=false
no_sandbox=false
allow_loopback=@defaultAllowLoopback@
allow_trustd=@defaultAllowTrustd@
allow_nix=@defaultAllowNix@
allow_docker=@defaultAllowDocker@
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

# The docker CLI reaches the daemon over this socket, blocked by the same
# default-deny on unix sockets. Only added to the policy under --allow-docker.
#
# Anything that can reach this socket can run a privileged container, so the
# grant is bounded by what the daemon's VM can see and not by this policy: a
# container on a VM with $HOME mounted reads and writes all of it, which is
# what denyRead exists to prevent. So the socket is one named instance's, and
# __pi_assert_docker_vm checks that instance still declares the properties
# that bound the grant.
#
# Read from neither DOCKER_HOST nor LIMA_HOME: this path becomes both a
# filesystem.allowRead entry and an allowUnixSockets entry, so taking it from
# the environment would let a checkout's .envrc choose what the sandbox grants.
docker_lima_dir="$HOME/.lima/@dockerLimaInstance@"
docker_socket="$docker_lima_dir/sock/docker.sock"
# lima copies the config here at creation and reads this copy for the life of
# the instance, so it describes the VM that is running rather than what some
# store path intended.
docker_vm_config="$docker_lima_dir/lima.yaml"

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
#     injection (arbitrary code at fetch/push time); harmless here since strict
#     mode denies ssh egress anyway.
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
	if "$allow_docker"; then
		hardening+=("DOCKER_HOST=unix://$docker_socket")
	fi
	for kv in "${hardening[@]}"; do
		export "${kv%%=*}=${kv#*=}"
		[[ ${PI_DEBUG:-} == "plan" ]] && printf 'PI_PLAN_HARDENING: %s\n' "$kv"
	done
	[[ ${PI_DEBUG:-} == "plan" ]] || mkdir -p "$pi_cache_root" "$pi_cache_root/tmp" 2>/dev/null || true
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
	--allow-docker)
		# Exact-match case: it shadows any network bundle named "docker".
		allow_docker=true
		shift
		;;
	--allow-ssh-agent)
		# Exact-match case: it shadows any network bundle named "ssh-agent".
		allow_ssh_agent=true
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

# The VM is the boundary for everything reachable through the docker socket, so
# refuse the grant unless the instance still declares what bounds it: no host
# path mounted, and a port-forward list whose tail denies (lima appends its own
# forward-everything fallback after the last rule, so omitting is not denying).
# nix/pkgs/forge/vm.nix declares both, and nix/checks/forge-vm.nix asserts them
# on the config in the store; this asserts them on the instance that exists.
__pi_assert_docker_vm() {
	if [[ ! -f $docker_vm_config ]]; then
		echo "pi: --allow-docker: no lima instance at $docker_lima_dir" >&2
		echo "pi:          'forge up' creates it. Refusing the grant." >&2
		exit 1
	fi
	if ! jq -e '(.mounts // []) == []' "$docker_vm_config" >/dev/null 2>&1; then
		echo "pi: --allow-docker: instance $docker_lima_dir mounts a host path," >&2
		echo "pi:          so a privileged container would reach it. Refusing the grant." >&2
		exit 1
	fi
	if ! jq -e '[.portForwards[]? | select(.ignore == true and .proto == "any")] | length >= 2' \
		"$docker_vm_config" >/dev/null 2>&1; then
		echo "pi: --allow-docker: instance $docker_lima_dir does not deny the port" >&2
		echo "pi:          forwards it leaves unnamed. Refusing the grant." >&2
		exit 1
	fi
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

if "$allow_docker"; then
	__pi_assert_docker_vm
fi

if "$allow_ssh_agent"; then
	__pi_assert_ssh_agent
fi

__pi_set_hardening_env
__pi_resolve_all
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
# Paths a container orchestrator writes (kubeconfigs, helm state) are
# deliberately not here, they belong to whoever configures the tool.
if "$allow_docker"; then
	extra_read_paths+=("$docker_socket")
fi

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
	printf 'PI_PLAN_GIT_DIRS: dir=%s common=%s branch=%s write=%s mode=%s nix=%s docker=%s ssh_agent=%s\n' \
		"${git_dir:-none}" "${git_common_dir:-none}" "${git_branch:-none}" \
		"$git_write_granted" "$git_write_mode" "$allow_nix" "$allow_docker" "$allow_ssh_agent"
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

	# srt names this shape "denyAllExcept": allowRead takes precedence over
	# denyRead, so denying "/" hides everything read_paths does not name.
	# credential_masks is not consulted here, the root deny subsumes it.
	deny_read_json='["/"]'
	allow_read_json=$(printf '%s\n' "${read_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')

	unix_sockets=()
	if "$allow_nix"; then
		unix_sockets+=("$nix_daemon_socket")
		if [[ -n $nix_daemon_socket_real && $nix_daemon_socket_real != "$nix_daemon_socket" ]]; then
			unix_sockets+=("$nix_daemon_socket_real")
		fi
		__pi_warn_nix_trust
	fi
	if "$allow_docker"; then
		unix_sockets+=("$docker_socket")
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
