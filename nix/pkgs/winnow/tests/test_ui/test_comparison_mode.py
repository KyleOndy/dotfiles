"""Tests for comparison mode in ViewingArea.

These tests verify that ViewingArea correctly handles multiple selected photos
by creating synchronized ImageWidgets in a grid layout with coordinated zoom/pan.
"""

from winnow.core.session import Session
from winnow.ui.image_widget import ImageWidget
from winnow.ui.viewing_area import ViewingArea


def test_two_images_creates_two_widgets(qapp, portrait_image, landscape_image):
    """Test that set_images with 2 paths creates 2 ImageWidgets."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Call with two paths
    viewing_area.set_images([portrait_image, landscape_image])

    # Should create 2 widgets
    assert len(viewing_area.image_widgets) == 2
    assert isinstance(viewing_area.image_widgets[0], ImageWidget)
    assert isinstance(viewing_area.image_widgets[1], ImageWidget)
    assert viewing_area.image_widgets[0].path == portrait_image
    assert viewing_area.image_widgets[1].path == landscape_image


def test_three_images_creates_three_widgets(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that set_images with 3 paths creates 3 ImageWidgets."""
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)

    # Call with three paths
    viewing_area.set_images([portrait_image, landscape_image, square_image])

    # Should create 3 widgets
    assert len(viewing_area.image_widgets) == 3
    assert all(isinstance(w, ImageWidget) for w in viewing_area.image_widgets)


def test_four_images_creates_four_widgets(qapp, tmp_path):
    """Test that set_images with 4 paths creates 4 ImageWidgets."""
    # Create 4 test images
    from PIL import Image

    images = []
    for i in range(4):
        path = tmp_path / f"img{i}.jpg"
        img = Image.new("RGB", (100, 100), color="red")
        img.save(path)
        images.append(path)

    session = Session(directory=tmp_path, images=images)
    viewing_area = ViewingArea(session)

    # Call with four paths
    viewing_area.set_images(images)

    # Should create 4 widgets
    assert len(viewing_area.image_widgets) == 4
    assert all(isinstance(w, ImageWidget) for w in viewing_area.image_widgets)


def test_five_images_creates_five_widgets(qapp, tmp_path):
    """Test that set_images with 5 paths creates 5 ImageWidgets."""
    # Create 5 test images
    from PIL import Image

    images = []
    for i in range(5):
        path = tmp_path / f"img{i}.jpg"
        img = Image.new("RGB", (100, 100), color="blue")
        img.save(path)
        images.append(path)

    session = Session(directory=tmp_path, images=images)
    viewing_area = ViewingArea(session)

    # Call with five paths
    viewing_area.set_images(images)

    # Should create 5 widgets
    assert len(viewing_area.image_widgets) == 5
    assert all(isinstance(w, ImageWidget) for w in viewing_area.image_widgets)


def test_widgets_have_synchronized_true(qapp, portrait_image, landscape_image):
    """Test that all widgets in comparison mode have synchronized=True."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image])

    # All widgets should have synchronized=True
    assert all(w.synchronized for w in viewing_area.image_widgets)


def test_widgets_added_to_correct_grid_positions(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that widgets are positioned at correct grid coordinates."""
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)

    # Set 3 images - should be laid out as 1x3 (one row, three columns)
    viewing_area.set_images([portrait_image, landscape_image, square_image])

    # Verify widgets are in layout at correct positions
    layout = viewing_area.layout()

    # First widget at (0, 0)
    widget_at_0_0 = layout.itemAtPosition(0, 0)
    assert widget_at_0_0 is not None
    assert widget_at_0_0.widget() is viewing_area.image_widgets[0]

    # Second widget at (0, 1)
    widget_at_0_1 = layout.itemAtPosition(0, 1)
    assert widget_at_0_1 is not None
    assert widget_at_0_1.widget() is viewing_area.image_widgets[1]

    # Third widget at (0, 2)
    widget_at_0_2 = layout.itemAtPosition(0, 2)
    assert widget_at_0_2 is not None
    assert widget_at_0_2.widget() is viewing_area.image_widgets[2]


def test_each_widget_has_own_path(qapp, portrait_image, landscape_image, square_image):
    """Test that each widget displays a different image."""
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)

    paths = [portrait_image, landscape_image, square_image]
    viewing_area.set_images(paths)

    # Each widget should have the corresponding path
    for i, widget in enumerate(viewing_area.image_widgets):
        assert widget.path == paths[i]


def test_all_widgets_registered_with_controller(qapp, portrait_image, landscape_image):
    """Test that all widgets are registered with the sync controller."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image])

    # Sync controller should have both widgets
    assert len(viewing_area.sync_controller.widgets) == 2
    assert viewing_area.sync_controller.widgets[0] is viewing_area.image_widgets[0]
    assert viewing_area.sync_controller.widgets[1] is viewing_area.image_widgets[1]


def test_zooming_one_widget_zooms_all(qapp, portrait_image, landscape_image):
    """Test that zooming one widget synchronizes zoom to all others."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image])

    widget1, widget2 = viewing_area.image_widgets

    # Both start at 1.0 zoom
    assert widget1.zoom_level == 1.0
    assert widget2.zoom_level == 1.0

    # Zoom widget1 to 2.5
    widget1.set_zoom(2.5, emit_signal=True)

    # Widget2 should be synchronized to 2.5
    assert widget1.zoom_level == 2.5
    assert widget2.zoom_level == 2.5


def test_panning_one_widget_pans_all(qapp, portrait_image, landscape_image):
    """Test that panning one widget synchronizes pan to all others."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image])

    widget1, widget2 = viewing_area.image_widgets

    # Both start at (0, 0) pan
    assert widget1.pan_offset.x() == 0
    assert widget1.pan_offset.y() == 0
    assert widget2.pan_offset.x() == 0
    assert widget2.pan_offset.y() == 0

    # Pan widget1 to (100, 50)
    widget1.set_pan(100, 50, emit_signal=True)

    # Widget2 should be synchronized
    assert widget1.pan_offset.x() == 100
    assert widget1.pan_offset.y() == 50
    assert widget2.pan_offset.x() == 100
    assert widget2.pan_offset.y() == 50


def test_zoom_syncs_across_three_widgets(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that zoom synchronizes across 3 widgets."""
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image, square_image])

    widget1, widget2, widget3 = viewing_area.image_widgets

    # Zoom the middle widget
    widget2.set_zoom(3.0, emit_signal=True)

    # All should be at 3.0
    assert widget1.zoom_level == 3.0
    assert widget2.zoom_level == 3.0
    assert widget3.zoom_level == 3.0


def test_pan_syncs_across_three_widgets(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that pan synchronizes across 3 widgets."""
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image, square_image])

    widget1, widget2, widget3 = viewing_area.image_widgets

    # Pan the first widget
    widget1.set_pan(75, 125, emit_signal=True)

    # All should be at (75, 125)
    assert widget1.pan_offset.x() == 75
    assert widget1.pan_offset.y() == 125
    assert widget2.pan_offset.x() == 75
    assert widget2.pan_offset.y() == 125
    assert widget3.pan_offset.x() == 75
    assert widget3.pan_offset.y() == 125


def test_each_widget_has_status_overlay(qapp, portrait_image, landscape_image):
    """Test that each widget has its own status overlay."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    viewing_area.set_images([portrait_image, landscape_image])

    # Each widget should have an overlay
    for widget in viewing_area.image_widgets:
        assert widget.overlay is not None
        assert hasattr(widget.overlay, "mark_requested")


def test_switching_from_single_to_comparison_clears(
    qapp, portrait_image, landscape_image
):
    """Test that switching from single to comparison mode clears old widget."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Start with single image
    viewing_area.set_images([portrait_image])
    assert len(viewing_area.image_widgets) == 1
    first_widget = viewing_area.image_widgets[0]
    assert not first_widget.synchronized

    # Switch to comparison mode
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # New widgets should be different instances
    assert viewing_area.image_widgets[0] is not first_widget
    assert viewing_area.image_widgets[1] is not first_widget

    # New widgets should be synchronized
    assert all(w.synchronized for w in viewing_area.image_widgets)


def test_switching_from_comparison_to_single_clears(
    qapp, portrait_image, landscape_image
):
    """Test that switching from comparison to single mode clears old widgets."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Start with comparison mode
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2
    old_widgets = list(viewing_area.image_widgets)

    # Switch to single image
    viewing_area.set_images([landscape_image])
    assert len(viewing_area.image_widgets) == 1

    # New widget should be a different instance
    assert viewing_area.image_widgets[0] not in old_widgets
    assert not viewing_area.image_widgets[0].synchronized

    # Sync controller should be cleared
    assert len(viewing_area.sync_controller.widgets) == 0


def test_empty_label_hidden_in_comparison_mode(qapp, portrait_image, landscape_image):
    """Test that empty label is hidden when in comparison mode."""
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)

    # Initially visible
    assert not viewing_area.empty_label.isHidden()

    # Hide when switching to comparison mode
    viewing_area.set_images([portrait_image, landscape_image])
    assert viewing_area.empty_label.isHidden()


def test_four_images_in_2x2_grid(qapp, tmp_path):
    """Test that 4 images are positioned in a 2x2 grid."""
    # Create 4 test images
    from PIL import Image

    images = []
    for i in range(4):
        path = tmp_path / f"img{i}.jpg"
        img = Image.new("RGB", (100, 100), color="green")
        img.save(path)
        images.append(path)

    session = Session(directory=tmp_path, images=images)
    viewing_area = ViewingArea(session)

    viewing_area.set_images(images)

    layout = viewing_area.layout()

    # Verify 2x2 grid positions
    # (0, 0), (0, 1), (1, 0), (1, 1)
    assert layout.itemAtPosition(0, 0).widget() is viewing_area.image_widgets[0]
    assert layout.itemAtPosition(0, 1).widget() is viewing_area.image_widgets[1]
    assert layout.itemAtPosition(1, 0).widget() is viewing_area.image_widgets[2]
    assert layout.itemAtPosition(1, 1).widget() is viewing_area.image_widgets[3]


def test_switching_between_different_comparison_counts(qapp, tmp_path):
    """Test switching between different numbers of images in comparison mode."""
    # Create 5 test images
    from PIL import Image

    images = []
    for i in range(5):
        path = tmp_path / f"img{i}.jpg"
        img = Image.new("RGB", (100, 100), color="purple")
        img.save(path)
        images.append(path)

    session = Session(directory=tmp_path, images=images)
    viewing_area = ViewingArea(session)

    # Start with 2 images
    viewing_area.set_images(images[:2])
    assert len(viewing_area.image_widgets) == 2
    assert len(viewing_area.sync_controller.widgets) == 2

    # Switch to 5 images
    viewing_area.set_images(images)
    assert len(viewing_area.image_widgets) == 5
    assert len(viewing_area.sync_controller.widgets) == 5

    # Switch to 3 images
    viewing_area.set_images(images[:3])
    assert len(viewing_area.image_widgets) == 3
    assert len(viewing_area.sync_controller.widgets) == 3


# Zoom/Pan State Preservation Tests


def test_zoom_pan_preserved_4_to_5_photos(qapp, tmp_path):
    """Test zoom/pan state preserved when adding 5th photo to 4-photo comparison.

    This is the exact scenario mentioned in the task: when selection changes
    during comparison mode (e.g., 4 photos → 5 photos), new ImageWidgets should
    inherit current zoom_level and pan_offset from existing widgets.

    When the grid layout changes (4 images = 2x2, 5 images = 2x3), the
    cell size changes, so pan offset is scaled proportionally to maintain the
    same visual content in view.
    """
    from PIL import Image

    # Create 5 test images
    images = []
    for i in range(5):
        path = tmp_path / f"img{i}.jpg"
        img = Image.new("RGB", (800, 600), color="blue")
        img.save(path)
        images.append(path)

    session = Session(directory=tmp_path, images=images)
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)  # Set known size for predictable cell sizes

    # Start with 4 images in 2x2 grid
    viewing_area.set_images(images[:4])
    assert len(viewing_area.image_widgets) == 4

    # Set custom zoom and pan on all widgets
    custom_zoom = 2.5
    custom_pan_x = 150
    custom_pan_y = 100

    for widget in viewing_area.image_widgets:
        widget.set_zoom(custom_zoom, emit_signal=False)
        widget.set_pan(custom_pan_x, custom_pan_y, emit_signal=False)

    # Add 5th image - cell size will change from 600x400 to 400x400
    viewing_area.set_images(images)
    assert len(viewing_area.image_widgets) == 5

    # Zoom should be preserved
    for widget in viewing_area.image_widgets:
        assert widget.zoom_level == custom_zoom

    # Pan offset should be adjusted to maintain visual center
    # Old viewport: 600×400, new viewport: 400×400
    # Delta in viewport center: (200 - 300, 200 - 200) = (-100, 0)
    # At zoom 2.5: delta in original coords = (-100 / 2.5, 0) = (-40, 0)
    # Adjusted pan: (150 - (-40), 100 - 0) = (190, 100)
    expected_pan_x = 190
    expected_pan_y = 100
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == expected_pan_x
        assert widget.pan_offset.y() == expected_pan_y


def test_zoom_pan_preserved_2_to_3_photos(
    qapp, portrait_image, landscape_image, square_image
):
    """Test zoom/pan state preserved when transitioning 2→3 photos.

    Pan offset is in original-image coordinates, so it remains constant.
    """
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with 2 images (1x2 layout)
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Set custom zoom and pan
    custom_zoom = 1.5
    custom_pan_x = 75
    custom_pan_y = 125

    for widget in viewing_area.image_widgets:
        widget.set_zoom(custom_zoom, emit_signal=False)
        widget.set_pan(custom_pan_x, custom_pan_y, emit_signal=False)

    # Add 3rd image (1x3 layout)
    viewing_area.set_images([portrait_image, landscape_image, square_image])
    assert len(viewing_area.image_widgets) == 3

    # Zoom should be preserved
    for widget in viewing_area.image_widgets:
        assert widget.zoom_level == custom_zoom

    # Pan offset should be adjusted to maintain visual center
    # Old viewport: 600×800, new viewport: 400×800
    # Delta in viewport center: (200 - 300, 400 - 400) = (-100, 0)
    # At zoom 1.5: delta in original coords = (-100 / 1.5, 0) = (-66.66..., 0) → (-66, 0)
    # Adjusted pan: (75 - (-66), 125 - 0) = (141, 125)
    expected_pan_x = 141
    expected_pan_y = 125
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == expected_pan_x
        assert widget.pan_offset.y() == expected_pan_y


def test_zoom_pan_preserved_3_to_2_photos(
    qapp, portrait_image, landscape_image, square_image
):
    """Test zoom/pan state preserved when removing photo from comparison.

    Pan offset is in original-image coordinates, so it remains constant.
    """
    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with 3 images (1x3 layout)
    viewing_area.set_images([portrait_image, landscape_image, square_image])
    assert len(viewing_area.image_widgets) == 3

    # Set custom zoom and pan
    custom_zoom = 3.0
    custom_pan_x = 200
    custom_pan_y = 150

    for widget in viewing_area.image_widgets:
        widget.set_zoom(custom_zoom, emit_signal=False)
        widget.set_pan(custom_pan_x, custom_pan_y, emit_signal=False)

    # Remove one image (back to 1x2 layout)
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Zoom should be preserved
    for widget in viewing_area.image_widgets:
        assert widget.zoom_level == custom_zoom

    # Pan offset should be adjusted to maintain visual center
    # Old viewport: 400×800, new viewport: 600×800
    # Delta in viewport center: (300 - 200, 400 - 400) = (100, 0)
    # At zoom 3.0: delta in original coords = (100 / 3.0, 0) = (33.33..., 0) → (33, 0)
    # Adjusted pan: (200 - 33, 150 - 0) = (167, 150)
    expected_pan_x = 167
    expected_pan_y = 150
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == expected_pan_x
        assert widget.pan_offset.y() == expected_pan_y


def test_zoom_pan_preserved_single_to_comparison(qapp, portrait_image, landscape_image):
    """Test zoom/pan state preserved when adding second image.

    Pan offset is in original-image coordinates, so it remains constant.
    """
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with single image (uses full viewport)
    viewing_area.set_images([portrait_image])
    assert len(viewing_area.image_widgets) == 1
    widget = viewing_area.image_widgets[0]

    # Set custom zoom and pan on single image
    custom_zoom = 2.0
    custom_pan_x = 50
    custom_pan_y = 75

    widget.set_zoom(custom_zoom, emit_signal=False)
    widget.set_pan(custom_pan_x, custom_pan_y, emit_signal=False)

    # Add second image for comparison (1x2 layout)
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Zoom should be preserved
    for widget in viewing_area.image_widgets:
        assert widget.zoom_level == custom_zoom

    # Pan offset should be adjusted to maintain visual center
    # Old viewport: 1200×800 (full), new viewport: 600×800
    # Delta in viewport center: (300 - 600, 400 - 400) = (-300, 0)
    # At zoom 2.0: delta in original coords = (-300 / 2.0, 0) = (-150, 0)
    # Adjusted pan: (50 - (-150), 75 - 0) = (200, 75)
    expected_pan_x = 200
    expected_pan_y = 75
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == expected_pan_x
        assert widget.pan_offset.y() == expected_pan_y


def test_zoom_pan_preserved_comparison_to_single(qapp, portrait_image, landscape_image):
    """Test zoom/pan state preserved when switching from comparison to single.

    Pan offset is in original-image coordinates, so it remains constant.
    """
    session = Session(
        directory=portrait_image.parent, images=[portrait_image, landscape_image]
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with comparison mode (1x2 layout)
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Set custom zoom and pan
    custom_zoom = 1.75
    custom_pan_x = 125
    custom_pan_y = 100

    for widget in viewing_area.image_widgets:
        widget.set_zoom(custom_zoom, emit_signal=False)
        widget.set_pan(custom_pan_x, custom_pan_y, emit_signal=False)

    # Switch to single image (full viewport)
    viewing_area.set_images([landscape_image])
    assert len(viewing_area.image_widgets) == 1

    # Zoom should be preserved
    widget = viewing_area.image_widgets[0]
    assert widget.zoom_level == custom_zoom

    # Pan offset should be adjusted to maintain visual center
    # Old viewport: 600×800, new viewport: 1200×800 (full)
    # Delta in viewport center: (600 - 300, 400 - 400) = (300, 0)
    # At zoom 1.75: delta in original coords = (300 / 1.75, 0) = (171.42..., 0) → (171, 0)
    # Adjusted pan: (125 - 171, 100 - 0) = (-46, 100)
    expected_pan_x = -46
    expected_pan_y = 100
    assert widget.pan_offset.x() == expected_pan_x
    assert widget.pan_offset.y() == expected_pan_y


def test_default_zoom_pan_when_no_previous_state(qapp, portrait_image):
    """Test that default zoom/pan used when no previous state exists."""
    session = Session(directory=portrait_image.parent, images=[portrait_image])
    viewing_area = ViewingArea(session)

    # Set images for first time (no previous state)
    viewing_area.set_images([portrait_image])
    assert len(viewing_area.image_widgets) == 1

    widget = viewing_area.image_widgets[0]

    # Should have default zoom (1.0) and default pan (0, 0)
    assert widget.zoom_level == 1.0
    assert widget.pan_offset.x() == 0
    assert widget.pan_offset.y() == 0


def test_individual_pan_offset_preserved_when_adding_image(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that individual_pan_offset is preserved per-image when adding to comparison.

    Each image's individual offset is saved and restored independently. New images
    get a default offset of (0, 0).
    """
    from PySide6.QtCore import QPoint

    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with 2 images in comparison mode
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Set synchronized pan (simulating normal pan/drag). Pan only applies once
    # zoomed in - fit mode ignores and zeroes it - so exit fit mode first, as
    # a real zoom-then-pan interaction would.
    synchronized_pan_x = 100
    synchronized_pan_y = 75
    for widget in viewing_area.image_widgets:
        widget.fit_mode = False
        widget.set_pan(synchronized_pan_x, synchronized_pan_y, emit_signal=False)

    # Set different individual pan offsets per widget (simulating Shift+drag)
    portrait_offset = QPoint(50, 30)
    landscape_offset = QPoint(-20, 15)
    viewing_area.image_widgets[0].individual_pan_offset = (
        portrait_offset  # portrait_image
    )
    viewing_area.image_widgets[1].individual_pan_offset = (
        landscape_offset  # landscape_image
    )

    # Add 3rd image to comparison
    viewing_area.set_images([portrait_image, landscape_image, square_image])
    assert len(viewing_area.image_widgets) == 3

    # All widgets should have the same synchronized pan_offset, adjusted for
    # the grid cell size change (2->3 photos narrows each cell) so the same
    # visual point stays centered - see adjust_pan_for_viewport_change.
    first_pan = viewing_area.image_widgets[0].pan_offset
    assert (
        first_pan.x() != synchronized_pan_x
    )  # cell width changed, so pan was compensated
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == first_pan.x()
        assert widget.pan_offset.y() == first_pan.y()

    # Each widget should have its own individual_pan_offset restored by path
    widgets_by_path = {w.path: w for w in viewing_area.image_widgets}
    assert widgets_by_path[portrait_image].individual_pan_offset == portrait_offset
    assert widgets_by_path[landscape_image].individual_pan_offset == landscape_offset
    assert widgets_by_path[square_image].individual_pan_offset == QPoint(0, 0)


def test_individual_pan_offset_preserved_when_removing_image(
    qapp, portrait_image, landscape_image, square_image
):
    """Test that individual_pan_offset is preserved per-image when removing from comparison.

    Each remaining image gets its own saved offset back; removed images are forgotten.
    """
    from PySide6.QtCore import QPoint

    session = Session(
        directory=portrait_image.parent,
        images=[portrait_image, landscape_image, square_image],
    )
    viewing_area = ViewingArea(session)
    viewing_area.resize(1200, 800)

    # Start with 3 images in comparison mode
    viewing_area.set_images([portrait_image, landscape_image, square_image])
    assert len(viewing_area.image_widgets) == 3

    # Set synchronized pan. Pan only applies once zoomed in - fit mode ignores
    # and zeroes it - so exit fit mode first, as a real zoom-then-pan
    # interaction would.
    synchronized_pan_x = 150
    synchronized_pan_y = 125
    for widget in viewing_area.image_widgets:
        widget.fit_mode = False
        widget.set_pan(synchronized_pan_x, synchronized_pan_y, emit_signal=False)

    # Set different individual pan offsets per widget
    portrait_offset = QPoint(75, 50)
    landscape_offset = QPoint(-30, 20)
    widgets_by_path = {w.path: w for w in viewing_area.image_widgets}
    widgets_by_path[portrait_image].individual_pan_offset = portrait_offset
    widgets_by_path[landscape_image].individual_pan_offset = landscape_offset

    # Remove one image (back to 2 images)
    viewing_area.set_images([portrait_image, landscape_image])
    assert len(viewing_area.image_widgets) == 2

    # Both widgets should have the same synchronized pan_offset, adjusted for
    # the grid cell size change (3->2 photos widens each cell) so the same
    # visual point stays centered - see adjust_pan_for_viewport_change.
    first_pan = viewing_area.image_widgets[0].pan_offset
    assert (
        first_pan.x() != synchronized_pan_x
    )  # cell width changed, so pan was compensated
    for widget in viewing_area.image_widgets:
        assert widget.pan_offset.x() == first_pan.x()
        assert widget.pan_offset.y() == first_pan.y()

    # Each remaining widget should have its own individual_pan_offset restored by path
    widgets_by_path = {w.path: w for w in viewing_area.image_widgets}
    assert widgets_by_path[portrait_image].individual_pan_offset == portrait_offset
    assert widgets_by_path[landscape_image].individual_pan_offset == landscape_offset
