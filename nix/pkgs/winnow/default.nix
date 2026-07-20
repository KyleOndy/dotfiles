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
    python3.pkgs.send2trash
  ];

  # PySide6 needs its Qt platform plugin (xcb on Linux, cocoa on darwin) on
  # QT_PLUGIN_PATH at runtime; wrapQtAppsHook wraps $out/bin/winnow with that
  # automatically on both platforms. It needs qtbase in buildInputs to find
  # the plugin prefix to wrap with.
  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase ];

  # pytest-qt needs a Qt/X11 (or Qt/cocoa) environment; tests run manually
  # via `nix develop` + `pytest`, not as part of the package build.
  doCheck = false;

  meta = {
    description = "Fast photo viewer for culling JPEG photos";
    mainProgram = "winnow";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
