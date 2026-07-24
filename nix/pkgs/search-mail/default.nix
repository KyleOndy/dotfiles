{ writeShellApplication }:

writeShellApplication {
  name = "search-mail";
  text = builtins.readFile ./search-mail.sh;
}
