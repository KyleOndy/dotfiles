{ writers }:

writers.writePython3Bin "pika-console" {
  # E203 and W503 are the ones ruff format's style breaks.
  flakeIgnore = [
    "E203"
    "E501"
    "W503"
  ];
} (builtins.readFile ./pika-console.py)
