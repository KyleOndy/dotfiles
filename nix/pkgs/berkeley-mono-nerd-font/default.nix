# Berkeley Mono patched with Nerd Fonts glyphs (file icons, git status, etc.)
# for terminal use. https://github.com/ryanoasis/nerd-fonts
{
  lib,
  stdenvNoCC,
  berkeley-mono,
  nerd-font-patcher,
}:

stdenvNoCC.mkDerivation {
  pname = "berkeley-mono-nerd-font";
  version = berkeley-mono.version;

  dontUnpack = true;
  nativeBuildInputs = [ nerd-font-patcher ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    mkdir -p src patched

    # nerd-font-patcher writes back to the font it reads, so it needs a
    # writable copy; the store path is read-only.
    cp ${berkeley-mono}/share/fonts/opentype/berkeley-mono/*.otf src/
    chmod u+w src/*.otf

    # Berkeley Mono's oblique faces carry their style only in the
    # preferred-family/subfamily name records (nameID 16/17), which
    # nerd-font-patcher doesn't read; it falls back to "Regular" for
    # every face and every style ends up overwriting the same output
    # file. Forcing --name per face keeps Regular/Bold/Oblique/Bold
    # Oblique as distinct, selectable styles. The patcher itself splits
    # the oblique faces into a second family (suffixed "Obl") to work
    # around the legacy 4-style-per-family limit.
    patch_style () {
      nerd-font-patcher --complete --mono --quiet --name "$2" -out patched "src/$1"
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
    cp patched/*.otf $out/share/fonts/opentype/berkeley-mono-nerd-font
    runHook postInstall
  '';

  meta = with lib; {
    description = "Berkeley Mono patched with Nerd Fonts glyphs for terminal icons";
    homepage = "https://github.com/ryanoasis/nerd-fonts";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
