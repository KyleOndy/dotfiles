# Babashka Scripts

This package contains Kyle's babashka scripts, organized for scalability and maintainability.

## Structure

```bash
babashka-scripts/
├── simple/                    # Single-file .bb scripts
│   └── roku-check.bb         # Media compatibility checker
├── projects/                  # Structured babashka projects
│   └── roku-transcode/       # Video transcoding tool
├── shared/                    # Common utilities library
│   ├── bb.edn               # Shared dependencies
│   └── src/common/          # Reusable namespaces
├── templates/                 # DEV-ONLY: Not packaged
│   ├── simple-script.bb      # Template for simple scripts
│   └── structured-project/   # Template for complex projects
└── babashka-builder.nix      # Custom Nix build function
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
