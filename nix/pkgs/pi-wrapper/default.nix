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
  # Paths re-allowed for READING in strict mode, which denies "/" and re-allows
  # an explicit set. $PWD, ~/.pi and defaultSystemReadPaths are always readable;
  # this list adds more, typically the toolchain config/caches an agent's
  # commands read (e.g. ~/.gitconfig, ~/.cargo, ~/.rustup, ~/go, ~/.npmrc).
  # Runtime --allow-read extends this. Supports ~ expansion.
  defaultReadPaths ? [ ],
  # System paths re-allowed under that root deny, measured against this
  # toolchain rather than guessed: git, ripgrep, node, python3, jq, pi itself,
  # xcrun, sw_vers and TLS through srt's proxy all work with these and nothing
  # more. The two lists differ in kind. On darwin they are deny carve-outs, and
  # short because dyld maps the shared cache instead of reading it as a file.
  # On linux srt binds each entry into a fresh mount namespace, so the list has
  # to carry what /bin/sh needs to exist at all.
  #
  # /var is the symlink node, not /private/var: reaching the zoneinfo database
  # through /etc/localtime and /usr/share/zoneinfo traverses it, and naming it
  # does not re-open /private/var/folders. Omit it and the sandbox reports UTC,
  # with no error to say so.
  defaultSystemReadPaths ?
    if stdenv.isDarwin then
      [
        "/nix"
        "/etc"
        "/private/etc"
        "/dev"
        "/private/var/select"
        "/System"
        "/usr"
        "/var"
        "/private/var/db/timezone"
      ]
    else
      [
        "/nix"
        "/etc"
        "/usr"
        "/bin"
        "/proc"
        "/sys"
        "/dev"
        "/run"
        "/var"
      ],
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
  # loopback only, external network is still gated by the domain allowlist.
  defaultAllowLoopback ? false,
  # Default for srt's enableWeakerNetworkIsolation setting. When true (or when
  # --allow-trustd is passed, or when an invoked bundle declares trustd=true),
  # the macOS sandbox profile permits com.apple.trustd.agent mach lookups so
  # Go on macOS can verify TLS certificates through Security framework. The
  # tradeoff is a wider egress surface (trustd resolves LDAP / OCSP responder
  # URLs); off by default.
  defaultAllowTrustd ? false,
  # Write access to the repo's git dirs, which is what lets the agent commit.
  # "branch-gated" grants it off a non-protected branch only, "always" and
  # "off" are unconditional; --allow-git-write / --no-git-write override per
  # invocation. Reading those dirs is not a knob: without it git reports the
  # workspace as "not a git repository" in any worktree layout.
  gitWriteMode ? "branch-gated",
  # Refs and reflogs kept in denyWrite even once write is granted for another
  # branch, so an agent commit cannot move these.
  protectedBranches ? [
    "main"
    "master"
  ],
  # Default for --allow-nix (nix's channel search path plus the daemon socket).
  # Off because the grant is equivalent to --no-sandbox wherever the invoking
  # user is in nix's trusted-users: such a client can build as root, outside
  # srt, and read what denyRead covers. See the nix_daemon_socket comment in
  # wrapper.sh for the measurement. Leave this false and grant per-invocation,
  # so the escape is scoped to a session you chose it for rather than every
  # session on the host, including ones spent reading someone else's code.
  defaultAllowNix ? false,
  # Default for --allow-docker (one lima instance's daemon socket). Off because
  # a caller that reaches the socket can start a privileged container, so the
  # real boundary becomes whatever the daemon's VM mounts rather than this
  # policy. The wrapper refuses the grant unless that instance declares no
  # mounts, which keeps the failure mode a refusal rather than a silent
  # widening, but leaving this false still scopes the grant to sessions chosen
  # for it.
  defaultAllowDocker ? false,
  # Default for --allow-ssh-agent (the ssh-agent socket, plus the ssh config,
  # known_hosts and public keys ssh needs to use it). Off because it lets the
  # agent authenticate as the human to anything the network allowlist reaches,
  # so it belongs to a session chosen for it. Unlike the other two socket
  # grants this one narrows what a working ssh costs: without it the only way
  # to sign is re-allowing ~/.ssh, which exposes the private keys and still
  # fails on a passphrase-protected one.
  defaultAllowSshAgent ? false,
  # The lima instance whose docker socket --allow-docker grants, under
  # ~/.lima/<name>. forge's VM (nix/pkgs/forge/vm.nix) is the one instance here
  # that declares no mounts and denies the port forwards it does not name,
  # which is what bounds the grant; colima's default profile mounts $HOME.
  dockerLimaInstance ? "forge",
  # Named bundles enabling per-invocation `--allow-<name>` CLI flags. Each is
  # { domains = [str]; trustd = bool; readPaths = [str]; writePaths = [str]; }.
  # domains extend the network allowlist, readPaths and writePaths extend the
  # filesystem grants (leading ~ expanded like the default*Paths lists), and
  # trustd ORs into the wrapper's allow_trustd. Default empty so the wrapper
  # itself is self-contained; the hm module ships the standard set
  # (go/rust/node/python/java/clojure).
  networkBundles ? { },
  # Secrets resolved outside the sandbox and exported as env vars before exec.
  # { VAR_NAME = "shell command that prints the secret on stdout"; ... }
  # Each command runs in the wrapper's parent shell, so it has full access to
  # the host (Keychain, pass, sops, kubectl). Resolved values flow through to
  # pi via process env; non-zero exit on any resolver aborts pi startup.
  envFromCommands ? { },
  # Identity stamped on any git commit pi makes. Exported as GIT_AUTHOR_* /
  # GIT_COMMITTER_* in the wrapper process so it overrides repo & global
  # config without mutating either. Defaults are deliberately non-human,
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
  # Keeping the resolver list out of wrapper.sh, and substituting a single
  # file path instead of a code block, means the wrapper is byte-stable
  # across overrides and there's no token-in-comment hazard for code.
  envResolversFile = writeText "pi-env-resolvers" (
    lib.concatMapStrings (name: "${name}\t${envFromCommands.${name}}\n") (lib.attrNames envFromCommands)
  );

  # Tab-separated VAR<TAB>value lines for static env vars. Same sidecar
  # pattern as envResolversFile: wrapper reads at runtime, bash-expands
  # each value with double-quote semantics so $PWD/$HOME resolve, then
  # exports.
  envVarsFile = writeText "pi-env-vars" (
    lib.concatMapStrings (name: "${name}\t${defaultEnvVars.${name}}\n") (lib.attrNames defaultEnvVars)
  );

  # TSV sidecar for network bundles:
  # name<TAB>trustd<TAB>domains<TAB>readPaths<TAB>writePaths, each list
  # space-joined. wrapper.sh reads at runtime and splits into four associative
  # arrays. Empty file when networkBundles == {}; wrapper short-circuits on
  # empty so unknown --allow-<x> fails fast with "known: " (empty list) in the
  # diagnostic.
  networkBundlesFile = writeText "pi-network-bundles" (
    lib.concatMapStrings (
      name:
      let
        b = networkBundles.${name};
        join = lib.concatStringsSep " ";
      in
      lib.concatStringsSep "\t" [
        name
        (if b.trustd or false then "true" else "false")
        (join (b.domains or [ ]))
        (join (b.readPaths or [ ]))
        (join (b.writePaths or [ ]))
      ]
      + "\n"
    ) (lib.attrNames networkBundles)
  );

  body =
    builtins.replaceStrings
      [
        "@realPiBin@"
        "@credentialMasks@"
        "@defaultDomains@"
        "@defaultWritePaths@"
        "@defaultReadPaths@"
        "@systemReadPaths@"
        "@defaultPiArgs@"
        "@envResolversFile@"
        "@envVarsFile@"
        "@networkBundlesFile@"
        "@defaultAllowLoopback@"
        "@defaultAllowTrustd@"
        "@defaultAllowNix@"
        "@defaultAllowDocker@"
        "@defaultAllowSshAgent@"
        "@dockerLimaInstance@"
        "@gitWriteMode@"
        "@protectedBranches@"
        "@gitAuthorName@"
        "@gitAuthorEmail@"
      ]
      [
        realPiBin
        (bashArray credentialMasks)
        (bashArray defaultDomains)
        (bashArray defaultWritePaths)
        (bashArray defaultReadPaths)
        (bashArray defaultSystemReadPaths)
        (lib.escapeShellArgs defaultPiArgs)
        "${envResolversFile}"
        "${envVarsFile}"
        "${networkBundlesFile}"
        (if defaultAllowLoopback then "true" else "false")
        (if defaultAllowTrustd then "true" else "false")
        (if defaultAllowNix then "true" else "false")
        (if defaultAllowDocker then "true" else "false")
        (if defaultAllowSshAgent then "true" else "false")
        dockerLimaInstance
        (lib.escapeShellArg gitWriteMode)
        (bashArray protectedBranches)
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
  # SC2088: a leading ~ in default{Read,Write}Paths is expanded by wrapper.sh
  # (${p/#\~/$HOME}) rather than by the shell, so the quoted tilde is correct.
  excludeShellChecks = [
    "SC2064"
    "SC2088"
  ];
  text = body;
}
