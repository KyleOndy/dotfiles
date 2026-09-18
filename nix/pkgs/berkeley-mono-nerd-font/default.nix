# Berkeley Mono patched with Nerd Fonts glyphs (file icons, git status, etc.)
# for terminal use. https://github.com/ryanoasis/nerd-fonts
{
  lib,
  stdenvNoCC,
  berkeley-mono,
  nerd-font-patcher,
  python3,
  writeText,
}:

let
  vendor = "${berkeley-mono}/share/fonts/opentype/berkeley-mono";
  # nerd-font-patcher brings its own python, without fonttools.
  python = python3.withPackages (ps: [ ps.fonttools ]);

  # fontforge translates every glyph right by its own lsb when it reads a CFF
  # font, which leaves the ink overhanging its cell and the text raggedly
  # spaced. Fixed upstream, unreleased as of fontforge 20251009:
  # https://github.com/fontforge/fontforge/commit/9d119ca0bf415e3d69086f4931fcbb39d3d85c51
  # The records are redundant for CFF outlines, which carry their own bearings,
  # and the patcher writes fresh ones back out from those outlines, so blanking
  # them loses nothing and turns into a no-op once fontforge carries the fix.
  blankLsb = writeText "blank-hmtx-lsb.py" ''
    import sys
    from fontTools.ttLib import TTFont

    font = TTFont(sys.argv[1])
    font["hmtx"].metrics = {g: (w, 0) for g, (w, _) in font["hmtx"].metrics.items()}
    font.save(sys.argv[2])
  '';

  # r, colon and period hold the widest left bearings, so they are the first
  # glyphs to move if fontforge starts shifting outlines again. The tolerance
  # is in font units, 1/1000 em: fontforge recomputes these records from the
  # outlines and lands a unit off on the slanted faces, while the shift this
  # guards against is 57 units or more.
  assertMetricsKept = writeText "assert-metrics-kept.py" ''
    import sys
    from fontTools.ttLib import TTFont

    vendor, patched = (TTFont(p)["hmtx"].metrics for p in sys.argv[1:3])
    moved = [
        (g, vendor[g], patched[g])
        for g in ("o", "r", "colon", "period")
        if vendor[g][0] != patched[g][0] or abs(vendor[g][1] - patched[g][1]) > 2
    ]
    if moved:
        sys.exit("{}: glyph metrics moved during patching: {} [{}]".format(sys.argv[2], moved, sys.argv[3]))
  '';
in
stdenvNoCC.mkDerivation {
  pname = "berkeley-mono-nerd-font";
  version = berkeley-mono.version;

  dontUnpack = true;
  nativeBuildInputs = [ nerd-font-patcher ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    mkdir -p src patched
    patcher=$(nerd-font-patcher --version | head -1)

    # nerd-font-patcher writes back to the font it reads, so it needs a
    # writable copy; the store path is read-only.
    for f in ${vendor}/*.otf; do
      ${python}/bin/python3 ${blankLsb} "$f" "src/$(basename "$f")"
    done

    # Berkeley Mono's oblique faces carry their style only in the
    # preferred-family/subfamily name records (nameID 16/17), which
    # nerd-font-patcher doesn't read; it falls back to "Regular" for
    # every face and every style ends up overwriting the same output
    # file. Forcing --name per face keeps Regular/Bold/Oblique/Bold
    # Oblique as distinct, selectable styles. The legacy name records
    # (nameID 1/2) file the obliques under a second family suffixed
    # "Obl"; the preferred records (nameID 16/17), which CoreText uses,
    # keep all four faces in one family.
    patch_style () {
      local dir="patched/''${1%.otf}"
      nerd-font-patcher --complete --mono --quiet --name "$2" -out "$dir" "src/$1"
      ${python}/bin/python3 ${assertMetricsKept} "${vendor}/$1" "$dir"/*.otf "$patcher"
    }
    patch_style BerkeleyMono-Regular.otf "Berkeley Mono Nerd Font Mono"
    patch_style BerkeleyMono-Bold.otf "Berkeley Mono Bold Nerd Font Mono"
    patch_style BerkeleyMono-Oblique.otf "Berkeley Mono Oblique Nerd Font Mono"
    patch_style BerkeleyMono-Bold-Oblique.otf "Berkeley Mono Bold Oblique Nerd Font Mono"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/fonts/opentype/berkeley-mono-nerd-font
    cp patched/*/*.otf $out/share/fonts/opentype/berkeley-mono-nerd-font
    runHook postInstall
  '';

  meta = with lib; {
    description = "Berkeley Mono patched with Nerd Fonts glyphs for terminal icons";
    homepage = "https://github.com/ryanoasis/nerd-fonts";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
