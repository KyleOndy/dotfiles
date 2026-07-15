"""Tests for the thumbnailer module."""

from pathlib import Path

from PIL import Image
from PySide6.QtGui import QPixmap

from winnow.core.focus import sharpness_score
from winnow.core.thumbnailer import Thumbnailer


def create_test_image(
    tmp_path: Path, filename: str, width: int, height: int, mode: str = "RGB"
) -> Path:
    """Create a test image with the specified dimensions and mode.

    Args:
        tmp_path: Temporary directory path from pytest fixture.
        filename: Name for the image file (e.g., "test.jpg").
        width: Image width in pixels.
        height: Image height in pixels.
        mode: PIL image mode (RGB, RGBA, L for grayscale, etc.).

    Returns:
        Path to the created image file.
    """
    img = Image.new(
        mode, (width, height), color=(100, 150, 200) if mode == "RGB" else None
    )
    image_path = tmp_path / filename

    # Save as JPEG for RGB and L modes, PNG for RGBA
    if mode == "RGBA":
        img.save(image_path, "PNG")
    else:
        img.save(image_path, "JPEG")

    return image_path


# Basic thumbnail generation tests


def test_generate_creates_qpixmap(qapp, tmp_path):
    """Test that generate() returns a QPixmap instance."""
    image_path = create_test_image(tmp_path, "test.jpg", 100, 100)
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert isinstance(result, QPixmap)


def test_generate_with_valid_jpeg(qapp, tmp_path):
    """Test that generate() creates a non-null QPixmap from a valid JPEG."""
    image_path = create_test_image(tmp_path, "photo.jpg", 200, 150)
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert not result.isNull()


def test_generate_returns_non_empty_pixmap(qapp, tmp_path):
    """Test that generated pixmap has non-zero dimensions."""
    image_path = create_test_image(tmp_path, "image.jpg", 100, 100)
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert result.width() > 0
    assert result.height() > 0


# Size handling tests


def test_default_size_is_150():
    """Test that Thumbnailer initializes with default size of 150."""
    thumbnailer = Thumbnailer()

    assert thumbnailer.size == 150


def test_custom_size():
    """Test that Thumbnailer can be initialized with a custom size."""
    thumbnailer = Thumbnailer(size=200)

    assert thumbnailer.size == 200


def test_set_size_updates_size():
    """Test that set_size() method updates the size attribute."""
    thumbnailer = Thumbnailer(size=150)

    thumbnailer.set_size(300)

    assert thumbnailer.size == 300


def test_generate_respects_size(qapp, tmp_path):
    """Test that generated thumbnails fit within the configured size."""
    # Create a large image
    image_path = create_test_image(tmp_path, "large.jpg", 800, 600)
    thumbnailer = Thumbnailer(size=100)

    result = thumbnailer.generate(image_path)

    # Both dimensions should be <= size
    assert result.width() <= 100
    assert result.height() <= 100
    # At least one dimension should equal size (for the limiting dimension)
    assert result.width() == 100 or result.height() == 100


def test_thumbnail_at_different_sizes(qapp, tmp_path):
    """Test generating thumbnails at different sizes produces different results."""
    image_path = create_test_image(tmp_path, "photo.jpg", 400, 400)

    thumbnailer_small = Thumbnailer(size=100)
    thumbnailer_large = Thumbnailer(size=200)

    result_small = thumbnailer_small.generate(image_path)
    result_large = thumbnailer_large.generate(image_path)

    assert result_small.width() < result_large.width()
    assert result_small.height() < result_large.height()


# Aspect ratio preservation tests


def test_portrait_maintains_aspect_ratio(qapp, tmp_path):
    """Test that portrait images maintain aspect ratio in thumbnail."""
    # Create 100x200 portrait image (aspect ratio 1:2)
    image_path = create_test_image(tmp_path, "portrait.jpg", 100, 200)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Height should be limiting dimension (200 > 100)
    # So height should be 150, width should be 75
    assert result.height() == 150
    assert result.width() == 75

    # Verify aspect ratio approximately preserved (0.5 = 1:2)
    aspect_ratio = result.width() / result.height()
    assert abs(aspect_ratio - 0.5) < 0.01


def test_landscape_maintains_aspect_ratio(qapp, tmp_path):
    """Test that landscape images maintain aspect ratio in thumbnail."""
    # Create 200x100 landscape image (aspect ratio 2:1)
    image_path = create_test_image(tmp_path, "landscape.jpg", 200, 100)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Width should be limiting dimension (200 > 100)
    # So width should be 150, height should be 75
    assert result.width() == 150
    assert result.height() == 75

    # Verify aspect ratio approximately preserved (2.0 = 2:1)
    aspect_ratio = result.width() / result.height()
    assert abs(aspect_ratio - 2.0) < 0.01


def test_square_maintains_aspect_ratio(qapp, tmp_path):
    """Test that square images maintain 1:1 aspect ratio in thumbnail."""
    # Create 100x100 square image
    image_path = create_test_image(tmp_path, "square.jpg", 100, 100)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Both dimensions should be equal and at most 100 (original size)
    assert result.width() == result.height()
    assert result.width() <= 100


def test_very_wide_aspect_ratio(qapp, tmp_path):
    """Test extreme landscape aspect ratio (panorama)."""
    # Create 400x100 very wide image (4:1)
    image_path = create_test_image(tmp_path, "panorama.jpg", 400, 100)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Width is limiting, should be 150
    assert result.width() == 150
    # Height should be ~37-38 (150/4)
    expected_height = 150 / 4
    assert abs(result.height() - expected_height) <= 1  # Allow 1px rounding


# QPixmap conversion and image mode tests


def test_rgb_image_conversion(qapp, tmp_path):
    """Test conversion of RGB mode JPEG to QPixmap."""
    image_path = create_test_image(tmp_path, "rgb.jpg", 100, 100, mode="RGB")
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert not result.isNull()
    assert result.width() > 0
    assert result.height() > 0


def test_rgba_image_conversion(qapp, tmp_path):
    """Test conversion of RGBA mode PNG to QPixmap."""
    image_path = create_test_image(tmp_path, "rgba.png", 100, 100, mode="RGBA")
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert not result.isNull()
    assert result.width() > 0
    assert result.height() > 0


def test_grayscale_conversion(qapp, tmp_path):
    """Test conversion of grayscale image to QPixmap."""
    image_path = create_test_image(tmp_path, "gray.jpg", 100, 100, mode="L")
    thumbnailer = Thumbnailer()

    result = thumbnailer.generate(image_path)

    assert not result.isNull()
    assert result.width() > 0
    assert result.height() > 0


def test_pixmap_has_correct_dimensions(qapp, tmp_path):
    """Test that QPixmap dimensions match expected thumbnail size."""
    # Create 200x100 image, thumbnail at 150
    image_path = create_test_image(tmp_path, "test.jpg", 200, 100)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Width is limiting (200 > 100), should be scaled to 150
    # Height should be 75 (maintaining 2:1 ratio)
    assert result.width() == 150
    assert result.height() == 75


# Error handling tests


def test_nonexistent_file_returns_blank_pixmap(qapp, tmp_path):
    """Test that a non-existent file returns a blank pixmap."""
    nonexistent = tmp_path / "does_not_exist.jpg"
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(nonexistent)

    # Should return a QPixmap, but it should be the blank error pixmap
    assert isinstance(result, QPixmap)
    # Error pixmap should have size matching thumbnailer size
    assert result.width() == 150
    assert result.height() == 150


def test_corrupt_image_returns_blank_pixmap(qapp, tmp_path):
    """Test that a corrupt image file returns a blank pixmap."""
    corrupt_file = tmp_path / "corrupt.jpg"
    # Write random bytes that aren't a valid image
    corrupt_file.write_bytes(b"\x00\x01\x02\x03random garbage data not an image")

    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(corrupt_file)

    assert isinstance(result, QPixmap)
    # Should return blank pixmap with configured size
    assert result.width() == 150
    assert result.height() == 150


def test_empty_file_returns_blank_pixmap(qapp, tmp_path):
    """Test that an empty file returns a blank pixmap."""
    empty_file = tmp_path / "empty.jpg"
    empty_file.write_bytes(b"")

    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(empty_file)

    assert isinstance(result, QPixmap)
    assert result.width() == 150
    assert result.height() == 150


def test_non_image_file_returns_blank_pixmap(qapp, tmp_path):
    """Test that a text file with .jpg extension returns blank pixmap."""
    text_file = tmp_path / "notanimage.jpg"
    text_file.write_text("This is just text, not an image!")

    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(text_file)

    assert isinstance(result, QPixmap)
    assert result.width() == 150
    assert result.height() == 150


def test_blank_pixmap_has_correct_size_for_custom_size(qapp, tmp_path):
    """Test that error pixmaps match custom thumbnailer size."""
    nonexistent = tmp_path / "missing.jpg"
    thumbnailer = Thumbnailer(size=200)

    result = thumbnailer.generate(nonexistent)

    # Error pixmap should match the custom size
    assert result.width() == 200
    assert result.height() == 200


def test_small_image_not_upscaled(qapp, tmp_path):
    """Test that small images are not upscaled beyond original size."""
    # Create 50x50 image (smaller than default 150 size)
    image_path = create_test_image(tmp_path, "small.jpg", 50, 50)
    thumbnailer = Thumbnailer(size=150)

    result = thumbnailer.generate(image_path)

    # Image should not be upscaled, should remain 50x50 or smaller
    assert result.width() <= 50
    assert result.height() <= 50


# Sharpness scoring tests (background queue path)


def test_queue_thumbnail_emits_sharpness_ready(qapp, qtbot, tmp_path):
    """Test that a queued decode reports a sharpness score for the photo."""
    image_path = create_test_image(tmp_path, "photo.jpg", 400, 300)
    thumbnailer = Thumbnailer(size=150)

    received = []
    thumbnailer.sharpness_ready.connect(
        lambda path, score: received.append((path, score))
    )

    thumbnailer.queue_thumbnail(image_path)
    qtbot.waitUntil(lambda: len(received) == 1, timeout=2000)

    path, score = received[0]
    assert path == image_path
    assert isinstance(score, float)
    assert score >= 0.0


def test_sharpness_ready_scores_full_resolution_not_thumbnail_size(
    qapp, qtbot, tmp_path
):
    """Test that scoring runs on the full image, not the shrunk thumbnail.

    A tiny thumbnail (size=20) would starve sharpness_score of the detail
    it needs - this checks the background path's score roughly matches
    scoring the original file directly, confirming the thumbnailer scores
    before its own thumbnail() shrink rather than after.
    """
    image_path = create_test_image(tmp_path, "photo.jpg", 400, 300)
    thumbnailer = Thumbnailer(size=20)  # aggressively small thumbnail target

    received = []
    thumbnailer.sharpness_ready.connect(lambda path, score: received.append(score))

    thumbnailer.queue_thumbnail(image_path)
    qtbot.waitUntil(lambda: len(received) == 1, timeout=2000)

    direct_score = sharpness_score(Image.open(image_path))
    # Both computed on the same full-resolution decode, so they should
    # match closely regardless of the thumbnail's tiny target size.
    assert abs(received[0] - direct_score) < 1e-6


def test_sharpness_ready_not_emitted_for_corrupt_file(qapp, qtbot, tmp_path):
    """Test that a decode failure reports no sharpness score."""
    corrupt_file = tmp_path / "corrupt.jpg"
    corrupt_file.write_bytes(b"\x00\x01\x02\x03random garbage data not an image")
    thumbnailer = Thumbnailer(size=150)

    sharpness_received = []
    thumbnail_received = []
    thumbnailer.sharpness_ready.connect(
        lambda path, score: sharpness_received.append(score)
    )
    thumbnailer.thumbnail_ready.connect(
        lambda path, pixmap: thumbnail_received.append(pixmap)
    )

    thumbnailer.queue_thumbnail(corrupt_file)
    # Wait on thumbnail_ready (always emitted, even on failure) rather than
    # sharpness_ready, which this test expects never fires.
    qtbot.waitUntil(lambda: len(thumbnail_received) == 1, timeout=2000)

    assert sharpness_received == []


def test_queue_thumbnail_scores_each_photo_once(qapp, qtbot, tmp_path):
    """Test that queuing several photos reports one score per photo."""
    paths = [create_test_image(tmp_path, f"photo{i}.jpg", 200, 200) for i in range(4)]
    thumbnailer = Thumbnailer(size=150)

    received = []
    thumbnailer.sharpness_ready.connect(lambda path, score: received.append(path))

    for path in paths:
        thumbnailer.queue_thumbnail(path)
    qtbot.waitUntil(lambda: len(received) == len(paths), timeout=3000)

    assert sorted(received) == sorted(paths)
