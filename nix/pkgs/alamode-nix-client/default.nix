# nix for alamode sessions: nix-upstream built as its own packages.nix
# builds it, plus o-search.patch, without which the client cannot read a
# file by absolute path inside srt. Only nix's own components rebuild; the
# rest is the same derivations Hydra serves.
{ nix-upstream, system }:
let
  pkgs = import nix-upstream.inputs.nixpkgs {
    localSystem = { inherit system; };
    overlays = [ nix-upstream.overlays.internal ];
  };
in
(pkgs.nixComponents2.appendPatches [ ./o-search.patch ]).nix-everything
