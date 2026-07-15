"""Tests for the ThumbnailWidget class."""

from unittest.mock import Mock

import pytest

from winnow.core.session import PhotoStatus, Session
from winnow.core.thumbnailer import Thumbnailer
from winnow.ui.thumbnail_strip import ThumbnailWidget


@pytest.fixture
def mock_strip():
    """Create a mock ThumbnailStrip for testing."""
    strip = Mock()
    strip.thumbnail_widgets = []
    return strip


def test_thumbnail_widget_displays_pixmap(qapp, portrait_image, mock_strip):
    """Test that ThumbnailWidget displays the provided pixmap."""
    # Create session and generate thumbnail
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Create widget
    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify pixmap is set
    assert widget.pixmap() is not None
    assert widget.pixmap().size() == pixmap.size()


def test_thumbnail_widget_unmarked_border(qapp, portrait_image, mock_strip):
    """Test that unmarked photo has gray 1px border."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify unmarked has gray 1px border
    assert "border: 3px solid #757575" in widget.styleSheet()


def test_thumbnail_widget_keeper_border(qapp, portrait_image, mock_strip):
    """Test that keeper photo has green 2px border."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Mark as keeper
    session.set_status(portrait_image, PhotoStatus.KEEPER)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify keeper has green 4px border
    assert "border: 4px solid #4CAF50" in widget.styleSheet()


def test_thumbnail_widget_delete_border(qapp, portrait_image, mock_strip):
    """Test that delete photo has red 2px border."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Mark for deletion
    session.set_status(portrait_image, PhotoStatus.DELETE)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify delete has red 4px border
    assert "border: 4px solid #F44336" in widget.styleSheet()


def test_thumbnail_widget_selected_border(qapp, portrait_image, mock_strip):
    """Test that selected photo has blue 3px border."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Mark as selected
    session.selected.append(portrait_image)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify selected has blue 5px border
    assert "border: 5px solid #2196F3" in widget.styleSheet()


def test_thumbnail_widget_selected_overrides_keeper(qapp, portrait_image, mock_strip):
    """Test that selected+keeper shows both blue border and green outline."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Mark as both keeper and selected
    session.set_status(portrait_image, PhotoStatus.KEEPER)
    session.selected.append(portrait_image)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify dual borders: blue selection border + green keeper outline
    assert "border: 5px solid #2196F3" in widget.styleSheet()
    assert "outline: 3px solid #4CAF50" in widget.styleSheet()


def test_thumbnail_widget_selected_overrides_delete(qapp, portrait_image, mock_strip):
    """Test that selected+delete shows both blue border and red outline."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Mark as both delete and selected
    session.set_status(portrait_image, PhotoStatus.DELETE)
    session.selected.append(portrait_image)

    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)

    # Verify dual borders: blue selection border + red delete outline
    assert "border: 5px solid #2196F3" in widget.styleSheet()
    assert "outline: 3px solid #F44336" in widget.styleSheet()


def test_thumbnail_widget_update_appearance_changes_border(
    qapp, portrait_image, mock_strip
):
    """Test that update_appearance() refreshes border after status change."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    thumbnailer = Thumbnailer(size=150)
    pixmap = thumbnailer.generate(portrait_image)

    # Start unmarked
    widget = ThumbnailWidget(pixmap, portrait_image, session, mock_strip)
    assert "border: 3px solid #757575" in widget.styleSheet()

    # Change to keeper
    session.set_status(portrait_image, PhotoStatus.KEEPER)
    widget.update_appearance()
    assert "border: 4px solid #4CAF50" in widget.styleSheet()

    # Change to delete
    session.set_status(portrait_image, PhotoStatus.DELETE)
    widget.update_appearance()
    assert "border: 4px solid #F44336" in widget.styleSheet()

    # Select it (should show blue border + red outline)
    session.selected.append(portrait_image)
    widget.update_appearance()
    assert "border: 5px solid #2196F3" in widget.styleSheet()
    assert "outline: 3px solid #F44336" in widget.styleSheet()


def test_thumbnail_widget_size_matches_pixmap(qapp, landscape_image, mock_strip):
    """Test that widget size matches pixmap dimensions."""
    session = Session(directory=landscape_image.parent, images=[landscape_image])
    thumbnailer = Thumbnailer(size=200)
    pixmap = thumbnailer.generate(landscape_image)

    widget = ThumbnailWidget(pixmap, landscape_image, session, mock_strip)

    # Verify widget size matches pixmap
    assert widget.width() == pixmap.width()
    assert widget.height() == pixmap.height()


def test_thumbnail_widget_with_different_images(
    qapp, portrait_image, landscape_image, mock_strip
):
    """Test that multiple widgets can exist with different images."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    thumbnailer = Thumbnailer(size=150)

    # Create two widgets
    pixmap1 = thumbnailer.generate(portrait_image)
    pixmap2 = thumbnailer.generate(landscape_image)
    widget1 = ThumbnailWidget(pixmap1, portrait_image, session, mock_strip)
    widget2 = ThumbnailWidget(pixmap2, landscape_image, session, mock_strip)

    # Mark one as keeper
    session.set_status(portrait_image, PhotoStatus.KEEPER)
    widget1.update_appearance()

    # Verify each has correct border
    assert "border: 4px solid #4CAF50" in widget1.styleSheet()
    assert "border: 3px solid #757575" in widget2.styleSheet()
