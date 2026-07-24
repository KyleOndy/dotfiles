{ writeShellApplication }:

writeShellApplication {
  name = "mlx-status";
  text = builtins.readFile ./mlx-status.sh;
}
