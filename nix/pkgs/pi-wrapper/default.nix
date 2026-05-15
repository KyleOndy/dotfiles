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
  # Secrets resolved outside the sandbox and exported as env vars before exec.
  # { VAR_NAME = "shell command that prints the secret on stdout"; ... }
  # Each command runs in the wrapper's parent shell, so it has full access to
  # the host (Keychain, pass, sops, kubectl). Resolved values flow through to
  # pi via process env; non-zero exit on any resolver aborts pi startup.
  envFromCommands ? { },
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

  envResolveBlock = lib.concatMapStrings (
    name: "__pi_resolve ${lib.escapeShellArg name} ${lib.escapeShellArg envFromCommands.${name}}\n"
  ) (lib.attrNames envFromCommands);

  body =
    builtins.replaceStrings
      [
        "@realPiBin@"
        "@credentialMasks@"
        "@defaultDomains@"
        "@defaultWritePaths@"
        "@envResolveBlock@"
      ]
      [
        realPiBin
        (bashArray credentialMasks)
        (bashArray defaultDomains)
        (bashArray defaultWritePaths)
        envResolveBlock
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
