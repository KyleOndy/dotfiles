# Built through the session nix daemon before every session that holds nix
# (nix_canary in session.py). fod, fetchurl and localnet are the shapes the
# darwin sandbox gives network, so the pre-build hook must refuse them. net
# gets past the hook and must fail in the sandbox. large has more than the
# 1,069 inputs a sandbox profile holds, the case GHSA-m4vq-qf6v-82pj left
# without file confinement, and must succeed only while confined.
{
  nonce,
  # A store path whose closure has well over 1,069 paths: the running system.
  closure,
  system ? builtins.currentSystem,
}:
let
  big = builtins.storePath closure;
  build =
    name: script: extra:
    derivation (
      {
        name = "alamode-canary-${name}";
        inherit system nonce;
        builder = "/bin/bash";
        args = [
          "-c"
          script
        ];
      }
      // extra
    );
  connects = "(exec 3<>/dev/tcp/1.1.1.1/443) 2>/dev/null";
  noHash = "0000000000000000000000000000000000000000000000000000";
in
{
  fod = build "fod" "${connects}; exit 1" {
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = noHash;
  };
  fetchurl = import <nix/fetchurl.nix> {
    name = "alamode-canary-fetchurl";
    url = "https://example.com/?${nonce}";
    sha256 = noHash;
  };
  localnet = build "localnet" "echo > $out" { __darwinAllowLocalNetworking = true; };
  net = build "net" "${connects} && echo > $out" { };
  # Opening a file for reading is the check; a stat would pass while denied.
  large = build "large" ''
    (: < ${big}/darwin-version) || exit 1
    (: < /private/etc/ssh/ssh_config) 2>/dev/null && exit 1
    ${connects} && exit 1
    echo > $out
  '' { };
}
