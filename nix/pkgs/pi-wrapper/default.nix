{
  lib,
  stdenv,
  writeShellApplication,
  writeText,
  writeTextFile,
  symlinkJoin,
  bashInteractive,
  python3,
  nodejs,
  git,
  git-crypt,
  coreutils,
  ripgrep,
  jq,
  yq-go,
  vips,
  bubblewrap,
  llm-agents,
  pi-session,
  pi-provider-relay,
  pi-builder,
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
  coordinatorBroker ? "",
  seatsFile ? "",
  settingsFile ? "",
  catalogFile ? "",
  runtimeSource ? "",
  privateProviderHosts ? [ ],
  builder ? "",
  trustedProviders ? [ ],
  networkBundles ? { },
  envFromCommands ? { },
  envGrantGates ? { },
  gitAuthorName ? "Kyle's Daemon",
  gitAuthorEmail ? "ai-daemon@noreply.ondy.org",
}:
let
  runtime = "${pi-session}/libexec/pi-session";
  tools = [
    bashInteractive
    python3
    nodejs
    git
    git-crypt
    coreutils
    ripgrep
    jq
    yq-go
    vips
    llm-agents.sandbox-runtime
  ]
  ++ lib.optionals stdenv.isLinux [ bubblewrap ];
  configuration = writeText "pi-session-config.json" (
    builtins.toJSON {
      pi = realPiBin;
      shell = lib.getExe bashInteractive;
      node = lib.getExe nodejs;
      path = "${lib.makeBinPath tools}:/run/current-system/sw/bin:/usr/bin:/bin";
      sandboxRunner = "${runtime}/sandbox.mjs";
      buildClient = "${pi-session}/bin/nix";
      builderModule = "${pi-builder}/libexec/pi-builder/builder.py";
      relayModule = "${pi-provider-relay}/libexec/pi-provider-relay/relay.py";
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
      broker = coordinatorBroker;
      inherit
        seatsFile
        settingsFile
        catalogFile
        runtimeSource
        trustedProviders
        privateProviderHosts
        builder
        ;
      resolvers = envFromCommands;
      resolverGates = envGrantGates;
      bundles = networkBundles;
      gitName = gitAuthorName;
      gitEmail = gitAuthorEmail;
    }
  );
  script = writeShellApplication {
    name = "pi";
    text =
      builtins.replaceStrings
        [ "@python@" "@runtime@" "@configuration@" ]
        [ (lib.getExe python3) runtime (toString configuration) ]
        (builtins.readFile ./wrapper.sh);
  };
  completion = writeTextFile {
    name = "pi-completion";
    destination = "/share/zsh/site-functions/_pi";
    text =
      builtins.replaceStrings
        [ "@bundleFlags@" ]
        [
          (lib.concatMapStrings (name: "  '--allow-${name}[grant ${name} package registries]' \\\n") (
            lib.attrNames networkBundles
          ))
        ]
        (builtins.readFile ./_pi);
  };
  # Names whose --allow-<name> flag session.py's parse() defines itself. A
  # bundle by one of these names makes argparse refuse every pi invocation.
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
  reservedBundles = lib.intersectLists reservedBundleNames (lib.attrNames networkBundles);
in
assert lib.assertMsg (reservedBundles == [ ]) (
  "pi-wrapper: networkBundles ${lib.concatStringsSep ", " reservedBundles} shadow the session's own --allow-<name> grants; rename them"
);
symlinkJoin {
  name = "pi";
  paths = [
    script
    completion
  ];
  meta.mainProgram = "pi";
}
