# Hands one job to a headless pi run and streams its progress; see
# pi-delegate.sh for the interface.
{
  writeShellApplication,
  coreutils,
  git,
  jq,
  my-scripts,
  ripgrep,
  tmux,
}:

writeShellApplication {
  name = "pi-delegate";
  runtimeInputs = [
    coreutils
    git
    jq
    my-scripts
    # my-scripts' lib/common.sh finds the .bare root with rg.
    ripgrep
    tmux
  ];
  text = builtins.readFile ./pi-delegate.sh;
}
