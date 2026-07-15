"""Pytest configuration for winnow tests."""

import os

# Force the offscreen platform before pytest-qt creates the QApplication.
# Tests show and activate real windows for keyboard dispatch; on the live
# desktop session the compositor fights them for focus (flaky activation,
# windows flashing on screen), and with the session locked activation
# fails outright. Offscreen activation is deterministic.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import gc
from pathlib import Path

import pytest
from PySide6.QtWidgets import QApplication

from winnow.core.scanner import scan_directory
from winnow.core.session import Session
from winnow.core.thumbnailer import Thumbnailer
from winnow.ui.main_window import MainWindow


@pytest.fixture(autouse=True)
def _drain_thumbnailers():
    """Enforce the Thumbnailer teardown contract after every test.

    Thumbnailer.wait_for_pending's docstring requires draining background
    decodes before teardown so no worker thread emits into an object being
    destroyed. The app honors this in MainWindow.closeEvent; tests that
    create strips inline and drop them at test end do not, which corrupts
    the heap and segfaults a later, unrelated test's event processing.
    """
    yield
    for obj in gc.get_objects():
        if isinstance(obj, Thumbnailer):
            try:
                obj.wait_for_pending()
            except (AttributeError, RuntimeError):
                # Mid-destruction wrapper: __dict__ already cleared or the
                # C++ object is gone. Nothing left to drain.
                continue
    app = QApplication.instance()
    if app is not None:
        app.processEvents()


@pytest.fixture(scope="session")
def fixture_dir():
    """Return path to the test fixtures directory.

    Returns:
        Path to tests/fixtures directory containing sample images.
    """
    return Path(__file__).parent / "fixtures"


@pytest.fixture(scope="session")
def portrait_image(fixture_dir):
    """Return path to portrait orientation test image.

    Returns:
        Path to portrait.jpg (100x200px, 1:2 aspect ratio).
    """
    return fixture_dir / "portrait.jpg"


@pytest.fixture(scope="session")
def landscape_image(fixture_dir):
    """Return path to landscape orientation test image.

    Returns:
        Path to landscape.jpg (200x100px, 2:1 aspect ratio).
    """
    return fixture_dir / "landscape.jpg"


@pytest.fixture(scope="session")
def square_image(fixture_dir):
    """Return path to square orientation test image.

    Returns:
        Path to square.jpg (100x100px, 1:1 aspect ratio).
    """
    return fixture_dir / "square.jpg"


@pytest.fixture
def session(fixture_dir):
    """Create a Session with test images.

    Returns:
        Session object with portrait, landscape, and square test images.
    """
    images = scan_directory(fixture_dir)
    return Session(directory=fixture_dir, images=images)


@pytest.fixture
def thumbnailer():
    """Create a Thumbnailer instance.

    Returns:
        Thumbnailer with default settings.
    """
    return Thumbnailer()


@pytest.fixture
def main_window(fixture_dir, qapp):
    """Create a MainWindow instance with test images.

    Args:
        fixture_dir: Path to test fixtures directory.
        qapp: QApplication instance.

    Returns:
        MainWindow initialized with test images.
    """
    return MainWindow(fixture_dir)
