"""Tests for visual polish: color scheme, spacing, margins, and layout consistency.

This module verifies the visual consistency of the UI including:
- Color scheme consistency (status colors, selection highlights, memory indicators)
- Spacing and margins (layouts, overlays, containers)
- Window sizing behavior (resize handling, dynamic updates)
- Layout with different aspect ratios (portrait, landscape, square, mixed)
"""

import pytest
from fixtures.aspect_ratio_images import generate_test_images
from PySide6.QtCore import QSize

from winnow.core.session import PhotoStatus
from winnow.ui.thumbnail_strip import ThumbnailStrip
from winnow.ui.viewing_area import ViewingArea


class TestColorConsistency:
    """Test color scheme consistency across UI components."""

    def test_status_colors_thumbnail_borders(self, session, thumbnailer, qtbot):
        """Verify status colors match specification in thumbnail borders."""
        # Create thumbnail strip
        strip = ThumbnailStrip(session, thumbnailer)
        qtbot.addWidget(strip)

        # Get a thumbnail widget
        widget = strip.thumbnail_widgets[0]

        # Test unmarked (default) - gray border
        session.set_status(widget.path, PhotoStatus.UNMARKED)
        widget.update_appearance()
        assert (
            "#757575" in widget.styleSheet()
        ), "Unmarked should have gray #757575 border"

        # Test keeper - green border
        session.set_status(widget.path, PhotoStatus.KEEPER)
        widget.update_appearance()
        assert (
            "#4CAF50" in widget.styleSheet()
        ), "Keeper should have green #4CAF50 border"

        # Test delete - red border
        session.set_status(widget.path, PhotoStatus.DELETE)
        widget.update_appearance()
        assert "#F44336" in widget.styleSheet(), "Delete should have red #F44336 border"

    def test_selection_highlight_color(self, session, thumbnailer, qtbot):
        """Verify selection highlight uses consistent blue color."""
        strip = ThumbnailStrip(session, thumbnailer)
        qtbot.addWidget(strip)

        # Select first thumbnail
        first_path = session.images[0]
        session.selected.append(first_path)

        # Update appearance
        widget = strip.thumbnail_widgets[0]
        widget.update_appearance()

        # Check for blue selection color
        assert "#2196F3" in widget.styleSheet(), "Selection should use blue #2196F3"

    def test_filter_button_colors(self, session, thumbnailer, qtbot):
        """Verify filter buttons use consistent checked/unchecked colors."""
        strip = ThumbnailStrip(session, thumbnailer)
        qtbot.addWidget(strip)

        # Checked buttons should have blue background
        assert strip.unmarked_btn.isChecked()
        assert "#2196F3" in strip.unmarked_btn.styleSheet()

        # Unchecked buttons should have gray background
        assert not strip.deletes_btn.isChecked()
        assert "#f0f0f0" in strip.deletes_btn.styleSheet()

    def test_memory_label_reflects_cache_usage(self, main_window, qtbot):
        """Verify the status bar memory label reflects the cache's reported usage.

        The cache is bounded to the active selection (see ImageCache), so
        there's no fixed budget to color-code against - the label just
        reports the current total.
        """
        from unittest.mock import MagicMock

        qtbot.addWidget(main_window)

        mock_cache = MagicMock()
        main_window.session.image_cache = mock_cache

        mock_cache.get_memory_usage_mb.return_value = 42.5
        main_window._refresh_memory_label()
        assert main_window.memory_label.text() == "Memory: 42.5 MB"

        mock_cache.get_memory_usage_mb.return_value = 128.0
        main_window._refresh_memory_label()
        assert main_window.memory_label.text() == "Memory: 128.0 MB"


class TestSpacingAndMargins:
    """Test spacing and margin consistency across layouts."""

    def test_main_window_layout_margins(self, main_window, qtbot):
        """Verify main window has zero margins and spacing."""
        qtbot.addWidget(main_window)

        layout = main_window.centralWidget().layout()
        margins = layout.contentsMargins()

        assert margins.left() == 0, "Main window should have 0 left margin"
        assert margins.top() == 0, "Main window should have 0 top margin"
        assert margins.right() == 0, "Main window should have 0 right margin"
        assert margins.bottom() == 0, "Main window should have 0 bottom margin"
        assert layout.spacing() == 0, "Main window should have 0 spacing"

    def test_thumbnail_strip_spacing(self, session, thumbnailer, qtbot):
        """Verify thumbnail strip control bar and container spacing."""
        strip = ThumbnailStrip(session, thumbnailer)
        qtbot.addWidget(strip)

        # Check control bar margins (should be 10, 5, 10, 5)
        # Note: Control bar is created inline, check via main layout children
        main_layout = strip.layout()
        control_widget = main_layout.itemAt(0).widget()
        control_layout = control_widget.layout()
        margins = control_layout.contentsMargins()

        assert margins.left() == 10, "Control bar should have 10px left margin"
        assert margins.top() == 5, "Control bar should have 5px top margin"
        assert margins.right() == 10, "Control bar should have 10px right margin"
        assert margins.bottom() == 5, "Control bar should have 5px bottom margin"

        # Check container margins (should be 10px all around)
        container_margins = strip.container_layout.contentsMargins()
        assert container_margins.left() == 10, "Container should have 10px left margin"
        assert container_margins.top() == 10, "Container should have 10px top margin"
        assert (
            container_margins.right() == 10
        ), "Container should have 10px right margin"
        assert (
            container_margins.bottom() == 10
        ), "Container should have 10px bottom margin"

        # Check container spacing (should be 5px)
        assert (
            strip.container_layout.spacing() == 5
        ), "Container should have 5px spacing"

    def test_viewing_area_grid_spacing(self, session, qtbot):
        """Verify viewing area grid reserves 3px margins and has 2px spacing.

        The 3px margin reserves constant room for the mode-color frame (see
        ViewingArea.set_mode_frame) so toggling it never reflows the grid -
        the same reserved-space pattern ImageWidget uses for its focus ring.
        """
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        layout = viewing_area.layout()
        margins = layout.contentsMargins()

        assert margins.left() == 3, "Viewing area should have 3px left margin"
        assert margins.top() == 3, "Viewing area should have 3px top margin"
        assert margins.right() == 3, "Viewing area should have 3px right margin"
        assert margins.bottom() == 3, "Viewing area should have 3px bottom margin"
        assert layout.spacing() == 2, "Viewing area should have 2px spacing"

    def test_overlay_positioning(self, session, qtbot):
        """Verify overlays are positioned correctly."""
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        # Select an image to show overlays
        viewing_area.set_images([session.images[0]])

        # Status overlay should be at (10, 10) relative to image widget
        image_widget = viewing_area.image_widgets[0]
        status_overlay = image_widget.overlay
        assert status_overlay.pos().x() == 10, "Status overlay should be 10px from left"
        assert status_overlay.pos().y() == 10, "Status overlay should be 10px from top"

        # Zoom overlay should be 10px from bottom-right
        # Need to show widget and process events for layout to complete
        viewing_area.show()
        viewing_area.resize(1200, 800)
        qtbot.waitExposed(viewing_area)
        viewing_area.update_zoom_overlay_position()
        zoom_overlay = viewing_area.zoom_overlay

        expected_x = 1200 - zoom_overlay.width() - 10
        expected_y = 800 - zoom_overlay.height() - 10

        # Allow some tolerance for window manager differences
        assert (
            abs(zoom_overlay.pos().x() - expected_x) < 5
        ), f"Zoom overlay X position {zoom_overlay.pos().x()} should be near {expected_x}"
        assert (
            abs(zoom_overlay.pos().y() - expected_y) < 5
        ), f"Zoom overlay Y position {zoom_overlay.pos().y()} should be near {expected_y}"


class TestLayoutWithAspectRatios:
    """Test layout behavior with different photo aspect ratios."""

    @pytest.fixture(scope="class")
    def aspect_ratio_session(self, tmp_path_factory):
        """Create a session with test images of different aspect ratios."""
        from winnow.core.scanner import scan_directory
        from winnow.core.session import Session

        # Generate test images
        tmp_path = tmp_path_factory.mktemp("test_images")
        test_dir = generate_test_images(tmp_path)

        # Scan and create session
        images = scan_directory(test_dir)
        session = Session(directory=test_dir, images=images)

        return session

    def test_grid_layout_positions(self, aspect_ratio_session, qtbot):
        """Verify grid layout positions are calculated correctly."""
        viewing_area = ViewingArea(aspect_ratio_session)
        qtbot.addWidget(viewing_area)

        # Test 1 image
        positions = viewing_area.calculate_grid_layout(1)
        assert positions == [(0, 0)], "Single image should be at (0, 0)"

        # Test 2 images (1x2 horizontal)
        positions = viewing_area.calculate_grid_layout(2)
        assert positions == [(0, 0), (0, 1)], "Two images should be 1x2 horizontal"

        # Test 3 images (1x3 horizontal)
        positions = viewing_area.calculate_grid_layout(3)
        assert positions == [(0, 0), (0, 1), (0, 2)], "Three images should be 1x3"

        # Test 4 images (2x2 grid)
        positions = viewing_area.calculate_grid_layout(4)
        assert positions == [
            (0, 0),
            (0, 1),
            (1, 0),
            (1, 1),
        ], "Four images should be 2x2"

        # Test 5 images (rows of 3, last row left-aligned)
        positions = viewing_area.calculate_grid_layout(5)
        expected = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1)]
        assert positions == expected, "Five images should fill two rows"

        # Test 7 images (rows of 3, last row centered)
        positions = viewing_area.calculate_grid_layout(7)
        # First two rows full, last row centered: (2, 1)
        assert positions[6] == (2, 1), "Seventh image should be centered in third row"

    def test_uniform_cell_sizing(self, aspect_ratio_session, qtbot):
        """Verify all grid cells have uniform size in comparison mode."""
        viewing_area = ViewingArea(aspect_ratio_session)
        qtbot.addWidget(viewing_area)
        viewing_area.resize(1200, 800)

        # Test with 4 images (2x2 grid)
        viewing_area.set_images(aspect_ratio_session.images[:4])

        # Calculate expected cell size
        expected_cell_size = viewing_area.calculate_uniform_cell_size(4)

        # Verify all widgets have the same fixed_size
        for widget in viewing_area.image_widgets:
            assert (
                widget.fixed_size == expected_cell_size
            ), "All grid cells should have uniform size"

    def test_mixed_aspect_ratios_display(self, aspect_ratio_session, qtbot):
        """Verify mixed aspect ratios display correctly in grid."""
        viewing_area = ViewingArea(aspect_ratio_session)
        qtbot.addWidget(viewing_area)
        viewing_area.resize(1200, 800)

        # Get portrait, landscape, and square images
        portrait = [p for p in aspect_ratio_session.images if "portrait" in p.name][0]
        landscape = [p for p in aspect_ratio_session.images if "landscape" in p.name][0]
        square = [p for p in aspect_ratio_session.images if "square" in p.name][0]

        # Display mixed aspect ratios
        viewing_area.set_images([portrait, landscape, square])

        # All should use the same uniform cell size
        assert len(viewing_area.image_widgets) == 3
        cell_size = viewing_area.image_widgets[0].fixed_size

        for widget in viewing_area.image_widgets:
            assert (
                widget.fixed_size == cell_size
            ), "Mixed aspects should use uniform sizing"

    def test_aspect_ratio_preservation(self, aspect_ratio_session, qtbot):
        """Verify images maintain aspect ratio in all layouts."""
        viewing_area = ViewingArea(aspect_ratio_session)
        qtbot.addWidget(viewing_area)
        viewing_area.resize(1200, 800)

        # Test single image
        portrait = [p for p in aspect_ratio_session.images if "portrait" in p.name][0]
        viewing_area.set_images([portrait])

        widget = viewing_area.image_widgets[0]
        pixmap = widget.image_label.pixmap()

        # Image should maintain aspect ratio (portrait is taller than wide)
        assert (
            pixmap.height() > pixmap.width()
        ), "Portrait image should maintain tall aspect ratio"


class TestWindowSizing:
    """Test window sizing and resize behavior."""

    def test_default_window_size(self, main_window, qtbot):
        """Verify default window size is 1200x800."""
        qtbot.addWidget(main_window)

        # Note: Window managers may affect actual size, check initial resize call
        assert main_window.size().width() == 1200, "Default width should be 1200"
        assert main_window.size().height() == 800, "Default height should be 800"

    def test_thumbnail_strip_height_updates(self, session, thumbnailer, qtbot):
        """Verify thumbnail strip height updates with zoom changes."""
        strip = ThumbnailStrip(session, thumbnailer)
        qtbot.addWidget(strip)

        # Initial height with default thumbnail size (150px)
        initial_height = strip.height()
        initial_thumb_size = thumbnailer.size

        # Change thumbnail size
        thumbnailer.set_size(250)
        strip._update_strip_height()

        # Height should increase by the difference in thumbnail size
        expected_height = initial_height + (250 - initial_thumb_size)
        assert strip.height() == expected_height, "Strip height should update with zoom"

    def test_viewing_area_resize_updates_grid(self, session, qtbot):
        """Verify viewing area recalculates grid on resize."""
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        # Display 4 images in grid
        viewing_area.set_images(session.images[:4])
        viewing_area.resize(1200, 800)

        # Get initial cell size
        initial_cell_size = viewing_area.image_widgets[0].fixed_size

        # Resize window
        viewing_area.resize(1600, 1000)

        # Trigger resize event
        viewing_area.resizeEvent(None)

        # Cell size should have updated
        new_cell_size = viewing_area.image_widgets[0].fixed_size
        assert new_cell_size != initial_cell_size, "Grid should recalculate on resize"

    def test_overlay_repositioning_on_resize(self, session, qtbot):
        """Verify overlays reposition correctly on window resize."""
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        # Display image to show zoom overlay
        viewing_area.set_images([session.images[0]])
        viewing_area.show()
        viewing_area.resize(1200, 800)
        qtbot.waitExposed(viewing_area)
        viewing_area.update_zoom_overlay_position()

        initial_x = viewing_area.zoom_overlay.pos().x()

        # Resize wider
        viewing_area.resize(1600, 800)
        qtbot.wait(10)  # Brief wait for resize to process
        viewing_area.update_zoom_overlay_position()

        new_x = viewing_area.zoom_overlay.pos().x()

        # Overlay should move right (further from left edge)
        # Calculate expected positions for validation
        expected_delta = 400  # Width increased by 400px
        assert (
            new_x >= initial_x + expected_delta - 10
        ), f"Zoom overlay should reposition on resize: {new_x} vs {initial_x}"


class TestButtonSizes:
    """Test fixed button sizes are consistent."""

    def test_status_overlay_button_sizes(self, session, qtbot):
        """Verify status overlay buttons are 30x30."""
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        viewing_area.set_images([session.images[0]])
        image_widget = viewing_area.image_widgets[0]
        overlay = image_widget.overlay

        # All buttons should be 30x30
        assert overlay.btn_keeper.size() == QSize(
            30, 30
        ), "Keeper button should be 30x30"
        assert overlay.btn_delete.size() == QSize(
            30, 30
        ), "Delete button should be 30x30"
        assert overlay.btn_clear.size() == QSize(30, 30), "Clear button should be 30x30"

    def test_zoom_control_button_sizes(self, session, qtbot):
        """Verify zoom control buttons have correct sizes."""
        viewing_area = ViewingArea(session)
        qtbot.addWidget(viewing_area)

        viewing_area.set_images([session.images[0]])
        zoom_overlay = viewing_area.zoom_overlay

        # Zoom in/out buttons should be 36x36
        assert zoom_overlay.btn_zoom_in.size() == QSize(
            36, 36
        ), "Zoom in should be 36x36"
        assert zoom_overlay.btn_zoom_out.size() == QSize(
            36, 36
        ), "Zoom out should be 36x36"

        # Zoom 100% and Fit buttons should be 50x36
        assert zoom_overlay.btn_zoom_100.size() == QSize(
            50, 36
        ), "Zoom 100% should be 50x36"
        assert zoom_overlay.btn_zoom_fit.size() == QSize(
            50, 36
        ), "Zoom Fit should be 50x36"
