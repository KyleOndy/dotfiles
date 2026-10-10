{
  writeShellApplication,
  coreutils,
  gnused,
  jq,
  llm-agents,
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
  ''
  + builtins.readFile ./advisor-eval.sh;
}
