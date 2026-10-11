# ~/.codex/config.toml is left to Codex: it writes trust decisions and /model
# choices there, which fails through a symlink into the store. Our defaults
# sit a layer below, in darwin_modules/codex.nix.

{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
let
  cfg = config.hmFoundry.dev.codex;
in
{
  options.hmFoundry.dev.codex.enable = lib.mkEnableOption "OpenAI's Codex CLI";

  config = lib.mkIf cfg.enable {
    programs.codex = {
      enable = true;
      # Not the overlay's pkgs.llm-agents.codex: that builds against our
      # nixpkgs, which cache.numtide.com never has, so it compiles from source.
      package = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codex;
      context =
        builtins.readFile ../agent-context/instructions.md
        + "\n"
        + builtins.readFile ../agent-context/style.md;
      skills = lib.listToAttrs (
        map (skill: lib.nameValuePair skill.name skill.source) (config.lib.agentContext.skillsFor "codex")
      );
    };
  };
}
