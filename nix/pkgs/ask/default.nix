{ writeShellApplication }:

writeShellApplication {
  name = "ask";
  text = builtins.readFile ./ask.sh;
}
