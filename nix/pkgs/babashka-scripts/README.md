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

All scripts can use utilities from `shared/src/common/`:

- `common.cli` - CLI parsing and help utilities
- `common.fs` - Filesystem operations
- `common.process` - Process execution utilities

## Development

### Creating Simple Scripts

1. Copy `templates/simple-script.bb` to `simple/your-script-name.bb`
2. Update the script name and functionality
3. The build system will automatically package it

### Creating Complex Projects

1. Copy `templates/structured-project/` to `projects/your-project-name/`
2. Rename files and update namespaces accordingly
3. The build system will automatically create wrapper scripts

### Templates

Templates in `templates/` are development-only and not included in built packages.

## Building

This package uses a custom Nix builder that:

- Auto-detects simple vs structured scripts
- Properly handles `bb.edn` dependencies
- Creates wrapper scripts with correct classpaths
- Excludes templates from final packages

The builder is used by importing `./babashka-builder.nix` in the package definition.
