# https://github.com/jlesquembre/dotfiles/blob/1e97bcc4d7800a75cf845484f44f9e97c1833d29/overlays/pkgs/vscode-ls/default.nix
{ lib
, stdenv
, makeWrapper
, nodejs_latest
, unzip
, vscode
}:

# Adapted from
# https://github.com/kabouzeid/nvim-lspinstall/blob/main/lua/lspinstall/servers/css.lua
stdenv.mkDerivation rec {
  pname = "vscode-ls";
  version = vscode.version;

  src = vscode.src;

  buildInputs = [ unzip ];
  nativeBuildInputs = [ makeWrapper ];

  unpackPhase = ''
    unzip $src
  '';

  buildPhase = null;

  installPhase = ''
    mkdir -p $out/extensions

    cd "Visual Studio Code.app/Contents"
    ls -laxo .

    cp -r "Resources/app/extensions/node_modules" $out/extensions/node_modules
    cp -r "Resources/app/extensions/css-language-features" $out/extensions/css-ls
    cp -r "Resources/app/extensions/json-language-features" $out/extensions/json-ls
    cp -r "Resources/app/extensions/html-language-features" $out/extensions/html-ls

    makeWrapper '${nodejs_latest}/bin/node' "$out/bin/vscode-css-language-server" \
      --add-flags "$out/extensions/css-ls/server/dist/node/cssServerMain.js"

    makeWrapper '${nodejs_latest}/bin/node' "$out/bin/vscode-json-language-server" \
      --add-flags "$out/extensions/json-ls/server/dist/node/jsonServerMain.js"

    makeWrapper '${nodejs_latest}/bin/node' "$out/bin/vscode-html-language-server" \
      --add-flags "$out/extensions/html-ls/server/dist/node/htmlServerMain.js"
  '';

  meta = with lib; {
    homepage = "https://github.com/microsoft/vscode";
    description = "LSP server dependecies extracted from vscode";
  };
}
