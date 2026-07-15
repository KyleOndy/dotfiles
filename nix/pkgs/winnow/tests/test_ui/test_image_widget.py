"""Tests for ImageWidget and StatusOverlay classes."""

from unittest.mock import Mock

import pytest
from PySide6.QtCore import QPoint, Qt
from PySide6.QtGui import QPixmap

from winnow.core.image_cache import ImageCache
from winnow.core.session import PhotoStatus, Session
from winnow.ui.image_widget import ImageWidget, StatusOverlay

# ImageWidget Initialization Tests


def test_image_widget_initialization(qapp, portrait_image):
    """Test that ImageWidget initializes correctly."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=False)

    # Check basic properties
    assert widget.path == portrait_image
    assert widget.session == session
    assert widget.synchronized is False
    assert widget.zoom_level == 1.0
    assert widget.fit_mode is True
    assert widget.pan_offset == QPoint(0, 0)
    assert widget.last_mouse_pos is None


def test_image_widget_loads_pixmap(qapp, portrait_image):
    """Test that ImageWidget loads the image pixmap."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Check pixmap was loaded
    assert widget.original_pixmap is not None
    assert not widget.original_pixmap.isNull()


def test_image_widget_creates_overlay(qapp, portrait_image):
    """Test that ImageWidget creates StatusOverlay at correct position."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Check overlay exists and is positioned
    assert widget.overlay is not None
    assert widget.overlay.pos() == QPoint(10, 10)
    assert widget.overlay.path == portrait_image


def test_image_widget_synchronized_flag(qapp, portrait_image):
    """Test that synchronized flag is stored correctly."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])

    widget_sync = ImageWidget(portrait_image, session, synchronized=True)
    assert widget_sync.synchronized is True

    widget_nosync = ImageWidget(portrait_image, session, synchronized=False)
    assert widget_nosync.synchronized is False


# Async Background-Decode Tests


def test_cache_miss_with_cache_present_shows_placeholder_and_requests(
    qapp, qtbot, portrait_image
):
    """A cache miss with a background cache present never decodes synchronously.

    Instead it shows a placeholder immediately and queues a background
    decode - the real pixmap arrives later via set_full_image(), driven by
    ViewingArea.on_image_ready (see test_viewing_area.py).
    """
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()

    widget = ImageWidget(portrait_image, session)

    # Pending: shown pixmap is a placeholder, not yet the real decode.
    assert widget._pending_full_load is True
    assert widget.has_valid_image()

    qtbot.waitUntil(
        lambda: session.image_cache.get(portrait_image) is not None, timeout=2000
    )


def test_cache_miss_placeholder_uses_existing_thumbnail(qapp, qtbot, portrait_image):
    """The placeholder reuses session.thumbnails when one is already cached."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()
    thumbnail = QPixmap(10, 10)
    thumbnail.fill(Qt.GlobalColor.red)
    session.thumbnails[portrait_image] = thumbnail

    widget = ImageWidget(portrait_image, session)

    assert widget.original_pixmap is thumbnail

    # Drain the background decode request() queued regardless, so no task
    # is left in flight past this test.
    qtbot.waitUntil(
        lambda: session.image_cache.get(portrait_image) is not None, timeout=2000
    )


def test_set_full_image_swaps_in_real_pixmap(qapp, qtbot, portrait_image):
    """set_full_image() replaces the placeholder and clears the pending flag."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()

    widget = ImageWidget(portrait_image, session)
    assert widget._pending_full_load is True

    real_pixmap = QPixmap(str(portrait_image))
    widget.set_full_image(real_pixmap)

    assert widget._pending_full_load is False
    assert widget.original_pixmap is real_pixmap

    qtbot.waitUntil(
        lambda: session.image_cache.get(portrait_image) is not None, timeout=2000
    )


def test_set_full_image_ignores_null_pixmap(qapp, qtbot, portrait_image):
    """A null pixmap (e.g. a stale/failed delivery) is not swapped in."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()

    widget = ImageWidget(portrait_image, session)
    placeholder = widget.original_pixmap

    widget.set_full_image(QPixmap())

    assert widget.original_pixmap is placeholder
    assert widget._pending_full_load is True

    qtbot.waitUntil(
        lambda: session.image_cache.get(portrait_image) is not None, timeout=2000
    )


def test_show_load_failed_displays_placeholder_text(qapp, qtbot, portrait_image):
    """show_load_failed() shows the same message as a synchronous decode failure."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()

    widget = ImageWidget(portrait_image, session)
    widget.show_load_failed()

    assert not widget.has_valid_image()
    assert "Unable to load image" in widget.image_label.text()

    qtbot.waitUntil(
        lambda: session.image_cache.get(portrait_image) is not None, timeout=2000
    )


# Zoom Functionality Tests


def test_zoom_wheel_event_zoom_in(qapp, portrait_image):
    """Test that mouse wheel scroll up increases zoom level to next stop."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Start at explicit 100% zoom (exits fit mode so wheel uses zoom_level as base)
    widget.set_zoom(1.0, emit_signal=False)
    assert widget.zoom_level == 1.0
    assert widget.fit_mode is False

    # Simulate wheel scroll up (positive delta)
    # Mock position to be at center of widget
    event = Mock()
    event.angleDelta.return_value = Mock(y=Mock(return_value=120))
    event.position.return_value = Mock(
        x=Mock(return_value=widget.width() / 2),
        y=Mock(return_value=widget.height() / 2),
    )
    widget.wheelEvent(event)

    # Zoom should jump to next stop: 150% (1.5)
    assert widget.zoom_level == pytest.approx(1.5, rel=0.01)
    assert widget.fit_mode is False


def test_zoom_wheel_event_zoom_out(qapp, portrait_image):
    """Test that mouse wheel scroll down decreases zoom level to previous stop."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Start at explicit 100% zoom (exits fit mode so wheel uses zoom_level as base)
    widget.set_zoom(1.0, emit_signal=False)
    assert widget.zoom_level == 1.0
    assert widget.fit_mode is False

    # Simulate wheel scroll down (negative delta)
    # Mock position to be at center of widget
    event = Mock()
    event.angleDelta.return_value = Mock(y=Mock(return_value=-120))
    event.position.return_value = Mock(
        x=Mock(return_value=widget.width() / 2),
        y=Mock(return_value=widget.height() / 2),
    )
    widget.wheelEvent(event)

    # Zoom should jump to previous stop: 75% (0.75)
    assert widget.zoom_level == pytest.approx(0.75, rel=0.01)
    assert widget.fit_mode is False


def test_zoom_clamps_at_minimum(qapp, portrait_image):
    """Test that zoom level clamps at 0.1x minimum."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Set zoom to near minimum
    widget.set_zoom(0.11, emit_signal=False)

    # Try to zoom out below minimum
    # Mock position to be at center of widget
    event = Mock()
    event.angleDelta.return_value = Mock(y=Mock(return_value=-120))
    event.position.return_value = Mock(
        x=Mock(return_value=widget.width() / 2),
        y=Mock(return_value=widget.height() / 2),
    )
    widget.wheelEvent(event)

    # Should clamp at 0.1
    assert widget.zoom_level == pytest.approx(0.1, rel=0.01)


def test_zoom_clamps_at_maximum(qapp, portrait_image):
    """Test that zoom level clamps at 10.0x maximum."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Set zoom to near maximum
    widget.set_zoom(9.5, emit_signal=False)

    # Try to zoom in above maximum
    # Mock position to be at center of widget
    event = Mock()
    event.angleDelta.return_value = Mock(y=Mock(return_value=120))
    event.position.return_value = Mock(
        x=Mock(return_value=widget.width() / 2),
        y=Mock(return_value=widget.height() / 2),
    )
    widget.wheelEvent(event)

    # Should clamp at 4.0 (400% max zoom)
    assert widget.zoom_level == pytest.approx(4.0, rel=0.01)


def test_set_zoom_updates_level(qapp, portrait_image):
    """Test that set_zoom() updates the zoom level and exits fit mode."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    assert widget.fit_mode is True  # starts in fit mode

    widget.set_zoom(2.5, emit_signal=False)
    assert widget.zoom_level == 2.5
    assert widget.fit_mode is False  # exited fit mode

    widget.set_zoom(0.5, emit_signal=False)
    assert widget.zoom_level == 0.5
    assert widget.fit_mode is False


# Pan Functionality Tests


def test_pan_mouse_press_captures_position(qapp, portrait_image):
    """Test that mouse press captures the starting position."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Simulate mouse press
    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.pos.return_value = QPoint(100, 150)
    event.modifiers.return_value = Qt.KeyboardModifier.NoModifier

    widget.mousePressEvent(event)

    assert widget.last_mouse_pos == QPoint(100, 150)


def test_pan_mouse_move_updates_offset(qapp, portrait_image):
    """Test that mouse move updates pan offset."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=False)

    # Fit mode ignores pan entirely (dragging while fitted is a no-op), so
    # exit fit mode to exercise panning, as a user would after zooming in.
    widget.fit_mode = False

    # Start pan at (100, 100)
    widget.last_mouse_pos = QPoint(100, 100)

    # Initial offset is (0, 0)
    assert widget.pan_offset == QPoint(0, 0)

    # Simulate mouse move to (120, 130) - delta of (20, 30)
    event = Mock()
    event.pos.return_value = QPoint(120, 130)

    widget.mouseMoveEvent(event)

    # Pan offset should be (0, 0) + (20, 30) = (20, 30)
    assert widget.pan_offset.x() == 20
    assert widget.pan_offset.y() == 30
    assert widget.last_mouse_pos == QPoint(120, 130)


def test_pan_mouse_release_clears_tracking(qapp, portrait_image):
    """Test that mouse release clears position tracking."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Set up tracking
    widget.last_mouse_pos = QPoint(100, 100)

    # Simulate mouse release
    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton

    widget.mouseReleaseEvent(event)

    assert widget.last_mouse_pos is None


def test_pan_only_works_with_left_button(qapp, portrait_image):
    """Test that pan only activates with left mouse button."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Try to start pan with right button
    event = Mock()
    event.button.return_value = Qt.MouseButton.RightButton
    event.pos.return_value = QPoint(100, 100)

    widget.mousePressEvent(event)

    # Should not capture position
    assert widget.last_mouse_pos is None


def test_set_pan_updates_offset(qapp, portrait_image):
    """Test that set_pan() updates the pan offset."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    widget.set_pan(50, 75, emit_signal=False)
    assert widget.pan_offset == QPoint(50, 75)

    widget.set_pan(-20, 100, emit_signal=False)
    assert widget.pan_offset == QPoint(-20, 100)


# Synchronization Signal Tests


def test_zoom_signal_emitted_when_synchronized(qapp, portrait_image):
    """Test that zoom_changed signal is emitted when synchronized=True."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)

    # Connect signal spy
    signal_received = []
    widget.zoom_changed.connect(lambda level: signal_received.append(level))

    # Change zoom
    widget.set_zoom(2.0, emit_signal=True)

    # Signal should be emitted
    assert len(signal_received) == 1
    assert signal_received[0] == 2.0


def test_zoom_signal_emitted_when_not_synchronized(qapp, portrait_image):
    """Test that zoom_changed is emitted even when synchronized=False.

    Needed so the zoom% overlay label updates on wheel/pinch/double-click
    zoom in single-image mode (synchronized=False) - see ViewingArea's
    zoom_overlay.update_zoom_label connection. Only emit_signal=False (used
    by SynchronizedViewController to prevent broadcast feedback loops)
    suppresses the signal, not the synchronized flag.
    """
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=False)

    # Connect signal spy
    signal_received = []
    widget.zoom_changed.connect(lambda level: signal_received.append(level))

    # Change zoom
    widget.set_zoom(2.0, emit_signal=True)

    # Signal should be emitted
    assert len(signal_received) == 1
    assert signal_received[0] == 2.0


def test_zoom_signal_not_emitted_when_emit_false(qapp, portrait_image):
    """Test that zoom_changed signal respects emit_signal parameter."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)

    # Connect signal spy
    signal_received = []
    widget.zoom_changed.connect(lambda level: signal_received.append(level))

    # Change zoom with emit_signal=False
    widget.set_zoom(2.0, emit_signal=False)

    # Signal should NOT be emitted
    assert len(signal_received) == 0


def test_pan_signal_emitted_when_synchronized(qapp, portrait_image):
    """Test that pan_changed signal is emitted when synchronized=True."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)

    # Connect signal spy
    signal_received = []
    widget.pan_changed.connect(lambda x, y: signal_received.append((x, y)))

    # Change pan
    widget.set_pan(50, 100, emit_signal=True)

    # Signal should be emitted
    assert len(signal_received) == 1
    assert signal_received[0] == (50, 100)


def test_pan_signal_not_emitted_when_not_synchronized(qapp, portrait_image):
    """Test that pan_changed signal is NOT emitted when synchronized=False."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=False)

    # Connect signal spy
    signal_received = []
    widget.pan_changed.connect(lambda x, y: signal_received.append((x, y)))

    # Change pan
    widget.set_pan(50, 100, emit_signal=True)

    # Signal should NOT be emitted
    assert len(signal_received) == 0


def test_pan_signal_not_emitted_when_emit_false(qapp, portrait_image):
    """Test that pan_changed signal respects emit_signal parameter."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)

    # Connect signal spy
    signal_received = []
    widget.pan_changed.connect(lambda x, y: signal_received.append((x, y)))

    # Change pan with emit_signal=False
    widget.set_pan(50, 100, emit_signal=False)

    # Signal should NOT be emitted
    assert len(signal_received) == 0


# StatusOverlay Tests


def test_status_overlay_initialization(qapp, portrait_image):
    """Test that StatusOverlay initializes correctly."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    assert overlay.path == portrait_image
    assert overlay.session == session


def test_status_overlay_has_three_buttons(qapp, portrait_image):
    """Test that StatusOverlay has keep, reject, and clear buttons."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    assert overlay.btn_keeper is not None
    assert "Space" in overlay.btn_keeper.toolTip()

    assert overlay.btn_delete is not None
    assert "(x)" in overlay.btn_delete.toolTip()

    assert overlay.btn_clear is not None
    assert "(c)" in overlay.btn_clear.toolTip()


def test_status_overlay_mark_keeper_requests_status(qapp, portrait_image):
    """Test that the K button requests keeper status without mutating."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    received = []
    overlay.mark_requested.connect(received.append)

    overlay.mark_keeper()

    # The overlay only requests; applying the mark is the controller's job
    assert received == [PhotoStatus.KEEPER]
    assert session.get_status(portrait_image) == PhotoStatus.UNMARKED


def test_status_overlay_mark_delete_requests_status(qapp, portrait_image):
    """Test that the D button requests delete status without mutating."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    received = []
    overlay.mark_requested.connect(received.append)

    overlay.mark_delete()

    assert received == [PhotoStatus.DELETE]
    assert session.get_status(portrait_image) == PhotoStatus.UNMARKED


def test_status_overlay_clear_requests_unmarked(qapp, portrait_image):
    """Test that the clear button requests unmarked status."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)
    session.set_status(portrait_image, PhotoStatus.KEEPER)

    received = []
    overlay.mark_requested.connect(received.append)

    overlay.clear_status()

    assert received == [PhotoStatus.UNMARKED]
    assert session.get_status(portrait_image) == PhotoStatus.KEEPER


def test_status_overlay_emits_request_per_button(qapp, portrait_image):
    """Test that each button press emits one mark request."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    received = []
    overlay.mark_requested.connect(received.append)

    overlay.mark_keeper()
    overlay.mark_delete()
    overlay.clear_status()

    assert received == [PhotoStatus.KEEPER, PhotoStatus.DELETE, PhotoStatus.UNMARKED]


def test_status_overlay_appearance_keeper(qapp, portrait_image):
    """Test that keeper status highlights K button with green."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    # Mark as keeper
    session.set_status(portrait_image, PhotoStatus.KEEPER)
    overlay.update_appearance()

    # Check keeper button has green background
    assert "#4CAF50" in overlay.btn_keeper.styleSheet()
    assert "color: white" in overlay.btn_keeper.styleSheet()


def test_status_overlay_appearance_delete(qapp, portrait_image):
    """Test that delete status highlights D button with red."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    # Mark as delete
    session.set_status(portrait_image, PhotoStatus.DELETE)
    overlay.update_appearance()

    # Check delete button has red background
    assert "#F44336" in overlay.btn_delete.styleSheet()
    assert "color: white" in overlay.btn_delete.styleSheet()


def test_status_overlay_appearance_unmarked(qapp, portrait_image):
    """Test that unmarked status has no button highlighting."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    # Ensure unmarked
    session.set_status(portrait_image, PhotoStatus.UNMARKED)
    overlay.update_appearance()

    # Check buttons have default white background styling
    assert "background-color: white" in overlay.btn_keeper.styleSheet()
    assert "background-color: white" in overlay.btn_delete.styleSheet()
    assert "background-color: white" in overlay.btn_clear.styleSheet()


def test_status_overlay_appearance_updates_on_change(qapp, portrait_image):
    """Test that appearance updates when status changes."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    overlay = StatusOverlay(portrait_image, session)

    # Start unmarked - should have default white background
    assert "background-color: white" in overlay.btn_keeper.styleSheet()
    assert "background-color: white" in overlay.btn_delete.styleSheet()

    # Change to keeper - keeper highlighted green, others white
    session.set_status(portrait_image, PhotoStatus.KEEPER)
    overlay.update_appearance()
    assert "#4CAF50" in overlay.btn_keeper.styleSheet()
    assert "background-color: white" in overlay.btn_delete.styleSheet()
    assert "#4CAF50" not in overlay.btn_delete.styleSheet()

    # Change to delete - delete highlighted red, others white
    session.set_status(portrait_image, PhotoStatus.DELETE)
    overlay.update_appearance()
    assert "background-color: white" in overlay.btn_keeper.styleSheet()
    assert "#F44336" in overlay.btn_delete.styleSheet()
    assert "#F44336" not in overlay.btn_keeper.styleSheet()

    # Clear status - all buttons back to white
    session.set_status(portrait_image, PhotoStatus.UNMARKED)
    overlay.update_appearance()
    assert "background-color: white" in overlay.btn_keeper.styleSheet()
    assert "background-color: white" in overlay.btn_delete.styleSheet()
    assert "#4CAF50" not in overlay.btn_keeper.styleSheet()
    assert "#F44336" not in overlay.btn_delete.styleSheet()


# Integration Tests


def test_image_widget_relays_mark_request_with_path(qapp, portrait_image):
    """Test that ImageWidget tags overlay requests with its path."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    received = []
    widget.mark_requested.connect(lambda path, status: received.append((path, status)))

    widget.overlay.mark_keeper()

    assert received == [(portrait_image, PhotoStatus.KEEPER)]


def test_overlay_button_click_reaches_viewing_area_signal(qapp, portrait_image):
    """Test that a button click surfaces as a ViewingArea mark request.

    Application of the request is the keyboard controller's job; the full
    pipeline is covered in test_keyboard_shortcuts.TestOverlayButtons.
    """
    from winnow.ui.viewing_area import ViewingArea

    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])

    received = []
    viewing_area.mark_requested.connect(
        lambda path, status: received.append((path, status))
    )

    viewing_area.image_widgets[0].overlay.btn_keeper.click()

    assert received == [(portrait_image, PhotoStatus.KEEPER)]
    assert session.get_status(portrait_image) == PhotoStatus.UNMARKED


def test_image_widget_with_different_images(qapp, portrait_image, landscape_image):
    """Test that overlay appearances track their own photo independently."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )

    widget1 = ImageWidget(portrait_image, session)
    widget2 = ImageWidget(landscape_image, session)

    session.set_status(portrait_image, PhotoStatus.KEEPER)
    widget1.overlay.update_appearance()
    widget2.overlay.update_appearance()

    assert "#4CAF50" in widget1.overlay.btn_keeper.styleSheet()
    assert "background-color: white" in widget2.overlay.btn_keeper.styleSheet()
    assert "#4CAF50" not in widget2.overlay.btn_keeper.styleSheet()


# Double-Click Zoom Tests


def test_double_click_from_fit_zooms_to_100(qapp, portrait_image):
    """Test that double-click from fit mode zooms to 100%."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)
    widget.resize(800, 600)

    assert widget.fit_mode is True

    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.modifiers.return_value = Qt.KeyboardModifier.NoModifier
    event.position.return_value = Mock(
        x=Mock(return_value=400.0), y=Mock(return_value=300.0)
    )

    widget.mouseDoubleClickEvent(event)

    assert widget.fit_mode is False
    assert widget.zoom_level == pytest.approx(1.0, rel=0.01)


def test_double_click_when_zoomed_returns_to_fit(qapp, portrait_image):
    """Test that double-click when zoomed returns to fit mode."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)
    widget.resize(800, 600)

    widget.set_zoom(2.0, emit_signal=False)
    assert widget.fit_mode is False

    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.modifiers.return_value = Qt.KeyboardModifier.NoModifier
    event.position.return_value = Mock(
        x=Mock(return_value=400.0), y=Mock(return_value=300.0)
    )

    widget.mouseDoubleClickEvent(event)

    assert widget.fit_mode is True


def test_double_click_ctrl_ignored(qapp, portrait_image):
    """Test that Ctrl+double-click is ignored (no zoom change)."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    assert widget.fit_mode is True

    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.modifiers.return_value = Qt.KeyboardModifier.ControlModifier

    widget.mouseDoubleClickEvent(event)

    assert widget.fit_mode is True


def test_shift_double_click_no_zoom_signal(qapp, portrait_image):
    """Test that Shift+double-click does not emit zoom_changed signal."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)
    widget.resize(800, 600)

    zoom_signals = []
    widget.zoom_changed.connect(lambda z: zoom_signals.append(z))

    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.modifiers.return_value = Qt.KeyboardModifier.ShiftModifier
    event.position.return_value = Mock(
        x=Mock(return_value=400.0), y=Mock(return_value=300.0)
    )

    widget.mouseDoubleClickEvent(event)

    assert len(zoom_signals) == 0
    assert widget.fit_mode is False
    assert widget.zoom_level == pytest.approx(1.0, rel=0.01)


def test_shift_double_click_adjusts_individual_pan_not_shared(qapp, portrait_image):
    """Test that Shift+double-click adjusts individual_pan_offset, not pan_offset."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session, synchronized=True)
    # Small widget so fit scale < 1.0, ensuring old_zoom != new_zoom
    widget.resize(50, 50)

    initial_pan = QPoint(widget.pan_offset.x(), widget.pan_offset.y())

    # Click off-center (35px right, 30px down — offset from center of 50x50)
    event = Mock()
    event.button.return_value = Qt.MouseButton.LeftButton
    event.modifiers.return_value = Qt.KeyboardModifier.ShiftModifier
    event.position.return_value = Mock(
        x=Mock(return_value=35.0), y=Mock(return_value=30.0)
    )

    widget.mouseDoubleClickEvent(event)

    # Shared pan_offset must be unchanged
    assert widget.pan_offset == initial_pan
    # Individual pan offset should have been adjusted for the off-center cursor
    assert widget.individual_pan_offset != QPoint(0, 0)


def test_image_widget_resize_updates_display(qapp, portrait_image):
    """Test that resize event triggers display update."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    widget = ImageWidget(portrait_image, session)

    # Resize widget
    widget.resize(800, 600)

    # Display should update (pixmap may change size due to scaling)
    # We can't directly test that update_display was called, but we can
    # verify the widget accepted the resize
    assert widget.width() == 800
    assert widget.height() == 600
