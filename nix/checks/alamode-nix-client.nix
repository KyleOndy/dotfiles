# The reproducer from nix/pkgs/alamode-nix-client/o-search.patch: a file
# beneath a directory that grants search but not read. Unpatched 2.35 fails
# with "opening directory ... Permission denied".
{ pkgs }:
pkgs.runCommand "alamode-nix-client-check" { nativeBuildInputs = [ pkgs.alamode-nix-client ]; } ''
  export HOME=$TMPDIR NIX_CONF_DIR=$TMPDIR/conf
  mkdir -p "$NIX_CONF_DIR" locked
  echo '"read through a search-only directory"' > locked/f.nix
  chmod 0311 locked
  nix --extra-experimental-features nix-command eval --store dummy:// --impure \
    --expr "import $PWD/locked/f.nix"
  touch $out
''
