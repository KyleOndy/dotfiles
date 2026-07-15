"""Tests for SynchronizedViewController class."""

from winnow.core.session import Session
from winnow.ui.image_widget import ImageWidget
from winnow.ui.viewing_area import SynchronizedViewController


def test_synchronized_controller_initialization(qapp, tmp_path):
    """Test that SynchronizedViewController initializes with empty widget list."""
    controller = SynchronizedViewController()

    assert controller.widgets == []
    assert isinstance(controller.widgets, list)


def test_add_widget_appends_to_list(qapp, portrait_image):
    """Test that add_widget() adds widget to the list."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    controller = SynchronizedViewController()
    widget = ImageWidget(portrait_image, session, synchronized=True)

    controller.add_widget(widget)

    assert len(controller.widgets) == 1
    assert controller.widgets[0] is widget


def test_add_multiple_widgets(qapp, portrait_image, landscape_image):
    """Test that add_widget() can add multiple widgets."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    assert len(controller.widgets) == 2
    assert controller.widgets[0] is widget1
    assert controller.widgets[1] is widget2


def test_clear_empties_widget_list(qapp, portrait_image):
    """Test that clear() empties the widget list."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    controller = SynchronizedViewController()
    widget = ImageWidget(portrait_image, session, synchronized=True)

    controller.add_widget(widget)
    assert len(controller.widgets) == 1

    controller.clear()
    assert len(controller.widgets) == 0
    assert controller.widgets == []


def test_zoom_change_broadcasts_to_other_widgets(qapp, portrait_image, landscape_image):
    """Test that zoom change in one widget broadcasts to others."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Both start at 1.0 zoom
    assert widget1.zoom_level == 1.0
    assert widget2.zoom_level == 1.0

    # Trigger zoom change on widget1 by calling set_zoom
    # This will emit the signal which controller is listening to
    widget1.set_zoom(2.5, emit_signal=True)

    # Widget2 should be updated to match
    assert widget1.zoom_level == 2.5
    assert widget2.zoom_level == 2.5


def test_zoom_change_does_not_affect_sender(qapp, portrait_image, landscape_image):
    """Test that sender widget is not affected by its own broadcast."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Change zoom on widget1
    widget1.set_zoom(3.0, emit_signal=True)

    # Verify widget1 stayed at 3.0 (didn't get re-set)
    assert widget1.zoom_level == 3.0
    assert widget2.zoom_level == 3.0


def test_pan_change_broadcasts_to_other_widgets(qapp, portrait_image, landscape_image):
    """Test that pan change in one widget broadcasts to others."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Both start at (0, 0) pan
    assert widget1.pan_offset.x() == 0
    assert widget1.pan_offset.y() == 0
    assert widget2.pan_offset.x() == 0
    assert widget2.pan_offset.y() == 0

    # Trigger pan change on widget1
    widget1.set_pan(100, 50, emit_signal=True)

    # Widget2 should be updated to match
    assert widget1.pan_offset.x() == 100
    assert widget1.pan_offset.y() == 50
    assert widget2.pan_offset.x() == 100
    assert widget2.pan_offset.y() == 50


def test_pan_change_does_not_affect_sender(qapp, portrait_image, landscape_image):
    """Test that sender widget is not affected by its own pan broadcast."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Change pan on widget1
    widget1.set_pan(75, 125, emit_signal=True)

    # Verify widget1 stayed at (75, 125) (didn't get re-set)
    assert widget1.pan_offset.x() == 75
    assert widget1.pan_offset.y() == 125
    assert widget2.pan_offset.x() == 75
    assert widget2.pan_offset.y() == 125


def test_zoom_broadcasts_to_all_except_sender(qapp, tmp_path):
    """Test that zoom broadcasts to all widgets except the sender."""
    # Create test images
    img1 = tmp_path / "img1.jpg"
    img2 = tmp_path / "img2.jpg"
    img3 = tmp_path / "img3.jpg"

    # Create dummy JPEG files
    from PIL import Image

    for path in [img1, img2, img3]:
        img = Image.new("RGB", (100, 100), color="red")
        img.save(path)

    session = Session(directory=tmp_path, images=[img1, img2, img3])
    controller = SynchronizedViewController()

    widget1 = ImageWidget(img1, session, synchronized=True)
    widget2 = ImageWidget(img2, session, synchronized=True)
    widget3 = ImageWidget(img3, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)
    controller.add_widget(widget3)

    # Change zoom on widget2 (the middle one)
    widget2.set_zoom(4.0, emit_signal=True)

    # All should have the same zoom
    assert widget1.zoom_level == 4.0
    assert widget2.zoom_level == 4.0
    assert widget3.zoom_level == 4.0


def test_pan_broadcasts_to_all_except_sender(qapp, tmp_path):
    """Test that pan broadcasts to all widgets except the sender."""
    # Create test images
    img1 = tmp_path / "img1.jpg"
    img2 = tmp_path / "img2.jpg"
    img3 = tmp_path / "img3.jpg"

    # Create dummy JPEG files
    from PIL import Image

    for path in [img1, img2, img3]:
        img = Image.new("RGB", (100, 100), color="blue")
        img.save(path)

    session = Session(directory=tmp_path, images=[img1, img2, img3])
    controller = SynchronizedViewController()

    widget1 = ImageWidget(img1, session, synchronized=True)
    widget2 = ImageWidget(img2, session, synchronized=True)
    widget3 = ImageWidget(img3, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)
    controller.add_widget(widget3)

    # Change pan on widget3
    widget3.set_pan(200, 150, emit_signal=True)

    # All should have the same pan
    assert widget1.pan_offset.x() == 200
    assert widget1.pan_offset.y() == 150
    assert widget2.pan_offset.x() == 200
    assert widget2.pan_offset.y() == 150
    assert widget3.pan_offset.x() == 200
    assert widget3.pan_offset.y() == 150


def test_single_widget_no_broadcast_needed(qapp, portrait_image):
    """Test that controller works with single widget (no broadcast needed)."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    controller = SynchronizedViewController()

    widget = ImageWidget(portrait_image, session, synchronized=True)
    controller.add_widget(widget)

    # Change zoom - should work without errors
    widget.set_zoom(1.5, emit_signal=True)
    assert widget.zoom_level == 1.5

    # Change pan - should work without errors
    widget.set_pan(50, 50, emit_signal=True)
    assert widget.pan_offset.x() == 50
    assert widget.pan_offset.y() == 50


def test_multiple_rapid_zoom_changes(qapp, portrait_image, landscape_image):
    """Test that multiple rapid zoom changes are handled correctly."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Rapid zoom changes
    widget1.set_zoom(1.5, emit_signal=True)
    widget1.set_zoom(2.0, emit_signal=True)
    widget1.set_zoom(2.5, emit_signal=True)

    # Both should end up at final zoom level
    assert widget1.zoom_level == 2.5
    assert widget2.zoom_level == 2.5


def test_multiple_rapid_pan_changes(qapp, portrait_image, landscape_image):
    """Test that multiple rapid pan changes are handled correctly."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    controller = SynchronizedViewController()

    widget1 = ImageWidget(portrait_image, session, synchronized=True)
    widget2 = ImageWidget(landscape_image, session, synchronized=True)

    controller.add_widget(widget1)
    controller.add_widget(widget2)

    # Rapid pan changes
    widget2.set_pan(10, 10, emit_signal=True)
    widget2.set_pan(20, 20, emit_signal=True)
    widget2.set_pan(30, 40, emit_signal=True)

    # Both should end up at final pan position
    assert widget1.pan_offset.x() == 30
    assert widget1.pan_offset.y() == 40
    assert widget2.pan_offset.x() == 30
    assert widget2.pan_offset.y() == 40
