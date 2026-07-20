"""Winnow application entry point.

This module provides the main() function for starting the Winnow photo culling
application. It handles command-line argument parsing, directory validation,
and Qt application initialization.
"""

import argparse
import ctypes
import os
import sys
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication

from winnow.ui.main_window import MainWindow

# Fraction of physical RAM used as the default full-resolution image cache
# budget (see --max-memory / ImageCache.max_memory_mb). A soft cap, not a
# preallocation, so this only bounds how much the LRU cache is allowed to
# grow to under sustained navigation.
_DEFAULT_CACHE_RAM_FRACTION = 0.4

# Used when physical RAM can't be detected (unknown platform, sysctl/sysconf
# failure). Conservative rather than the old flat 24576 MB default.
_FALLBACK_MAX_MEMORY_MB = 8192.0


def _physical_memory_bytes() -> int | None:
    """Best-effort detection of total physical RAM in bytes.

    Returns:
        Total physical memory in bytes, or None if it can't be determined.
    """
    if sys.platform == "darwin":
        try:
            size = ctypes.c_uint64(0)
            size_of_size = ctypes.c_size_t(ctypes.sizeof(size))
            libc = ctypes.CDLL("libSystem.dylib", use_errno=True)
            if (
                libc.sysctlbyname(
                    b"hw.memsize",
                    ctypes.byref(size),
                    ctypes.byref(size_of_size),
                    None,
                    0,
                )
                != 0
            ):
                return None
            return size.value
        except (OSError, AttributeError):
            return None

    # Linux and other POSIX platforms.
    try:
        return os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
    except (ValueError, OSError, AttributeError):
        return None


def default_max_memory_mb() -> float:
    """Default full-resolution image cache budget, in MB.

    Computed as a fraction of detected physical RAM so the default scales
    with the machine instead of assuming a fixed amount. Falls back to a
    conservative flat value if RAM can't be detected.

    Returns:
        Default value for --max-memory, in MB.
    """
    total_bytes = _physical_memory_bytes()
    if total_bytes is None:
        return _FALLBACK_MAX_MEMORY_MB
    return (total_bytes * _DEFAULT_CACHE_RAM_FRACTION) / (1024 * 1024)


def main() -> int:
    """Main entry point for the Winnow application.

    Parses command-line arguments, validates the directory path, and launches
    the Qt application with the main window.

    Returns:
        Exit code (0 for success, 1 for error)
    """
    # Parse command-line arguments
    parser = argparse.ArgumentParser(
        prog="winnow",
        description="A focused photo culling application for JPEG images",
    )
    parser.add_argument(
        "directory",
        type=str,
        help="Path to directory containing JPEG photos to cull",
    )
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s 0.1.0",
    )
    parser.add_argument(
        "--max-memory",
        type=float,
        default=default_max_memory_mb(),
        help="Maximum memory (MB) for the full-resolution image cache "
        "(default: 40%% of physical RAM)",
    )

    args = parser.parse_args()

    # Validate directory path
    directory = Path(args.directory)

    if not directory.exists():
        print(f"Error: Directory does not exist: {directory}", file=sys.stderr)
        return 1

    if not directory.is_dir():
        print(f"Error: Path is not a directory: {directory}", file=sys.stderr)
        return 1

    # On macOS, Qt maps Ctrl in QKeySequence/modifiers to Cmd by default so
    # apps feel native. winnow's Ctrl+h/j/k/l/0/r bindings (and Ctrl+click)
    # are meant to match the physical Control key on every platform, so
    # disable that remapping. Must be set before QApplication is constructed.
    if sys.platform == "darwin":
        QApplication.setAttribute(
            Qt.ApplicationAttribute.AA_MacDontSwapCtrlAndMeta, True
        )

    # Initialize Qt application
    app = QApplication(sys.argv)

    # Create and show main window
    try:
        window = MainWindow(directory, max_memory_mb=args.max_memory)
    except OSError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    window.show()

    # Run event loop
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
