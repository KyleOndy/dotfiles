{
  writeShellApplication,
  coreutils,
  gawk,
  git,
  gitleaks,
  gnused,
  yq-go,
}:

writeShellApplication {
  name = "secrets-check";
  runtimeInputs = [
    coreutils
    gawk
    git
    gitleaks
    gnused
    yq-go
  ];
  text = builtins.readFile ./secrets-check.sh;
}
