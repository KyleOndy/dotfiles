"""Tests for the comparison-mode focus ring."""

import pytest

from winnow.core.session import Session
from winnow.ui.viewing_area import ViewingArea

RING_COLOR = "#FFC107"


@pytest.fixture
def paths(tmp_path):
    """Five image paths (files need not exist; placeholders render)."""
    return [tmp_path / f"photo{n}.jpg" for n in range(5)]


@pytest.fixture
def viewing_area(qapp, tmp_path, paths):
    """ViewingArea over a session containing the five test paths."""
    session = Session(directory=tmp_path, images=list(paths))
    return ViewingArea(session)


def ring_flags(viewing_area):
    """Return each displayed tile's focus state in display order."""
    return [RING_COLOR in w.styleSheet() for w in viewing_area.image_widgets]


def test_single_view_has_no_ring(viewing_area, paths):
    """A single displayed photo never shows a focus ring."""
    viewing_area.set_images([paths[0]])

    assert viewing_area.focused_index == 0
    assert ring_flags(viewing_area) == [False]
    assert viewing_area.focused_path() == paths[0]


def test_fresh_comparison_focuses_first_tile(viewing_area, paths):
    """Entering comparison mode puts the ring on tile 0."""
    viewing_area.set_images(paths[:3])

    assert viewing_area.focused_index == 0
    assert ring_flags(viewing_area) == [True, False, False]


def test_move_focus_horizontal_is_clamped(viewing_area, paths):
    """h/l movement stops at both ends of the tile order."""
    viewing_area.set_images(paths[:3])

    viewing_area.move_focus(dx=-1)
    assert viewing_area.focused_index == 0

    viewing_area.move_focus(dx=1)
    viewing_area.move_focus(dx=1)
    viewing_area.move_focus(dx=1)
    assert viewing_area.focused_index == 2
    assert ring_flags(viewing_area) == [False, False, True]


def test_set_focused_index_clamps_out_of_range(viewing_area, paths):
    """Jumping past the last tile lands on the last tile."""
    viewing_area.set_images(paths[:3])

    viewing_area.set_focused_index(9)

    assert viewing_area.focused_index == 2


def test_move_focus_rows_in_2x2_grid(viewing_area, paths):
    """j/k move between grid rows, staying in the same column."""
    viewing_area.set_images(paths[:4])  # 2x2: (0,0) (0,1) (1,0) (1,1)
    viewing_area.set_focused_index(1)

    viewing_area.move_focus(dy=1)
    assert viewing_area.focused_index == 3

    viewing_area.move_focus(dy=-1)
    assert viewing_area.focused_index == 1

    viewing_area.move_focus(dy=-1)  # No row above: no-op
    assert viewing_area.focused_index == 1


def test_move_focus_down_to_shorter_row_lands_nearest(viewing_area, paths):
    """Moving into a shorter centered row picks the nearest column."""
    viewing_area.set_images(paths[:5])  # Rows of 3: last row is 2 tiles
    viewing_area.set_focused_index(2)  # Row 0, column 2

    viewing_area.move_focus(dy=1)

    assert viewing_area.focused_index == 4


def test_focus_follows_photo_when_other_tile_removed(viewing_area, paths):
    """Removing a different tile keeps the ring on the same photo."""
    viewing_area.set_images(paths[:3])
    viewing_area.set_focused_index(2)

    viewing_area.set_images([paths[0], paths[2]])  # paths[1] removed

    assert viewing_area.focused_path() == paths[2]
    assert viewing_area.focused_index == 1


def test_focus_holds_position_when_focused_tile_removed(viewing_area, paths):
    """Removing the focused tile focuses whatever slid into its slot."""
    viewing_area.set_images(paths[:3])
    viewing_area.set_focused_index(1)

    viewing_area.set_images([paths[0], paths[2]])  # Focused paths[1] removed

    assert viewing_area.focused_index == 1
    assert viewing_area.focused_path() == paths[2]


def test_fresh_selection_resets_focus(viewing_area, paths):
    """A selection that is not a subset restarts focus at tile 0."""
    viewing_area.set_images(paths[:3])
    viewing_area.set_focused_index(2)

    viewing_area.set_images([paths[3], paths[4]])

    assert viewing_area.focused_index == 0


def test_focused_path_none_when_empty(viewing_area):
    """No displayed images means no focused path."""
    viewing_area.set_images([])

    assert viewing_area.focused_path() is None
