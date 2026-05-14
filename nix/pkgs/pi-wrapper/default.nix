# Sandbox-wrapped `pi` binary. See default.nix in
# hm_modules/dev/pi-coding-agent for the home-manager module that consumes
# this. The flake check at nix/checks/pi-coding-agent.nix uses .override to
# inject a stub `pi` binary and exercise the wrapper's decisions.
{
  lib,
  stdenv,
  writeShellApplication,
  bubblewrap,
  jq,
  llm-agents,
  realPiBin ? lib.getExe llm-agents.pi,
  defaultDomains ? [ ],
  defaultWritePaths ? [ ],
  credentialMasks ? [
    ".ssh"
    ".gnupg"
    ".config/sops"
    ".aws"
    ".azure"
    ".gcloud"
    ".kube"
    ".docker"
    ".netrc"
    ".git-credentials"
  ],
}:

let
  bashArray = xs: lib.concatStringsSep " " (map (x: ''"${x}"'') xs);

  body =
    builtins.replaceStrings
      [
        "@realPiBin@"
        "@credentialMasks@"
        "@defaultDomains@"
        "@defaultWritePaths@"
      ]
      [
        realPiBin
        (bashArray credentialMasks)
        (bashArray defaultDomains)
        (bashArray defaultWritePaths)
      ]
      (builtins.readFile ./wrapper.sh);
in
writeShellApplication {
  name = "pi";
  runtimeInputs = [
    llm-agents.sandbox-runtime
    jq
  ]
  ++ lib.optionals stdenv.isLinux [ bubblewrap ];
  excludeShellChecks = [ "SC2064" ];
  text = body;
}
