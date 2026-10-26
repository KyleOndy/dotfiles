{
  writeShellApplication,
  gawk,
  git,
  gnused,
  openscad,
  unzip,
}:

writeShellApplication {
  name = "pad-case";
  runtimeInputs = [
    gawk
    git
    gnused
    openscad
    unzip
  ];
  text = builtins.readFile ./render.sh;
}
