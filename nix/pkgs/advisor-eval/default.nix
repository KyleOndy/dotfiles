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
  # pi's real binary, not the sandbox wrapper also named pi.
  runtimeInputs = [
    llm-agents.pi
    coreutils
    gnused
    jq
  ];
  text = ''
    CASES="''${CASES:-${./cases.json}}"
    ADVISOR_TS="''${ADVISOR_TS:-${../../modules/hm_modules/dev/pi/extensions/advisor.ts}}"
    [ -n "''${MCLOUD_API_KEY_COMMAND:-}" ] || MCLOUD_API_KEY_COMMAND=${lib.escapeShellArg keyCommand}
  ''
  + builtins.readFile ./advisor-eval.sh;
}
