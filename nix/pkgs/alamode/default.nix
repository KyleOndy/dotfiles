{
  lib,
  stdenv,
  writeShellApplication,
  writeText,
  writeTextFile,
  writeTextDir,
  symlinkJoin,
  bashInteractive,
  python3,
  nodejs,
  git,
  git-crypt,
  coreutils,
  findutils,
  diffutils,
  gnused,
  gnugrep,
  gawk,
  gnutar,
  gzip,
  gnumake,
  patch,
  fd,
  ripgrep,
  jq,
  yq-go,
  vips,
  bubblewrap,
  llm-agents,
  alamode-runtime,
  alamode-relay,
  alamode-builder,
  realPiBin ? lib.getExe llm-agents.pi,
  defaultDomains ? [ ],
  defaultWritePaths ? [ ],
  defaultReadPaths ? [ ],
  defaultSystemReadPaths ?
    if stdenv.isDarwin then
      [
        "/nix"
        "/etc"
        "/private/etc"
        "/dev"
        "/System"
        "/bin"
        "/usr"
        "/private/var/select"
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
      ],
  defaultPiArgs ? [ ],
  defaultEnvVars ? { },
  defaultAllowTrustd ? false,
  defaultAllowNix ? false,
  defaultGitWrite ? true,
  defaultListenPorts ? [ ],
  coordinatorDaemon ? "",
  delegateBin ? "",
  seatsBin ? "",
  sliceBin ? "",
  seatsFile ? "",
  settingsFile ? "",
  catalogFile ? "",
  runtimeSource ? "",
  privateProviderHosts ? [ ],
  builder ? "",
  # The session nix daemon (systemFoundry.alamodeNixDaemon) and the client
  # sessions reach it with; exclusive with builder.
  nixDaemonSocket ? "",
  nixDaemonLabel ? "",
  nixClient ? null,
  # Program the relay runs for the bell extension; empty leaves it off.
  bell ? "",
  trustedProviders ? [ ],
  bundles ? { },
  profiles ? { },
  envFromCommands ? { },
  envGrantGates ? { },
  gitAuthorName ? "Kyle's Daemon",
  gitAuthorEmail ? "ai-daemon@noreply.ondy.org",
}:
let
  runtime = "${alamode-runtime}/libexec/alamode-runtime";
  tools = [
    bashInteractive
    python3
    nodejs
    git
    git-crypt
    # nixpkgs stdenv's own baseline (pkgs/stdenv/generic/common-path.nix).
    # Without it these resolve to /usr/bin: BSD grep and sed, and a make that
    # is an xcrun shim the sandbox cannot run.
    coreutils
    findutils
    diffutils
    gnused
    gnugrep
    gawk
    gnutar
    gzip
    gnumake
    patch
    ripgrep
    # The engine's structured find tool runs fd, resolving it from PATH before
    # it ever downloads into the session-denied agent bin dir (getToolPath), so
    # shipping it here keeps find working while bin stays unwritable.
    fd
    jq
    yq-go
    vips
    llm-agents.sandbox-runtime
  ]
  ++ lib.optionals stdenv.isLinux [ bubblewrap ];
  # The client's own, so it never reads Determinate's /etc/nix/nix.conf,
  # whose settings upstream nix warns are unknown.
  nixClientConf = writeTextDir "nix.conf" ''
    experimental-features = nix-command flakes
  '';
  configuration = writeText "alamode-session-config.json" (
    builtins.toJSON {
      pi = realPiBin;
      shell = lib.getExe bashInteractive;
      node = lib.getExe nodejs;
      path = "${lib.makeBinPath tools}:/run/current-system/sw/bin:/usr/bin:/bin";
      sandboxRunner = "${runtime}/sandbox.mjs";
      buildClient = "${alamode-runtime}/bin/nix";
      builderModule = "${alamode-builder}/libexec/alamode-builder/builder.py";
      nixClient = lib.optionalString (nixClient != null) "${nixClient}/bin";
      nixClientConf = lib.optionalString (nixClient != null) "${nixClientConf}";
      nixCanary = "${runtime}/nix-canary.nix";
      relayModule = "${alamode-relay}/libexec/alamode-relay/relay.py";
      domains = defaultDomains;
      readPaths = defaultReadPaths;
      writePaths = defaultWritePaths;
      systemReadPaths = defaultSystemReadPaths;
      piArgs = defaultPiArgs;
      env = defaultEnvVars;
      allowTrustd = defaultAllowTrustd;
      allowNix = defaultAllowNix;
      gitWrite = defaultGitWrite;
      listenPorts = defaultListenPorts;
      coordinatorDaemon = coordinatorDaemon;
      delegateBin = delegateBin;
      seatsBin = seatsBin;
      sliceBin = sliceBin;
      inherit
        seatsFile
        settingsFile
        catalogFile
        runtimeSource
        trustedProviders
        privateProviderHosts
        builder
        nixDaemonSocket
        nixDaemonLabel
        bell
        ;
      resolvers = envFromCommands;
      resolverGates = envGrantGates;
      inherit bundles profiles;
      gitName = gitAuthorName;
      gitEmail = gitAuthorEmail;
    }
  );
  script = writeShellApplication {
    name = "alamode";
    text =
      builtins.replaceStrings
        [ "@python@" "@runtime@" "@configuration@" ]
        [ (lib.getExe python3) runtime (toString configuration) ]
        (builtins.readFile ./wrapper.sh);
  };
  completionText =
    builtins.replaceStrings
      [ "@bundleFlags@" "@bundleFlagWords@" "@providerFlags@" "@providerFlagWords@" "@profileNames@" ]
      [
        # _arguments option specs for the grant_flags array
        (lib.concatMapStrings (name: "'--allow-${name}[grant ${name} package registries]' ") (
          lib.attrNames bundles
        ))
        # _describe entries for the flat flag list offered beside verbs
        (lib.concatMapStrings (name: "'--allow-${name}:grant ${name} package registries' ") (
          lib.attrNames bundles
        ))
        (lib.concatMapStrings (
          name: "'--no-${name}[exclude ${name} and every model on its endpoints]' "
        ) trustedProviders)
        (lib.concatMapStrings (
          name: "'--no-${name}:exclude ${name} and every model on its endpoints' "
        ) trustedProviders)
        # --profile choices
        (lib.concatMapStrings (name: "'${name}' ") (lib.attrNames profiles))
      ]
      (builtins.readFile ./_alamode);
  completion = writeTextFile {
    name = "alamode-completion";
    destination = "/share/zsh/site-functions/_alamode";
    text = completionText;
  };
  # Names whose --allow-<name> flag session.py's parse() defines itself. A
  # bundle by one of these names makes argparse refuse every alamode
  # invocation.
  reservedBundleNames = [
    "read"
    "write"
    "rw"
    "git-write"
    "trustd"
    "nix"
    "forge"
    "clipboard"
  ];
  reservedBundles = lib.intersectLists reservedBundleNames (lib.attrNames bundles);
  # Same for the --no-<name> flags parse() defines itself.
  reservedProviders = lib.intersectLists [ "git-write" ] trustedProviders;
  # A profile may only name bundles the wrapper actually knows, so a typo
  # fails the build instead of the first launch that uses the profile.
  knownBundles = lib.attrNames bundles;
  profileUnknown = lib.concatMapStringsSep ", " (
    name:
    let
      missing = lib.subtractLists knownBundles (profiles.${name}.bundles or [ ]);
    in
    if missing == [ ] then "" else "${name}: ${lib.concatStringsSep ", " missing}"
  ) (lib.attrNames profiles);
in
assert lib.assertMsg (reservedBundles == [ ]) (
  "alamode: bundles ${lib.concatStringsSep ", " reservedBundles} shadow the session's own --allow-<name> grants; rename them"
);
assert lib.assertMsg (reservedProviders == [ ]) (
  "alamode: trustedProviders ${lib.concatStringsSep ", " reservedProviders} shadow the session's own --no-<name> flags; rename them"
);
assert lib.assertMsg (profileUnknown == "") (
  "alamode: profiles name unknown bundles (${profileUnknown})"
);
# The completion must be named for the program zsh completes, and its #compdef
# token must match meta.mainProgram; a mismatch completes nothing, silently.
assert lib.assertMsg (lib.hasPrefix "#compdef alamode\n" completionText) (
  "alamode: _alamode must start with '#compdef alamode' to match the binary name"
);
symlinkJoin {
  name = "alamode";
  paths = [
    script
    completion
  ];
  # The completion file must be named for the program zsh completes; a
  # mismatched #compdef token completes nothing, silently.
  meta.mainProgram = "alamode";
}
