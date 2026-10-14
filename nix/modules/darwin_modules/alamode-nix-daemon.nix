# A second nix daemon that only alamode sessions reach: Determinate's own
# binary, so one upgrade moves both daemons, on a socket and config of its
# own, refusing every build the darwin sandbox would give network.
# docs/alamode-host-nix.md has the design and the measurements.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.systemFoundry.alamodeNixDaemon;
  dir = "/private/var/run/alamode-nix";

  # Nix reads the hook's stdout as commands and logs its stderr to the
  # daemon's log; the client sees only that the hook failed. An
  # input-addressed output is {"path": ...}; fixed-output, impure and
  # floating content-addressed ones have other shapes and get the network.
  hook = pkgs.writeShellScript "alamode-nix-pre-build-hook" ''
    set -euo pipefail
    if ${lib.getExe pkgs.jq} -e '
      (.outputs | all(keys == ["path"]))
      and ([.env.__darwinAllowLocalNetworking?, .structuredAttrs.__darwinAllowLocalNetworking?]
           | all(. == null or . == "" or . == false))
    ' "$NIX_DERIVATION_V4" >/dev/null; then
      exit 0
    fi
    echo "alamode: refused $1, which would get network" >&2
    exit 1
  '';

  # Nothing reads /etc/nix, so every setting the daemon needs is here.
  settings = config.determinateNix.customSettings;
  conf = pkgs.writeTextDir "nix.conf" ''
    sandbox = true
    # darwin's default without /private/tmp and /private/var/tmp, which every
    # build could read and write, and with the store, without which a build
    # of more than about 1,069 inputs cannot start.
    sandbox-paths = /System/Library/Frameworks /System/Library/PrivateFrameworks /bin/sh /bin/bash /usr/lib /nix/store
    pre-build-hook = ${hook}
    # A remote build never runs the hook.
    builders =
    trusted-substituters =
    substituters = ${toString settings.substituters}
    trusted-public-keys = ${toString settings.trusted-public-keys}
    ssl-cert-file = /etc/nix/macos-keychain.crt
    max-jobs = auto
    cores = 0
  '';

  # /private/var/run empties at boot. The darwin sandbox lets every build
  # reach unix sockets under the daemon's TMPDIR, so that one is root's alone.
  start = pkgs.writeShellScript "alamode-nix-daemon" ''
    set -euo pipefail
    /usr/bin/install -d -o root -g wheel -m 0755 ${dir}
    /usr/bin/install -d -o root -g wheel -m 0700 ${dir}/tmp
    exec /nix/var/nix/profiles/default/bin/nix --extra-experimental-features nix-command \
      daemon --socket-path ${cfg.socket}
  '';
in
{
  options.systemFoundry.alamodeNixDaemon = {
    enable = lib.mkEnableOption "the nix daemon alamode sessions build through";
    socket = lib.mkOption {
      type = lib.types.str;
      default = "${dir}/socket";
      readOnly = true;
      description = "The daemon's socket, spelled with its real path for srt.";
    };
    label = lib.mkOption {
      type = lib.types.str;
      default = "org.ondy.alamode-nix-daemon";
      readOnly = true;
      description = "The launchd label, which alamode names when the daemon needs a hand.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.determinateNix.enable or false;
        message = "systemFoundry.alamodeNixDaemon runs Determinate's nix and copies its substituters.";
      }
    ];

    launchd.daemons.alamode-nix-daemon = {
      # `command`, so nix-darwin waits for /nix/store (monitoring-agent.nix).
      command = "${start}";
      serviceConfig = {
        Label = cfg.label;
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          NIX_CONF_DIR = "${conf}";
          # Empty, not unset: unset reads root's ~/.config/nix/nix.conf.
          NIX_USER_CONF_FILES = "";
          TMPDIR = "${dir}/tmp";
        };
        SoftResourceLimits.NumberOfFiles = 1048576;
        HardResourceLimits.NumberOfFiles = 1048576;
        StandardOutPath = "/var/log/alamode-nix-daemon.log";
        StandardErrorPath = "/var/log/alamode-nix-daemon.log";
      };
    };
  };
}
