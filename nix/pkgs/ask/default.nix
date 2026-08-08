{
  writeShellApplication,
  runCommand,
  symlinkJoin,
}:

let
  ask = writeShellApplication {
    name = "ask";
    text = builtins.readFile ./ask.sh;
  };

  # writeShellApplication builds through writeTextFile, whose buildCommand ends
  # at `eval "$checkPhase"` and never runs postInstall, so the completion has to
  # be joined in from its own derivation rather than appended to that one.
  completion = runCommand "ask-completion" { } ''
    install -Dm444 ${./_ask} $out/share/zsh/site-functions/_ask
  '';
in
symlinkJoin {
  name = "ask";
  paths = [
    ask
    completion
  ];
  meta.mainProgram = "ask";
}
