# Code Reference Guidelines

When referencing code locations in this repository, always include both the file path and a GitHub permalink for easy navigation.

## GitHub Permalink Format

### For Specific Lines

When referencing specific functions or code sections, include:

- File path with line numbers: `path/to/file.ext:L123-L456`
- GitHub permalink with commit hash: `https://github.com/modularml/mojo/blob/<COMMIT_HASH>/path/to/file.ext#L123-L456`

**Example:**

```
The `parse_config` function is defined in src/parser/config.py:L45-L78 (https://github.com/modularml/mojo/blob/abc123def456/src/parser/config.py#L45-L78)
```

### For Entire Files

When referencing an entire file:

- File path: `path/to/file.ext`
- GitHub permalink: `https://github.com/modularml/mojo/blob/<COMMIT_HASH>/path/to/file.ext`

**Example:**

```
The configuration module is in src/parser/config.py (https://github.com/modularml/mojo/blob/abc123def456/src/parser/config.py)
```

### For Directories

When referencing a directory:

- Directory path: `path/to/directory/`
- GitHub permalink: `https://github.com/modularml/mojo/tree/<COMMIT_HASH>/path/to/directory`

**Example:**

```
Parser implementations are in src/parser/ (https://github.com/modularml/mojo/tree/abc123def456/src/parser)
```

## Important Guidelines

1. **Use commit hashes, not branch names** - This ensures permalinks remain stable even as branches evolve
2. **Get the current commit hash** - Use `git rev-parse HEAD` to get the current commit hash
3. **Include both formats** - Always provide the relative path for local navigation AND the GitHub URL for web access
4. **Line number ranges** - Use `L123-L456` format for multi-line references, `L123` for single lines

## Repository Information

- **Repository**: https://github.com/modularml/mojo
- **To get current commit**: Run `git rev-parse HEAD` in the repository root

## Example Response Format

When answering questions about code locations:

> The error handling logic is implemented in `stdlib/src/error/handler.mojo:L234-L267` (https://github.com/modularml/mojo/blob/a1b2c3d4e5f6/stdlib/src/error/handler.mojo#L234-L267)

This format provides:

- Quick local reference: `stdlib/src/error/handler.mojo:L234-L267`
- Stable web link: The full GitHub permalink with commit hash

## AWS Resources

When creating AWS resources manually (via console/clickops):

**Required Tags:**

- `Owner`: Kyle Ondy
- `Managed-By`: Clickops
- `Ticket`: CLIN-nnnn (determine from current work context if possible)

These tags ensure proper resource attribution and tracking.
