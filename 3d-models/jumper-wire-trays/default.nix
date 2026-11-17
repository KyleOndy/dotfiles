{
  writeShellApplication,
  gawk,
  git,
  gnused,
  openscad,
  unzip,
}:

writeShellApplication {
  name = "jumper-trays";
  runtimeInputs = [
    gawk
    git
    gnused
    openscad
    unzip
  ];
  text = builtins.readFile ./render.sh;
}
