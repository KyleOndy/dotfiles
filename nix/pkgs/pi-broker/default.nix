# Spawns a pi coordinator's agents outside the sandbox: worktree, forge
# instance, tmux window. The pi wrapper starts it for `pi --coordinator`; see
# pi-broker.sh for the protocol.
{
  writeShellApplication,
  coreutils,
  forge,
  git,
  jq,
  my-scripts,
  ripgrep,
  tmux,
  # Across every coordinator on the host, not per coordinator.
  maxAgents ? 8,
  # GiB of forge VM memory all agents may hold at once, counted from forge's
  # sizes (small 4, large 8).
  memoryBudgetGib ? 32,
}:

writeShellApplication {
  name = "pi-broker";
  runtimeInputs = [
    coreutils
    forge
    git
    jq
    my-scripts
    # my-scripts' lib/common.sh finds the .bare root with rg.
    ripgrep
    tmux
  ];
  # $names in single quotes are jq variables. pi-broker.sh carries the same
  # disable for the pre-commit hook, but the lines this prepends take it off
  # the top of the file, where it applies to all of it.
  excludeShellChecks = [ "SC2016" ];
  text =
    builtins.replaceStrings
      [
        "@maxAgents@"
        "@memoryBudgetGib@"
      ]
      [
        (toString maxAgents)
        (toString memoryBudgetGib)
      ]
      (builtins.readFile ./pi-broker.sh);
}
