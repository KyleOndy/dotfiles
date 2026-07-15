"""Demonstration test using fixture images."""

from winnow.core.thumbnailer import Thumbnailer


def test_portrait_fixture_with_thumbnailer(qapp, portrait_image):
    """Test that the portrait fixture works with thumbnailer."""
    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(portrait_image)

    # Portrait is 100x200, so height is limiting dimension
    # Should scale to 75x150
    assert result.height() == 150
    assert result.width() == 75
    assert not result.isNull()


def test_landscape_fixture_with_thumbnailer(qapp, landscape_image):
    """Test that the landscape fixture works with thumbnailer."""
    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(landscape_image)

    # Landscape is 200x100, so width is limiting dimension
    # Should scale to 150x75
    assert result.width() == 150
    assert result.height() == 75
    assert not result.isNull()


def test_square_fixture_with_thumbnailer(qapp, square_image):
    """Test that the square fixture works with thumbnailer."""
    thumbnailer = Thumbnailer(size=150)
    result = thumbnailer.generate(square_image)

    # Square is 100x100, shouldn't be upscaled
    assert result.width() == 100
    assert result.height() == 100
    assert not result.isNull()
