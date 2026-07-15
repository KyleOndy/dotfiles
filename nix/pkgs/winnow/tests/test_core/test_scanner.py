"""Tests for the scanner module."""

import os
from pathlib import Path

import pytest

from winnow.core.scanner import scan_directory


def test_scan_finds_jpeg_files(tmp_path):
    """Test that scan_directory finds all JPEG files with various extensions."""
    # Create test files with different JPEG extensions
    (tmp_path / "photo1.jpg").touch()
    (tmp_path / "photo2.jpeg").touch()
    (tmp_path / "photo3.JPG").touch()
    (tmp_path / "photo4.JPEG").touch()

    result = scan_directory(tmp_path)

    assert len(result) == 4
    assert all(isinstance(p, Path) for p in result)
    assert {p.name for p in result} == {
        "photo1.jpg",
        "photo2.jpeg",
        "photo3.JPG",
        "photo4.JPEG",
    }


def test_scan_filters_non_jpeg(tmp_path):
    """Test that non-JPEG files are filtered out."""
    # Create mix of JPEG and non-JPEG files
    (tmp_path / "photo.jpg").touch()
    (tmp_path / "image.png").touch()
    (tmp_path / "document.txt").touch()
    (tmp_path / "video.mp4").touch()
    (tmp_path / "another.jpeg").touch()

    result = scan_directory(tmp_path)

    assert len(result) == 2
    assert {p.name for p in result} == {"photo.jpg", "another.jpeg"}


def test_scan_sorts_by_filename(tmp_path):
    """Test that results are sorted alphabetically by filename."""
    # Create files in non-alphabetical order
    (tmp_path / "zebra.jpg").touch()
    (tmp_path / "alpha.jpg").touch()
    (tmp_path / "charlie.jpg").touch()
    (tmp_path / "bravo.jpg").touch()

    result = scan_directory(tmp_path)

    # Verify sorted order
    filenames = [p.name for p in result]
    assert filenames == ["alpha.jpg", "bravo.jpg", "charlie.jpg", "zebra.jpg"]


def test_scan_non_recursive(tmp_path):
    """Test that subdirectories are not scanned recursively."""
    # Create files in main directory
    (tmp_path / "main.jpg").touch()

    # Create subdirectory with its own images
    subdir = tmp_path / "subdir"
    subdir.mkdir()
    (subdir / "nested.jpg").touch()

    result = scan_directory(tmp_path)

    # Should only find the file in the main directory
    assert len(result) == 1
    assert result[0].name == "main.jpg"


def test_scan_empty_directory(tmp_path):
    """Test that scanning an empty directory returns an empty list."""
    result = scan_directory(tmp_path)

    assert result == []
    assert isinstance(result, list)


def test_scan_no_jpegs(tmp_path):
    """Test that a directory with no JPEG files returns an empty list."""
    # Create only non-JPEG files
    (tmp_path / "image.png").touch()
    (tmp_path / "document.pdf").touch()
    (tmp_path / "data.json").touch()

    result = scan_directory(tmp_path)

    assert result == []


def test_scan_ignores_directories(tmp_path):
    """Test that directories are ignored even if they have JPEG-like names."""
    # Create a regular JPEG file
    (tmp_path / "photo.jpg").touch()

    # Create a directory with a JPEG-like name
    (tmp_path / "folder.jpg").mkdir()

    result = scan_directory(tmp_path)

    # Should only find the file, not the directory
    assert len(result) == 1
    assert result[0].name == "photo.jpg"
    assert result[0].is_file()


def test_scan_case_insensitive_extensions(tmp_path):
    """Test that extension matching is case-insensitive."""
    # Create files with mixed case extensions
    (tmp_path / "image1.jpg").touch()
    (tmp_path / "image2.JPG").touch()
    (tmp_path / "image3.Jpg").touch()
    (tmp_path / "image4.JpG").touch()
    (tmp_path / "image5.jpeg").touch()
    (tmp_path / "image6.JPEG").touch()
    (tmp_path / "image7.JpEg").touch()

    result = scan_directory(tmp_path)

    # All should be found regardless of case
    assert len(result) == 7


def test_scan_nonexistent_directory_raises_oserror(tmp_path):
    """A directory that doesn't exist (e.g. removed after being validated by
    the caller) raises a clean OSError instead of an unhandled traceback."""
    missing = tmp_path / "does-not-exist"

    with pytest.raises(OSError):
        scan_directory(missing)


@pytest.mark.skipif(
    os.geteuid() == 0, reason="permission bits are not enforced for root"
)
def test_scan_unreadable_directory_raises_oserror(tmp_path):
    """A directory that exists but can't be read raises a clean OSError
    instead of an unhandled PermissionError traceback."""
    (tmp_path / "photo.jpg").touch()
    os.chmod(tmp_path, 0o000)

    try:
        with pytest.raises(OSError):
            scan_directory(tmp_path)
    finally:
        os.chmod(tmp_path, 0o755)


def test_scan_skips_broken_symlink(tmp_path):
    """A broken symlink with a .jpg name is skipped, not returned or crashed on."""
    (tmp_path / "real.jpg").touch()
    broken_link = tmp_path / "broken.jpg"
    broken_link.symlink_to(tmp_path / "does-not-exist.jpg")

    result = scan_directory(tmp_path)

    assert [p.name for p in result] == ["real.jpg"]


def test_scan_typical_photo_naming(tmp_path):
    """Test with typical photo naming patterns."""
    # Create files with realistic photo names
    (tmp_path / "IMG_0001.JPG").touch()
    (tmp_path / "IMG_0002.JPG").touch()
    (tmp_path / "IMG_0010.JPG").touch()
    (tmp_path / "DSC_1234.jpg").touch()
    (tmp_path / "P1000567.jpeg").touch()

    result = scan_directory(tmp_path)

    assert len(result) == 5
    # Verify alphabetical sorting (note: IMG_0010 comes after IMG_0002)
    filenames = [p.name for p in result]
    assert filenames == [
        "DSC_1234.jpg",
        "IMG_0001.JPG",
        "IMG_0002.JPG",
        "IMG_0010.JPG",
        "P1000567.jpeg",
    ]
