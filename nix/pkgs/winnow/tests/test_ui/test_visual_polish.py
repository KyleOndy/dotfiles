"""Tests for layout behaviour that responds to state.

Deliberately not a place for assertions that mirror a source constant
(literal hex colours, pixel margins, fixed widget sizes, the default window
size): those only detect that the constant changed, which the diff already
says, and they fail every time the UI is intentionally adjusted.

What is here instead:
- the memory readout tracking real cache usage
- layout holding up across portrait, landscape, square and mixed photos
- widgets responding to resize and to thumbnail-size changes
"""

import pytest
from fixtures.aspect_ratio_images import generate_test_images

from winnow.ui.thumbnail_strip import ThumbnailStrip
from winnow.ui.viewing_area import ViewingArea


class TestMemoryLabel:
    """Test the memory readout reflects real cache state."""

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
