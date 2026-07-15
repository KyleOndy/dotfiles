"""Winnow application entry point.

This module provides the main() function for starting the Winnow photo culling
application. It handles command-line argument parsing, directory validation,
and Qt application initialization.
"""

import argparse
import sys
from pathlib import Path

from PySide6.QtWidgets import QApplication

from winnow.ui.main_window import MainWindow


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
        default=24576.0,
        help="Maximum memory (MB) for the full-resolution image cache (default: 24576 MB)",
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
