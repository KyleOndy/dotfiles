# Desktop profile - the server profile plus the GUI layer.
# Used by trex and work-mac. The dev tooling lives in server.nix so the
# two profiles cannot drift apart.

{ ... }:
{
  imports = [
    ./server.nix
    ./common/desktop.nix
  ];
}
