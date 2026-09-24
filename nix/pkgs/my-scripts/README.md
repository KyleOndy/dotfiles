# Scripts

Scripts that are not important or complex enough to be broken into their own
package. Installed through `hmFoundry.dev` (`nix/modules/hm_modules/dev/core.nix`).

## What gets installed

- **`scripts/`**: every executable file, found recursively and flattened into
  `bin/` with symlinks followed. A file in a subdirectory keeps its own name, so
  `scripts/gpg-renewal/renew-gpg.sh` installs as `renew-gpg.sh`. Files without
  the executable bit (READMEs, `gpg-renewal/reset-command`) are skipped.
- **`lib/common.sh`**: copied to `lib/`. The build rewrites the exact line
  `source "${SCRIPT_DIR}/../lib/common.sh"` to the store path, so a new script
  has to source it with that line, byte for byte.
- **`completions/`**: zsh completions, installed to `share/zsh/site-functions`.
  Only the `git-*` commands have one. `dots_common.bash` is their shared helper;
  the build points them at it by absolute path and swaps its `gawk` for a store
  path.

## Runtime dependencies

Nothing is wrapped. `buildInputs` never reach a script's `PATH`, so a script
either uses what is already on the user's `PATH` (git, fzf, gh and so on) or
declares its own with a `nix-shell` shebang (`copy-dvd`, `yt-download`).
