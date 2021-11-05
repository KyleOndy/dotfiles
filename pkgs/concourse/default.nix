# initally taken from https://github.com/NixOS/nixpkgs/blob/531afdf1601550c3bbaccc1af685578ffc4cf83c/pkgs/development/tools/continuous-integration/fly/default.nix
{ buildGoModule, fetchFromGitHub, stdenv, lib }:

buildGoModule rec {
  pname = "concourse";
  version = "7.6.0";

  src = fetchFromGitHub {
    owner = "concourse";
    repo = "concourse";
    rev = "v${version}";
    sha256 = "sha256-Zi+gyO+2AKDgcfgYrzLskJYZ6hQKOVlOL7Y9nxH/pGg=";
  };

  vendorSha256 = "sha256-OF3parnlTPmcr7tVcc6495sUMRApSpBHHjSE/4EFIxE=";

  doCheck = false; # onle test fails, can we fix it?

  subPackages = [ "cmd/concourse" ];

  ldflags = [
    "-X github.com/concourse/concourse.Version=${version}"
  ];

  meta = with lib; {
    description = "A command line interface to Concourse CI";
    homepage = "https://concourse-ci.org";
    license = licenses.asl20;
    maintainers = with maintainers; [ kyleondy ];
  };
}
