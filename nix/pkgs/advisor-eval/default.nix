{
  writeShellApplication,
  coreutils,
  curl,
  jq,
}:

writeShellApplication {
  name = "advisor-eval";
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = ''
    ADVISOR_TS="''${ADVISOR_TS:-${../../modules/hm_modules/dev/pi/extensions/advisor.ts}}"
    CASES="''${CASES:-${./cases.json}}"
  ''
  + builtins.readFile ./advisor-eval.sh;
}
