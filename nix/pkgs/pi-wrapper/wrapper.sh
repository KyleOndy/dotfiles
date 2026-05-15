# shellcheck shell=bash
# Pi sandbox wrapper. Placeholders @realPiBin@ etc. are substituted at build
# time. writeShellApplication injects `set -euo pipefail` automatically.

default_domains=(@defaultDomains@)
default_write_paths=(@defaultWritePaths@)
credential_masks=(@credentialMasks@)
default_pi_args=(@defaultPiArgs@)
real_pi="${PI_REAL_BIN:-@realPiBin@}"

extra_domains=()
extra_write_paths=()
web_mode=false
no_sandbox=false
allow_loopback=@defaultAllowLoopback@
allow_trustd=@defaultAllowTrustd@

# Scope agent commit attribution to a non-human identity. Exported on every
# invocation regardless of sandbox mode, so attribution holds even under
# --no-sandbox. GIT_{AUTHOR,COMMITTER}_* override any repo/global config
# without mutating it (see gitenvironment(7)). GIT_CONFIG_COUNT layers
# commit.gpgsign=false and tag.gpgsign=false on top of whatever the user's
# normal config says — agent commits must never carry the user's signature
# so `git log --show-signature` makes the source obvious at a glance.
export GIT_AUTHOR_NAME=@gitAuthorName@
export GIT_AUTHOR_EMAIL=@gitAuthorEmail@
export GIT_COMMITTER_NAME=@gitAuthorName@
export GIT_COMMITTER_EMAIL=@gitAuthorEmail@
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign
export GIT_CONFIG_VALUE_1=false
if [[ ${PI_DEBUG:-} == "plan" ]]; then
	printf 'PI_PLAN_GIT: author=%s <%s> sign=false\n' \
		"$GIT_AUTHOR_NAME" "$GIT_AUTHOR_EMAIL"
fi

# Resolve a secret outside the sandbox and export it into pi's env. Driven
# by a tab-separated VAR<TAB>cmd file generated at build time (see
# envResolversFile in default.nix) — keeps the resolver list out of this
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
# Trust model matches __pi_resolve_all — values come from user-authored
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

# Named bundles for the --allow-<name> CLI flags. Each bundle is a pair of
# (space-joined domains, trustd-needed bool). TSV sidecar comes from
# default.nix; empty when no bundles are configured. The catch-all
# --allow-* arg-parser case looks bundles up by name and ORs trustd into
# the wrapper's allow_trustd flag.
pi_network_bundles_file="@networkBundlesFile@"
declare -A bundle_domains=()
declare -A bundle_trustd=()
if [[ -s $pi_network_bundles_file ]]; then
	while IFS=$'\t' read -r __bname __btrustd __bdomains; do
		[[ -n $__bname ]] || continue
		bundle_domains[$__bname]="$__bdomains"
		bundle_trustd[$__bname]="$__btrustd"
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
	--allow-*)
		# Bundle lookup. Resolves to a curated set of network hosts and an
		# optional trustd flip. Unknown bundle names hard-fail so typos
		# surface immediately instead of being silently treated as
		# unrecognised args and passed to pi.
		bundle_name="${1#--allow-}"
		if [[ -n ${bundle_domains[$bundle_name]+x} ]]; then
			# shellcheck disable=SC2206  # intentional word-split of host list
			extra_domains+=(${bundle_domains[$bundle_name]})
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

__pi_resolve_all
__pi_apply_env_vars

# Prepend the build-time default pi args before any user-supplied args. Pi
# uses last-wins for repeated flags (e.g. --model), so the user can still
# override on the command line.
set -- "${default_pi_args[@]}" "$@"

resolved_extra_writes=()
for p in "${default_write_paths[@]}" "${extra_write_paths[@]}"; do
	resolved_extra_writes+=("${p/#\~/$HOME}")
done

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
		echo '(allow process-fork process-exec process-signal process-info*)'
		echo '(allow mach* ipc* sysctl* system*)'
		echo '(allow network*)'
		echo '(allow file-read*)'
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
	local settings_file all_domains allowed_json write_paths write_json deny_read_json
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

	deny_read_json=$(
		for sub in "${credential_masks[@]}"; do
			echo "$HOME/$sub"
		done | jq -Rs '[split("\n")[] | select(. != "")]'
	)

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
		--argjson denyRead "$deny_read_json" \
		--argjson allowLoopback "$allow_loopback" \
		--argjson allowTrustd "$allow_trustd" \
		'{
            "network": {
              "allowedDomains": $allowed,
              "deniedDomains": [],
              "allowLocalBinding": $allowLoopback
            },
            "filesystem": {"allowWrite": $write, "denyRead": $denyRead, "denyWrite": []},
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
