"""End-to-end tests for the vim-flavored keyboard scheme.

These press real keys with qtbot.keyClick against an active window, so they
exercise QShortcut registration and (mode, key) dispatch, not just handler
methods. WindowShortcuts only fire on an active window, hence the
show/activate dance in the win fixture.

Covers:
- Single view: h/l navigation, Space/x/c marking with the one advance rule
- Comparison view: focus movement (h/l/j/k, 1-9), per-tile marking, Esc
- Zoom keys (=/-/0/f)
- Undo/redo (u, Ctrl+r)
- Overlay buttons flowing through the same marking pipeline
- Keymap-to-QShortcut registration sync
"""

import pytest
from PIL import Image
from PySide6.QtCore import QCoreApplication, QEvent, QPoint, Qt
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import QApplication, QMessageBox

from winnow.core.session import PhotoStatus, Session
from winnow.ui.keymap import KEYMAP, Mode, legend_text, unique_key_strings
from winnow.ui.main_window import MainWindow
from winnow.ui.thumbnail_strip import ThumbnailStrip

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def photo_dir(tmp_path):
    """Create a directory with 4 JPEG test images."""
    for i in range(4):
        img = Image.new("RGB", (100, 100), color=(i * 60, 0, 0))
        img.save(tmp_path / f"photo{i + 1}.jpg")
    return tmp_path


@pytest.fixture
def photos(photo_dir):
    """Return sorted list of photo paths."""
    return sorted(photo_dir.glob("*.jpg"))


@pytest.fixture
def win(photo_dir, qtbot, monkeypatch):
    """An ACTIVE MainWindow, required for WindowShortcut dispatch.

    The image cache is disabled so tests stay deterministic and cache-free
    even though the window is shown.
    """
    monkeypatch.setattr(MainWindow, "_start_image_loading", lambda self: None)
    window = MainWindow(photo_dir)
    window.show()
    window.activateWindow()
    qtbot.waitUntil(window.isActiveWindow)
    yield window
    # Tear the window down deterministically: drop marks so the closeEvent
    # confirmation dialog can never block a headless run, then flush the
    # deferred delete so this window's QShortcuts are gone before the next
    # test registers its own (two live windows make dispatch flaky).
    window.session.keepers.clear()
    window.session.deletes.clear()
    window.close()
    window.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    QCoreApplication.processEvents()


@pytest.fixture
def win_single(win, photos):
    """Active MainWindow showing the first photo in single view."""
    win.viewing_area.set_images(photos[:1])
    return win


@pytest.fixture
def win_compare(win, photos):
    """Active MainWindow comparing the first three photos."""
    win.viewing_area.set_images(photos[:3])
    return win


def displayed(window):
    """Paths currently shown in the viewing area, in display order."""
    return [w.path for w in window.viewing_area.image_widgets]


def press(qtbot, window, key, modifier=Qt.KeyboardModifier.NoModifier):
    """Send a key to window, re-asserting activation first.

    Offscreen window activation can drift between fixture setup and the
    keypress when other tests have left windows around, and Qt matches
    WindowShortcuts against QApplication.activeWindow() specifically -
    checking widget.isActiveWindow() is not enough, so without this the
    key dispatch is flaky under the full suite.
    """
    app = QApplication.instance()
    if app.activeWindow() is not window:
        window.activateWindow()
        qtbot.waitUntil(lambda: app.activeWindow() is window)
    qtbot.keyClick(window, key, modifier)


# ---------------------------------------------------------------------------
# Single view: navigation
# ---------------------------------------------------------------------------


class TestSingleNavigationKeys:
    def test_l_advances_to_next_photo(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_L)

        assert displayed(win_single) == [photos[1]]

    def test_h_goes_to_previous_photo(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_H)

        assert displayed(win_single) == [photos[0]]

    def test_arrow_keys_alias_h_and_l(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Right)
        assert displayed(win_single) == [photos[1]]

        press(qtbot, win_single, Qt.Key_Left)
        assert displayed(win_single) == [photos[0]]

    def test_h_clamps_at_start(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_H)

        assert displayed(win_single) == [photos[0]]


# ---------------------------------------------------------------------------
# Single view: marking rhythm
# ---------------------------------------------------------------------------


class TestSingleMarkKeys:
    def test_space_marks_keeper_and_advances(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Space)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert displayed(win_single) == [photos[1]]
        assert win_single.session.selected == [photos[1]]

    def test_x_marks_delete_and_advances(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_X)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.DELETE
        assert displayed(win_single) == [photos[1]]
        # Deletes are hidden by default, so the thumbnail leaves the strip
        strip_paths = [w.path for w in win_single.thumbnail_strip.thumbnail_widgets]
        assert photos[0] not in strip_paths

    def test_c_clears_mark_without_advancing(self, win_single, qtbot, photos):
        win_single.session.set_status(photos[0], PhotoStatus.KEEPER)

        press(qtbot, win_single, Qt.Key_C)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert displayed(win_single) == [photos[0]]

    def test_space_at_end_clamps_and_flashes_pass_complete(self, win, qtbot, photos):
        win.viewing_area.set_images([photos[-1]])

        press(qtbot, win, Qt.Key_Space)

        assert win.session.get_status(photos[-1]) == PhotoStatus.KEEPER
        assert displayed(win) == [photos[-1]]
        assert "pass complete" in win.statusBar().currentMessage()

    def test_x_at_end_falls_back_to_previous_photo(self, win, qtbot, photos):
        win.viewing_area.set_images([photos[-1]])

        press(qtbot, win, Qt.Key_X)

        assert win.session.get_status(photos[-1]) == PhotoStatus.DELETE
        assert displayed(win) == [photos[-2]]
        assert "pass complete" in win.statusBar().currentMessage()

    def test_rejecting_every_photo_empties_the_view(self, win_single, qtbot, photos):
        for _ in photos:
            press(qtbot, win_single, Qt.Key_X)

        assert displayed(win_single) == []
        for path in photos:
            assert win_single.session.get_status(path) == PhotoStatus.DELETE

    def test_advance_respects_unmarked_only_filter(self, win_single, qtbot, photos):
        # Keepers-only pass: hide keepers so marking shrinks the strip
        win_single.thumbnail_strip.keepers_btn.click()

        press(qtbot, win_single, Qt.Key_Space)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert displayed(win_single) == [photos[1]]
        strip_paths = [w.path for w in win_single.thumbnail_strip.thumbnail_widgets]
        assert photos[0] not in strip_paths

    def test_mark_keys_are_noops_with_nothing_displayed(self, win, qtbot):
        press(qtbot, win, Qt.Key_Space)
        press(qtbot, win, Qt.Key_X)
        press(qtbot, win, Qt.Key_C)

        assert displayed(win) == []
        assert win.session.keepers == set()
        assert win.session.deletes == set()


# ---------------------------------------------------------------------------
# Comparison view: focus movement
# ---------------------------------------------------------------------------


class TestCompareFocusKeys:
    def test_fresh_comparison_focuses_first_tile(self, win_compare):
        assert win_compare.viewing_area.focused_index == 0

    def test_l_and_h_move_focus_through_tiles(self, win_compare, qtbot):
        press(qtbot, win_compare, Qt.Key_L)
        assert win_compare.viewing_area.focused_index == 1

        press(qtbot, win_compare, Qt.Key_H)
        assert win_compare.viewing_area.focused_index == 0

    def test_focus_clamps_at_both_ends(self, win_compare, qtbot):
        press(qtbot, win_compare, Qt.Key_H)
        assert win_compare.viewing_area.focused_index == 0

        for _ in range(5):
            press(qtbot, win_compare, Qt.Key_L)
        assert win_compare.viewing_area.focused_index == 2

    def test_digits_jump_focus_to_tile(self, win_compare, qtbot):
        press(qtbot, win_compare, Qt.Key_3)
        assert win_compare.viewing_area.focused_index == 2

        press(qtbot, win_compare, Qt.Key_1)
        assert win_compare.viewing_area.focused_index == 0

    def test_out_of_range_digit_clamps_to_last_tile(self, win_compare, qtbot):
        press(qtbot, win_compare, Qt.Key_9)

        assert win_compare.viewing_area.focused_index == 2

    def test_j_and_k_move_between_grid_rows(self, win, qtbot, photos):
        win.viewing_area.set_images(photos[:4])  # 2x2 grid
        win.viewing_area.set_focused_index(1)

        press(qtbot, win, Qt.Key_J)
        assert win.viewing_area.focused_index == 3

        press(qtbot, win, Qt.Key_K)
        assert win.viewing_area.focused_index == 1

    def test_digits_do_nothing_in_single_view(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_2)

        assert displayed(win_single) == [photos[0]]


# ---------------------------------------------------------------------------
# Comparison view: per-tile marking
# ---------------------------------------------------------------------------


class TestCompareMarkKeys:
    def test_space_marks_focused_tile_and_advances_focus(
        self, win_compare, qtbot, photos
    ):
        press(qtbot, win_compare, Qt.Key_Space)

        assert win_compare.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert win_compare.session.get_status(photos[1]) == PhotoStatus.UNMARKED
        assert len(displayed(win_compare)) == 3
        assert win_compare.viewing_area.focused_index == 1

    def test_space_on_last_tile_keeps_focus_clamped(self, win_compare, qtbot, photos):
        win_compare.viewing_area.set_focused_index(2)

        press(qtbot, win_compare, Qt.Key_Space)

        assert win_compare.session.get_status(photos[2]) == PhotoStatus.KEEPER
        assert win_compare.viewing_area.focused_index == 2

    def test_x_marks_focused_tile_delete_and_removes_it(
        self, win_compare, qtbot, photos
    ):
        press(qtbot, win_compare, Qt.Key_X)

        assert win_compare.session.get_status(photos[0]) == PhotoStatus.DELETE
        assert displayed(win_compare) == [photos[1], photos[2]]
        # Focus holds its grid position: the tile that slid in is focused
        assert win_compare.viewing_area.focused_path() == photos[1]

    def test_x_marks_only_the_focused_tile(self, win_compare, qtbot, photos):
        win_compare.viewing_area.set_focused_index(1)

        press(qtbot, win_compare, Qt.Key_X)

        assert win_compare.session.get_status(photos[1]) == PhotoStatus.DELETE
        assert win_compare.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert win_compare.session.get_status(photos[2]) == PhotoStatus.UNMARKED
        assert displayed(win_compare) == [photos[0], photos[2]]

    def test_x_collapses_to_single_view_when_one_tile_left(self, win, qtbot, photos):
        win.viewing_area.set_images(photos[:2])

        press(qtbot, win, Qt.Key_X)

        assert win.session.get_status(photos[0]) == PhotoStatus.DELETE
        assert displayed(win) == [photos[1]]
        assert win.keyboard.mode is Mode.SINGLE

    def test_c_clears_only_the_focused_tile(self, win_compare, qtbot, photos):
        for path in photos[:3]:
            win_compare.session.set_status(path, PhotoStatus.KEEPER)
        win_compare.viewing_area.set_focused_index(1)

        press(qtbot, win_compare, Qt.Key_C)

        assert win_compare.session.get_status(photos[1]) == PhotoStatus.UNMARKED
        assert win_compare.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert win_compare.session.get_status(photos[2]) == PhotoStatus.KEEPER
        assert len(displayed(win_compare)) == 3

    def test_esc_exits_comparison_to_focused_photo(self, win_compare, qtbot, photos):
        win_compare.viewing_area.set_focused_index(1)

        press(qtbot, win_compare, Qt.Key_Escape)

        assert displayed(win_compare) == [photos[1]]
        assert win_compare.session.selected == [photos[1]]
        assert win_compare.keyboard.mode is Mode.SINGLE


# ---------------------------------------------------------------------------
# Visual mode
# ---------------------------------------------------------------------------


class TestVisualMode:
    def test_v_enters_visual_mode(self, win_single, qtbot):
        press(qtbot, win_single, Qt.Key_V)

        assert win_single.keyboard.mode is Mode.VISUAL

    def test_l_extends_selection_into_compare_grid(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)

        assert displayed(win_single) == photos[:3]
        assert win_single.keyboard.mode is Mode.VISUAL
        # The ring tracks the cursor end of the span
        assert win_single.viewing_area.focused_path() == photos[2]

    def test_h_shrinks_selection_back(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_H)

        assert displayed(win_single) == photos[:2]

    def test_extending_left_from_the_anchor(self, win, qtbot, photos):
        win.viewing_area.set_images([photos[2]])

        press(qtbot, win, Qt.Key_V)
        press(qtbot, win, Qt.Key_H)

        assert displayed(win) == [photos[1], photos[2]]
        assert win.viewing_area.focused_path() == photos[1]

    def test_extension_clamps_at_strip_end(self, win, qtbot, photos):
        win.viewing_area.set_images([photos[-1]])

        press(qtbot, win, Qt.Key_V)
        press(qtbot, win, Qt.Key_L)

        assert displayed(win) == [photos[-1]]
        assert win.keyboard.mode is Mode.VISUAL

    def test_x_rejects_whole_span_and_advances_past_it(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_X)

        for path in photos[:3]:
            assert win_single.session.get_status(path) == PhotoStatus.DELETE
        assert win_single.keyboard.mode is Mode.SINGLE
        assert displayed(win_single) == [photos[3]]

    def test_space_keeps_whole_span(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_Space)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert win_single.session.get_status(photos[1]) == PhotoStatus.KEEPER
        assert win_single.keyboard.mode is Mode.SINGLE
        assert displayed(win_single) == [photos[2]]

    def test_c_clears_span_and_lands_on_cursor(self, win_single, qtbot, photos):
        win_single.session.set_status(photos[0], PhotoStatus.KEEPER)
        win_single.session.set_status(photos[1], PhotoStatus.KEEPER)

        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_C)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert win_single.session.get_status(photos[1]) == PhotoStatus.UNMARKED
        assert win_single.keyboard.mode is Mode.SINGLE
        assert displayed(win_single) == [photos[1]]

    def test_enter_commits_to_compare_with_focus_on_cursor(
        self, win_single, qtbot, photos
    ):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_Return)

        assert win_single.keyboard.mode is Mode.COMPARE
        assert displayed(win_single) == photos[:3]
        assert win_single.viewing_area.focused_path() == photos[2]

        # Per-tile semantics after commit: Space marks only the focused tile
        press(qtbot, win_single, Qt.Key_Space)
        assert win_single.session.get_status(photos[2]) == PhotoStatus.KEEPER
        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED

    def test_v_also_commits(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_V)

        assert win_single.keyboard.mode is Mode.COMPARE
        assert displayed(win_single) == photos[:2]

    def test_esc_cancels_without_marking(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_Escape)

        assert win_single.keyboard.mode is Mode.SINGLE
        assert displayed(win_single) == [photos[2]]
        assert win_single.session.keepers == set()
        assert win_single.session.deletes == set()

    def test_mouse_click_cancels_visual(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)

        win_single.thumbnail_strip.handle_thumbnail_click(
            photos[3], ctrl_pressed=False, shift_pressed=False
        )

        assert win_single.keyboard.mode is Mode.SINGLE
        assert displayed(win_single) == [photos[3]]

    def test_visual_batch_is_one_undo_op(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_V)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_L)
        press(qtbot, win_single, Qt.Key_X)

        press(qtbot, win_single, Qt.Key_U)

        for path in photos[:3]:
            assert win_single.session.get_status(path) == PhotoStatus.UNMARKED
        # Undo restores the span as a plain compare selection, not visual mode
        assert displayed(win_single) == photos[:3]
        assert win_single.keyboard.mode is Mode.COMPARE


# ---------------------------------------------------------------------------
# Zoom keys
# ---------------------------------------------------------------------------


class TestZoomKeys:
    def test_equal_key_zooms_in(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(0.50, emit_signal=False)

        press(qtbot, win_single, Qt.Key_Equal)

        assert widget.zoom_level > 0.50

    def test_minus_key_zooms_out(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_Minus)

        assert widget.zoom_level < 1.0

    def test_0_key_zooms_to_100(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        assert widget.fit_mode

        press(qtbot, win_single, Qt.Key_0)

        assert not widget.fit_mode
        assert widget.zoom_level == 1.0

    def test_f_key_zooms_to_fit(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)
        assert not widget.fit_mode

        press(qtbot, win_single, Qt.Key_F)

        assert widget.fit_mode

    def test_zoom_applies_to_all_comparison_tiles(self, win_compare, qtbot):
        press(qtbot, win_compare, Qt.Key_0)

        for widget in win_compare.viewing_area.image_widgets:
            assert widget.zoom_level == 1.0
            assert not widget.fit_mode


# ---------------------------------------------------------------------------
# Pan keys (Shift+h/j/k/l): pan the synchronized group
# ---------------------------------------------------------------------------


class TestPanKeys:
    def test_shift_h_pans_left(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_H, Qt.KeyboardModifier.ShiftModifier)

        assert widget.pan_offset.x() > 0
        assert widget.pan_offset.y() == 0

    def test_shift_l_pans_right(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_L, Qt.KeyboardModifier.ShiftModifier)

        assert widget.pan_offset.x() < 0

    def test_shift_j_pans_down(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_J, Qt.KeyboardModifier.ShiftModifier)

        assert widget.pan_offset.y() < 0

    def test_shift_k_pans_up(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_K, Qt.KeyboardModifier.ShiftModifier)

        assert widget.pan_offset.y() > 0

    def test_pan_is_a_no_op_in_fit_mode(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        assert widget.fit_mode is True

        press(qtbot, win_single, Qt.Key_H, Qt.KeyboardModifier.ShiftModifier)

        assert widget.pan_offset == QPoint(0, 0)

    def test_pan_applies_to_all_comparison_tiles(self, win_compare, qtbot):
        for widget in win_compare.viewing_area.image_widgets:
            widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_compare, Qt.Key_L, Qt.KeyboardModifier.ShiftModifier)

        offsets = {
            w.pan_offset.toTuple() for w in win_compare.viewing_area.image_widgets
        }
        assert len(offsets) == 1


# ---------------------------------------------------------------------------
# Align keys (Ctrl+h/j/k/l, Ctrl+0): register one mismatched tile
# ---------------------------------------------------------------------------


class TestAlignKeys:
    def test_ctrl_h_nudges_only_the_focused_tile(self, win_compare, qtbot):
        for widget in win_compare.viewing_area.image_widgets:
            widget.set_zoom(1.0, emit_signal=False)
        win_compare.viewing_area.set_focused_index(1)

        press(qtbot, win_compare, Qt.Key_H, Qt.KeyboardModifier.ControlModifier)

        widgets = win_compare.viewing_area.image_widgets
        assert widgets[1].individual_pan_offset.x() > 0
        assert widgets[0].individual_pan_offset.x() == 0
        assert widgets[2].individual_pan_offset.x() == 0

    def test_align_does_not_touch_the_shared_pan_offset(self, win_compare, qtbot):
        for widget in win_compare.viewing_area.image_widgets:
            widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_compare, Qt.Key_L, Qt.KeyboardModifier.ControlModifier)

        for widget in win_compare.viewing_area.image_widgets:
            assert widget.pan_offset.toTuple() == (0, 0)

    def test_ctrl_0_resets_focused_tile_alignment(self, win_compare, qtbot):
        widget = win_compare.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)
        widget.individual_pan_offset = QPoint(9, -4)

        press(qtbot, win_compare, Qt.Key_0, Qt.KeyboardModifier.ControlModifier)

        assert widget.individual_pan_offset.toTuple() == (0, 0)

    def test_align_keys_are_inert_in_single_mode(self, win_single, qtbot):
        widget = win_single.viewing_area.image_widgets[0]
        widget.set_zoom(1.0, emit_signal=False)

        press(qtbot, win_single, Qt.Key_H, Qt.KeyboardModifier.ControlModifier)

        assert widget.individual_pan_offset.toTuple() == (0, 0)


# ---------------------------------------------------------------------------
# Chords: gg / G jumps, t-prefix filters
# ---------------------------------------------------------------------------


class TestChordKeys:
    def test_gg_jumps_to_first_photo(self, win, qtbot, photos):
        win.viewing_area.set_images([photos[2]])

        press(qtbot, win, Qt.Key_G)
        press(qtbot, win, Qt.Key_G)

        assert displayed(win) == [photos[0]]

    def test_shift_g_jumps_to_last_photo(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_G, Qt.KeyboardModifier.ShiftModifier)

        assert displayed(win_single) == [photos[-1]]

    def test_tu_toggles_unmarked_filter(self, win_single, qtbot):
        assert win_single.session.show_unmarked is True

        press(qtbot, win_single, Qt.Key_T)
        press(qtbot, win_single, Qt.Key_U)

        assert win_single.session.show_unmarked is False
        assert not win_single.thumbnail_strip.unmarked_btn.isChecked()

    def test_tk_toggles_keepers_filter(self, win_single, qtbot):
        assert win_single.session.show_keepers is True

        press(qtbot, win_single, Qt.Key_T)
        press(qtbot, win_single, Qt.Key_K)

        assert win_single.session.show_keepers is False
        assert not win_single.thumbnail_strip.keepers_btn.isChecked()

    def test_td_toggles_deletes_filter(self, win_single, qtbot, photos):
        win_single.session.set_status(photos[3], PhotoStatus.DELETE)
        assert win_single.session.show_deletes is False

        press(qtbot, win_single, Qt.Key_T)
        press(qtbot, win_single, Qt.Key_D)

        assert win_single.session.show_deletes is True
        strip_paths = [w.path for w in win_single.thumbnail_strip.thumbnail_widgets]
        assert photos[3] in strip_paths

    def test_ts_toggles_sharpness_sort(self, win_single, qtbot):
        assert win_single.session.sort_by_sharpness is False

        press(qtbot, win_single, Qt.Key_T)
        press(qtbot, win_single, Qt.Key_S)

        assert win_single.session.sort_by_sharpness is True
        assert win_single.thumbnail_strip.sort_btn.isChecked()

    def test_broken_chord_swallows_exactly_one_key(self, win_single, qtbot, photos):
        """Characterization: a stray chord prefix eats the next keypress.

        Qt does not replay the key that broke a partial chord match; this
        is an accepted wart of the T/G prefixes. See the keymap module.
        """
        press(qtbot, win_single, Qt.Key_T)
        press(qtbot, win_single, Qt.Key_L)  # Swallowed by the broken chord

        assert displayed(win_single) == [photos[0]]

        press(qtbot, win_single, Qt.Key_L)  # Dispatches normally again

        assert displayed(win_single) == [photos[1]]

    def test_undo_still_works_after_filter_chord(self, win_single, qtbot, photos):
        """The T,U chord must not shadow bare-u undo outside the chord."""
        press(qtbot, win_single, Qt.Key_Space)
        press(qtbot, win_single, Qt.Key_U)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED


# ---------------------------------------------------------------------------
# Undo / redo
# ---------------------------------------------------------------------------


class TestUndoRedo:
    def test_u_undoes_mark_and_returns_to_the_photo(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Space)
        assert displayed(win_single) == [photos[1]]

        press(qtbot, win_single, Qt.Key_U)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert displayed(win_single) == [photos[0]]

    def test_ctrl_r_redoes_the_undone_mark(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Space)
        press(qtbot, win_single, Qt.Key_U)

        press(qtbot, win_single, Qt.Key_R, Qt.KeyboardModifier.ControlModifier)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert displayed(win_single) == [photos[1]]

    def test_undo_restores_a_removed_comparison_tile(self, win_compare, qtbot, photos):
        press(qtbot, win_compare, Qt.Key_X)
        assert displayed(win_compare) == [photos[1], photos[2]]

        press(qtbot, win_compare, Qt.Key_U)

        assert win_compare.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert displayed(win_compare) == [photos[0], photos[1], photos[2]]
        assert win_compare.viewing_area.focused_index == 0

    def test_undo_walks_back_through_multiple_marks(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Space)
        press(qtbot, win_single, Qt.Key_X)

        press(qtbot, win_single, Qt.Key_U)
        press(qtbot, win_single, Qt.Key_U)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert win_single.session.get_status(photos[1]) == PhotoStatus.UNMARKED
        assert displayed(win_single) == [photos[0]]

    def test_new_mark_clears_redo_history(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Space)
        press(qtbot, win_single, Qt.Key_U)

        press(qtbot, win_single, Qt.Key_X)
        press(qtbot, win_single, Qt.Key_R, Qt.KeyboardModifier.ControlModifier)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.DELETE
        assert "Nothing to redo" in win_single.statusBar().currentMessage()

    def test_undo_with_empty_history_flashes_notice(self, win_single, qtbot):
        press(qtbot, win_single, Qt.Key_U)

        assert "Nothing to undo" in win_single.statusBar().currentMessage()


# ---------------------------------------------------------------------------
# Overlay buttons share the marking pipeline
# ---------------------------------------------------------------------------


class TestOverlayButtons:
    def test_keeper_button_marks_and_advances(self, win_single, photos):
        win_single.viewing_area.image_widgets[0].overlay.btn_keeper.click()

        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER
        assert displayed(win_single) == [photos[1]]

    def test_delete_button_on_compare_tile_removes_it(self, win_compare, photos):
        # Click reject on the SECOND tile: focus follows the click
        win_compare.viewing_area.image_widgets[1].overlay.btn_delete.click()

        assert win_compare.session.get_status(photos[1]) == PhotoStatus.DELETE
        assert displayed(win_compare) == [photos[0], photos[2]]

    def test_button_marks_are_undoable(self, win_single, qtbot, photos):
        win_single.viewing_area.image_widgets[0].overlay.btn_keeper.click()

        press(qtbot, win_single, Qt.Key_U)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert displayed(win_single) == [photos[0]]


# ---------------------------------------------------------------------------
# Quit key
# ---------------------------------------------------------------------------


class TestQuitKey:
    def test_q_closes_a_clean_session(self, win, qtbot):
        press(qtbot, win, Qt.Key_Q)

        qtbot.waitUntil(lambda: not win.isVisible())

    def test_q_with_marks_prompts_and_no_keeps_window_open(
        self, win_single, qtbot, monkeypatch, photos
    ):
        press(qtbot, win_single, Qt.Key_Space)

        asked = []

        def mock_question(*args, **kwargs):
            asked.append(args)
            return QMessageBox.StandardButton.No

        monkeypatch.setattr(QMessageBox, "question", mock_question)

        press(qtbot, win_single, Qt.Key_Q)

        assert len(asked) == 1
        assert win_single.isVisible()
        assert win_single.session.get_status(photos[0]) == PhotoStatus.KEEPER


# ---------------------------------------------------------------------------
# Strip navigation engine (drives h/l)
# ---------------------------------------------------------------------------


class TestNavigation:
    @pytest.fixture
    def strip(self, photo_dir, photos, qapp):
        """ThumbnailStrip with 4 photos, all unmarked."""
        from winnow.core.thumbnailer import Thumbnailer

        session = Session(directory=photo_dir, images=photos)
        thumbnailer = Thumbnailer()
        return ThumbnailStrip(session, thumbnailer)

    def test_navigate_forward_selects_next_image(self, strip, photos):
        strip.handle_thumbnail_click(photos[0], ctrl_pressed=False, shift_pressed=False)

        strip.navigate(1)

        assert strip.session.selected == [photos[1]]

    def test_navigate_backward_selects_previous_image(self, strip, photos):
        strip.handle_thumbnail_click(photos[2], ctrl_pressed=False, shift_pressed=False)

        strip.navigate(-1)

        assert strip.session.selected == [photos[1]]

    def test_navigate_no_wrap_at_end(self, strip, photos):
        strip.handle_thumbnail_click(
            photos[-1], ctrl_pressed=False, shift_pressed=False
        )

        strip.navigate(1)

        assert strip.session.selected == [photos[-1]]

    def test_navigate_no_wrap_at_start(self, strip, photos):
        strip.handle_thumbnail_click(photos[0], ctrl_pressed=False, shift_pressed=False)

        strip.navigate(-1)

        assert strip.session.selected == [photos[0]]

    def test_navigate_right_from_no_selection_goes_to_first(self, strip, photos):
        assert strip.session.selected == []

        strip.navigate(1)

        assert strip.session.selected == [photos[0]]

    def test_navigate_left_from_no_selection_goes_to_last(self, strip, photos):
        assert strip.session.selected == []

        strip.navigate(-1)

        assert strip.session.selected == [photos[-1]]

    def test_navigate_respects_filters(self, strip, photos):
        strip.session.show_unmarked = False
        strip.session.show_keepers = True
        strip.session.show_deletes = False
        strip.session.set_status(photos[1], PhotoStatus.KEEPER)

        strip.session.selected = [photos[0]]
        strip.navigate(1)

        assert strip.session.selected == [photos[1]]

    def test_navigate_no_op_when_no_visible_images(self, strip, photos):
        strip.session.show_unmarked = False
        strip.session.show_keepers = False
        strip.session.show_deletes = False

        strip.navigate(1)  # Should not raise
        strip.navigate(-1)  # Should not raise

    def test_navigate_emits_selection_changed(self, strip, photos):
        received = []
        strip.selection_changed.connect(received.append)
        strip.handle_thumbnail_click(photos[0], ctrl_pressed=False, shift_pressed=False)
        received.clear()

        strip.navigate(1)

        assert received == [[photos[1]]]


# ---------------------------------------------------------------------------
# Thumbnail strip auto-scroll (keeps the current photo in view)
# ---------------------------------------------------------------------------


@pytest.fixture
def wide_photo_dir(tmp_path):
    """Create enough photos to overflow the thumbnail strip's viewport width."""
    for i in range(24):
        img = Image.new("RGB", (100, 100), color=(i % 256, 0, 0))
        img.save(tmp_path / f"photo{i + 1:02d}.jpg")
    return tmp_path


@pytest.fixture
def wide_photos(wide_photo_dir):
    return sorted(wide_photo_dir.glob("*.jpg"))


@pytest.fixture
def win_wide(wide_photo_dir, qtbot, monkeypatch):
    """An ACTIVE MainWindow with enough photos to overflow the thumbnail strip."""
    monkeypatch.setattr(MainWindow, "_start_image_loading", lambda self: None)
    window = MainWindow(wide_photo_dir)
    window.show()
    window.activateWindow()
    qtbot.waitUntil(window.isActiveWindow)
    yield window
    window.session.keepers.clear()
    window.session.deletes.clear()
    window.close()
    window.deleteLater()
    QCoreApplication.sendPostedEvents(None, QEvent.Type.DeferredDelete)
    QCoreApplication.processEvents()


@pytest.fixture
def win_wide_single(win_wide, wide_photos):
    """win_wide with the first photo already selected in single view."""
    win_wide.viewing_area.set_images(wide_photos[:1])
    return win_wide


def thumbnail_fully_visible(window, path):
    """True if path's thumbnail is entirely within the strip's scrolled viewport."""
    strip = window.thumbnail_strip
    widget = next(w for w in strip.thumbnail_widgets if w.path == path)
    scrollbar = strip.scroll_area.horizontalScrollBar()
    viewport_width = strip.scroll_area.viewport().width()
    visible_left = scrollbar.value()
    visible_right = visible_left + viewport_width
    return widget.x() >= visible_left and widget.x() + widget.width() <= visible_right


class TestThumbnailStripAutoScroll:
    def test_l_scrolls_strip_to_keep_current_photo_visible(
        self, win_wide_single, qtbot, wide_photos
    ):
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide_single, Qt.Key_L)

        assert displayed(win_wide_single) == [wide_photos[-1]]
        assert thumbnail_fully_visible(win_wide_single, wide_photos[-1])

    def test_h_scrolls_strip_back_toward_start(
        self, win_wide_single, qtbot, wide_photos
    ):
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide_single, Qt.Key_L)
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide_single, Qt.Key_H)

        assert displayed(win_wide_single) == [wide_photos[0]]
        assert thumbnail_fully_visible(win_wide_single, wide_photos[0])

    def test_shift_g_scrolls_strip_to_last_photo(
        self, win_wide_single, qtbot, wide_photos
    ):
        press(qtbot, win_wide_single, Qt.Key_G, Qt.KeyboardModifier.ShiftModifier)

        assert displayed(win_wide_single) == [wide_photos[-1]]
        assert thumbnail_fully_visible(win_wide_single, wide_photos[-1])

    def test_gg_scrolls_strip_back_to_first_photo(self, win_wide, qtbot, wide_photos):
        win_wide.viewing_area.set_images(wide_photos[-1:])

        press(qtbot, win_wide, Qt.Key_G)
        press(qtbot, win_wide, Qt.Key_G)

        assert displayed(win_wide) == [wide_photos[0]]
        assert thumbnail_fully_visible(win_wide, wide_photos[0])

    def test_mark_and_advance_scrolls_strip(self, win_wide_single, qtbot, wide_photos):
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide_single, Qt.Key_Space)

        assert displayed(win_wide_single) == [wide_photos[-1]]
        assert thumbnail_fully_visible(win_wide_single, wide_photos[-1])

    def test_visual_extend_right_scrolls_to_new_cursor(
        self, win_wide_single, qtbot, wide_photos
    ):
        press(qtbot, win_wide_single, Qt.Key_V)
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide_single, Qt.Key_L)

        assert win_wide_single.viewing_area.focused_path() == wide_photos[-1]
        assert thumbnail_fully_visible(win_wide_single, wide_photos[-1])

    def test_visual_extend_left_scrolls_to_new_cursor(
        self, win_wide, qtbot, wide_photos
    ):
        win_wide.viewing_area.set_images(wide_photos[-1:])

        press(qtbot, win_wide, Qt.Key_V)
        for _ in range(len(wide_photos) - 1):
            press(qtbot, win_wide, Qt.Key_H)

        assert win_wide.viewing_area.focused_path() == wide_photos[0]
        assert thumbnail_fully_visible(win_wide, wide_photos[0])


# ---------------------------------------------------------------------------
# Position number labels (serve the 1-9 focus jump)
# ---------------------------------------------------------------------------


class TestPositionLabels:
    @pytest.fixture
    def window(self, photo_dir, qapp):
        """Unshown MainWindow (no shortcut dispatch needed here)."""
        return MainWindow(photo_dir)

    def test_position_labels_shown_in_comparison_mode(self, window, photos):
        """Comparison tiles show 1-indexed jump targets.

        Uses isHidden() rather than isVisible() because the test window is
        not shown, so isVisible() returns False even if show() was called.
        """
        window.viewing_area.set_images(photos[:3])
        widgets = window.viewing_area.image_widgets
        assert len(widgets) == 3
        for i, widget in enumerate(widgets, start=1):
            assert not widget.position_label.isHidden()
            assert widget.position_label.text() == str(i)

    def test_position_label_hidden_in_single_mode(self, window, photos):
        window.viewing_area.set_images(photos[:1])
        widget = window.viewing_area.image_widgets[0]
        assert widget.position_label.isHidden()

    def test_position_labels_start_at_1(self, window, photos):
        window.viewing_area.set_images(photos[:2])
        widgets = window.viewing_area.image_widgets
        assert widgets[0].position_label.text() == "1"
        assert widgets[1].position_label.text() == "2"

    def test_position_label_hidden_after_switching_to_single(self, window, photos):
        window.viewing_area.set_images(photos[:2])
        assert not window.viewing_area.image_widgets[0].position_label.isHidden()

        window.viewing_area.set_images(photos[:1])

        assert window.viewing_area.image_widgets[0].position_label.isHidden()


# ---------------------------------------------------------------------------
# Registration stays in sync with the keymap
# ---------------------------------------------------------------------------


class TestShortcutRegistration:
    def test_every_keymap_sequence_has_exactly_one_shortcut(self, qapp, photo_dir):
        """Each keymap sequence registers once; duplicates would dead-key."""
        window = MainWindow(photo_dir)
        registered = [s.key().toString() for s in window.findChildren(QShortcut)]

        assert len(registered) == len(set(registered))
        for key in unique_key_strings():
            assert QKeySequence(key).toString() in registered

    def test_old_scheme_keys_are_gone(self, qapp, photo_dir):
        """The K/D mark-all bindings from the old scheme are not registered."""
        window = MainWindow(photo_dir)
        registered = {s.key().toString() for s in window.findChildren(QShortcut)}

        assert "D" not in registered


class TestModeDerivation:
    def test_mode_follows_view_state(self, win, photos):
        assert win.keyboard.mode is Mode.SINGLE

        win.viewing_area.set_images(photos[:2])
        assert win.keyboard.mode is Mode.COMPARE

        win.viewing_area.set_images(photos[:1])
        assert win.keyboard.mode is Mode.SINGLE

    def test_every_keymap_action_has_a_handler(self, qapp, photo_dir):
        """A binding without a handler would silently dead-key."""
        window = MainWindow(photo_dir)

        for binding in KEYMAP:
            assert binding.action in window.keyboard._actions, binding.action


# ---------------------------------------------------------------------------
# Legend and help overlay
# ---------------------------------------------------------------------------


class TestLegend:
    def test_legend_shows_single_view_keys_at_start(self, win):
        assert win.legend_label.text() == legend_text(Mode.SINGLE)

    def test_legend_follows_mode_changes(self, win, qtbot, photos):
        win.viewing_area.set_images(photos[:2])
        assert win.legend_label.text() == legend_text(Mode.COMPARE)

        press(qtbot, win, Qt.Key_Escape)
        assert win.legend_label.text() == legend_text(Mode.SINGLE)

        press(qtbot, win, Qt.Key_V)
        assert win.legend_label.text() == legend_text(Mode.VISUAL)


class TestHelpOverlay:
    def test_question_mark_opens_the_overlay(self, win_single, qtbot):
        # Key_Question must be synthesized WITHOUT Shift or it won't match
        press(qtbot, win_single, Qt.Key_Question)

        assert not win_single.help_overlay.isHidden()

    def test_open_overlay_swallows_other_keys(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Question)

        press(qtbot, win_single, Qt.Key_X)

        assert win_single.session.get_status(photos[0]) == PhotoStatus.UNMARKED
        assert displayed(win_single) == [photos[0]]

    def test_question_mark_toggles_closed(self, win_single, qtbot):
        press(qtbot, win_single, Qt.Key_Question)
        press(qtbot, win_single, Qt.Key_Question)

        assert win_single.help_overlay.isHidden()

    def test_esc_closes_the_overlay(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Question)
        press(qtbot, win_single, Qt.Key_Escape)

        assert win_single.help_overlay.isHidden()
        # Keys dispatch normally again
        press(qtbot, win_single, Qt.Key_L)
        assert displayed(win_single) == [photos[1]]

    def test_click_dismisses_and_restores_keys(self, win_single, qtbot, photos):
        press(qtbot, win_single, Qt.Key_Question)

        qtbot.mouseClick(win_single.help_overlay, Qt.MouseButton.LeftButton)

        assert win_single.help_overlay.isHidden()
        press(qtbot, win_single, Qt.Key_L)
        assert displayed(win_single) == [photos[1]]


class TestFocusHygiene:
    def test_no_widget_can_steal_the_shortcut_keys(self, qapp, photo_dir):
        """Filter buttons, sliders, and overlay buttons refuse focus."""
        window = MainWindow(photo_dir)
        strip = window.thumbnail_strip

        assert strip.zoom_slider.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert strip.unmarked_btn.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert strip.keepers_btn.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert strip.deletes_btn.focusPolicy() == Qt.FocusPolicy.NoFocus

        zoom = window.viewing_area.zoom_overlay
        assert zoom.btn_zoom_in.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert zoom.btn_zoom_out.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert zoom.btn_zoom_100.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert zoom.btn_zoom_fit.focusPolicy() == Qt.FocusPolicy.NoFocus

    def test_status_overlay_buttons_refuse_focus(self, qapp, photo_dir, photos):
        window = MainWindow(photo_dir)
        window.viewing_area.set_images(photos[:1])
        overlay = window.viewing_area.image_widgets[0].overlay

        assert overlay.btn_keeper.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert overlay.btn_delete.focusPolicy() == Qt.FocusPolicy.NoFocus
        assert overlay.btn_clear.focusPolicy() == Qt.FocusPolicy.NoFocus
