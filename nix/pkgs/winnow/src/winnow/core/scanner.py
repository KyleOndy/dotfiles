"""Scanner module for finding JPEG files in a directory.

This module provides functionality to scan a directory for JPEG image files,
filtering by extension and sorting by filename.
"""

from pathlib import Path


def scan_directory(directory: Path) -> list[Path]:
    """Scan a directory for JPEG files, sorted by filename.

    Performs a non-recursive scan of the specified directory, finding all files
    with JPEG extensions (.jpg, .jpeg, .JPG, .JPEG). Results are sorted
    alphabetically by filename.

    Args:
        directory: Path to the directory to scan. Must be a valid directory.

    Returns:
        List of Path objects for all JPEG files found, sorted by filename.
        Returns an empty list if no JPEG files are found.

    Raises:
        OSError: If the directory cannot be read (e.g. permission denied, or
            it was removed after the caller validated it exists).

    Example:
        >>> from pathlib import Path
        >>> photos_dir = Path("/home/user/photos")
        >>> jpegs = scan_directory(photos_dir)
        >>> print([p.name for p in jpegs])
        ['IMG_001.jpg', 'IMG_002.JPG', 'IMG_003.jpeg']
    """
    # Valid JPEG extensions (case-insensitive)
    jpeg_extensions = {".jpg", ".jpeg"}

    try:
        entries = list(directory.iterdir())
    except OSError as e:
        raise OSError(f"Cannot read directory {directory}: {e}") from e

    # Find all JPEG files in the directory (non-recursive). Skip entries that
    # raise on stat (e.g. a broken symlink) instead of failing the whole scan.
    jpeg_files = []
    for path in entries:
        try:
            if path.is_file() and path.suffix.lower() in jpeg_extensions:
                jpeg_files.append(path)
        except OSError:
            continue

    # Sort by filename for consistent ordering
    return sorted(jpeg_files, key=lambda p: p.name)
