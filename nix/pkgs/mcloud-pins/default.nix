{
  writeShellApplication,
  runCommand,
  python3,
  coreutils,
  curl,
  gnugrep,
  jq,
}:

let
  # 64x64, every pixel #00a000: one color with one obvious name, as an
  # unfiltered 8-bit RGB PNG.
  greenPng = runCommand "green-64x64.png" { nativeBuildInputs = [ python3 ]; } ''
    python3 - "$out" <<'EOF'
    import struct, sys, zlib

    def chunk(kind, data):
        crc = zlib.crc32(kind + data)
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    row = b"\x00" + b"\x00\xa0\x00" * 64
    with open(sys.argv[1], "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", 64, 64, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(row * 64, 9)))
        f.write(chunk(b"IEND", b""))
    EOF
  '';
in
writeShellApplication {
  name = "mcloud-pins";
  runtimeInputs = [
    coreutils
    curl
    gnugrep
    jq
  ];
  text = ''
    GREEN_PNG=${greenPng}
  ''
  + builtins.readFile ./mcloud-pins.sh;
}
