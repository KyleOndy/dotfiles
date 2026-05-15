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
  # Static env vars exported before sandbox dispatch. Values are bash
  # double-quote-expanded at wrapper runtime, so `$PWD` and `$HOME` resolve
  # against the user's CWD-at-invocation. Use for tool-cache redirects
  # (GOCACHE/GOMODCACHE/etc.) so writes land under $PWD instead of broadening
  # allowWrite to $HOME/Library/Caches.
  defaultEnvVars ? { },
  # Default for srt's network.allowLocalBinding setting. When true (or when
  # --allow-loopback is passed), srt's macOS profile permits bind/listen on
  # loopback only — external network is still gated by the domain allowlist.
  defaultAllowLoopback ? false,
  # Default for srt's enableWeakerNetworkIsolation setting. When true (or when
  # --allow-trustd is passed, or when an invoked bundle declares trustd=true),
  # the macOS sandbox profile permits com.apple.trustd.agent mach lookups so
  # Go on macOS can verify TLS certificates through Security framework. The
  # tradeoff is a wider egress surface (trustd resolves LDAP / OCSP responder
  # URLs); off by default.
  defaultAllowTrustd ? false,
  # Named bundles enabling per-invocation `--allow-<name>` CLI flags. Each
  # bundle is { domains = [str]; trustd = bool; } — domains extend the network
  # allowlist; trustd ORs into the wrapper's allow_trustd. Default empty so
  # the wrapper itself is self-contained; the hm module ships the standard
  # set (go/rust/node/python).
  networkBundles ? { },
  # Secrets resolved outside the sandbox and exported as env vars before exec.
  # { VAR_NAME = "shell command that prints the secret on stdout"; ... }
  # Each command runs in the wrapper's parent shell, so it has full access to
  # the host (Keychain, pass, sops, kubectl). Resolved values flow through to
  # pi via process env; non-zero exit on any resolver aborts pi startup.
  envFromCommands ? { },
  # Identity stamped on any git commit pi makes. Exported as GIT_AUTHOR_* /
  # GIT_COMMITTER_* in the wrapper process so it overrides repo & global
  # config without mutating either. Defaults are deliberately non-human —
  # agent commits should be obvious in `git log` so a human auditor can
  # tell them apart at a glance. Signing is hardcoded off in wrapper.sh
  # (not a knob) for the same reason.
  gitAuthorName ? "Kyle's Daemon",
  gitAuthorEmail ? "ai-daemon@noreply.ondy.org",
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

  # Tab-separated VAR<TAB>value lines for static env vars. Same sidecar
  # pattern as envResolversFile — wrapper reads at runtime, bash-expands
  # each value with double-quote semantics so $PWD/$HOME resolve, then
  # exports.
  envVarsFile = writeText "pi-env-vars" (
    lib.concatMapStrings (name: "${name}\t${defaultEnvVars.${name}}\n") (lib.attrNames defaultEnvVars)
  );

  # TSV sidecar for network bundles: name<TAB>trustd<TAB>space-joined-domains.
  # wrapper.sh reads at runtime and splits into two associative arrays
  # (bundle_domains / bundle_trustd). Empty file when networkBundles == {};
  # wrapper short-circuits on empty so unknown --allow-<x> fails fast with
  # "known: " (empty list) in the diagnostic.
  networkBundlesFile = writeText "pi-network-bundles" (
    lib.concatMapStrings (
      name:
      let
        b = networkBundles.${name};
      in
      "${name}\t${if b.trustd or false then "true" else "false"}\t${
        lib.concatStringsSep " " (b.domains or [ ])
      }\n"
    ) (lib.attrNames networkBundles)
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
        "@envVarsFile@"
        "@networkBundlesFile@"
        "@defaultAllowLoopback@"
        "@defaultAllowTrustd@"
        "@gitAuthorName@"
        "@gitAuthorEmail@"
      ]
      [
        realPiBin
        (bashArray credentialMasks)
        (bashArray defaultDomains)
        (bashArray defaultWritePaths)
        (lib.escapeShellArgs defaultPiArgs)
        "${envResolversFile}"
        "${envVarsFile}"
        "${networkBundlesFile}"
        (if defaultAllowLoopback then "true" else "false")
        (if defaultAllowTrustd then "true" else "false")
        (lib.escapeShellArg gitAuthorName)
        (lib.escapeShellArg gitAuthorEmail)
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
