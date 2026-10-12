{
  lib,
  writeShellApplication,
  coreutils,
  gnused,
  jq,
  llm-agents,
  # A command printing the mcloud key from this host's secret store.
  # MCLOUD_API_KEY, or MCLOUD_API_KEY_COMMAND, overrides it for one run.
  keyCommand ? "",
}:

writeShellApplication {
  name = "advisor-eval";
  # pi's real binary. alamode wraps it in the sandbox; this grader does not.
  runtimeInputs = [
    llm-agents.pi
    coreutils
    gnused
    jq
  ];
  text = ''
    CASES="''${CASES:-${./cases.json}}"
    ADVISOR_TS="''${ADVISOR_TS:-${../../modules/hm_modules/dev/alamode/source/extensions/advisor.ts}}"
    [ -n "''${MCLOUD_API_KEY_COMMAND:-}" ] || MCLOUD_API_KEY_COMMAND=${lib.escapeShellArg keyCommand}
  ''
  + builtins.readFile ./advisor-eval.sh;
}
