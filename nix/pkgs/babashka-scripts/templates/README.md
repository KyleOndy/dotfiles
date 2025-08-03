# Babashka Script Templates

This directory contains templates for creating new babashka scripts. These
templates are **development-only** and are not included in the built packages.

## Templates

### `simple-script.bb`

Template for single-file babashka scripts. Use this for simple utilities
that don't require complex project structure.

**Usage:**

1. Copy to `../simple/your-script-name.bb`
2. Replace `script-name` with your actual script name
3. Update the description and CLI specification
4. Implement your logic in the `process-input` function

### `structured-project/`

Template for complex babashka projects with multiple namespaces and files.

**Usage:**

1. Copy the entire directory to `../projects/your-project-name/`
2. Rename `project-name.bb` to `your-project-name.bb`
3. Replace `project-name` and `project_name` throughout all files
4. Implement your logic in the various namespace files

## Shared Utilities

Both templates can use the shared utilities from `../shared/src/common/`:

- `common.cli` - CLI parsing and help utilities
- `common.fs` - Filesystem operations
- `common.process` - Process execution utilities

## Development Guidelines

- Follow the existing code style and patterns
- Use descriptive names for functions and variables
- Include proper error handling
- Add examples in help text
- Test your scripts before committing
