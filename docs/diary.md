gpg: WARNING: unsafe permissions on homedir '/Users/kyle.ondy/.gnupg'

chown -R $(whoami) ~/.gnupg/
chmod 600 ~/.gnupg/\*
chmod 700 ~/.gnupg

---

var/empty

check env var, ex $GNUPGHOME

---

Uh oh, messed up your nix-store? Maybe tried to `rm -rf` some config file that
was actually in the nix store? Try running the following to save the day.

```
nix-store --verify --check-contents --repair
```

---

## Treesitter parsing seems broken

Current `HEAD` of my configuration is
`7cc8fa13521308b41a1182e5b088fe6d31248358S` Tree sitter broke on markdown
highlighting. This was the error I am getting:

```txt
> nvim README.md
Error detected while processing FileType Autocommands for "*":
E5108: Error executing lua ...ed-0.6.1/share/nvim/runtime/lua/vim/treesitter/query.lua:161: query: invalid node type at position 39
stack traceback:
        [C]: in function '_ts_parse_query'
        ...ed-0.6.1/share/nvim/runtime/lua/vim/treesitter/query.lua:161: in function 'get_query'
        ...1/share/nvim/runtime/lua/vim/treesitter/languagetree.lua:37: in function 'new'
        ...nwrapped-0.6.1/share/nvim/runtime/lua/vim/treesitter.lua:45: in function '_create_parser'
        ...nwrapped-0.6.1/share/nvim/runtime/lua/vim/treesitter.lua:93: in function 'get_parser'
        .../start/nvim-treesitter/lua/nvim-treesitter/highlight.lua:107: in function 'attach'
        ...er/start/nvim-treesitter/lua/nvim-treesitter/configs.lua:458: in function 'attach_module'
        ...er/start/nvim-treesitter/lua/nvim-treesitter/configs.lua:481: in function 'reattach_module'
        [string ":lua"]:1: in main chunk
```

The following patch makes the error go away, seeming to isolate the problem to highlighting

```git
--- a/modules/hm_modules/terminal/editors/neovim.nix
+++ b/modules/hm_modules/terminal/editors/neovim.nix
@@ -36,7 +36,7 @@ in
               require 'nvim-treesitter.install'.compilers = { 'clang++'}
               require 'nvim-treesitter.configs'.setup {
                 highlight = {
-                  enable = false,
+                  enable = true,
                 },
                 indent = {
                   enable = true,
```

Did some searching on the nixpkgs github page, found [pull request
154767](https://github.com/NixOS/nixpkgs/pull/154767) which sounds promising.
Just need to figure out how to use that fork for treesitter.

Example of how to use arbitrary patches of `nixpkgs`.

```patch
diff --git c/flake.nix i/flake.nix
index 47bc43a..e57ac22 100644
--- c/flake.nix
+++ i/flake.nix
@@ -1,6 +1,10 @@
 {
   inputs = {
     nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
+    # pinning the current head of the `tree-sitter-markdown` branch, I want to
+    # be explicit. I don't like the idea of the branch changing on blindly
+    # taking the changes.
+    nixpkg-treesitter-patchs.url = "github:lesquembre/nixpkgs/b70734ae8ca8a0c625f40305357ea217da25d823";
     home-manager = {
       url = "github:nix-community/home-manager/master";
       inputs.nixpkgs.follows = "nixpkgs";
@@ -33,6 +37,9 @@
         inputs.nur.overlay
         (import ./pkgs)
         (import ./overlays/st)
+        ( final: prev: {
+          nixpkgs-treesitter-patchs = import inputs.nixpkg-treesitter-patchs { system = final.system;};
+        })
       ];


diff --git c/modules/hm_modules/terminal/editors/neovim.nix i/modules/hm_modules/terminal/editors/neovim.nix
index 911b01b..beaca75 100644
--- c/modules/hm_modules/terminal/editors/neovim.nix
+++ i/modules/hm_modules/terminal/editors/neovim.nix
@@ -30,7 +30,7 @@ in
           #
           # https://github.com/nvim-treesitter/nvim-treesitter
           # https://nixos.org/manual/nixpkgs/unstable/#managing-plugins-with-vim-packages
-          plugin = nvim-treesitter.withPlugins (plugins: pkgs.tree-sitter.allGrammars);
+          plugin = nvim-treesitter.withPlugins (plugins: pkgs.nixpkgs-treesitter-patchs.tree-sitter.allGrammars);
           config = ''
             lua <<CFG
               require 'nvim-treesitter.install'.compilers = { 'clang++'}
```
