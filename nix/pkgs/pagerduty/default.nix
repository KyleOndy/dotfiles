{
  lib,
  writeShellApplication,
  curl,
  jq,
  # A command printing the PagerDuty API token from this host's secret store.
  # PAGERDUTY_TOKEN, or PAGERDUTY_TOKEN_COMMAND, overrides it for one run.
  tokenCommand ? "",
}:

writeShellApplication {
  name = "pagerduty";
  runtimeInputs = [
    curl
    jq
  ];
  text = ''
    [ -n "''${PAGERDUTY_TOKEN_COMMAND:-}" ] || PAGERDUTY_TOKEN_COMMAND=${lib.escapeShellArg tokenCommand}
  ''
  + builtins.readFile ./pagerduty.sh;
}
