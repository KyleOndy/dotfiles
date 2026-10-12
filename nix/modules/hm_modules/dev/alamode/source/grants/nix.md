# Isolated Nix builds

`nix build` and `nix eval` submit the current workspace to the trusted build
service. Dirty files are snapshotted without changing your branch or index.
Each request passes Git admission before a fresh Darwin VM executes it.

The VM has its own Nix daemon, disk and enforced network policy. Host daemon
sockets, credentials and directories remain unavailable. Package-fetching
permission is part of the recorded builder configuration; `--web` and
toolchain grants do not change it.

Output streams to the terminal. Ctrl-C cancels the build. The printed build
record retains logs and the VM for inspection; Nix outputs stay in that VM.
No build output is imported into the host store automatically.

Only `build` and `eval` are supported by the session's `nix` command. A
missing prerequisite or failed containment probe stops the request.
