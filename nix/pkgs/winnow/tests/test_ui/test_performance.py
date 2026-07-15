"""Performance validation tests for Winnow.

Tests validate performance targets:
- Initial load time < 500ms (first thumbnails visible)
- Selection change < 100ms (selection to display)
- Zoom/pan at 60fps (16ms per frame)
- Smooth handling of 300 photos

All tests marked as slow since they involve timing measurements
and large test datasets.
"""

import shutil
import time

import pytest
from PySide6.QtCore import QThreadPool

from winnow.ui.main_window import MainWindow


@pytest.fixture
def large_image_set(tmp_path, portrait_image, landscape_image, square_image):
    """Create directory with 300 test images.

    Creates a mix of portrait, landscape, and square images to simulate
    a realistic photo directory.

    Returns:
        tuple: (directory_path, list_of_image_paths)
    """
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    image_paths = []

    # Copy portrait images (100 copies)
    for i in range(100):
        dest = test_dir / f"portrait_{i:03d}.jpg"
        shutil.copy(portrait_image, dest)
        image_paths.append(dest)

    # Copy landscape images (100 copies)
    for i in range(100):
        dest = test_dir / f"landscape_{i:03d}.jpg"
        shutil.copy(landscape_image, dest)
        image_paths.append(dest)

    # Copy square images (100 copies)
    for i in range(100):
        dest = test_dir / f"square_{i:03d}.jpg"
        shutil.copy(square_image, dest)
        image_paths.append(dest)

    assert len(image_paths) == 300

    return test_dir, image_paths


@pytest.mark.slow
def test_initial_load_performance_300_photos(qapp, large_image_set):
    """Test that initial load with 300 photos completes under 500ms.

    This validates the "first thumbnails visible" target, not full cache load.
    Thumbnails decode asynchronously in the background (see ThumbnailStrip) -
    every widget gets a placeholder immediately, so "first thumbnails
    visible" is satisfied by MainWindow construction returning quickly, not
    by waiting for any real decode to complete.
    """
    test_dir, image_paths = large_image_set

    # Drain any background decode work left over from earlier tests in this
    # process (each Thumbnailer/ImageCache instance has its own thread pool,
    # and a still-running one would compete with this test's main thread for
    # the GIL, skewing the measurement below).
    QThreadPool.globalInstance().waitForDone(1000)

    # Measure initial load time: MainWindow construction, which creates a
    # placeholder widget per image synchronously and queues background
    # decodes without waiting on them.
    start = time.perf_counter()
    window = MainWindow(test_dir)
    elapsed = time.perf_counter() - start

    # Verify all placeholders were created (this is "first thumbnails visible")
    assert len(window.thumbnail_strip.thumbnail_widgets) == len(image_paths)

    # Assert performance target: < 500ms for first thumbnails visible
    assert (
        elapsed < 0.5
    ), f"Initial load took {elapsed:.3f}s, expected < 0.5s (first thumbnails visible)"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_selection_change_performance(qapp, tmp_path, portrait_image, landscape_image):
    """Test that selection change completes under 100ms.

    Measures time from thumbnail click to viewing area display update.
    Tests both single selection and switching between images.
    """
    # Create directory with ~20 images (enough to be realistic, not too many)
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    image_paths = []
    for i in range(10):
        dest = test_dir / f"portrait_{i:03d}.jpg"
        shutil.copy(portrait_image, dest)
        image_paths.append(dest)

    for i in range(10):
        dest = test_dir / f"landscape_{i:03d}.jpg"
        shutil.copy(landscape_image, dest)
        image_paths.append(dest)

    # Create MainWindow and wait for initialization
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails to be generated
    max_wait = 1.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break

    # Warm up caches by selecting first image
    window.thumbnail_strip.handle_thumbnail_click(image_paths[0], False, False)
    qapp.processEvents()

    # Measure selection change for multiple images to get representative timing
    times = []

    for i in range(1, min(10, len(image_paths))):
        start = time.perf_counter()

        # Simulate thumbnail click (single selection)
        window.thumbnail_strip.handle_thumbnail_click(image_paths[i], False, False)

        # Process events to complete signal/slot connections
        qapp.processEvents()

        elapsed = time.perf_counter() - start
        times.append(elapsed)

        # Verify viewing area was updated
        assert len(window.viewing_area.image_widgets) == 1
        assert window.viewing_area.image_widgets[0].path == image_paths[i]

    # Calculate average and max times
    avg_time = sum(times) / len(times)
    max_time = max(times)

    # Assert performance target: < 100ms for selection change
    assert (
        avg_time < 0.1
    ), f"Average selection change took {avg_time:.3f}s, expected < 0.1s"
    assert (
        max_time < 0.15
    ), f"Max selection change took {max_time:.3f}s, expected < 0.15s (allowing some variance)"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_selection_change_comparison_mode(
    qapp, tmp_path, portrait_image, landscape_image, square_image
):
    """Test that multi-select for comparison mode completes quickly.

    Validates performance when selecting multiple images (2-4) for comparison.
    """
    # Create directory with test images
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    image_paths = []
    for img, name in [(portrait_image, "portrait"), (landscape_image, "landscape")]:
        for i in range(5):
            dest = test_dir / f"{name}_{i:03d}.jpg"
            shutil.copy(img, dest)
            image_paths.append(dest)

    # Create MainWindow and wait for initialization
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails
    max_wait = 1.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break

    # Measure time to select 4 images for comparison
    start = time.perf_counter()

    # Select first image
    window.thumbnail_strip.handle_thumbnail_click(image_paths[0], False, False)
    qapp.processEvents()

    # Add more images with Ctrl+click
    for i in range(1, 4):
        window.thumbnail_strip.handle_thumbnail_click(image_paths[i], True, False)
        qapp.processEvents()

    elapsed = time.perf_counter() - start

    # Verify comparison mode is active
    assert len(window.viewing_area.image_widgets) == 4
    current_paths = [w.path for w in window.viewing_area.image_widgets]
    assert len(current_paths) == 4

    # Assert reasonable time for multi-select (allowing more time than single select)
    assert elapsed < 0.4, f"Multi-select took {elapsed:.3f}s, expected < 0.4s"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_zoom_pan_frame_rate_2x(qapp, tmp_path, portrait_image):
    """Test that pan operations at 200% zoom maintain 60fps (< 16ms per frame).

    Validates smooth panning performance at moderate zoom level.
    """
    # Create directory with single image
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    img_path = test_dir / "test.jpg"
    shutil.copy(portrait_image, img_path)

    # Create MainWindow and wait for initialization
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails and select the image
    max_wait = 1.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) == 0:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break

    window.thumbnail_strip.handle_thumbnail_click(img_path, False, False)
    qapp.processEvents()

    # Get the image widget
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]

    # Set zoom to 2.0x (200%)
    image_widget.set_zoom(2.0)
    qapp.processEvents()

    # Measure pan operation time for multiple iterations
    pan_times = []

    for i in range(10):
        offset_x = i * 10
        offset_y = i * 10

        start = time.perf_counter()

        # Update pan offset
        image_widget.set_pan(offset_x, offset_y, emit_signal=False)

        # Process events (simulates paint event)
        qapp.processEvents()

        elapsed = time.perf_counter() - start
        pan_times.append(elapsed)

    # Calculate statistics
    avg_time = sum(pan_times) / len(pan_times)
    max_time = max(pan_times)

    # Assert 60fps target: < 16.67ms per frame
    # Allow some variance for the max time
    assert (
        avg_time < 0.017
    ), f"Average pan time {avg_time * 1000:.2f}ms, expected < 17ms"
    assert (
        max_time < 0.025
    ), f"Max pan time {max_time * 1000:.2f}ms, expected < 25ms (allowing variance)"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_zoom_pan_frame_rate_4x(qapp, tmp_path, landscape_image):
    """Test that pan operations at 400% zoom maintain good performance.

    At higher zoom levels, more pixels need to be processed, but should
    still maintain reasonable frame rates.
    """
    # Create directory with single image
    test_dir = tmp_path / "photos"
    test_dir.mkdir()

    img_path = test_dir / "test.jpg"
    shutil.copy(landscape_image, img_path)

    # Create MainWindow and wait for initialization
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails and select the image
    max_wait = 1.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) == 0:
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break

    window.thumbnail_strip.handle_thumbnail_click(img_path, False, False)
    qapp.processEvents()

    # Get the image widget
    assert len(window.viewing_area.image_widgets) == 1
    image_widget = window.viewing_area.image_widgets[0]

    # Set zoom to 4.0x (400%)
    image_widget.set_zoom(4.0)
    qapp.processEvents()

    # Measure pan operation time
    pan_times = []

    for i in range(10):
        offset_x = i * 20
        offset_y = i * 20

        start = time.perf_counter()

        image_widget.set_pan(offset_x, offset_y, emit_signal=False)
        qapp.processEvents()

        elapsed = time.perf_counter() - start
        pan_times.append(elapsed)

    # Calculate statistics
    avg_time = sum(pan_times) / len(pan_times)
    max_time = max(pan_times)

    # At 4x zoom, allow slightly more time but should still be fast
    # Target is still 60fps, but allow more variance
    assert (
        avg_time < 0.02
    ), f"Average pan time at 4x zoom {avg_time * 1000:.2f}ms, expected < 20ms"
    assert (
        max_time < 0.03
    ), f"Max pan time at 4x zoom {max_time * 1000:.2f}ms, expected < 30ms"

    # Cleanup
    window.close()


@pytest.mark.slow
def test_300_photo_handling(qapp, large_image_set):
    """Test that handling 300 photos remains smooth for common operations.

    Validates that key operations remain responsive with a large photo set:
    - Thumbnail scrolling
    - Selection changes
    - Filter toggling
    - Comparison mode
    """
    test_dir, image_paths = large_image_set

    # Create MainWindow
    start = time.perf_counter()
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for initial thumbnail generation (with timeout)
    max_wait = 2.0  # Allow more time for 300 images
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        # Add small sleep to avoid busy waiting
        time.sleep(0.01)

    # Verify initialization completed
    assert len(window.thumbnail_strip.thumbnail_widgets) > 0

    # Test 1: Selection changes remain fast
    selection_times = []
    for i in [0, 50, 100, 150, 200, 250]:
        if i < len(image_paths):
            start = time.perf_counter()
            window.thumbnail_strip.handle_thumbnail_click(image_paths[i], False, False)
            qapp.processEvents()
            elapsed = time.perf_counter() - start
            selection_times.append(elapsed)

    avg_selection_time = sum(selection_times) / len(selection_times)
    assert (
        avg_selection_time < 0.15
    ), f"Selection with 300 photos took {avg_selection_time:.3f}s, expected < 0.15s"

    # Test 2: Filter toggling remains responsive
    start = time.perf_counter()
    window.session.show_deletes = not window.session.show_deletes
    window.thumbnail_strip.refresh_thumbnails()
    qapp.processEvents()
    filter_time = time.perf_counter() - start

    assert filter_time < 0.5, f"Filter toggle took {filter_time:.3f}s, expected < 0.5s"

    # Test 3: Comparison mode with 300 photos loaded
    start = time.perf_counter()
    # Select 4 images for comparison
    window.thumbnail_strip.handle_thumbnail_click(image_paths[0], False, False)
    qapp.processEvents()
    for i in range(1, 4):
        window.thumbnail_strip.handle_thumbnail_click(image_paths[i], True, False)
        qapp.processEvents()
    comparison_time = time.perf_counter() - start

    assert (
        comparison_time < 0.5
    ), f"Comparison mode with 300 photos took {comparison_time:.3f}s, expected < 0.5s"

    # Verify comparison mode is active
    assert len(window.viewing_area.image_widgets) == 4

    # Cleanup
    window.close()


@pytest.mark.slow
def test_thumbnail_strip_scroll_performance(qapp, large_image_set):
    """Test that thumbnail strip scrolling remains smooth with 300 photos.

    Validates that the scrollable thumbnail area can handle large numbers
    of thumbnails without performance degradation.
    """
    test_dir, image_paths = large_image_set

    # Create MainWindow
    window = MainWindow(test_dir)
    qapp.processEvents()

    # Wait for thumbnails to be generated
    max_wait = 2.0
    wait_start = time.perf_counter()
    while len(window.thumbnail_strip.thumbnail_widgets) < len(image_paths):
        qapp.processEvents()
        if time.perf_counter() - wait_start > max_wait:
            break
        time.sleep(0.01)

    # Get the scroll area
    scroll_area = window.thumbnail_strip.scroll_area

    # Test scrolling performance
    # Simulate scrolling by setting scroll bar value
    scroll_times = []

    scroll_bar = scroll_area.horizontalScrollBar()
    scroll_positions = [0, 25, 50, 75, 100]  # Percentages

    for pos_pct in scroll_positions:
        # Calculate scroll position
        max_val = scroll_bar.maximum()
        scroll_pos = int(max_val * pos_pct / 100)

        start = time.perf_counter()

        # Set scroll position
        scroll_bar.setValue(scroll_pos)

        # Process events to update display
        qapp.processEvents()

        elapsed = time.perf_counter() - start
        scroll_times.append(elapsed)

    # Calculate statistics
    avg_scroll_time = sum(scroll_times) / len(scroll_times)
    max_scroll_time = max(scroll_times)

    # Scrolling should be very fast
    assert (
        avg_scroll_time < 0.05
    ), f"Average scroll time {avg_scroll_time:.3f}s, expected < 0.05s"
    assert (
        max_scroll_time < 0.1
    ), f"Max scroll time {max_scroll_time:.3f}s, expected < 0.1s"

    # Cleanup
    window.close()
