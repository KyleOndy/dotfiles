"""Edge case tests for UI components.

Tests verify that UI components handle edge cases correctly:
- Single photo UI behavior
- Very large image files (>50MB)
- Mixed orientation comparison mode
- 1000+ photo UI handling with acceptable degradation
- Corrupt/unreadable JPEG files
"""

import shutil
import time
from unittest.mock import Mock

import pytest
from PIL import Image
from PySide6.QtCore import QPointF

from winnow.ui.main_window import MainWindow


def test_single_photo_ui(qapp, tmp_path, portrait_image):
    """Test that MainWindow works correctly with a single photo.

    Verifies that the UI handles minimal (1 image) datasets without
    edge case failures in thumbnail strip, viewing area, and controls.
    """
    # Create directory with single image
    test_dir = tmp_path / "single_photo"
    test_dir.mkdir()

    single_image = test_dir / "photo.jpg"
    shutil.copy(portrait_image, single_image)

    # Create MainWindow
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnail generation
    max_wait = 1.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) == 0:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break

    # Verify single thumbnail created
    assert len(window.thumbnail_strip.thumbnail_widgets) == 1
    assert window.thumbnail_strip.thumbnail_widgets[0].path == single_image

    # Verify thumbnail selection works
    window.thumbnail_strip.handle_thumbnail_click(single_image, False, False)
    qapp.processEvents()

    # Verify viewing area displays the image
    assert len(window.viewing_area.image_widgets) == 1
    assert window.viewing_area.image_widgets[0].path == single_image

    # Test zoom on single image
    image_widget = window.viewing_area.image_widgets[0]
    image_widget.set_zoom(2.0)
    qapp.processEvents()
    assert image_widget.zoom_level == 2.0

    # Test pan on single image
    image_widget.set_pan(50, 50)
    qapp.processEvents()
    assert image_widget.pan_offset.x() == 50
    assert image_widget.pan_offset.y() == 50

    # Cleanup
    window.close()


@pytest.mark.slow
def test_very_large_image_file(qapp, tmp_path):
    """Test handling of very large JPEG files (>20MB).

    Validates that large image files can be loaded, thumbnailed, and
    displayed without crashes. Tests with 8000x6000 pixel image which
    is significantly larger than typical photos (20-30MB compressed).
    Performance may degrade but should work.
    """
    # Create directory with very large image
    test_dir = tmp_path / "large_images"
    test_dir.mkdir()

    # Generate large image: 8000x6000 pixels at high quality
    # JPEG compression is very effective, so this will be ~20-30MB
    large_image_path = test_dir / "large_photo.jpg"

    # Create a detailed image with random noise (less compressible)
    import random

    img = Image.new("RGB", (8000, 6000))

    # Fill with semi-random pattern using fast block tiling
    # Using smaller blocks (10x10) creates more variation and less compression
    # while still being much faster than pixel-by-pixel writes
    block_size = 10
    for y in range(0, 6000, block_size):
        for x in range(0, 8000, block_size):
            color = (
                random.randint(50, 250),
                random.randint(50, 250),
                random.randint(50, 250),
            )
            # Calculate actual block dimensions (handle edges)
            actual_width = min(block_size, 8000 - x)
            actual_height = min(block_size, 6000 - y)
            # Create and paste block (much faster than pixel-by-pixel)
            block = Image.new("RGB", (actual_width, actual_height), color)
            img.paste(block, (x, y))

    # Save with high quality
    img.save(large_image_path, "JPEG", quality=95)

    # Verify file size is actually large (8000x6000 at quality 95 should be >20MB)
    file_size_mb = large_image_path.stat().st_size / (1024 * 1024)
    assert file_size_mb > 15, f"Test image only {file_size_mb:.1f}MB, expected >15MB"

    # Create MainWindow with large image
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnail generation (may take longer for large file)
    max_wait = 5.0  # Allow more time for large file
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) == 0:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    # Verify thumbnail was created
    assert len(window.thumbnail_strip.thumbnail_widgets) == 1
    assert window.thumbnail_strip.thumbnail_widgets[0].path == large_image_path

    # Select and display the large image
    window.thumbnail_strip.handle_thumbnail_click(large_image_path, False, False)
    qapp.processEvents()

    # Wait for image to load in viewing area
    max_wait = 5.0
    wait_start = time.perf_counter()
    while len(window.viewing_area.image_widgets) == 0:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    # Verify large image is displayed
    assert len(window.viewing_area.image_widgets) == 1
    assert window.viewing_area.image_widgets[0].path == large_image_path

    # Test zoom works on large image
    image_widget = window.viewing_area.image_widgets[0]
    image_widget.set_zoom(2.0)
    qapp.processEvents()
    assert image_widget.zoom_level == 2.0

    # Test pan works on large image
    image_widget.set_pan(100, 100)
    qapp.processEvents()
    assert image_widget.pan_offset.x() == 100
    assert image_widget.pan_offset.y() == 100

    # Cleanup
    window.close()


def test_mixed_orientations_comparison_mode(qapp, tmp_path):
    """Test comparison mode with mixed image orientations.

    Verifies that synchronized zoom and pan work correctly when
    comparing images with different aspect ratios (portrait, landscape,
    square, ultra-wide).
    """
    # Create directory with images of different orientations
    test_dir = tmp_path / "mixed_orientations"
    test_dir.mkdir()

    # Create portrait image (2:3 ratio)
    portrait_path = test_dir / "portrait.jpg"
    portrait_img = Image.new("RGB", (2000, 3000), color=(255, 100, 100))
    portrait_img.save(portrait_path, "JPEG", quality=90)

    # Create landscape image (3:2 ratio)
    landscape_path = test_dir / "landscape.jpg"
    landscape_img = Image.new("RGB", (3000, 2000), color=(100, 255, 100))
    landscape_img.save(landscape_path, "JPEG", quality=90)

    # Create square image (1:1 ratio)
    square_path = test_dir / "square.jpg"
    square_img = Image.new("RGB", (2000, 2000), color=(100, 100, 255))
    square_img.save(square_path, "JPEG", quality=90)

    # Create ultra-wide image (4:1 ratio)
    ultrawide_path = test_dir / "ultrawide.jpg"
    ultrawide_img = Image.new("RGB", (4000, 1000), color=(255, 255, 100))
    ultrawide_img.save(ultrawide_path, "JPEG", quality=90)

    # Create MainWindow
    window = MainWindow(test_dir)
    window.resize(1600, 1000)
    qapp.processEvents()

    # Wait for thumbnails
    max_wait = 2.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < 4:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    # Verify all thumbnails created
    assert len(window.thumbnail_strip.thumbnail_widgets) == 4

    # Select all 4 images for comparison (Ctrl+click)
    all_images = [portrait_path, landscape_path, square_path, ultrawide_path]

    # First image (normal click)
    window.thumbnail_strip.handle_thumbnail_click(all_images[0], False, False)
    qapp.processEvents()

    # Add remaining images (Ctrl+click)
    for img_path in all_images[1:]:
        window.thumbnail_strip.handle_thumbnail_click(img_path, True, False)
        qapp.processEvents()

    # Verify comparison mode is active
    assert len(window.viewing_area.image_widgets) == 4

    # Verify all images are in synchronized mode
    assert all(w.synchronized for w in window.viewing_area.image_widgets)

    # Get all widgets
    widgets = window.viewing_area.image_widgets

    # Test synchronized zoom across all orientations
    widgets[0].set_zoom(2.5, emit_signal=True)
    qapp.processEvents()

    # All widgets should have same zoom level
    for widget in widgets:
        assert widget.zoom_level == 2.5

    # Test synchronized pan across all orientations
    widgets[1].set_pan(150, 100, emit_signal=True)
    qapp.processEvents()

    # All widgets should have same pan offset
    for widget in widgets:
        assert widget.pan_offset.x() == 150
        assert widget.pan_offset.y() == 100

    # Verify each widget maintains its own aspect ratio
    # (This is implicit - each has different image dimensions)
    assert widgets[0].path == portrait_path
    assert widgets[1].path == landscape_path
    assert widgets[2].path == square_path
    assert widgets[3].path == ultrawide_path

    # Cleanup
    window.close()


@pytest.mark.slow
def test_1000_photo_ui_initialization(qapp, tmp_path, portrait_image, landscape_image):
    """Test MainWindow initialization with 1000 photos (acceptable degradation).

    Validates that the UI can handle very large photo sets. Initialization
    may take significant time (10-60 seconds) which is acceptable degradation.
    Basic operations should still work.
    """
    # Create directory with 1000 images
    test_dir = tmp_path / "large_ui_test"
    test_dir.mkdir()

    # Create 1000 images (500 portrait + 500 landscape)
    image_paths = []
    for i in range(500):
        dest = test_dir / f"portrait_{i:04d}.jpg"
        shutil.copy(portrait_image, dest)
        image_paths.append(dest)

    for i in range(500):
        dest = test_dir / f"landscape_{i:04d}.jpg"
        shutil.copy(landscape_image, dest)
        image_paths.append(dest)

    # Create MainWindow
    start = time.perf_counter()
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails to be generated (with generous timeout)
    max_wait = 10.0  # Allow up to 10 seconds for initial thumbnails
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    init_time = time.perf_counter() - start

    # Verify at least some thumbnails were created
    # (May not have all 1000 within timeout, but should have started)
    assert len(window.thumbnail_strip.thumbnail_widgets) > 0

    # Document initialization time (for reference, not strict requirement)
    print(
        f"\n1000-photo initialization: {init_time:.2f}s, "
        f"{len(window.thumbnail_strip.thumbnail_widgets)} thumbnails"
    )

    # Test that selection still works with large dataset
    # Select a few images across the range
    test_indices = [0, 100, 500, 900]
    for idx in test_indices:
        if idx < len(image_paths):
            start = time.perf_counter()
            window.thumbnail_strip.handle_thumbnail_click(
                image_paths[idx], False, False
            )
            qapp.processEvents()
            elapsed = time.perf_counter() - start

            # Selection should still be reasonably fast
            assert elapsed < 0.5, f"Selection at index {idx} took {elapsed:.2f}s"

            # Verify viewing area updated
            assert len(window.viewing_area.image_widgets) == 1
            assert window.viewing_area.image_widgets[0].path == image_paths[idx]

    # Test thumbnail strip scrolling performance
    scroll_area = window.thumbnail_strip.scroll_area
    scroll_bar = scroll_area.horizontalScrollBar()

    # Test scrolling to different positions
    for pos_pct in [0, 25, 50, 75, 100]:
        max_val = scroll_bar.maximum()
        scroll_pos = int(max_val * pos_pct / 100)

        start = time.perf_counter()
        scroll_bar.setValue(scroll_pos)
        qapp.processEvents()
        elapsed = time.perf_counter() - start

        # Scrolling should be fast even with 1000 photos
        assert elapsed < 0.1, f"Scrolling to {pos_pct}% took {elapsed:.2f}s"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_1000_photo_comparison_mode(qapp, tmp_path, portrait_image, landscape_image):
    """Test comparison mode with 1000 photos loaded.

    Verifies that comparison mode operations (multi-select, synchronized
    zoom/pan) work correctly even with 1000 photos loaded in background.
    """
    # Create directory with 1000 images
    test_dir = tmp_path / "large_comparison"
    test_dir.mkdir()

    image_paths = []
    for i in range(500):
        dest = test_dir / f"portrait_{i:04d}.jpg"
        shutil.copy(portrait_image, dest)
        image_paths.append(dest)

    for i in range(500):
        dest = test_dir / f"landscape_{i:04d}.jpg"
        shutil.copy(landscape_image, dest)
        image_paths.append(dest)

    # Create MainWindow
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for initial thumbnails
    max_wait = 10.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    # Select 4 images for comparison
    comparison_images = [image_paths[0], image_paths[1], image_paths[2], image_paths[3]]

    start = time.perf_counter()

    # First image
    window.thumbnail_strip.handle_thumbnail_click(comparison_images[0], False, False)
    qapp.processEvents()

    # Add 3 more with Ctrl+click
    for img_path in comparison_images[1:]:
        window.thumbnail_strip.handle_thumbnail_click(img_path, True, False)
        qapp.processEvents()

    elapsed = time.perf_counter() - start

    # Verify comparison mode active
    assert len(window.viewing_area.image_widgets) == 4

    # Multi-select should complete in reasonable time even with 1000 photos loaded
    assert elapsed < 1.0, f"Comparison mode setup took {elapsed:.2f}s with 1000 photos"

    # Test synchronized zoom works
    widgets = window.viewing_area.image_widgets
    widgets[0].set_zoom(2.0, emit_signal=True)
    qapp.processEvents()

    for widget in widgets:
        assert widget.zoom_level == 2.0

    # Test synchronized pan works
    widgets[0].set_pan(75, 50, emit_signal=True)
    qapp.processEvents()

    for widget in widgets:
        assert widget.pan_offset.x() == 75
        assert widget.pan_offset.y() == 50

    # Cleanup
    window.close()


def test_corrupt_jpeg_does_not_crash_on_selection(qapp, tmp_path, portrait_image):
    """A corrupt or zero-byte JPEG must not crash the app when selected.

    Regression test: a file that fails to decode used to yield a null 0x0
    pixmap, and the fit-percentage/zoom-to-cursor math divided by its
    width/height unconditionally, raising an unhandled ZeroDivisionError as
    soon as the file was selected - no interaction beyond selection needed.
    """
    test_dir = tmp_path / "corrupt_photos"
    test_dir.mkdir()

    good_image = test_dir / "good.jpg"
    shutil.copy(portrait_image, good_image)

    corrupt_image = test_dir / "corrupt.jpg"
    corrupt_image.write_bytes(b"not a real jpeg" * 20)

    zero_byte_image = test_dir / "zero.jpg"
    zero_byte_image.write_bytes(b"")

    window = MainWindow(test_dir)
    qapp.processEvents()

    # Select the corrupt file alone - this is exactly where the
    # ZeroDivisionError used to fire, before any user interaction.
    window.thumbnail_strip.handle_thumbnail_click(corrupt_image, False, False)
    qapp.processEvents()

    assert len(window.viewing_area.image_widgets) == 1
    widget = window.viewing_area.image_widgets[0]
    assert not widget.has_valid_image()

    # Wheel-zoom on it (used to divide by original_pixmap.width()==0).
    event = Mock()
    event.angleDelta.return_value = Mock(y=lambda: 120)
    event.position.return_value = QPointF(50, 50)
    widget.wheelEvent(event)

    # Zero-byte file too.
    window.thumbnail_strip.handle_thumbnail_click(zero_byte_image, False, False)
    qapp.processEvents()
    assert not window.viewing_area.image_widgets[0].has_valid_image()

    # Comparison mode mixing a good image with both bad ones.
    window.thumbnail_strip.handle_thumbnail_click(good_image, False, False)
    qapp.processEvents()
    window.thumbnail_strip.handle_thumbnail_click(corrupt_image, True, False)
    window.thumbnail_strip.handle_thumbnail_click(zero_byte_image, True, False)
    qapp.processEvents()
    assert len(window.viewing_area.image_widgets) == 3

    # Cleanup
    window.close()
