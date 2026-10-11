# What the agent harnesses share. claude-code, pi-coding-agent and codex each
# install the skills in their own layout. instructions.md and style.md reach
# only claude-code and codex: pi's global AGENTS.md is its own (dev/pi).

{
  lib,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.agent-context;
in
{
  options.hmFoundry.dev.agent-context.skills = mkOption {
    type = types.listOf (
      types.submodule {
        options = {
          name = mkOption {
            type = types.str;
            description = "Skill name, which is also the directory it installs as";
          };
          source = mkOption {
            type = types.path;
            description = "Path to the skill directory or file";
          };
          isFile = mkOption {
            type = types.bool;
            default = false;
            description = "If true, source is a single .md file installed as <name>/SKILL.md";
          };
        };
      }
    );
    description = ''
      Skills for every agent harness. This module defines the shared ones;
      a host's definitions add to them, for skills only that host needs.
    '';
  };

  config = {
    hmFoundry.dev.agent-context.skills =
      map (fname: {
        name = removeSuffix ".md" fname;
        source = ./skills + "/${fname}";
        isFile = true;
      }) (attrNames (filterAttrs (n: t: t == "regular" && hasSuffix ".md" n) (builtins.readDir ./skills)))
      ++
        map
          (name: {
            inherit name;
            source = "${inputs.claude-skills-ponytail}/skills/${name}/SKILL.md";
            isFile = true;
          })
          [
            "ponytail"
            "ponytail-audit"
          ];

    # home.file entries for every skill under dir, in the <name>/SKILL.md
    # layout Claude Code and pi both read.
    lib.agentContext.skillFiles =
      dir:
      listToAttrs (
        map (
          skill:
          nameValuePair (if skill.isFile then "${dir}/${skill.name}/SKILL.md" else "${dir}/${skill.name}") {
            inherit (skill) source;
          }
        ) cfg.skills
      );
  };
}
