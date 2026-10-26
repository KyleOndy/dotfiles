# shellcheck shell=bash
# writeShellApplication provides the shebang and `set -euo pipefail`; this
# file is only the body (keyboard/domestique-pad/case/default.nix).
#
# Reads the .scad files from the worktree rather than the store, so an edit
# shows up without a `git add`. It renders outside the build sandbox because
# openscad 2021.01 segfaults inside a darwin one, even on cube(5).
#
#   pad-case                every part, to out/<part>.3mf
#   pad-case fit-test       only the named parts
#   pad-case edit fit-test  the OpenSCAD GUI, which redraws on every save

readonly PARTS=(fit-test bar-pod carrier)
# The A1 mini prints 180 x 180 x 180.
readonly BED=180

src="$(git rev-parse --show-toplevel)/keyboard/domestique-pad/case"
readonly src
readonly out="$src/out"

if [ "${1:-}" = edit ]; then
	exec openscad "$src/${2:-${PARTS[0]}}.scad"
fi

if [ $# -eq 0 ]; then
	set -- "${PARTS[@]}"
fi

mkdir -p "$out"
for part in "$@"; do
	# --hardwarnings because a missing font or an undefined variable is only a
	# warning, and either would still export a part.
	if ! openscad --hardwarnings -o "$out/$part.3mf" "$src/$part.scad" 2>"$out/$part.log"; then
		cat "$out/$part.log" >&2
		exit 1
	fi
	unzip -p "$out/$part.3mf" 3D/3dmodel.model |
		grep -o '<vertex [^>]*>' |
		sed -E 's/.*x="([^"]+)" y="([^"]+)" z="([^"]+)".*/\1 \2 \3/' |
		awk -v part="$part" -v bed="$BED" '
			NR == 1 { for (i = 1; i <= 3; i++) lo[i] = hi[i] = $i }
			{ for (i = 1; i <= 3; i++) { if ($i < lo[i]) lo[i] = $i; if ($i > hi[i]) hi[i] = $i } }
			END {
				printf "%s: %.1f x %.1f x %.1f mm\n", part, hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3]
				for (i = 1; i <= 3; i++) if (hi[i] - lo[i] > bed) { print part ": larger than the A1 mini bed" > "/dev/stderr"; exit 1 }
			}'
done

echo
echo "Slice: open -a BambuStudio $out/$1.3mf"
echo "Edit:  nix run .#pad-case -- edit $1"
