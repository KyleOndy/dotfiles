# Personal home-manager configuration for trex.
# The desktop profile is imported via mkDarwinSystem; this file provides
# macOS-specific overrides, mirroring nix/hosts/work-mac/home.nix.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [ ];

  # Disable Linux-only features on macOS
  hmFoundry.desktop = {
    apps.discord.enable = lib.mkForce false;
    apps.slack.enable = lib.mkForce false;
    browsers.firefox.enable = lib.mkForce true;
    gaming.steam.enable = lib.mkForce false;
    term.foot.enable = lib.mkForce false;
    term.alacritty.enable = true;
    term.wezterm.enable = lib.mkForce false;
    wm.i3.enable = lib.mkForce false;
    media = {
      makemkv.enable = lib.mkForce false;
      documents.enable = lib.mkForce false;
    };
  };

  # Kensington trackball remapping - same physical hardware/need as dino's
  # hmFoundry.desktop.input.trackball, just the darwin-side mechanism.
  #
  # pcStyle (Ctrl->Cmd for copy/paste/etc) is disabled: going mac-native for
  # OS-wide shortcuts instead, which also keeps physical Ctrl free for
  # winnow's Ctrl+h/j/k/l/0/r bindings (see AA_MacDontSwapCtrlAndMeta in
  # winnow's app.py) without needing a per-app Karabiner exclusion.
  hmFoundry.desktop.input.karabiner = {
    enable = true;
    kensingtonExpert.enable = true;
    pcStyle.enable = false;
  };

  # App quick-switching
  hmFoundry.desktop.input.hammerspoon.enable = true;

  # Add Homebrew to PATH for all managed shells (including Claude Code).
  # Also add uv's tool install dir (~/.local/bin, e.g. mlx-lm's mlx_lm.*
  # executables) since `uv tool update-shell` can't write the home-manager
  # managed .zshenv symlink.
  home.sessionPath = [
    "/opt/homebrew/bin"
    "$HOME/.local/bin"
  ];

  hmFoundry.dev = {
    claude-code.enable = true;
    kubernetes.enable = true; # kubectl, kubectx, k9s, helm, kustomize, kind
    nixTools.enable = true; # nixfmt, nixpkgs-review, nix-index
    sysadmin.enable = true; # htop, lsof, nmap, mosh, dnsutils

    # Colima background service. Defaults (4 CPU / 8GB / 100GB) are
    # conservative starting points - tune once trex's actual RAM is known.
    docker.service.enable = true;

    # Local model for the pi coding agent, mirroring `ask`'s mlx backend
    # (see nix/pkgs/ask/ask.sh) but served OpenAI-compatible so pi can talk
    # to it as a regular provider. mlx-openai-server (not bare mlx_lm.server)
    # because pi lives on tool calls and mlx_lm.server's OpenAI tool-calling
    # is immature; mlx-openai-server ships first-class tool-call parsers.
    #
    # Model is Qwen3-14B (dense), not the earlier Qwen3-Coder-30B-A3B: that
    # MoE's 3B active params frequently dropped the leading <tool_call> tag
    # over long agentic loops (see github.com/QwenLM/Qwen3-Coder/issues/475).
    # A dense model gives consistent tool-call formatting, and at 32GB
    # unified memory on trex, KV cache -- not weights -- is the binding
    # constraint for running several concurrent clients (main agent +
    # advisor + task subagents all share this one resident model via
    # mlx-openai-server's continuous batching): ~8GB of weights leaves
    # ~14GB for KV, vs. ~4GB left over for a 32B-class model.
    #
    # Model selection is per-invocation (`pi --model local/qwen3-14b`) --
    # not pinned via sandbox.defaultArgs, so cloud models stay the default.
    pi-coding-agent = {
      sandbox.allowLocalBinding = true; # only lever to reach 127.0.0.1 egress from the sandbox; see nix/pkgs/pi-wrapper/wrapper.sh

      modelsJson.providers.local = {
        baseUrl = "http://127.0.0.1:8000/v1";
        api = "openai-completions";
        apiKey = "local-no-key"; # mlx-openai-server does not check this
        compat.supportsDeveloperRole = false;
        models = [
          {
            id = "qwen3-14b";
            name = "Qwen3 14B (local, mlx)";
            reasoning = true;
            input = [ "text" ];
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            contextWindow = 24576; # matches --context-length below
            maxTokens = 8192;
          }
        ];
      };
    };
  };

  # mlx-openai-server, uv-installed like mlx-lm (see ask's sessionPath note
  # above) -- Metal wheels don't package cleanly through nixpkgs on darwin.
  # Install once with: uv tool install mlx-openai-server
  #
  # RunAtLoad/KeepAlive both false: on-demand rather than always-resident, to
  # avoid holding the model's RAM footprint when not in use. Start with:
  #   launchctl kickstart -k gui/$(id -u)/org.ondy.mlx-openai-server
  # (nix/pkgs/pi-overnight does this automatically before an overnight run.)
  # Flip both to true for an always-on server.
  #
  # --context-length and --decode/--prompt-concurrency are capped well below
  # this server's defaults (unbounded / 32 / 8): on 32GB unified memory, KV
  # cache -- not model weights -- is what runs out first when several
  # clients (main agent, advisor, task subagents) share this one process
  # concurrently via continuous batching. Raise them if trex ever gets more
  # RAM or a smaller model is in use.
  launchd.agents.mlx-openai-server = {
    enable = true;
    config = {
      Label = "org.ondy.mlx-openai-server";
      ProgramArguments = [
        "${config.home.homeDirectory}/.local/bin/mlx-openai-server"
        "launch"
        "--model-path"
        "mlx-community/Qwen3-14B-4bit"
        "--served-model-name"
        "qwen3-14b"
        "--host"
        "127.0.0.1"
        "--port"
        "8000"
        "--tool-call-parser"
        "qwen3"
        "--enable-auto-tool-choice"
        "--context-length"
        "24576"
        "--decode-concurrency"
        "6"
        "--prompt-concurrency"
        "3"
      ];
      RunAtLoad = false;
      KeepAlive = false;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mlx-openai-server.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mlx-openai-server.log";
      ProcessType = "Background";
      EnvironmentVariables = {
        PATH = "${config.home.homeDirectory}/.local/bin:/opt/homebrew/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
    };
  };
}
