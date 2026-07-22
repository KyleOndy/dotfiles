{ writeShellApplication }:

writeShellApplication {
  name = "pi-overnight";
  text = builtins.readFile ./pi-overnight.sh;
}
