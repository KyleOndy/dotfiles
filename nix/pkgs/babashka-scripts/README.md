# Babashka Scripts

## Structure

```bash
babashka-scripts/
├── simple/                 # single-file .bb scripts
│   ├── retry.bb
│   └── roku-check.bb       # media compatibility checker
├── projects/               # structured babashka projects
│   └── roku-transcode/     # video transcoding tool
├── shared/                 # shared library
│   ├── bb.edn              # shared dependencies
│   └── src/common/         # process.clj
└── babashka-builder.nix    # custom Nix build function
```

## Available Scripts

### retry

Rerun a command until it succeeds, with backoff and jitter.

```bash
retry --max-attempts 3 --backoff-strategy fibonacci -- curl -fsS https://example.com
```

### roku-check

Check if video files are compatible with Roku devices.

```bash
roku-check --detailed video.mp4
```

### roku-transcode

Transcode a video to a Roku-compatible MP4 (H.264/AAC), written beside the
input with a `_roku` suffix. `--quality` takes `high` (default), `medium` or
`low`; `--gpu`, `--cpu` and `--encoder` pick the encoder.

```bash
roku-transcode --quality medium input.mkv   # writes input_roku.mp4
```

## Building

`babashka-builder.nix` decides what a script is by its directory:

- **`simple/<name>.bb`**: copied to `bin/<name>` as is.
- **`projects/<name>/`**: copied to `share/<name>`, with a `bin/<name>` wrapper
  that puts the project's `src/` and `shared/src/` on the classpath and loads
  `<name>.bb`, else `main.bb`, else the first `.bb` in the project root.

Only projects get the classpath, so `common.process` (`shared/src/common/`) is
out of reach for `simple/` scripts. `bb.edn` files are copied but never read, so
a script can use only the libraries babashka ships with.
