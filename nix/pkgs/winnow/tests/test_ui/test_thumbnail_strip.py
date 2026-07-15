"""Tests for ThumbnailStrip zoom slider functionality."""

import shutil
import time

import pytest

from winnow.core.session import PhotoStatus, Session
from winnow.core.thumbnailer import Thumbnailer
from winnow.ui.thumbnail_strip import ThumbnailStrip


@pytest.fixture
def test_images(tmp_path, portrait_image, landscape_image, square_image):
    """Create a temporary directory with test images."""
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    # Copy test images to temp directory
    import shutil

    img1 = test_dir / "portrait.jpg"
    img2 = test_dir / "landscape.jpg"
    img3 = test_dir / "square.jpg"

    shutil.copy(portrait_image, img1)
    shutil.copy(landscape_image, img2)
    shutil.copy(square_image, img3)

    return [img1, img2, img3]


def test_zoom_slider_exists_and_enabled(qapp, test_images):
    """Test that zoom slider exists and is enabled."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Verify slider exists and is accessible
    assert hasattr(strip, "zoom_slider")
    assert strip.zoom_slider is not None

    # Verify slider is enabled
    assert strip.zoom_slider.isEnabled()

    # Verify slider has correct range and default value
    assert strip.zoom_slider.minimum() == 100
    assert strip.zoom_slider.maximum() == 400
    assert strip.zoom_slider.value() == 150


def test_zoom_slider_updates_thumbnailer_size(qapp, test_images):
    """Test that moving slider updates thumbnailer size."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Initial size should be 150
    assert thumbnailer.size == 150

    # Change slider to 200 and trigger release
    strip.zoom_slider.setValue(200)
    strip.zoom_slider.sliderReleased.emit()

    # Thumbnailer size should be updated
    assert thumbnailer.size == 200

    # Change slider to 300 and trigger release
    strip.zoom_slider.setValue(300)
    strip.zoom_slider.sliderReleased.emit()

    # Thumbnailer size should be updated
    assert thumbnailer.size == 300


def test_zoom_slider_regenerates_thumbnails(qapp, test_images):
    """Test that zoom slider regenerates thumbnails at new size."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Get initial thumbnail sizes
    initial_widgets = strip.thumbnail_widgets.copy()
    assert len(initial_widgets) == 3

    # Get initial pixmap size for first image (portrait - taller than wide)
    initial_pixmap = initial_widgets[0].pixmap()
    initial_height = initial_pixmap.height()
    initial_width = initial_pixmap.width()

    # Change zoom to 300 (double the size)
    strip.zoom_slider.setValue(300)
    strip.zoom_slider.sliderReleased.emit()

    # Verify thumbnails were regenerated (new widget instances)
    new_widgets = strip.thumbnail_widgets
    assert len(new_widgets) == 3

    # Verify new thumbnail is larger
    new_pixmap = new_widgets[0].pixmap()
    new_height = new_pixmap.height()
    new_width = new_pixmap.width()

    # New thumbnails should be roughly 2x larger
    assert new_height > initial_height
    assert new_width > initial_width


def test_zoom_maintains_aspect_ratio(qapp, qtbot, test_images):
    """Test that thumbnails maintain aspect ratio at different zoom levels."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    def get_aspect_ratio(widget):
        """Calculate aspect ratio from widget's pixmap."""
        pixmap = widget.pixmap()
        return pixmap.width() / pixmap.height()

    def wait_for_batch(expected_count):
        """Wait for `expected_count` background decodes to be delivered.

        Thumbnails decode asynchronously - checking dict membership alone
        isn't reliable (a stale entry from the previous zoom level is still
        present until overwritten), so count fresh thumbnail_ready
        deliveries instead.
        """
        received = []

        def on_ready(path, pixmap):
            received.append(path)

        thumbnailer.thumbnail_ready.connect(on_ready)
        try:
            qtbot.waitUntil(lambda: len(received) >= expected_count, timeout=2000)
        finally:
            thumbnailer.thumbnail_ready.disconnect(on_ready)

    # Get aspect ratios at default size (150px)
    wait_for_batch(len(test_images))
    aspect_150 = [get_aspect_ratio(w) for w in strip.thumbnail_widgets]

    # Change to 100px
    strip.zoom_slider.setValue(100)
    strip.zoom_slider.sliderReleased.emit()
    wait_for_batch(len(test_images))
    aspect_100 = [get_aspect_ratio(w) for w in strip.thumbnail_widgets]

    # Change to 400px
    strip.zoom_slider.setValue(400)
    strip.zoom_slider.sliderReleased.emit()
    wait_for_batch(len(test_images))
    aspect_400 = [get_aspect_ratio(w) for w in strip.thumbnail_widgets]

    # Aspect ratios should be roughly the same at all zoom levels
    # (allowing for small rounding differences)
    for i in range(len(aspect_150)):
        assert abs(aspect_100[i] - aspect_150[i]) < 0.1
        assert abs(aspect_400[i] - aspect_150[i]) < 0.1


def test_zoom_maintains_selection(qapp, test_images):
    """Test that selection is preserved during zoom changes."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Select the second image by simulating a click (this updates indicator)
    strip.handle_thumbnail_click(
        test_images[1], ctrl_pressed=False, shift_pressed=False
    )

    # Verify selection before zoom
    assert test_images[1] in session.selected
    assert len(session.selected) == 1

    # Change zoom
    strip.zoom_slider.setValue(200)
    strip.zoom_slider.sliderReleased.emit()

    # Verify selection is still preserved in session
    assert test_images[1] in session.selected
    assert len(session.selected) == 1

    # Verify thumbnails were regenerated
    assert len(strip.thumbnail_widgets) == 3


def test_zoom_maintains_filter_state(qapp, test_images):
    """Test that filter state is respected during zoom."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Mark one image as delete
    session.set_status(test_images[0], PhotoStatus.DELETE)

    # Hide deletes (should show only 2 images)
    session.show_deletes = False
    strip.refresh_thumbnails()

    assert len(strip.thumbnail_widgets) == 2

    # Change zoom
    strip.zoom_slider.setValue(200)
    strip.zoom_slider.sliderReleased.emit()

    # Should still show only 2 images (filter state preserved)
    assert len(strip.thumbnail_widgets) == 2

    # Verify the deleted image is not shown
    visible_paths = [w.path for w in strip.thumbnail_widgets]
    assert test_images[0] not in visible_paths


def test_zoom_at_minimum_value(qapp, test_images):
    """Test zoom at minimum value (100px)."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Set to minimum
    strip.zoom_slider.setValue(100)
    strip.zoom_slider.sliderReleased.emit()

    # Verify thumbnailer size
    assert thumbnailer.size == 100

    # Verify thumbnails exist and are small
    assert len(strip.thumbnail_widgets) == 3
    for widget in strip.thumbnail_widgets:
        pixmap = widget.pixmap()
        # At least one dimension should be close to 100px
        assert min(pixmap.width(), pixmap.height()) <= 100


def test_zoom_at_maximum_value(qapp, test_images):
    """Test zoom at maximum value (400px)."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Set to maximum
    strip.zoom_slider.setValue(400)
    strip.zoom_slider.sliderReleased.emit()

    # Verify thumbnailer size
    assert thumbnailer.size == 400

    # Verify thumbnails exist
    assert len(strip.thumbnail_widgets) == 3

    # Note: Test fixture images are only 100x200px, so they won't upscale
    # The thumbnailer preserves original size if smaller than target
    for widget in strip.thumbnail_widgets:
        pixmap = widget.pixmap()
        # Verify pixmap exists and has valid dimensions
        assert pixmap.width() > 0
        assert pixmap.height() > 0


def test_zoom_updates_thumbnail_cache(qapp, qtbot, test_images):
    """Test that zoom updates session thumbnail cache."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Thumbnails decode asynchronously - wait for the initial batch to land.
    qtbot.waitUntil(lambda: test_images[0] in session.thumbnails, timeout=2000)

    # Get initial cached thumbnail size
    initial_pixmap = session.thumbnails[test_images[0]]
    initial_height = initial_pixmap.height()

    # Change zoom
    strip.zoom_slider.setValue(300)
    strip.zoom_slider.sliderReleased.emit()

    # Wait for the background regeneration at the new size to land.
    qtbot.waitUntil(
        lambda: session.thumbnails[test_images[0]].height() != initial_height,
        timeout=2000,
    )

    # Verify cache was updated with new size
    new_pixmap = session.thumbnails[test_images[0]]
    new_height = new_pixmap.height()

    assert new_height > initial_height


def test_zoom_with_multiple_selection(qapp, test_images):
    """Test zoom with multiple images selected."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Select first image
    strip.handle_thumbnail_click(
        test_images[0], ctrl_pressed=False, shift_pressed=False
    )

    # Add second image to selection with Ctrl
    strip.handle_thumbnail_click(test_images[2], ctrl_pressed=True, shift_pressed=False)

    # Verify selection before zoom
    assert len(session.selected) == 2

    # Change zoom
    strip.zoom_slider.setValue(250)
    strip.zoom_slider.sliderReleased.emit()

    # Verify both selections are preserved in session
    assert test_images[0] in session.selected
    assert test_images[2] in session.selected
    assert len(session.selected) == 2

    # Verify thumbnails were regenerated
    assert len(strip.thumbnail_widgets) == 3


def test_sort_btn_exists_and_starts_unchecked(qapp, test_images):
    """Test that the sort-by-sharpness toggle exists and defaults off."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    assert hasattr(strip, "sort_btn")
    assert strip.sort_btn.isCheckable()
    assert not strip.sort_btn.isChecked()
    assert session.sort_by_sharpness is False


def test_sort_btn_toggles_session_flag_and_reorders_strip(qapp, test_images):
    """Test that clicking sort_btn flips session.sort_by_sharpness and reorders."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Score directly (bypassing the background decode) so ordering is
    # deterministic: img1 sharpest, img0 softest.
    session.set_sharpness(test_images[0], 10.0)
    session.set_sharpness(test_images[1], 100.0)
    session.set_sharpness(test_images[2], 50.0)

    strip.sort_btn.click()

    assert session.sort_by_sharpness is True
    assert [w.path for w in strip.thumbnail_widgets] == [
        test_images[0],
        test_images[2],
        test_images[1],
    ]

    strip.sort_btn.click()

    assert session.sort_by_sharpness is False
    assert [w.path for w in strip.thumbnail_widgets] == test_images


def test_background_sharpness_score_updates_session(qapp, qtbot, test_images):
    """Test that a background decode's score lands in session.sharpness."""
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    ThumbnailStrip(session, thumbnailer)  # wires sharpness_ready on construction

    qtbot.waitUntil(lambda: len(session.sharpness) == len(test_images), timeout=3000)

    for path in test_images:
        assert path in session.sharpness
        assert isinstance(session.sharpness[path], float)


def test_sort_reorders_as_late_scores_arrive(qapp, qtbot, test_images):
    """Test that enabling sort while scores are still arriving eventually settles.

    Background decodes race with the sort toggle - this exercises the
    coalesced resort timer in ThumbnailStrip._on_sharpness_ready rather
    than assuming scores exist yet, the way test_sort_btn_toggles_* does
    with pre-set scores.
    """
    session = Session(directory=test_images[0].parent, images=test_images)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    strip.sort_btn.click()
    assert session.sort_by_sharpness is True

    qtbot.waitUntil(lambda: len(session.sharpness) == len(test_images), timeout=3000)
    # Give the debounced resort timer (200ms) time to fire.
    qtbot.wait(400)

    strip_order = [w.path for w in strip.thumbnail_widgets]
    expected_order = sorted(test_images, key=lambda p: session.sharpness[p])
    assert strip_order == expected_order


@pytest.mark.slow
def test_zoom_performance_200_thumbnails(
    qapp, tmp_path, portrait_image, landscape_image, square_image
):
    """Test that zoom regeneration completes under 1s for 200 thumbnails.

    This validates the improved performance target of 1s (down from 2s baseline)
    for regenerating thumbnails when zoom changes. Tests the Phase 7 optimization
    where widgets are updated in-place rather than fully recreated.

    Marked as slow because it generates and processes 200 test images.
    """
    # Create test directory with 200 images (mix of orientations)
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    image_paths = []

    # Copy portrait images (67 copies)
    for i in range(67):
        dest = test_dir / f"portrait_{i:03d}.jpg"
        shutil.copy(portrait_image, dest)
        image_paths.append(dest)

    # Copy landscape images (67 copies)
    for i in range(67):
        dest = test_dir / f"landscape_{i:03d}.jpg"
        shutil.copy(landscape_image, dest)
        image_paths.append(dest)

    # Copy square images (66 copies)
    for i in range(66):
        dest = test_dir / f"square_{i:03d}.jpg"
        shutil.copy(square_image, dest)
        image_paths.append(dest)

    # Verify we have exactly 200 images
    assert len(image_paths) == 200

    # Initialize session and thumbnail strip
    session = Session(directory=test_dir, images=image_paths)
    thumbnailer = Thumbnailer(size=150)
    strip = ThumbnailStrip(session, thumbnailer)

    # Verify initial setup
    assert len(strip.thumbnail_widgets) == 200

    # Measure zoom operation performance (150px -> 300px)
    start = time.perf_counter()
    strip.zoom_slider.setValue(300)
    strip.zoom_slider.sliderReleased.emit()
    elapsed = time.perf_counter() - start

    # Assert performance target: < 1.0 second (improved from 2s baseline)
    assert elapsed < 1.0, f"Zoom regeneration took {elapsed:.3f}s, expected < 1.0s"

    # Verify all thumbnails were regenerated
    assert len(strip.thumbnail_widgets) == 200

    # Verify thumbnailer size was updated
    assert thumbnailer.size == 300
