"""Tests for the MainWindow widget."""

import pytest
from PySide6.QtCore import Qt
from PySide6.QtGui import QMouseEvent, QPointingDevice
from PySide6.QtWidgets import QPushButton, QScrollArea, QSlider

from winnow.ui.main_window import MainWindow
from winnow.ui.thumbnail_strip import ThumbnailWidget


def test_main_window_initialization(qapp, tmp_path):
    """Test that MainWindow can be initialized with a directory."""
    # Create test directory with JPEG files
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()
    (test_dir / "photo2.jpg").touch()

    # Create MainWindow
    window = MainWindow(test_dir)

    # Verify window was created
    assert window is not None
    assert window.windowTitle() == f"Winnow - {test_dir.name}"


def test_main_window_creates_session(qapp, tmp_path):
    """Test that MainWindow creates a session with correct directory."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()
    (test_dir / "photo2.jpg").touch()

    window = MainWindow(test_dir)

    # Verify session was created with correct directory
    assert window.session is not None
    assert window.session.directory == test_dir


def test_main_window_session_contains_images(qapp, tmp_path):
    """Test that MainWindow session contains scanned images from directory."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo3 = test_dir / "photo3.JPG"
    photo1.touch()
    photo2.touch()
    photo3.touch()

    window = MainWindow(test_dir)

    # Verify session contains all JPEG files
    assert len(window.session.images) == 3
    assert photo1 in window.session.images
    assert photo2 in window.session.images
    assert photo3 in window.session.images


def test_main_window_has_viewing_area(qapp, tmp_path):
    """Test that MainWindow has a ViewingArea widget."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    window = MainWindow(test_dir)

    # Verify viewing area exists
    assert window.viewing_area is not None


def test_main_window_has_thumbnail_strip(qapp, tmp_path):
    """Test that MainWindow has a ThumbnailStrip widget."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    window = MainWindow(test_dir)

    # Verify thumbnail strip exists
    assert window.thumbnail_strip is not None


def test_main_window_with_empty_directory(qapp, tmp_path):
    """Test that MainWindow handles empty directory gracefully."""
    test_dir = tmp_path / "empty"
    test_dir.mkdir()

    window = MainWindow(test_dir)

    # Verify session was created with no images
    assert window.session is not None
    assert len(window.session.images) == 0


def test_main_window_ignores_non_jpeg_files(qapp, tmp_path):
    """Test that MainWindow session only includes JPEG files."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()
    (test_dir / "photo2.png").touch()  # Should be ignored
    (test_dir / "photo3.txt").touch()  # Should be ignored
    (test_dir / "photo4.jpeg").touch()

    window = MainWindow(test_dir)

    # Verify only JPEG files are in session
    assert len(window.session.images) == 2
    # Filenames should be sorted alphabetically
    assert window.session.images[0].name == "photo1.jpg"
    assert window.session.images[1].name == "photo4.jpeg"


def test_main_window_default_size(qapp, tmp_path):
    """Test that MainWindow has a reasonable default size."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    window = MainWindow(test_dir)

    # Verify default window size
    assert window.width() == 1200
    assert window.height() == 800


def test_thumbnail_strip_displays_thumbnails(qapp, portrait_image, landscape_image):
    """Test that ThumbnailStrip contains ThumbnailWidget instances for each image."""
    window = MainWindow(portrait_image.parent)

    # Find all ThumbnailWidget instances in the thumbnail strip
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)

    # Verify we have widgets for all images
    assert len(thumbnail_widgets) == len(window.session.images)

    # Verify each widget has a pixmap
    for widget in thumbnail_widgets:
        assert widget.pixmap() is not None
        assert not widget.pixmap().isNull()


def test_thumbnail_strip_has_control_bar(qapp, tmp_path):
    """Test that ThumbnailStrip has filter buttons and zoom slider."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()

    window = MainWindow(test_dir)

    # Find control bar elements
    buttons = window.thumbnail_strip.findChildren(QPushButton)
    sliders = window.thumbnail_strip.findChildren(QSlider)

    # Verify we have 3 filter buttons plus the sort-by-sharpness toggle
    assert len(buttons) == 4
    button_texts = [btn.text() for btn in buttons]
    assert "Unmarked" in button_texts
    assert "Keepers" in button_texts
    assert "Deletes" in button_texts
    assert "Sort: soft first" in button_texts

    # Verify buttons are enabled and checkable
    for btn in buttons:
        assert btn.isEnabled()
        assert btn.isCheckable()

    # Verify initial checked states match session defaults
    unmarked_btn = next(btn for btn in buttons if btn.text() == "Unmarked")
    keepers_btn = next(btn for btn in buttons if btn.text() == "Keepers")
    deletes_btn = next(btn for btn in buttons if btn.text() == "Deletes")
    sort_btn = next(btn for btn in buttons if btn.text() == "Sort: soft first")

    assert unmarked_btn.isChecked()  # Should be checked (show unmarked by default)
    assert keepers_btn.isChecked()  # Should be checked (show keepers by default)
    assert not deletes_btn.isChecked()  # Should be unchecked (hide deletes by default)
    assert not sort_btn.isChecked()  # Should be unchecked (capture order by default)

    # Verify we have a zoom slider
    assert len(sliders) == 1
    slider = sliders[0]
    assert slider.minimum() == 100
    assert slider.maximum() == 400
    assert slider.value() == 150
    assert slider.isEnabled()  # Slider should be enabled and functional


def test_filter_buttons_update_session_state(qapp, tmp_path):
    """Test filter buttons update session show_* flags when toggled."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()
    (test_dir / "photo2.jpg").touch()

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Verify initial state matches session defaults
    assert session.show_unmarked is True
    assert session.show_keepers is True
    assert session.show_deletes is False

    # Click unmarked button to toggle it off
    strip.unmarked_btn.click()
    assert session.show_unmarked is False
    assert not strip.unmarked_btn.isChecked()

    # Click unmarked button again to toggle it back on
    strip.unmarked_btn.click()
    assert session.show_unmarked is True
    assert strip.unmarked_btn.isChecked()

    # Click keepers button to toggle it off
    strip.keepers_btn.click()
    assert session.show_keepers is False
    assert not strip.keepers_btn.isChecked()

    # Click keepers button again to toggle it back on
    strip.keepers_btn.click()
    assert session.show_keepers is True
    assert strip.keepers_btn.isChecked()

    # Click deletes button to toggle it on (starts unchecked)
    strip.deletes_btn.click()
    assert session.show_deletes is True
    assert strip.deletes_btn.isChecked()

    # Click deletes button again to toggle it back off
    strip.deletes_btn.click()
    assert session.show_deletes is False
    assert not strip.deletes_btn.isChecked()


def test_filter_buttons_emit_signal(tmp_path, qtbot):
    """Test filter buttons emit filter_changed signal when clicked."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()

    window = MainWindow(test_dir)
    strip = window.thumbnail_strip

    # Test unmarked button emits signal
    with qtbot.waitSignal(strip.filter_changed, timeout=1000):
        strip.unmarked_btn.click()

    # Test keepers button emits signal
    with qtbot.waitSignal(strip.filter_changed, timeout=1000):
        strip.keepers_btn.click()

    # Test deletes button emits signal
    with qtbot.waitSignal(strip.filter_changed, timeout=1000):
        strip.deletes_btn.click()


def test_filter_buttons_independent_state(qapp, tmp_path):
    """Test that filter buttons maintain independent state."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Toggle unmarked off, verify others unchanged
    strip.unmarked_btn.click()
    assert session.show_unmarked is False
    assert session.show_keepers is True
    assert session.show_deletes is False

    # Toggle keepers off, verify others unchanged
    strip.keepers_btn.click()
    assert session.show_unmarked is False
    assert session.show_keepers is False
    assert session.show_deletes is False

    # Toggle deletes on, verify others unchanged
    strip.deletes_btn.click()
    assert session.show_unmarked is False
    assert session.show_keepers is False
    assert session.show_deletes is True


def test_thumbnail_strip_caches_thumbnails(
    qapp, qtbot, portrait_image, landscape_image
):
    """Test that session.thumbnails is populated with cached pixmaps."""
    window = MainWindow(portrait_image.parent)

    # Thumbnails decode asynchronously in the background - wait for all of
    # them to land before checking the cache.
    qtbot.waitUntil(
        lambda: len(window.session.thumbnails) == len(window.session.images),
        timeout=2000,
    )

    # Verify thumbnails are cached
    assert len(window.session.thumbnails) == len(window.session.images)

    # Verify each image has a cached thumbnail
    for image_path in window.session.images:
        assert image_path in window.session.thumbnails
        pixmap = window.session.thumbnails[image_path]
        assert pixmap is not None
        assert not pixmap.isNull()


def test_thumbnail_strip_horizontal_scroll(qapp, tmp_path):
    """Test that ThumbnailStrip has horizontal scroll area."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()

    window = MainWindow(test_dir)

    # Find scroll area
    scroll_areas = window.thumbnail_strip.findChildren(QScrollArea)
    assert len(scroll_areas) == 1

    scroll_area = scroll_areas[0]

    # Verify scroll policies
    from PySide6.QtCore import Qt

    # Horizontal scrollbar should be available when needed
    assert (
        scroll_area.horizontalScrollBarPolicy() == Qt.ScrollBarPolicy.ScrollBarAsNeeded
    )

    # Vertical scrollbar should be disabled
    assert (
        scroll_area.verticalScrollBarPolicy() == Qt.ScrollBarPolicy.ScrollBarAlwaysOff
    )


# Selection handling tests


def test_thumbnail_click_single_selection(qapp, portrait_image, landscape_image):
    """Test that clicking a thumbnail selects only that thumbnail."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only first image is selected
    assert len(window.session.selected) == 1
    assert window.session.selected[0] == first_widget.path

    # Verify first widget has blue selection border
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()


def test_thumbnail_click_replaces_selection(qapp, portrait_image, landscape_image):
    """Test that clicking different thumbnail replaces selection."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Click second thumbnail
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only second image is selected
    assert len(window.session.selected) == 1
    assert window.session.selected[0] == second_widget.path

    # Verify first widget no longer has selection border
    assert "border: 5px solid #2196F3" not in first_widget.styleSheet()

    # Verify second widget has selection border
    assert "border: 5px solid #2196F3" in second_widget.styleSheet()


def test_thumbnail_ctrl_click_multi_select(qapp, portrait_image, landscape_image):
    """Test that Ctrl+click adds to selection."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Ctrl+click second thumbnail
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify both images are selected
    assert len(window.session.selected) == 2
    assert first_widget.path in window.session.selected
    assert second_widget.path in window.session.selected

    # Verify both widgets have selection borders
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()
    assert "border: 5px solid #2196F3" in second_widget.styleSheet()


def test_thumbnail_ctrl_click_toggle_deselect(qapp, portrait_image, landscape_image):
    """Test that Ctrl+click on selected thumbnail deselects it."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Ctrl+click second thumbnail to add to selection
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    assert len(window.session.selected) == 2

    # Ctrl+click second thumbnail again to deselect it
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only first image is selected
    assert len(window.session.selected) == 1
    assert window.session.selected[0] == first_widget.path

    # Verify second widget no longer has selection border
    assert "border: 5px solid #2196F3" not in second_widget.styleSheet()


def test_thumbnail_shift_click_range_selection(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that Shift+click selects a range of thumbnails."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets (need at least 3 for range test)
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Shift+click third thumbnail
    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify all three thumbnails are selected
    assert len(window.session.selected) == 3
    assert first_widget.path in window.session.selected
    assert thumbnail_widgets[1].path in window.session.selected
    assert third_widget.path in window.session.selected

    # Verify all have selection borders
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()
    assert "border: 5px solid #2196F3" in thumbnail_widgets[1].styleSheet()
    assert "border: 5px solid #2196F3" in third_widget.styleSheet()


def test_thumbnail_shift_click_backwards_range(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that Shift+click works when selecting backwards (right to left)."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # Click third thumbnail
    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Shift+click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify all three thumbnails are selected
    assert len(window.session.selected) == 3
    assert first_widget.path in window.session.selected
    assert thumbnail_widgets[1].path in window.session.selected
    assert third_widget.path in window.session.selected


def test_thumbnail_shift_click_replaces_selection(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that Shift+click replaces previous selection with range."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Shift+click third thumbnail (should select range from first to third)
    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    assert len(window.session.selected) == 3

    # Now click just the second thumbnail (should replace range selection)
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only second thumbnail is now selected
    assert len(window.session.selected) == 1
    assert second_widget.path in window.session.selected

    # First and third widgets should no longer be selected
    assert first_widget.path not in window.session.selected
    assert third_widget.path not in window.session.selected


def test_thumbnail_shift_click_without_previous_click(
    qapp, portrait_image, landscape_image
):
    """Test that Shift+click without previous click behaves like single click."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Shift+click second thumbnail without clicking anything first
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only second thumbnail is selected (fallback to single select)
    assert len(window.session.selected) == 1
    assert window.session.selected[0] == second_widget.path


def test_thumbnail_ctrl_shift_click_adds_range_to_selection(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that Ctrl+Shift+click adds range to existing selection instead of replacing."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify only first is selected
    assert len(window.session.selected) == 1
    assert first_widget.path in window.session.selected

    # Ctrl+Shift+click third thumbnail (should add range 1-3 to selection)
    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify all three are selected
    assert len(window.session.selected) == 3
    assert first_widget.path in window.session.selected
    assert thumbnail_widgets[1].path in window.session.selected
    assert third_widget.path in window.session.selected


def test_thumbnail_ctrl_shift_click_preserves_previous_selection(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that Ctrl+Shift+click preserves selections made before the range."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # Manually select all three using Ctrl+click
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # All three should be selected
    assert len(window.session.selected) == 3

    # Now Ctrl+Shift+click second (should keep all three, not add duplicates)
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Should still have exactly 3 selected (no duplicates)
    assert len(window.session.selected) == 3
    assert first_widget.path in window.session.selected
    assert second_widget.path in window.session.selected
    assert third_widget.path in window.session.selected


def test_thumbnail_shift_vs_ctrl_shift_difference(
    qapp, portrait_image, landscape_image, square_image
):
    """Test the difference between Shift+click (replace) and Ctrl+Shift+click (add)."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 3

    # === First scenario: Shift+click replaces ===
    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Ctrl+click third to add it
    third_widget = thumbnail_widgets[2]
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Should have first and third selected
    assert len(window.session.selected) == 2
    assert first_widget.path in window.session.selected
    assert third_widget.path in window.session.selected

    # Shift+click second (should REPLACE with range from third to second)
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # First should be gone, only second and third remain (range from last anchor)
    assert len(window.session.selected) == 2
    assert first_widget.path not in window.session.selected
    assert second_widget.path in window.session.selected
    assert third_widget.path in window.session.selected

    # === Second scenario: Reset and test Ctrl+Shift+click adds ===
    # Click first thumbnail again
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Ctrl+click third to add it
    third_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            third_widget.rect().center(),
            third_widget.mapToGlobal(third_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    assert len(window.session.selected) == 2

    # Ctrl+Shift+click second (should ADD range from third to second, keeping first)
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # All three should be selected now
    assert len(window.session.selected) == 3
    assert first_widget.path in window.session.selected
    assert second_widget.path in window.session.selected
    assert third_widget.path in window.session.selected


def test_thumbnail_selection_changed_signal(qtbot, portrait_image, landscape_image):
    """Test that selection_changed signal is emitted with correct data."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    # Connect signal to capture emissions
    with qtbot.waitSignal(window.thumbnail_strip.selection_changed) as blocker:
        # Click first thumbnail
        first_widget = thumbnail_widgets[0]
        first_widget.mousePressEvent(
            QMouseEvent(
                QMouseEvent.Type.MouseButtonPress,
                first_widget.rect().center(),
                first_widget.mapToGlobal(first_widget.rect().center()),
                Qt.MouseButton.LeftButton,
                Qt.MouseButton.LeftButton,
                Qt.KeyboardModifier.NoModifier,
                device=QPointingDevice.primaryPointingDevice(),
            )
        )

    # Verify signal was emitted with correct selection
    assert blocker.args[0] == [first_widget.path]


def test_thumbnail_selection_updates_all_borders(qapp, portrait_image, landscape_image):
    """Test that all thumbnail borders update after selection change."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    first_widget = thumbnail_widgets[0]
    second_widget = thumbnail_widgets[1]

    # Initially, no selection borders
    assert "border: 5px solid #2196F3" not in first_widget.styleSheet()
    assert "border: 5px solid #2196F3" not in second_widget.styleSheet()

    # Click first thumbnail
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # First has selection, second doesn't
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()
    assert "border: 5px solid #2196F3" not in second_widget.styleSheet()

    # Click second thumbnail (replacing selection)
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # First no longer has selection, second does
    assert "border: 5px solid #2196F3" not in first_widget.styleSheet()
    assert "border: 5px solid #2196F3" in second_widget.styleSheet()


# ViewingArea integration tests


def test_thumbnail_selection_hides_empty_label(qapp, portrait_image, landscape_image):
    """Test that clicking a thumbnail hides the empty label in viewing area."""
    window = MainWindow(portrait_image.parent)

    # Initially, empty label should be visible (not hidden)
    assert not window.viewing_area.empty_label.isHidden()

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Empty label should now be hidden
    assert window.viewing_area.empty_label.isHidden()


def test_thumbnail_deselection_shows_empty_label(qapp, portrait_image, landscape_image):
    """Test that deselecting all thumbnails shows the empty label again."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    first_widget = thumbnail_widgets[0]

    # Click to select
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Empty label should be hidden
    assert window.viewing_area.empty_label.isHidden()

    # Ctrl+click to deselect
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.ControlModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Empty label should be visible again (not hidden)
    assert not window.viewing_area.empty_label.isHidden()


# Single Image View Integration Tests


@pytest.mark.integration
def test_single_thumbnail_selection_creates_image_widget(
    qapp, portrait_image, landscape_image
):
    """Test that selecting a single thumbnail creates ImageWidget in ViewingArea."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify ImageWidget was created
    assert len(window.viewing_area.image_widgets) == 1
    from winnow.ui.image_widget import ImageWidget

    assert isinstance(window.viewing_area.image_widgets[0], ImageWidget)
    assert window.viewing_area.image_widgets[0].path == first_widget.path
    assert window.viewing_area.empty_label.isHidden()


@pytest.mark.integration
def test_image_widget_displays_correct_image(qapp, portrait_image, landscape_image):
    """Test that ImageWidget loads and displays the correct image."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify image is loaded and displayed
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    assert image_widget.original_pixmap is not None
    assert not image_widget.original_pixmap.isNull()
    assert image_widget.image_label.pixmap() is not None
    assert not image_widget.image_label.pixmap().isNull()


@pytest.mark.integration
def test_status_overlay_keeper_button_updates_session(
    qapp, portrait_image, landscape_image
):
    """Test that clicking K button marks photo as keeper in session."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets and click first one
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Get the ImageWidget and its overlay
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    overlay = image_widget.overlay

    # Initial status should be unmarked
    from winnow.core.session import PhotoStatus

    assert window.session.get_status(first_widget.path) == PhotoStatus.UNMARKED

    # Click keeper button
    overlay.btn_keeper.click()

    # Verify status changed to keeper
    assert window.session.get_status(first_widget.path) == PhotoStatus.KEEPER

    # Keeper marking auto-advances to the next photo
    assert window.session.selected != [first_widget.path]
    displayed = [w.path for w in window.viewing_area.image_widgets]
    assert displayed == window.session.selected
    assert first_widget.path not in displayed


@pytest.mark.integration
def test_status_overlay_delete_button_updates_session(
    qapp, portrait_image, landscape_image
):
    """Test that clicking D button marks photo for deletion in session."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets and click first one
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Get the ImageWidget and its overlay
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    overlay = image_widget.overlay

    # Initial status should be unmarked
    from winnow.core.session import PhotoStatus

    assert window.session.get_status(first_widget.path) == PhotoStatus.UNMARKED

    # Click delete button
    overlay.btn_delete.click()

    # Verify status changed to delete
    assert window.session.get_status(first_widget.path) == PhotoStatus.DELETE

    # Delete marking auto-advances to the next photo
    displayed = [w.path for w in window.viewing_area.image_widgets]
    assert first_widget.path not in displayed
    assert len(displayed) == 1


@pytest.mark.integration
def test_status_overlay_clear_button_updates_session(
    qapp, portrait_image, landscape_image
):
    """Test that clicking X button clears status back to unmarked."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets and click first one
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Get the ImageWidget and its overlay
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    overlay = image_widget.overlay

    from winnow.core.session import PhotoStatus

    # Mark as keeper directly (a button click would auto-advance away)
    window.session.set_status(first_widget.path, PhotoStatus.KEEPER)
    overlay.update_appearance()
    assert "#4CAF50" in overlay.btn_keeper.styleSheet()

    # Click clear button
    overlay.btn_clear.click()

    # Verify status returned to unmarked, with no advance
    assert window.session.get_status(first_widget.path) == PhotoStatus.UNMARKED
    assert [w.path for w in window.viewing_area.image_widgets] == [first_widget.path]

    # Verify buttons returned to white background
    current_overlay = window.viewing_area.image_widgets[0].overlay
    assert "background-color: white" in current_overlay.btn_keeper.styleSheet()
    assert "background-color: white" in current_overlay.btn_delete.styleSheet()
    assert "background-color: white" in current_overlay.btn_clear.styleSheet()


@pytest.mark.integration
def test_switching_between_images_updates_widget(qapp, portrait_image, landscape_image):
    """Test that selecting different thumbnails updates the ImageWidget correctly."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 2

    # Click first thumbnail
    first_widget = thumbnail_widgets[0]
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Capture first ImageWidget
    assert len(window.viewing_area.image_widgets) == 1
    first_image_widget = window.viewing_area.image_widgets[0]
    assert first_image_widget.path == first_widget.path

    # Click second thumbnail
    second_widget = thumbnail_widgets[1]
    second_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            second_widget.rect().center(),
            second_widget.mapToGlobal(second_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify new ImageWidget was created
    assert len(window.viewing_area.image_widgets) == 1
    second_image_widget = window.viewing_area.image_widgets[0]
    assert second_image_widget.path == second_widget.path
    assert second_image_widget is not first_image_widget

    # Verify first widget was cleared from layout
    from winnow.ui.image_widget import ImageWidget

    layout_widgets = [
        window.viewing_area.layout().itemAt(i).widget()
        for i in range(window.viewing_area.layout().count())
        if window.viewing_area.layout().itemAt(i).widget() is not None
    ]
    image_widgets_in_layout = [w for w in layout_widgets if isinstance(w, ImageWidget)]
    assert len(image_widgets_in_layout) == 1
    assert image_widgets_in_layout[0] is second_image_widget


@pytest.mark.integration
def test_status_change_via_overlay_updates_thumbnail_border_keeper(
    qapp, portrait_image, landscape_image
):
    """Test that marking photo as keeper via overlay updates thumbnail border to green."""
    window = MainWindow(portrait_image.parent)

    # Get thumbnail widgets
    thumbnail_widgets = window.thumbnail_strip.findChildren(ThumbnailWidget)
    assert len(thumbnail_widgets) >= 1

    first_widget = thumbnail_widgets[0]

    # Verify initial state - unmarked (gray 1px border)
    from winnow.core.session import PhotoStatus

    assert window.session.get_status(first_widget.path) == PhotoStatus.UNMARKED
    assert "border: 3px solid #757575" in first_widget.styleSheet()

    # Click thumbnail to select it
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify thumbnail now has selection border (blue 3px)
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()

    # Get ImageWidget and click keeper button
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    overlay = image_widget.overlay

    overlay.btn_keeper.click()

    # Verify session state updated
    assert window.session.get_status(first_widget.path) == PhotoStatus.KEEPER

    # Keeper marking auto-advances, so the thumbnail is deselected and its
    # border shows keeper green immediately
    assert first_widget.path not in window.session.selected
    assert "border: 4px solid #4CAF50" in first_widget.styleSheet()


@pytest.mark.integration
def test_status_change_via_overlay_updates_thumbnail_border_delete(
    qapp, portrait_image, landscape_image
):
    """Test that marking photo as delete hides it (deletes hidden by default)."""
    window = MainWindow(portrait_image.parent)

    # Use the thumbnail_widgets list directly (more reliable than findChildren)
    initial_count = len(window.thumbnail_strip.thumbnail_widgets)
    assert initial_count >= 1

    first_widget = window.thumbnail_strip.thumbnail_widgets[0]
    first_path = first_widget.path

    # Verify initial state - unmarked (gray 1px border)
    from winnow.core.session import PhotoStatus

    assert window.session.get_status(first_path) == PhotoStatus.UNMARKED
    assert "border: 3px solid #757575" in first_widget.styleSheet()

    # Click thumbnail to select it
    first_widget.mousePressEvent(
        QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            first_widget.rect().center(),
            first_widget.mapToGlobal(first_widget.rect().center()),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            device=QPointingDevice.primaryPointingDevice(),
        )
    )

    # Verify thumbnail now has selection border (blue 3px)
    assert "border: 5px solid #2196F3" in first_widget.styleSheet()

    # Get ImageWidget and click delete button
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]
    overlay = image_widget.overlay

    overlay.btn_delete.click()

    # Verify session state updated
    assert window.session.get_status(first_path) == PhotoStatus.DELETE

    # Since deletes are hidden by default, the thumbnail should now be gone
    assert len(window.thumbnail_strip.thumbnail_widgets) == initial_count - 1

    # Verify the deleted photo is no longer in the thumbnail list
    remaining_paths = [w.path for w in window.thumbnail_strip.thumbnail_widgets]
    assert first_path not in remaining_paths

    # Verify it was removed from selection as well
    assert first_path not in window.session.selected


def test_refresh_thumbnails_filters_display(qapp, tmp_path):
    """Test refresh_thumbnails only shows filtered images."""
    # Create test directory with 6 photos
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photos = []
    for i in range(6):
        photo = test_dir / f"photo{i}.jpg"
        photo.touch()
        photos.append(photo)

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Mark photos: 0,1 = keepers, 2,3 = deletes, 4,5 = unmarked
    session.set_status(photos[0], session.get_status(photos[0]).__class__.KEEPER)
    session.set_status(photos[1], session.get_status(photos[1]).__class__.KEEPER)
    session.set_status(photos[2], session.get_status(photos[2]).__class__.DELETE)
    session.set_status(photos[3], session.get_status(photos[3]).__class__.DELETE)

    # Initial state: all 6 thumbnails should be visible
    assert len(strip.thumbnail_widgets) == 6

    # Set filters: show only keepers
    session.show_keepers = True
    session.show_deletes = False
    session.show_unmarked = False
    strip.refresh_thumbnails()

    # Should only show 2 keeper thumbnails
    assert len(strip.thumbnail_widgets) == 2
    keeper_paths = [w.path for w in strip.thumbnail_widgets]
    assert photos[0] in keeper_paths
    assert photos[1] in keeper_paths


def test_refresh_thumbnails_preserves_visible_selection(qapp, tmp_path):
    """Test selection preserved for visible photos after filter."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photos = []
    for i in range(4):
        photo = test_dir / f"photo{i}.jpg"
        photo.touch()
        photos.append(photo)

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Select all 4 photos
    session.selected = photos.copy()

    # Mark 2 as keepers, 2 as deletes
    from winnow.core.session import PhotoStatus

    session.set_status(photos[0], PhotoStatus.KEEPER)
    session.set_status(photos[1], PhotoStatus.KEEPER)
    session.set_status(photos[2], PhotoStatus.DELETE)
    session.set_status(photos[3], PhotoStatus.DELETE)

    # Filter to show only keepers
    session.show_keepers = True
    session.show_deletes = False
    session.show_unmarked = False
    strip.refresh_thumbnails()

    # Only the 2 keepers should remain selected
    assert len(session.selected) == 2
    assert photos[0] in session.selected
    assert photos[1] in session.selected
    assert photos[2] not in session.selected
    assert photos[3] not in session.selected


def test_refresh_thumbnails_clears_hidden_selection(qapp, tmp_path):
    """Test selection cleared for photos filtered out."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photo1 = test_dir / "photo1.jpg"
    photo2 = test_dir / "photo2.jpg"
    photo1.touch()
    photo2.touch()

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Select a photo and mark it for deletion
    session.selected = [photo1]
    from winnow.core.session import PhotoStatus

    session.set_status(photo1, PhotoStatus.DELETE)

    # Filter to hide deletes
    session.show_deletes = False
    strip.refresh_thumbnails()

    # Selection should be empty (photo1 is hidden)
    assert len(session.selected) == 0


def test_filter_button_triggers_refresh(qapp, tmp_path):
    """Test clicking filter button refreshes display."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    photos = []
    for i in range(4):
        photo = test_dir / f"photo{i}.jpg"
        photo.touch()
        photos.append(photo)

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Mark 2 photos for deletion
    from winnow.core.session import PhotoStatus

    session.set_status(photos[0], PhotoStatus.DELETE)
    session.set_status(photos[1], PhotoStatus.DELETE)

    # Initial state: all 4 thumbnails visible
    initial_count = len(strip.thumbnail_widgets)
    assert initial_count == 4

    # Click deletes button to hide them (it starts unchecked/hidden)
    # Deletes are hidden by default, so clicking should show them
    strip.deletes_btn.click()

    # Should still have 4 thumbnails (now showing deletes)
    assert len(strip.thumbnail_widgets) == 4

    # Click deletes button again to hide them
    strip.deletes_btn.click()

    # Should have 2 thumbnails (deletes hidden)
    assert len(strip.thumbnail_widgets) == 2


def test_refresh_with_all_filters_disabled(qapp, tmp_path):
    """Test refresh with all filters off shows no thumbnails."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()
    (test_dir / "photo1.jpg").touch()
    (test_dir / "photo2.jpg").touch()

    window = MainWindow(test_dir)
    session = window.session
    strip = window.thumbnail_strip

    # Initial state: 2 thumbnails
    assert len(strip.thumbnail_widgets) == 2

    # Disable all filters
    session.show_unmarked = False
    session.show_keepers = False
    session.show_deletes = False
    strip.refresh_thumbnails()

    # Should have no thumbnails
    assert len(strip.thumbnail_widgets) == 0
