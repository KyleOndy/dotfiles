# shellcheck shell=bash
# Pi sandbox wrapper. Placeholders @realPiBin@ etc. are substituted at build
# time. writeShellApplication injects `set -euo pipefail` automatically.

default_domains=(@defaultDomains@)
default_write_paths=(@defaultWritePaths@)
credential_masks=(@credentialMasks@)
real_pi="${PI_REAL_BIN:-@realPiBin@}"

extra_domains=()
extra_write_paths=()
web_mode=false
no_sandbox=false

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
	--)
		shift
		break
		;;
	*) break ;;
	esac
done

__pi_resolve_all

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
	jq -n \
		--argjson allowed "$allowed_json" \
		--argjson write "$write_json" \
		--argjson denyRead "$deny_read_json" \
		'{
            "network": {"allowedDomains": $allowed, "deniedDomains": []},
            "filesystem": {"allowWrite": $write, "denyRead": $denyRead, "denyWrite": []},
            "allowPty": true
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
