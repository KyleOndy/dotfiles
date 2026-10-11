# Codex reads /etc/codex/config.toml beneath ~/.codex/config.toml, which
# stays writable for Codex (hm_modules/dev/codex/default.nix says why).

{
  config,
  lib,
  pkgs,
  ...
}:
{
  config =
    lib.mkIf
      (lib.any (user: user.hmFoundry.dev.codex.enable) (lib.attrValues config.home-manager.users))
      {
        environment.etc."codex/config.toml".source = (pkgs.formats.toml { }).generate "codex-config.toml" {
          # Per directory, only where no AGENTS.md exists.
          project_doc_fallback_filenames = [ "CLAUDE.md" ];
          # Instead of a plaintext ~/.codex/auth.json.
          cli_auth_credentials_store = "keyring";
        };
      };
}
