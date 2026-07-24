{ writeShellApplication }:

writeShellApplication {
  name = "mlx-start";
  text = builtins.readFile ./mlx-start.sh;
}
