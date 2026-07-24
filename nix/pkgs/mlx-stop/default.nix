{ writeShellApplication }:

writeShellApplication {
  name = "mlx-stop";
  text = builtins.readFile ./mlx-stop.sh;
}
