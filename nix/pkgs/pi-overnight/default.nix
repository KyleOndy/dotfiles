{ writeShellApplication, curl }:

writeShellApplication {
  name = "pi-overnight";
  # `pi` itself is deliberately left to PATH: this drives whichever pi the
  # user profile has, and pinning one here would fight the agent's own updates.
  runtimeInputs = [ curl ];
  text = builtins.readFile ./pi-overnight.sh;
}
