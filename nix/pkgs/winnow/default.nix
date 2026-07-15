{
  lib,
  python3,
  qt6,
}:

python3.pkgs.buildPythonApplication rec {
  pname = "winnow";
  version = "20260715";
  pyproject = true;

  src = ./.;

  build-system = [ python3.pkgs.hatchling ];

  dependencies = [
    python3.pkgs.pyside6
    python3.pkgs.pillow
  ];

  # PySide6 needs its Qt platform plugins (xcb, etc) on QT_PLUGIN_PATH at
  # runtime; wrapQtAppsHook wraps $out/bin/winnow with that automatically.
  # It needs qtbase in buildInputs to find the plugin prefix to wrap with.
  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase ];

  # pytest-qt needs a Qt/X11 environment; tests run manually via
  # `nix develop` + `pytest`, not as part of the package build.
  doCheck = false;

  meta = {
    description = "Fast Linux photo viewer for culling JPEG photos";
    mainProgram = "winnow";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
