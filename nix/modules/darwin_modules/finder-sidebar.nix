# Folders pinned to the Favorites section of the Finder sidebar.
#
# /usr/bin/sfltool cannot do this. Its subcommands are csinfo, dumpbtm,
# archive, clear, resetbtm, resetlist, list and list-info; the add-item verb
# older recipes use is gone. mysides calls the LSSharedFileList API directly
# and still works on macOS 26.
{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.systemFoundry.finderSidebar;

  # mysides stores and prints directory URLs with a trailing slash. Match that
  # shape so a second run recognises its own entry instead of duplicating it.
  # nix-darwin bootstraps launchd.agents into the system domain, so this runs
  # as root, and a directory it creates under someone's home has to be handed
  # to them. The nearest existing ancestor is what knows who that is.
  addFolder = path: ''
    if [ ! -e ${escapeShellArg path} ]; then
      anc=${escapeShellArg path}
      while [ ! -e "$anc" ]; do anc="$(dirname "$anc")"; done
      install -d -o "$(stat -f %Su "$anc")" -g "$(stat -f %Sg "$anc")" ${escapeShellArg path}
    fi
    if ! printf '%s\n' "$current" | grep -qF "file://${path}/"; then
      "$mysides" add ${escapeShellArg (baseNameOf path)} "file://${path}/"
    fi
  '';

  script = pkgs.writeShellScript "finder-sidebar" ''
    set -euo pipefail
    readonly mysides="${pkgs.mysides}/bin/mysides"
    current="$("$mysides" list)"
    ${concatMapStringsSep "\n" addFolder cfg.folders}
  '';
in
{
  options.systemFoundry.finderSidebar.folders = mkOption {
    type = types.listOf types.str;
    default = [ ];
    example = [ "/Users/kyle/screenshots" ];
    description = ''
      Absolute paths pinned to the Finder sidebar, created if missing. Paths
      must not contain characters that need percent-encoding in a file URL.
      Entries already present are left alone, so folders dragged in by hand
      survive and nothing here is ever removed.
    '';
  };

  config = mkIf (cfg.folders != [ ]) {
    launchd.agents.finder-sidebar = {
      serviceConfig = {
        ProgramArguments = [ "${script}" ];
        RunAtLoad = true;
      };
    };
  };
}
