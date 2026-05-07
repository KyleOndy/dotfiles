# pi.dev coding agent with optional OS-level sandboxing.
#
# Sandbox wrapper flags (prepend before pi args):
#   --allow HOST           add domain to network allowlist (repeatable)
#   --allow-write PATH     add extra FS write path (repeatable)
#   --web                  FS isolation only, no network restriction
#   --no-sandbox           bypass sandbox entirely (with warning)
#
# Strict mode uses pkgs.llm-agents.sandbox-runtime (srt) on both platforms:
# bwrap on Linux, sandbox-exec on macOS; proxy-based network allowlist.
#
# Web mode (no domain restriction) bypasses srt — srt forbids wildcard domains.
# Linux: bwrap directly (FS isolation, no --unshare-net).
# macOS: sandbox-exec FS profile (network unrestricted).
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.hmFoundry.dev.pi-coding-agent;

  realPiBin = lib.getExe pkgs.llm-agents.pi;

  toBashArray = xs: if xs == [ ] then "" else lib.concatStringsSep " " (map (x: "\"${x}\"") xs);

  wrapper = pkgs.writeShellApplication {
    name = "pi";
    runtimeInputs = [
      pkgs.llm-agents.sandbox-runtime
      pkgs.jq
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.bubblewrap ];
    # SC2064: trap with double quotes is intentional — we want $var expanded at
    # trap setup time, not at signal time (value doesn't change after that point).
    excludeShellChecks = [ "SC2064" ];
    text =
      let
        defaultDomains = toBashArray cfg.sandbox.allowedDomains;
        defaultWritePaths = toBashArray cfg.sandbox.allowedWritePaths;
      in
      ''
        default_domains=(${defaultDomains})
        default_write_paths=(${defaultWritePaths})
        real_pi="${realPiBin}"

        extra_domains=()
        extra_write_paths=()
        web_mode=false
        no_sandbox=false

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --allow)         extra_domains+=("$2"); shift 2 ;;
            --allow=*)       extra_domains+=("''${1#--allow=}"); shift ;;
            --allow-write)   extra_write_paths+=("$2"); shift 2 ;;
            --allow-write=*) extra_write_paths+=("''${1#--allow-write=}"); shift ;;
            --web)           web_mode=true; shift ;;
            --no-sandbox)    no_sandbox=true; shift ;;
            --)              shift; break ;;
            *)               break ;;
          esac
        done

        if "$no_sandbox"; then
          echo "pi: WARNING: running without sandbox" >&2
          exec "$real_pi" "$@"
        fi

        resolved_extra_writes=()
        for p in "''${default_write_paths[@]}" "''${extra_write_paths[@]}"; do
          resolved_extra_writes+=("''${p/#\~/$HOME}")
        done

        if "$web_mode"; then
          # FS isolation only; network unrestricted.
          # srt forbids wildcard domains so we call the OS primitives directly.
          if [[ "$(uname)" == "Linux" ]]; then
            nixos_binds=()
            [[ -e /run/current-system ]] && nixos_binds+=(--ro-bind /run/current-system /run/current-system)
            [[ -e /run/wrappers ]] && nixos_binds+=(--ro-bind /run/wrappers /run/wrappers)
            [[ -d /run/systemd/resolve ]] && nixos_binds+=(--ro-bind /run/systemd/resolve /run/systemd/resolve)

            home_masks=()
            for sub in .ssh .gnupg ".config/sops" .aws .azure .gcloud .kube .docker .netrc .git-credentials; do
              [[ -e "$HOME/$sub" ]] && home_masks+=(--tmpfs "$HOME/$sub")
            done

            bwrap_args=(
              --ro-bind /nix /nix
              --ro-bind /etc /etc
              --proc /proc
              --dev /dev
              --tmpfs /tmp
              --tmpfs /run/user
              "''${nixos_binds[@]}"
              "''${home_masks[@]}"
              --bind "$PWD" "$PWD"
              --chdir "$PWD"
            )
            for p in "$HOME/.pi" "''${resolved_extra_writes[@]}"; do
              bwrap_args+=(--bind "$p" "$p")
            done
            bwrap_args+=(
              --unshare-user
              --uid "$(id -u)"
              --gid "$(id -g)"
              --unshare-pid
              --unshare-ipc
              --unshare-uts
              --die-with-parent
              --
              "$real_pi"
              "$@"
            )
            exec bwrap "''${bwrap_args[@]}"
          else
            # macOS: sandbox-exec FS profile, network unrestricted
            profile_file=$(mktemp /tmp/pi-sandbox-XXXXXX.sb)
            trap "rm -f '$profile_file'" EXIT
            {
              echo '(version 1)'
              echo '(deny default)'
              echo '(allow process-fork process-exec process-signal process-info*)'
              echo '(allow mach* ipc* sysctl* system*)'
              echo '(allow network*)'
              echo '(allow file-read*)'
              for sub in .ssh .gnupg ".config/sops" .aws .azure .gcloud .kube .docker .netrc .git-credentials; do
                [[ -e "$HOME/$sub" ]] && echo "(deny file-read* (subpath \"$HOME/$sub\"))"
              done
              echo "(allow file-write* (subpath \"$PWD\"))"
              echo "(allow file-write* (subpath \"$HOME/.pi\"))"
              for p in "''${resolved_extra_writes[@]}"; do
                echo "(allow file-write* (subpath \"$p\"))"
              done
            } > "$profile_file"
            exec sandbox-exec -f "$profile_file" "$real_pi" "$@"
          fi
        fi

        # Strict mode: srt with proxy-based network allowlist.
        # Empty allowedDomains = no network access (all outbound blocked by proxy).
        settings_file=$(mktemp /tmp/pi-srt-XXXXXX.json)
        trap "rm -f '$settings_file'" EXIT

        all_domains=("''${default_domains[@]}" "''${extra_domains[@]}")
        if [[ ''${#all_domains[@]} -gt 0 ]]; then
          allowed_json=$(printf '%s\n' "''${all_domains[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')
        else
          allowed_json='[]'
        fi

        write_paths=("$PWD" "$HOME/.pi" "''${resolved_extra_writes[@]}")
        write_json=$(printf '%s\n' "''${write_paths[@]}" | jq -Rs '[split("\n")[] | select(. != "")]')

        deny_read_json=$(
          for sub in .ssh .gnupg ".config/sops" .aws .azure .gcloud .kube .docker .netrc .git-credentials; do
            echo "$HOME/$sub"
          done | jq -Rs '[split("\n")[] | select(. != "")]'
        )

        jq -n \
          --argjson allowed "$allowed_json" \
          --argjson write "$write_json" \
          --argjson denyRead "$deny_read_json" \
          '{
            "network": {"allowedDomains": $allowed, "deniedDomains": []},
            "filesystem": {"allowWrite": $write, "denyRead": $denyRead, "denyWrite": []}
          }' > "$settings_file"

        exec srt --settings "$settings_file" -- "$real_pi" "$@"
      '';
  };

  piPackage = if cfg.sandbox.enable then wrapper else pkgs.llm-agents.pi;

in
{
  options.hmFoundry.dev.pi-coding-agent = {
    enable = lib.mkEnableOption "pi coding agent";

    sandbox = {
      enable = lib.mkEnableOption "sandbox pi via OS-level primitives" // {
        default = true;
      };

      allowedDomains = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [
          "openrouter.ai"
          "api.anthropic.com"
          "github.com"
        ];
        description = ''
          Base network allowlist. Empty by default — each host configures exactly
          the provider endpoints pi needs. Runtime --allow extends this.
          srt passes these through its filtering proxy; programs not respecting
          HTTP_PROXY/HTTPS_PROXY can bypass the filter.
        '';
      };

      allowedWritePaths = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          Extra filesystem write paths beyond CWD and ~/.pi.
          Supports ~ expansion. Runtime --allow-write extends this.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ piPackage ];

    home.sessionVariables = {
      PI_TELEMETRY = "0";
      PI_SKIP_VERSION_CHECK = "1";
    };
  };
}
