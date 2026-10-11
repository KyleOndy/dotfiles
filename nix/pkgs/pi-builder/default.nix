{
  lib,
  runCommand,
  python3,
  git,
  makeWrapper,
  writeShellApplication,
  coreutils,
  tart,
  softnet,
  fetchurl,
}:
let
  reviewedTart = tart.overrideAttrs (_: {
    version = "2.40.1";
    src = fetchurl {
      url = "https://github.com/cirruslabs/tart/releases/download/2.40.1/tart.tar.gz";
      hash = "sha256-Nj4nARVKgVXLwbtthFQwybQml9KhhrxJV0Rxyih320Y=";
    };
  });
  reviewedSoftnet = softnet.overrideAttrs (old: {
    version = "0.24.1";
    src = fetchurl {
      url = "https://github.com/cirruslabs/softnet/releases/download/0.24.1/softnet.tar.gz";
      hash = "sha256-j/j/CZwrWsGxEo55mcSnMKyF9IbIpMsCOeuYQyhZoPc=";
    };
    meta = old.meta // {
      license = lib.licenses.fsl11Asl20;
    };
  });
  softnetInstaller = writeShellApplication {
    name = "pi-install-softnet";
    runtimeInputs = [ coreutils ];
    text = builtins.readFile ./install-softnet.sh;
  };
in
runCommand "pi-builder"
  {
    nativeBuildInputs = [
      python3
      git
      makeWrapper
    ];
    passthru = {
      inherit softnetInstaller;
      tart = reviewedTart;
      softnet = reviewedSoftnet;
    };
    meta.mainProgram = "pi-check-builder";
  }
  ''
    mkdir -p "$out/libexec/pi-builder" "$out/bin"
    cp ${./builder.py} "$out/libexec/pi-builder/builder.py"
    cp ${./guest.py} "$out/libexec/pi-builder/guest.py"
    cp ${./native_check.py} "$out/libexec/pi-builder/native_check.py"
    cp ${../pi-session/workspace.py} "$out/libexec/pi-builder/workspace.py"
    cp ${./test_builder.py} test_builder.py
    PYTHONPATH="$out/libexec/pi-builder" python3 test_builder.py
    python3 -m py_compile "$out/libexec/pi-builder/"*.py
    makeWrapper ${python3}/bin/python3 "$out/bin/pi-check-builder" \
      --prefix PATH : ${lib.makeBinPath [ git ]} \
      --add-flags "$out/libexec/pi-builder/native_check.py"
  ''
