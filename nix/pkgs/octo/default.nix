# todo: contribute this back upstream to nixpkgs
# todo: support linux + osx
{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation rec {
  pname = "octo";
  version = "7.4.3264";

  # Work around the "unpacker appears to have produced no directories"
  # case that happens when the archive doesn't have a subdirectory.
  setSourceRoot = "sourceRoot=$(pwd)";

  # could not use fetchTarball, I get the following. The setSourceRoot above
  # did not seem to have an effect.
  #
  # error: tarball 'https://download.octopusdeploy.com/octopus-tools/7.4.3264/OctopusTools.7.4.3264.osx-x64.tar.gz' contains an unexpected number of top-level files
  src = fetchurl {
    url = "https://download.octopusdeploy.com/octopus-tools/${version}/OctopusTools.${version}.osx-x64.tar.gz";
    sha256 = "ikPJeVmJD8KnMwVf0TJG9VB6rag9KPRpd5XOcB9tL64=";
  };

  # This overrides the shell code that is run during the installPhase.
  # By default; this runs `make install`.
  # The install phase will fail if there is no makefile; so it is the
  # best choice to replace with our custom code.
  installPhase = ''
    mkdir -p $out/bin
    cp octo $out/bin/
  '';

  meta = with lib; {
    description = "Octopus CLI Tool";
    homepage = "https://github.com/OctopusDeploy/OctopusCLI";
    platforms = platforms.darwin;
    license = licenses.asl20;
  };
}
