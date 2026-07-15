"""Edge case tests for core functionality.

Tests verify that core components handle edge cases correctly:
- Single photo directories
- Very large directories (1000+ photos)
- Performance with acceptable degradation
"""

import shutil
import time

import pytest

from winnow.core.scanner import scan_directory
from winnow.core.session import PhotoStatus, Session


def test_single_photo_directory_scan(tmp_path, portrait_image):
    """Test that scan_directory works correctly with a single photo.

    Verifies that directories containing only one image are handled
    properly without any edge case failures.
    """
    # Create directory with single image
    test_dir = tmp_path / "single_photo"
    test_dir.mkdir()

    single_image = test_dir / "photo.jpg"
    shutil.copy(portrait_image, single_image)

    # Scan directory
    result = scan_directory(test_dir)

    # Should find exactly 1 image
    assert len(result) == 1
    assert result[0] == single_image
    assert result[0].is_file()


def test_single_photo_session(tmp_path, portrait_image):
    """Test that Session initializes correctly with a single photo.

    Verifies that session creation and basic operations work with
    minimal (1 image) datasets.
    """
    # Create directory with single image
    test_dir = tmp_path / "single_photo"
    test_dir.mkdir()

    single_image = test_dir / "photo.jpg"
    shutil.copy(portrait_image, single_image)

    # Scan and create session
    images = scan_directory(test_dir)
    session = Session(directory=test_dir, images=images)

    # Verify session state
    assert len(session.images) == 1
    assert session.images[0] == single_image
    assert session.directory == test_dir

    # Verify selections work
    session.selected = [single_image]
    assert session.selected == [single_image]


@pytest.mark.slow
def test_1000_photo_directory_scan(
    tmp_path, portrait_image, landscape_image, square_image
):
    """Test scan_directory with 1000 photos (acceptable degradation).

    This test validates that the scanner can handle very large directories
    without crashes. Performance may degrade, but should complete in
    reasonable time (< 5 seconds for scan operation).
    """
    # Create directory with 1000 images
    test_dir = tmp_path / "large_dir"
    test_dir.mkdir()

    image_paths = []
    source_images = [portrait_image, landscape_image, square_image]

    # Create 1000 images (cycling through the 3 source images)
    for i in range(1000):
        source = source_images[i % 3]
        dest = test_dir / f"photo_{i:04d}.jpg"
        shutil.copy(source, dest)
        image_paths.append(dest)

    # Measure scan time
    start = time.perf_counter()
    result = scan_directory(test_dir)
    elapsed = time.perf_counter() - start

    # Verify all images found
    assert len(result) == 1000

    # Performance target: scan should complete in < 5 seconds
    # (This is acceptable degradation - we don't expect instant results)
    assert elapsed < 5.0, f"Scan took {elapsed:.2f}s, expected < 5s"

    # Verify results are sorted
    filenames = [p.name for p in result]
    assert filenames == sorted(filenames)


@pytest.mark.slow
def test_1000_photo_session_creation(
    tmp_path, portrait_image, landscape_image, square_image
):
    """Test Session creation with 1000 photos (acceptable degradation).

    Validates that Session can be created with very large image sets.
    Session creation should be fast as it's just data structure initialization.
    """
    # Create directory with 1000 images
    test_dir = tmp_path / "large_dir"
    test_dir.mkdir()

    source_images = [portrait_image, landscape_image, square_image]

    for i in range(1000):
        source = source_images[i % 3]
        dest = test_dir / f"photo_{i:04d}.jpg"
        shutil.copy(source, dest)

    # Scan directory
    images = scan_directory(test_dir)
    assert len(images) == 1000

    # Measure session creation time
    start = time.perf_counter()
    session = Session(directory=test_dir, images=images)
    elapsed = time.perf_counter() - start

    # Verify session created correctly
    assert len(session.images) == 1000
    assert session.directory == test_dir

    # Session creation should be very fast (just data structure setup)
    assert elapsed < 1.0, f"Session creation took {elapsed:.2f}s, expected < 1s"


@pytest.mark.slow
def test_1000_photo_session_operations(tmp_path, portrait_image, landscape_image):
    """Test basic session operations with 1000 photos.

    Validates that selection, marking, and filtering operations work
    correctly with large datasets.
    """
    # Create directory with 1000 images
    test_dir = tmp_path / "large_dir"
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

    # Create session
    images = scan_directory(test_dir)
    session = Session(directory=test_dir, images=images)

    # Test selection with multiple images
    selected = [images[0], images[50], images[100], images[500]]
    session.selected = selected
    assert len(session.selected) == 4
    assert all(img in session.selected for img in selected)

    # Test marking images for deletion
    session.set_status(images[0], PhotoStatus.DELETE)
    session.set_status(images[10], PhotoStatus.DELETE)
    session.set_status(images[100], PhotoStatus.DELETE)

    # Verify marks
    assert session.get_status(images[0]) == PhotoStatus.DELETE
    assert session.get_status(images[10]) == PhotoStatus.DELETE
    assert session.get_status(images[100]) == PhotoStatus.DELETE
    assert session.get_status(images[1]) == PhotoStatus.UNMARKED

    # Test filtering (show_deletes toggle)
    session.show_deletes = False
    visible = session.filtered_images()
    assert images[0] not in visible
    assert images[10] not in visible
    assert images[1] in visible

    # Should have 997 visible images (1000 - 3 marked for delete)
    assert len(visible) == 997
