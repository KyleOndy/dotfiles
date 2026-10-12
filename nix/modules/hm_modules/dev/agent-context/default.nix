# What the agent harnesses share. claude-code, alamode and codex each
# install the skills in their own layout. instructions.md and style.md reach
# only claude-code and codex: alamode's global AGENTS.md is its own
# (dev/alamode/source).

{
  lib,
  config,
  inputs,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.agent-context;
  harnesses = [
    "claude-code"
    "alamode"
    "codex"
  ];
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
          harnesses = mkOption {
            type = types.listOf (types.enum harnesses);
            default = harnesses;
            description = "The harnesses that install this skill, for one written around a single harness's tools";
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

    lib.agentContext = rec {
      skillsFor = harness: filter (skill: elem harness skill.harnesses) cfg.skills;

      # home.file entries for harness's skills under dir, in the
      # <name>/SKILL.md layout Claude Code and pi both read.
      skillFiles =
        harness: dir:
        listToAttrs (
          map (
            skill:
            nameValuePair (if skill.isFile then "${dir}/${skill.name}/SKILL.md" else "${dir}/${skill.name}") {
              inherit (skill) source;
            }
          ) (skillsFor harness)
        );
    };
  };
}
