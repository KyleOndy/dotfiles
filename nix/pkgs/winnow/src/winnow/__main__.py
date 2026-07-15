"""Winnow module entry point.

This module enables running Winnow as a Python module via `python -m winnow`.
It delegates to the main() function in winnow.app for all application logic.
"""

from winnow.app import main

if __name__ == "__main__":
    main()
