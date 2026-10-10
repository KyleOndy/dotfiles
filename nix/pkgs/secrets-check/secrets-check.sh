# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (nix/pkgs/secrets-check/default.nix).
#
# Fails when a secret would reach a commit or a push in plaintext. Every check
# reads the bytes git stores, never the working tree: an unlocked worktree
# holds git-crypt files decrypted, and a clone with no git-crypt filter
# configured commits a new file under a git-crypt pattern as plaintext with no
# warning.
#
#   secrets-check          the index, as a pre-commit hook
#   secrets-check          PRE_COMMIT_FROM_REF..PRE_COMMIT_TO_REF, as a
#                          pre-push hook
#
# pre-commit passes the range of the first ref pushed only, so `git push
# --all` checks one branch.

# \0GITCRYPT\0, the header of every file git-crypt encrypted.
readonly MAGIC=00474954435259505400

# The flake check runs hooks on a snapshot whose git-crypt files are already
# decrypted, staged into a fresh repo with no filter.
if [ -n "${NIX_BUILD_TOP:-}" ]; then
	echo "secrets-check: skipped inside a nix build" >&2
	exit 0
fi

cd "$(git rev-parse --show-toplevel)" || exit
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Every creation rule's path_regex. sops matches them unanchored, as awk's ~
# does, and they are plain enough to read the same in RE2 and ERE.
SOPS_RE=$(yq -r '[.creation_rules[].path_regex] | join("|")' .sops.yaml)
export SOPS_RE

# protected <file>: <file> holds "<where>\t<blob>\t<path>" lines. Prints the
# ones git-crypt or sops protects, as "<kind>\t<where>\t<blob>\t<path>".
protected() {
	cut -f3 "$1" | sort -u | git check-attr --stdin filter |
		sed -n 's/: filter: git-crypt$//p' >"$tmp/crypt"
	awk -F'\t' -v OFS='\t' '
		FILENAME == ARGV[1] { crypt[$0] = 1; next }
		$3 in crypt { print "git-crypt", $0; next }
		$3 ~ ENVIRON["SOPS_RE"] { print "sops", $0 }' "$tmp/crypt" "$1"
}

# encrypted <kind> <blob>. The blob goes through a file: piping git into an
# early-exiting reader dies of SIGPIPE under pipefail, and a bash variable
# stops at the NUL that starts git-crypt's header.
encrypted() {
	git cat-file blob "$2" >"$tmp/blob"
	if [ "$1" = git-crypt ]; then
		[ "$(head -c 10 "$tmp/blob" | od -An -tx1 | tr -d ' \n')" = "$MAGIC" ]
	else
		# Every value outside sops' own metadata is ENC[...], int and bool
		# included, so one plaintext value fails the file.
		yq -e 'del(.sops) | [.. | select(tag != "!!map" and tag != "!!seq")] | all_c(tag == "!!str" and test("^ENC\["))' \
			"$tmp/blob" >/dev/null 2>&1
	fi
}

# gitleaks reads diffs through textconv, which for diff=git-crypt decrypts.
# cat hands it the stored ciphertext instead, so no git-crypt path needs an
# allowlist entry and a plaintext file under one is scanned like any other.
leaks() {
	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.git-crypt.textconv GIT_CONFIG_VALUE_0=cat \
		gitleaks git --no-banner --redact --exit-code 1 --config .gitleaks.toml "$@" .
}

# verify <file>: <file> as for protected; reports each plaintext blob.
verify() {
	local fail=0 kind where blob path
	while IFS=$'\t' read -r kind where blob path; do
		encrypted "$kind" "$blob" || {
			echo "secrets-check: $path is plaintext in $where" >&2
			fail=1
		}
	done < <(protected "$1")
	return "$fail"
}

check_index() {
	local fail=0
	git ls-files -s | awk -F'\t' -v OFS='\t' '{ split($1, f, " "); print "the index", f[2], $2 }' >"$tmp/blobs"
	verify "$tmp/blobs" || fail=1
	leaks --pre-commit --staged || fail=1
	return "$fail"
}

# Every blob any pushed commit adds, not only the tip's, since a push
# publishes the whole range. -m includes what a merge resolution adds.
check_range() {
	local fail=0
	git log -m --format='C %h' --raw --no-abbrev --no-renames "$1" | awk -F'\t' -v OFS='\t' '
		/^C / { c = substr($0, 3, 8); next }
		/^:/ { split($1, f, " "); if (f[4] !~ /^0+$/) print c, f[4], $2 }' >"$tmp/blobs"
	verify "$tmp/blobs" || fail=1
	leaks --log-opts="$1" || fail=1
	return "$fail"
}

if [ -n "${PRE_COMMIT_FROM_REF:-}" ] && [ -n "${PRE_COMMIT_TO_REF:-}" ]; then
	check_range "$PRE_COMMIT_FROM_REF..$PRE_COMMIT_TO_REF"
elif [ -n "${PRE_COMMIT_REMOTE_NAME:-}" ]; then
	# A push that includes the root commit, for which pre-commit sets no range.
	check_range HEAD
else
	check_index
fi
