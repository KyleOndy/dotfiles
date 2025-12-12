# https://github.com/jwiegley/nix-config/blob/master/overlays/20-my-scripts.nix
{
  lib,
  stdenv,
  pkgs,
  ffmpeg,
}:

stdenv.mkDerivation {
  pname = "my-scripts";
  version = "20250203";

  src = ./.;

  buildInputs = [
    ffmpeg
  ];

  installPhase = ''
    mkdir -p $out/bin
    find ./scripts \( -type f -o -type l \) -executable \
        -exec cp -pL {} $out/bin \;

    mkdir -p $out/lib
    if [ -d ./lib ]; then
      cp -r ./lib/* $out/lib/
    fi

    # Fix common.sh paths in scripts to use absolute path
    sed -i -e "s|source \"\''${SCRIPT_DIR}/../lib/common.sh\"|source \"$out/lib/common.sh\"|" $out/bin/* || true

    mkdir -p $out/share/zsh/site-functions
    find ./completions \( -type f -o -type l \) \
        -exec cp -pL {} $out/share/zsh/site-functions \;

    sed -i -e "s|source dots_common\.bash|source $out/share/zsh/site-functions/dots_common\.bash|" $out/share/zsh/site-functions/* || true
  '';

  meta = with lib; {
    description = "Kyle Ondy's various scripts";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
