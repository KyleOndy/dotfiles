{
  callPackage,
  stdenv,
  writeShellApplication,
  runCommand,
  symlinkJoin,
  docker_29,
  kind,
  kubectl,
  kubernetes-helm,
  yq-go,
  coreutils,
  gnugrep,
  # nixpkgs 25.11 ships lima 1.2.2, and vm.nix asks for 2.0.0 as its
  # minimumLimaVersion, so nix/pkgs/default.nix passes master.lima. Every
  # port-forwarding rule in vm.nix was measured against 2.2.0.
  lima,
  # One source of truth for the API port window: substituted into forge.sh and
  # baked into the VM's portForwards, so the range forge assigns from is the
  # range the VM actually forwards. See vm.nix.
  apiPortBase ? 6440,
  apiPortSpan ? 16,
  # The guest disk image, injected by the overlay in flake.nix because
  # nix/pkgs/default.nix cannot reach the flake's nixos-lima and
  # nixos-generators inputs. Defaulted to a throw rather than left required so
  # that plain `callPackage ./forge { }` still yields the script; only vmConfig,
  # which is where the image is named, forces this.
  guestImage ? throw "forge: guestImage is injected by the overlay in flake.nix",
}:

let
  vmConfig = callPackage ./vm.nix {
    inherit apiPortBase apiPortSpan guestImage;
    guestArch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
  };

  body =
    builtins.replaceStrings
      [
        "@apiPortBase@"
        "@apiPortSpan@"
        "@vmConfig@"
      ]
      [
        (toString apiPortBase)
        (toString apiPortSpan)
        "${vmConfig}"
      ]
      (builtins.readFile ./forge.sh);
  script = writeShellApplication {
    name = "forge";
    # docker_29 rather than the default `docker`, which nixpkgs marks insecure
    # and which would put a second daemon version in the closure alongside the
    # one hmFoundry.dev.docker already installs.
    runtimeInputs = [
      lima
      docker_29
      kind
      kubectl
      kubernetes-helm
      yq-go
      coreutils
      gnugrep
    ];
    text = body;
  };

  # writeShellApplication builds through writeTextFile, whose buildCommand ends
  # at `eval "$checkPhase"` and never runs postInstall, so the completion has to
  # be joined in from its own derivation rather than appended to that one.
  completion = runCommand "forge-completion" { } ''
    install -Dm444 ${./_forge} $out/share/zsh/site-functions/_forge
  '';
in
symlinkJoin {
  name = "forge";
  paths = [
    script
    completion
  ];
  passthru = { inherit vmConfig; };
  meta.mainProgram = "forge";
}
