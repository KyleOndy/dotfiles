{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.python;
  python-packages =
    python-packages:
    with python-packages;
    [
      virtualenv
    ]
    ++ optionals (!stdenv.isDarwin) [
      # TOOD: packages below _should_ work on darwin, I just need to fix them and
      #       contribute upstream.
      debugpy # dap implementation
    ];
  system-python-with-packages = pkgs.python3.withPackages python-packages;
in
{
  options.hmFoundry.dev.python = {
    enable = mkEnableOption "python";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      pyright
      poetry
      ruff
      uv
      system-python-with-packages
    ];
  };
}
