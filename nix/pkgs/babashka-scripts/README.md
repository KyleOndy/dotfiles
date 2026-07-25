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

### roku-check

Check if video files are compatible with Roku devices.

**Usage:**

```bash
roku-check --detailed video.mp4
```

### roku-transcode

Transcode videos to Roku-compatible format using babashka.

**Usage:**

```bash
roku-transcode -i input.mkv -o output.mp4 --quality high
```

## Shared Utilities

Scripts can use `common.process` from `shared/src/common/`, which is put
on the classpath automatically.

## Building

This package uses a custom Nix builder that:

- Auto-detects simple vs structured scripts
- Properly handles `bb.edn` dependencies
- Creates wrapper scripts with correct classpaths

The builder is used by importing `./babashka-builder.nix` in the package definition.
