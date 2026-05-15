# Sandbox-wrapped `pi` binary. See default.nix in
# hm_modules/dev/pi-coding-agent for the home-manager module that consumes
# this. The flake check at nix/checks/pi-coding-agent.nix uses .override to
# inject a stub `pi` binary and exercise the wrapper's decisions.
{
  lib,
  stdenv,
  writeShellApplication,
  writeText,
  bubblewrap,
  jq,
  llm-agents,
  realPiBin ? lib.getExe llm-agents.pi,
  defaultDomains ? [ ],
  defaultWritePaths ? [ ],
  # Args prepended to every `pi` invocation, before user args. Useful for
  # pinning a default model/provider so the user doesn't have to type
  # `--model …` each time. User args still win on duplicates (pi takes the
  # last occurrence of repeated flags like --model).
  defaultPiArgs ? [ ],
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

  # Tab-separated VAR<TAB>cmd lines, one per resolver entry. Empty for {}.
  # The wrapper reads this file at runtime and calls __pi_resolve per line.
  # Keeping the resolver list out of wrapper.sh — and substituting a single
  # file path instead of a code block — means the wrapper is byte-stable
  # across overrides and there's no token-in-comment hazard for code.
  envResolversFile = writeText "pi-env-resolvers" (
    lib.concatMapStrings (name: "${name}\t${envFromCommands.${name}}\n") (lib.attrNames envFromCommands)
  );

  body =
    builtins.replaceStrings
      [
        "@realPiBin@"
        "@credentialMasks@"
        "@defaultDomains@"
        "@defaultWritePaths@"
        "@defaultPiArgs@"
        "@envResolversFile@"
      ]
      [
        realPiBin
        (bashArray credentialMasks)
        (bashArray defaultDomains)
        (bashArray defaultWritePaths)
        (lib.escapeShellArgs defaultPiArgs)
        "${envResolversFile}"
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
