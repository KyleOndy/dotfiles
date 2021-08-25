# https://github.com/jwiegley/nix-config/blob/master/overlays/20-my-scripts.nix
self: super: {

  my-scripts = with self; stdenv.mkDerivation {
    name = "my-scripts";

    # todo: don't hardcode this
    src = ./../scripts;

    buildInputs = [ ];

    installPhase = ''
      mkdir -p $out/bin
      find . \( -type f -o -type l \) -executable \
          -exec cp -pL {} $out/bin \;
    '';

    meta = with pkgs.lib; {
      description = "Kyle Ondy's various scripts";
      homepage = https://github.com/kyleondy;
      license = licenses.mit;
      maintainers = with maintainers; [ kyleondy ];
      platforms = platforms.linux ++ platforms.darwin;
    };
  };

}
