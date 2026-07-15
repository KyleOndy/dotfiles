"""Tests for the SELECT/COMPARE/VISUAL mode color indicator (badge + frame).

A live VISUAL span and a committed COMPARE grid otherwise look identical - a
grid with an amber focus ring - so these confirm the status-bar mode badge
and the viewing-area frame both track the live keyboard mode and stay in
sync with each other.
"""

import pytest
from PIL import Image
from PySide6.QtCore import QCoreApplication, QEvent, Qt
from PySide6.QtWidgets import QApplication

from winnow.core.session import Session
from winnow.ui.keymap import Mode, mode_style
from winnow.ui.main_window import MainWindow
from winnow.ui.viewing_area import ViewingArea

# ---------------------------------------------------------------------------
# ViewingArea.set_mode_frame - pure widget-level checks
# ---------------------------------------------------------------------------


@pytest.fixture
def paths(tmp_path):
    """Three image paths (files need not exist; placeholders render)."""
    return [tmp_path / f"photo{n}.jpg" for n in range(3)]


@pytest.fixture
def viewing_area(qapp, tmp_path, paths):
    """ViewingArea over a session containing the three test paths."""
    session = Session(directory=tmp_path, images=list(paths))
    return ViewingArea(session)


def test_single_mode_has_transparent_frame(viewing_area):
    viewing_area.set_mode_frame(Mode.SINGLE)

    assert "transparent" in viewing_area.styleSheet()


def test_compare_mode_frame_matches_mode_style(viewing_area):
    viewing_area.set_mode_frame(Mode.COMPARE)

    assert mode_style(Mode.COMPARE).color in viewing_area.styleSheet()


def test_visual_mode_frame_matches_mode_style(viewing_area):
    viewing_area.set_mode_frame(Mode.VISUAL)

    assert mode_style(Mode.VISUAL).color in viewing_area.styleSheet()


def test_frame_margins_stay_constant_across_mode_changes(viewing_area):
    """Toggling the frame must never reflow the grid (reserved margins)."""
    margins_before = viewing_area.layout().contentsMargins()

    viewing_area.set_mode_frame(Mode.COMPARE)
    viewing_area.set_mode_frame(Mode.VISUAL)
    viewing_area.set_mode_frame(Mode.SINGLE)

    assert viewing_area.layout().contentsMargins() == margins_before
    assert (
        margins_before.left(),
        margins_before.top(),
        margins_before.right(),
        margins_before.bottom(),
    ) == (3, 3, 3, 3)


# ---------------------------------------------------------------------------
# MainWindow - badge and frame track the live keyboard mode
# ---------------------------------------------------------------------------


@pytest.fixture
def photo_dir(tmp_path):
    """Create a directory with 4 JPEG test images."""
    for i in range(4):
        img = Image.new("RGB", (100, 100), color=(i * 60, 0, 0))
        img.save(tmp_path / f"photo{i + 1}.jpg")
    return tmp_path


@pytest.fixture
def photos(photo_dir):
    """Return sorted list of photo paths."""
    return sorted(photo_dir.glob("*.jpg"))


@pytest.fixture
def win(photo_dir, qtbot, monkeypatch):
    """An ACTIVE MainWindow, required for WindowShortcut dispatch.

    The image cache is disabled so tests stay deterministic and cache-free
    even though the window is shown.
    """
    monkeypatch.setattr(MainWindow, "_start_image_loading", lambda self: None)
    window = MainWindow(photo_dir)
    window.show()
    window.activateWindow()
    qtbot.waitUntil(window.isActiveWindow)
    yield window
    # Tear the window down deterministically, matching
    # test_keyboard_shortcuts.py's win fixture.
    window.session.keepers.clear()
    window.session.deletes.clear()
    window.close()
    window.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    QCoreApplication.processEvents()


@pytest.fixture
def win_single(win, photos):
    """Active MainWindow showing the first photo in single view."""
    win.viewing_area.set_images(photos[:1])
    return win


@pytest.fixture
def win_compare(win, photos):
    """Active MainWindow comparing the first three photos."""
    win.viewing_area.set_images(photos[:3])
    return win


def press(qtbot, window, key, modifier=Qt.KeyboardModifier.NoModifier):
    """Send a key to window, re-asserting activation first.

    See test_keyboard_shortcuts.py's press() for why re-activation is
    needed under the full suite.
    """
    app = QApplication.instance()
    if app.activeWindow() is not window:
        window.activateWindow()
        qtbot.waitUntil(lambda: app.activeWindow() is window)
    qtbot.keyClick(window, key, modifier)


def test_single_view_shows_select_badge_and_no_frame(win_single):
    assert win_single.keyboard.mode is Mode.SINGLE
    assert mode_style(Mode.SINGLE).label in win_single.mode_badge.text()
    assert "transparent" in win_single.viewing_area.styleSheet()


def test_compare_view_shows_compare_badge_and_frame(win_compare):
    assert win_compare.keyboard.mode is Mode.COMPARE
    assert mode_style(Mode.COMPARE).label in win_compare.mode_badge.text()
    assert mode_style(Mode.COMPARE).color in win_compare.viewing_area.styleSheet()


def test_entering_visual_switches_badge_and_frame_to_visual(win_single, qtbot):
    press(qtbot, win_single, Qt.Key_V)

    assert win_single.keyboard.mode is Mode.VISUAL
    assert mode_style(Mode.VISUAL).label in win_single.mode_badge.text()
    assert mode_style(Mode.VISUAL).color in win_single.viewing_area.styleSheet()


def test_committing_visual_switches_badge_and_frame_to_compare(win_single, qtbot):
    press(qtbot, win_single, Qt.Key_V)
    press(qtbot, win_single, Qt.Key_L)  # extend the span to 2 photos
    press(qtbot, win_single, Qt.Key_Return)  # commit

    assert win_single.keyboard.mode is Mode.COMPARE
    assert mode_style(Mode.COMPARE).label in win_single.mode_badge.text()
    assert mode_style(Mode.COMPARE).color in win_single.viewing_area.styleSheet()


def test_canceling_visual_returns_to_select_badge_and_no_frame(win_single, qtbot):
    press(qtbot, win_single, Qt.Key_V)
    press(qtbot, win_single, Qt.Key_Escape)

    assert win_single.keyboard.mode is Mode.SINGLE
    assert mode_style(Mode.SINGLE).label in win_single.mode_badge.text()
    assert "transparent" in win_single.viewing_area.styleSheet()
