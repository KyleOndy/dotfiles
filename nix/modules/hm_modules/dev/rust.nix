{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.hmFoundry.dev.rust;
in
{
  options.hmFoundry.dev.rust = {
    enable = mkEnableOption "rust";
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Rust toolchain
      rustc
      cargo
      rustfmt
      rust-analyzer
      clippy

      # Additional development tools
      cargo-watch
      cargo-edit
      cargo-audit
    ];

    # Set up Rust environment variables
    home.sessionVariables = {
      RUST_SRC_PATH = "${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
    };
  };
}
