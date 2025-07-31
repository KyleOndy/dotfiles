# https://github.com/jwiegley/nix-config/blob/master/overlays/20-my-scripts.nix
{
  lib,
  stdenv,
  fetchurl,
  pkgs,
}:

stdenv.mkDerivation {
  pname = "my-scripts";
  version = "20220226";

  # todo: don't hardcode this
  src = ./.;

  buildInputs = [ ];

  installPhase = ''
    mkdir -p $out/bin
    find ./scripts \( -type f -o -type l \) -executable \
        -exec cp -pL {} $out/bin \;

    mkdir -p $out/share/zsh/site-functions
    find ./completions \( -type f -o -type l \) \
        -exec cp -pL {} $out/share/zsh/site-functions \;

    sed -i -e "s|source dots_common\.bash|source $out/share/zsh/site-functions/dots_common\.bash|" $out/share/zsh/site-functions/*
  '';

  meta = with pkgs.lib; {
    description = "Kyle Ondy's various scripts";
    homepage = "https://github.com/kyleondy";
    license = licenses.mit;
    maintainers = with maintainers; [ kyleondy ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
