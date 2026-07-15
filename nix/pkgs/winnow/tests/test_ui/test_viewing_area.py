"""Tests for the ViewingArea widget."""

import pytest
from PySide6.QtCore import QPoint
from PySide6.QtGui import QPixmap

from winnow.core.image_cache import ImageCache
from winnow.core.session import Session
from winnow.ui.image_widget import ImageWidget
from winnow.ui.viewing_area import ViewingArea, ZoomControlOverlay


def test_viewing_area_initial_state(qapp, tmp_path):
    """Test that ViewingArea shows empty label initially."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    # Empty label should not be hidden initially (it's the default state)
    assert not viewing_area.empty_label.isHidden()
    assert viewing_area.empty_label.text() == "Select photos from thumbnails below"


def test_viewing_area_set_images_empty_list(qapp, tmp_path):
    """Test that set_images with empty list shows empty label."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    # Hide the label first, then call with empty list to show it
    viewing_area.empty_label.hide()
    viewing_area.set_images([])

    # Empty label should not be hidden
    assert not viewing_area.empty_label.isHidden()


def test_viewing_area_set_images_single_path(qapp, portrait_image):
    """Test that set_images with single path hides empty label."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Call with single path
    viewing_area.set_images([portrait_image])

    # Empty label should be hidden
    assert viewing_area.empty_label.isHidden()


def test_viewing_area_set_images_multiple_paths(qapp, portrait_image, landscape_image):
    """Test that set_images with multiple paths hides empty label."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Create third test path
    path3 = portrait_image.parent / "photo3.jpg"

    # Call with multiple paths
    viewing_area.set_images([portrait_image, landscape_image, path3])

    # Empty label should be hidden
    assert viewing_area.empty_label.isHidden()


def test_viewing_area_toggle_visibility(qapp, portrait_image):
    """Test that toggling between empty and non-empty works correctly."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Start with label not hidden
    assert not viewing_area.empty_label.isHidden()

    # Hide with path
    viewing_area.set_images([portrait_image])
    assert viewing_area.empty_label.isHidden()

    # Show again with empty list
    viewing_area.set_images([])
    assert not viewing_area.empty_label.isHidden()

    # Hide again
    viewing_area.set_images([portrait_image])
    assert viewing_area.empty_label.isHidden()


def test_viewing_area_creates_image_widget_for_single_path(qapp, portrait_image):
    """Test that set_images with single path creates ImageWidget in layout."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Call with single path
    viewing_area.set_images([portrait_image])

    # Check that image_widgets list has one widget
    assert len(viewing_area.image_widgets) == 1
    assert isinstance(viewing_area.image_widgets[0], ImageWidget)
    assert viewing_area.image_widgets[0].path == portrait_image
    assert viewing_area.image_widgets[0].session == session

    # Check empty label is hidden
    assert viewing_area.empty_label.isHidden()


def test_viewing_area_clears_widget_on_selection_change(
    qapp, portrait_image, landscape_image
):
    """Test that old widget is cleared when selection changes."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Set first image
    viewing_area.set_images([portrait_image])
    assert len(viewing_area.image_widgets) == 1
    first_widget = viewing_area.image_widgets[0]
    assert first_widget.path == portrait_image

    # Set different image
    viewing_area.set_images([landscape_image])
    assert len(viewing_area.image_widgets) == 1
    second_widget = viewing_area.image_widgets[0]
    assert second_widget.path == landscape_image
    assert second_widget is not first_widget

    # Set empty list - should clear widget list and show empty label
    viewing_area.set_images([])
    assert len(viewing_area.image_widgets) == 0
    assert not viewing_area.empty_label.isHidden()


# Background-Decode Wiring Tests (ImageCache present, as in the real app)


def test_on_image_ready_updates_widget_after_background_decode(
    qapp, qtbot, portrait_image
):
    """on_image_ready swaps the real pixmap into the widget once decoding lands.

    Mirrors how MainWindow wires ImageCache.image_ready to this method (see
    MainWindow._start_image_loading) - here done manually since MainWindow
    only creates the cache once the window is shown.
    """
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    session.image_cache = ImageCache()

    viewing_area = ViewingArea(session)
    session.image_cache.image_ready.connect(viewing_area.on_image_ready)

    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]

    # Cache miss on construction - showing a placeholder, decode pending.
    assert widget._pending_full_load is True

    qtbot.waitUntil(lambda: not widget._pending_full_load, timeout=2000)

    assert widget.has_valid_image()
    assert widget.original_pixmap.width() == 100
    assert widget.original_pixmap.height() == 200


def test_on_image_ready_ignores_path_no_longer_displayed(
    qapp, qtbot, portrait_image, landscape_image
):
    """A decode landing for a path that isn't currently displayed is a no-op.

    Delivers the decode directly (put() + on_image_ready()) rather than
    racing a real background task, so the "not displayed" case is exercised
    deterministically. The session holds only landscape_image, so
    set_images has no neighbor to prefetch - portrait_image is used purely
    as an arbitrary path that isn't part of this session's display at all,
    keeping the only real background decode the one for landscape itself.
    """
    session = Session(directory=landscape_image.parent, images=[landscape_image])
    session.image_cache = ImageCache()

    viewing_area = ViewingArea(session)
    viewing_area.set_images([landscape_image])
    widget = viewing_area.image_widgets[0]
    original = widget.original_pixmap

    # Manually deliver a decode for portrait, which isn't displayed.
    session.image_cache.put(portrait_image, QPixmap(str(portrait_image)))
    viewing_area.on_image_ready(portrait_image)

    # The displayed (landscape) widget is untouched.
    assert widget.original_pixmap is original

    # Drain landscape's own background decode request so nothing is left
    # in flight past this test. Nothing is connected to image_ready here
    # (this test only exercises on_image_ready's no-op path directly), so
    # the widget's own _pending_full_load never clears - wait on the cache
    # instead of the widget.
    qtbot.waitUntil(
        lambda: session.image_cache.get(landscape_image) is not None, timeout=2000
    )


def test_on_image_load_failed_shows_placeholder(qapp, qtbot, tmp_path):
    """on_image_load_failed shows the failed-to-load placeholder on the matching widget."""
    corrupt = tmp_path / "corrupt.jpg"
    corrupt.write_bytes(b"not a real jpeg")

    session = Session(directory=tmp_path, images=[corrupt])
    session.image_cache = ImageCache()

    viewing_area = ViewingArea(session)
    session.image_cache.load_failed.connect(viewing_area.on_image_load_failed)

    viewing_area.set_images([corrupt])
    widget = viewing_area.image_widgets[0]

    qtbot.waitUntil(lambda: not widget.has_valid_image(), timeout=2000)
    assert "Unable to load image" in widget.image_label.text()


def test_calculate_grid_layout_zero_photos(qapp, tmp_path):
    """Test grid layout with zero photos returns empty list."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(0)

    assert layout == []
    assert isinstance(layout, list)


def test_calculate_grid_layout_one_photo(qapp, tmp_path):
    """Test grid layout with one photo returns single position."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(1)

    assert layout == [(0, 0)]
    assert len(layout) == 1


def test_calculate_grid_layout_two_photos(qapp, tmp_path):
    """Test grid layout with two photos returns 1x2 horizontal layout."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(2)

    assert layout == [(0, 0), (0, 1)]
    assert len(layout) == 2


def test_calculate_grid_layout_three_photos(qapp, tmp_path):
    """Test grid layout with three photos returns 1x3 horizontal layout."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(3)

    assert layout == [(0, 0), (0, 1), (0, 2)]
    assert len(layout) == 3


def test_calculate_grid_layout_four_photos(qapp, tmp_path):
    """Test grid layout with four photos returns 2x2 grid layout."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(4)

    assert layout == [(0, 0), (0, 1), (1, 0), (1, 1)]
    assert len(layout) == 4


def test_calculate_grid_layout_five_photos(qapp, tmp_path):
    """Test grid layout with five photos returns dynamic grid with rows of 3."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(5)

    assert layout == [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1)]
    assert len(layout) == 5


def test_calculate_grid_layout_six_photos(qapp, tmp_path):
    """Test grid layout with six photos returns 2 rows of 3."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(6)

    assert layout == [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2)]
    assert len(layout) == 6


def test_calculate_grid_layout_seven_photos(qapp, tmp_path):
    """Test grid layout with seven photos continues pattern (3 rows) with centered last row."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(7)

    # Last row (1 photo) should be centered at column 1
    expected = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (2, 1)]
    assert layout == expected
    assert len(layout) == 7


def test_calculate_grid_layout_eight_photos(qapp, tmp_path):
    """Test grid layout with eight photos continues pattern."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(8)

    expected = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (2, 0), (2, 1)]
    assert layout == expected
    assert len(layout) == 8


def test_calculate_grid_layout_nine_photos(qapp, tmp_path):
    """Test grid layout with nine photos returns 3x3 grid."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    layout = viewing_area.calculate_grid_layout(9)

    expected = [
        (0, 0),
        (0, 1),
        (0, 2),
        (1, 0),
        (1, 1),
        (1, 2),
        (2, 0),
        (2, 1),
        (2, 2),
    ]
    assert layout == expected
    assert len(layout) == 9


# ZoomControlOverlay Tests


def test_zoom_overlay_initializes(qapp, tmp_path):
    """Test that ZoomControlOverlay initializes with correct buttons."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    # Check overlay exists
    assert viewing_area.zoom_overlay is not None
    assert isinstance(viewing_area.zoom_overlay, ZoomControlOverlay)

    # Check buttons exist
    assert viewing_area.zoom_overlay.btn_zoom_100 is not None
    assert viewing_area.zoom_overlay.btn_zoom_fit is not None

    # Check button labels
    assert viewing_area.zoom_overlay.btn_zoom_100.text() == "100%"
    assert viewing_area.zoom_overlay.btn_zoom_fit.text() == "Fit"


def test_zoom_overlay_hidden_when_no_images(qapp, tmp_path):
    """Test that zoom overlay is hidden when no images are displayed."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    # Initially hidden
    assert viewing_area.zoom_overlay.isHidden()

    # Still hidden after setting empty list
    viewing_area.set_images([])
    assert viewing_area.zoom_overlay.isHidden()


def test_zoom_overlay_visible_with_single_image(qapp, portrait_image):
    """Test that zoom overlay is visible when single image is displayed."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Set single image
    viewing_area.set_images([portrait_image])

    # Overlay should be visible
    assert not viewing_area.zoom_overlay.isHidden()


def test_zoom_overlay_visible_with_multiple_images(
    qapp, portrait_image, landscape_image
):
    """Test that zoom overlay is visible in comparison mode."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Set multiple images
    viewing_area.set_images([portrait_image, landscape_image])

    # Overlay should be visible
    assert not viewing_area.zoom_overlay.isHidden()


def test_zoom_overlay_positioned_bottom_right(qapp, portrait_image):
    """Test that zoom overlay is positioned at bottom-right corner."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Show and resize the widget so it has a real size
    viewing_area.show()
    viewing_area.resize(800, 600)

    # Set image to show overlay
    viewing_area.set_images([portrait_image])

    # Process pending events to ensure layout is updated
    qapp.processEvents()

    # Check position is bottom-right (with 10px margin)
    expected_x = 800 - viewing_area.zoom_overlay.width() - 10
    expected_y = 600 - viewing_area.zoom_overlay.height() - 10

    assert viewing_area.zoom_overlay.x() == expected_x
    assert viewing_area.zoom_overlay.y() == expected_y


def test_zoom_to_fit_button_enters_fit_mode(qapp, portrait_image):
    """Test that Fit button enters fit_mode on all widgets."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Set image
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]

    # Set an explicit zoom level (exits fit mode)
    widget.set_zoom(2.5, emit_signal=False)
    assert widget.zoom_level == pytest.approx(2.5)
    assert widget.fit_mode is False

    # Click Fit button
    viewing_area.zoom_overlay.btn_zoom_fit.click()

    # Widget should be in fit mode
    assert widget.fit_mode is True


def test_zoom_to_100_button_applies_zoom(qapp, portrait_image):
    """Test that 100% button sets zoom_level=1.0 and exits fit mode."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Set image
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]

    # Widget starts in fit mode
    assert widget.fit_mode is True

    # Click 100% button
    viewing_area.zoom_overlay.btn_zoom_100.click()

    # Should be at 100% zoom (1.0) with fit mode off
    assert widget.zoom_level == pytest.approx(1.0)
    assert widget.fit_mode is False


def test_zoom_buttons_work_comparison_mode(qapp, portrait_image, landscape_image):
    """Test that zoom buttons work in comparison mode with multiple widgets."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Set multiple images
    viewing_area.set_images([portrait_image, landscape_image])

    # Should have 2 widgets
    assert len(viewing_area.image_widgets) == 2

    # Set different zoom on both
    for widget in viewing_area.image_widgets:
        widget.set_zoom(3.0, emit_signal=False)

    # Click Fit button
    viewing_area.zoom_overlay.btn_zoom_fit.click()

    # Both should be in fit mode
    for widget in viewing_area.image_widgets:
        assert widget.fit_mode is True

    # Click 100% button
    viewing_area.zoom_overlay.btn_zoom_100.click()

    # Both should be at 1.0 zoom with fit mode off
    for widget in viewing_area.image_widgets:
        assert widget.zoom_level == pytest.approx(1.0)
        assert widget.fit_mode is False


def test_zoom_buttons_handle_empty_widgets(qapp, tmp_path):
    """Test that zoom buttons do nothing when no widgets are present."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    # No images set
    assert len(viewing_area.image_widgets) == 0

    # Clicking buttons should not crash
    viewing_area.zoom_overlay.btn_zoom_fit.click()
    viewing_area.zoom_overlay.btn_zoom_100.click()


def test_overlay_position_updates_on_resize(qapp, portrait_image):
    """Test that overlay position updates when ViewingArea is resized."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Show widget and set initial size
    viewing_area.show()
    viewing_area.resize(800, 600)

    # Set image to show overlay
    viewing_area.set_images([portrait_image])
    qapp.processEvents()

    # Check initial position
    expected_x_1 = 800 - viewing_area.zoom_overlay.width() - 10
    expected_y_1 = 600 - viewing_area.zoom_overlay.height() - 10
    assert viewing_area.zoom_overlay.x() == expected_x_1
    assert viewing_area.zoom_overlay.y() == expected_y_1

    # Resize viewing area
    viewing_area.resize(1024, 768)
    qapp.processEvents()

    # Position should update
    expected_x_2 = 1024 - viewing_area.zoom_overlay.width() - 10
    expected_y_2 = 768 - viewing_area.zoom_overlay.height() - 10
    assert viewing_area.zoom_overlay.x() == expected_x_2
    assert viewing_area.zoom_overlay.y() == expected_y_2


# ---------------------------------------------------------------------------
# Pan (group) and align (single-tile) keyboard nudges
#
# Direction sign is verified empirically, not just by re-deriving the crop
# formula here: a left/right (and separately top/bottom) split-color image
# rendered through the real widget confirms dx=+1/dy=+1 reveal more of the
# right/bottom of the image, which is what these tests assert on pan_offset.
# ---------------------------------------------------------------------------


def test_pan_group_no_op_with_no_widgets(qapp, tmp_path):
    """pan_group does nothing (and does not crash) with nothing displayed."""
    session = Session(directory=tmp_path, images=[])
    viewing_area = ViewingArea(session)

    viewing_area.pan_group(dx=1, dy=0)  # should not raise


def test_pan_group_no_op_in_fit_mode(qapp, portrait_image):
    """Panning is a no-op while fit mode is active, matching mouse-drag panning."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]
    assert widget.fit_mode is True

    viewing_area.pan_group(dx=1, dy=0)

    assert widget.pan_offset == QPoint(0, 0)


def test_pan_group_moves_pan_offset_in_the_revealed_direction(qapp, portrait_image):
    """dx=+1/-1 and dy=+1/-1 reveal right/left and bottom/top respectively."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]
    widget.resize(40, 40)
    widget.set_zoom(1.0, emit_signal=False)

    viewing_area.pan_group(dx=1, dy=0)
    assert widget.pan_offset.x() < 0
    assert widget.pan_offset.y() == 0

    widget.set_pan(0, 0, emit_signal=False)
    viewing_area.pan_group(dx=-1, dy=0)
    assert widget.pan_offset.x() > 0

    widget.set_pan(0, 0, emit_signal=False)
    viewing_area.pan_group(dx=0, dy=1)
    assert widget.pan_offset.y() < 0

    widget.set_pan(0, 0, emit_signal=False)
    viewing_area.pan_group(dx=0, dy=-1)
    assert widget.pan_offset.y() > 0


def test_pan_group_applies_same_delta_to_every_comparison_tile(
    qapp, portrait_image, landscape_image
):
    """Group panning keeps every tile's shared pan_offset identical."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image, landscape_image])
    for widget in viewing_area.image_widgets:
        widget.set_zoom(1.0, emit_signal=False)

    viewing_area.pan_group(dx=1, dy=1)

    offsets = {widget.pan_offset.toTuple() for widget in viewing_area.image_widgets}
    assert len(offsets) == 1
    first = viewing_area.image_widgets[0].pan_offset
    assert first != QPoint(0, 0)


def test_pan_group_step_scales_with_zoom(qapp, portrait_image):
    """A pan step covers the same on-screen distance at any zoom level."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]
    # 200px wide at 0.15 fraction gives an exactly-integer step at both zoom
    # levels below (30 and 15 original px), so this isolates the intended
    # zoom scaling from unrelated float-to-int rounding.
    widget.resize(200, 200)

    widget.set_zoom(1.0, emit_signal=False)
    viewing_area.pan_group(dx=1, dy=0)
    delta_at_1x = widget.pan_offset.x()

    widget.set_pan(0, 0, emit_signal=False)
    widget.set_zoom(2.0, emit_signal=False)
    viewing_area.pan_group(dx=1, dy=0)
    delta_at_2x = widget.pan_offset.x()

    # On-screen distance = delta_orig * zoom_level; equal on-screen distance
    # at every zoom means this product stays constant.
    assert delta_at_1x * 1.0 == pytest.approx(delta_at_2x * 2.0)


def test_align_focused_no_op_outside_comparison(qapp, portrait_image):
    """align_focused does nothing with fewer than two tiles displayed."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]
    widget.set_zoom(1.0, emit_signal=False)

    viewing_area.align_focused(dx=1, dy=0)

    assert widget.individual_pan_offset == QPoint(0, 0)


def test_align_focused_no_op_in_fit_mode(qapp, portrait_image, landscape_image):
    """Aligning the focused tile is a no-op while it is still in fit mode."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image, landscape_image])
    assert viewing_area.image_widgets[0].fit_mode is True

    viewing_area.align_focused(dx=1, dy=0)

    assert viewing_area.image_widgets[0].individual_pan_offset == QPoint(0, 0)


def test_align_focused_only_touches_the_focused_tile(
    qapp, portrait_image, landscape_image
):
    """Aligning nudges only the focused tile's individual offset, leaving the shared pan and other tiles untouched."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image, landscape_image])
    for widget in viewing_area.image_widgets:
        widget.set_zoom(1.0, emit_signal=False)
    viewing_area.set_focused_index(1)

    viewing_area.align_focused(dx=1, dy=0)

    focused = viewing_area.image_widgets[1]
    other = viewing_area.image_widgets[0]
    assert focused.individual_pan_offset != QPoint(0, 0)
    assert other.individual_pan_offset == QPoint(0, 0)
    assert focused.pan_offset == QPoint(0, 0)
    assert other.pan_offset == QPoint(0, 0)


def test_reset_focused_alignment_zeroes_the_offset(
    qapp, portrait_image, landscape_image
):
    """Ctrl+0 snaps the focused tile's alignment back to the group."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image, landscape_image])
    widget = viewing_area.image_widgets[0]
    widget.set_zoom(1.0, emit_signal=False)
    widget.individual_pan_offset = QPoint(37, -12)

    viewing_area.reset_focused_alignment()

    assert widget.individual_pan_offset == QPoint(0, 0)


def test_reset_focused_alignment_no_op_outside_comparison(qapp, portrait_image):
    """Reset does nothing with a single displayed photo."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)
    viewing_area.set_images([portrait_image])
    widget = viewing_area.image_widgets[0]
    widget.individual_pan_offset = QPoint(5, 5)

    viewing_area.reset_focused_alignment()

    assert widget.individual_pan_offset == QPoint(5, 5)
