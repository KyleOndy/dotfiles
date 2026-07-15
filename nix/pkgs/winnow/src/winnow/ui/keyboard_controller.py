"""Keyboard controller for the culling workflow.

Registers one QShortcut per key sequence in the keymap and dispatches on
(mode, key): the same key can navigate photos in single view, extend the
selection in visual mode, and move the focus ring in comparison mode. A
single dispatcher (rather than per-mode QShortcut groups) makes duplicate
registrations structurally impossible - two enabled QShortcuts on the same
sequence would both go dead, firing only activatedAmbiguously.

The controller is also the single writer of mark operations: overlay button
clicks and mark keys funnel through _perform_mark, which applies statuses,
performs the view transition (advance, tile removal), records an undo op,
and only then notifies the thumbnail strip - the view-first ordering keeps
the strip's filter refresh from clobbering the transition with an empty
selection.
"""

from collections.abc import Callable
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from typing import TYPE_CHECKING

from PySide6.QtCore import QObject, Qt, Signal
from PySide6.QtGui import QKeySequence, QShortcut

from winnow.core.session import PhotoStatus
from winnow.core.undo import MarkOp, UndoStack
from winnow.ui.keymap import Mode, auto_repeat_for, build_lookup, unique_key_strings

if TYPE_CHECKING:
    from winnow.ui.main_window import MainWindow


@dataclass
class VisualState:
    """Visual-mode selection span, tracked by photo identity.

    Attributes:
        anchor: Photo where v was pressed; the fixed end of the span.
        cursor: Moving end of the span, driven by h/l.
    """

    anchor: Path
    cursor: Path


class KeyboardController(QObject):
    """Dispatches keymap actions against the current view mode.

    Signals:
        mode_changed(Mode): Emitted whenever the keyboard mode may have
            changed (after every dispatched action and view rebuild).
    """

    mode_changed = Signal(object)

    def __init__(self, window: "MainWindow") -> None:
        """Wire shortcuts and the marking pipeline into the main window.

        Args:
            window: The MainWindow owning the session and widgets.
        """
        super().__init__(window)
        self._window = window
        self._session = window.session
        self._viewing_area = window.viewing_area
        self._strip = window.thumbnail_strip
        self._lookup = build_lookup()
        self.undo_stack = UndoStack()
        self._visual: VisualState | None = None
        self._help_visible = False

        self._actions: dict[str, Callable[[str], None]] = {
            "single_prev": self._single_prev,
            "single_next": self._single_next,
            "single_keep": self._single_keep,
            "single_reject": self._single_reject,
            "single_clear": self._single_clear,
            "single_first": self._single_first,
            "single_last": self._single_last,
            "compare_focus_left": self._compare_focus_left,
            "compare_focus_right": self._compare_focus_right,
            "compare_focus_down": self._compare_focus_down,
            "compare_focus_up": self._compare_focus_up,
            "compare_keep": self._compare_keep,
            "compare_reject": self._compare_reject,
            "compare_clear": self._compare_clear,
            "compare_exit": self._compare_exit,
            "focus_tile": self._focus_tile,
            "enter_visual": self._enter_visual,
            "visual_left": self._visual_left,
            "visual_right": self._visual_right,
            "visual_keep": self._visual_keep,
            "visual_reject": self._visual_reject,
            "visual_clear": self._visual_clear,
            "visual_commit": self._visual_commit,
            "visual_cancel": self._visual_cancel,
            "zoom_in": self._zoom_in,
            "zoom_out": self._zoom_out,
            "zoom_100": self._zoom_100,
            "zoom_fit": self._zoom_fit,
            "pan_left": self._pan_left,
            "pan_right": self._pan_right,
            "pan_down": self._pan_down,
            "pan_up": self._pan_up,
            "align_left": self._align_left,
            "align_right": self._align_right,
            "align_down": self._align_down,
            "align_up": self._align_up,
            "align_reset": self._align_reset,
            "toggle_unmarked": self._toggle_unmarked,
            "toggle_keepers": self._toggle_keepers,
            "toggle_deletes": self._toggle_deletes,
            "toggle_sort_sharpness": self._toggle_sort_sharpness,
            "undo": self._undo,
            "redo": self._redo,
            "toggle_help": self._show_help,
            "quit": self._quit,
        }

        self._register_shortcuts()
        self._viewing_area.mark_requested.connect(self.on_overlay_mark)
        self._viewing_area.current_images_changed.connect(self._notify_mode)
        # Any strip-driven selection (mouse click, filter refresh dropping
        # the selection) invalidates a visual span in progress.
        self._strip.selection_changed.connect(self._on_external_selection)
        self._window.help_overlay.dismissed.connect(self._on_help_dismissed)

    # -- Mode -----------------------------------------------------------

    @property
    def mode(self) -> Mode:
        """Current keyboard mode, derived from view state."""
        if self._visual is not None:
            return Mode.VISUAL
        if len(self._viewing_area.image_widgets) >= 2:
            return Mode.COMPARE
        return Mode.SINGLE

    def _notify_mode(self, *_args: object) -> None:
        """Broadcast the (possibly changed) mode for the legend."""
        self.mode_changed.emit(self.mode)

    # -- Shortcut registration and dispatch ------------------------------

    def _register_shortcuts(self) -> None:
        """Create one window-level QShortcut per keymap sequence."""
        for key in unique_key_strings():
            shortcut = QShortcut(QKeySequence(key), self._window)
            shortcut.setContext(Qt.ShortcutContext.WindowShortcut)
            shortcut.setAutoRepeat(auto_repeat_for(key))
            shortcut.activated.connect(partial(self._dispatch, key))

    def _dispatch(self, key: str) -> None:
        """Run the action bound to key in the current mode, if any."""
        if self._help_visible:
            # The open help overlay swallows everything except its closers.
            if key in ("?", "Escape"):
                self._hide_help()
            return
        binding = self._lookup.get((self.mode, key))
        if binding is None:
            return
        handler = self._actions.get(binding.action)
        if handler is None:
            return
        handler(key)
        self._notify_mode()

    # -- Marking pipeline -------------------------------------------------

    def on_overlay_mark(self, path: Path, status: PhotoStatus) -> None:
        """Apply an overlay button's mark request with key semantics.

        In comparison mode the click also moves focus to the clicked tile,
        so buttons and keys stay one pipeline.

        Args:
            path: Photo the overlay belongs to.
            status: Requested status.
        """
        if self.mode is Mode.COMPARE:
            paths = [w.path for w in self._viewing_area.image_widgets]
            if path in paths:
                self._viewing_area.set_focused_index(paths.index(path))
            if status == PhotoStatus.KEEPER:
                self._compare_keep("")
            elif status == PhotoStatus.DELETE:
                self._compare_reject("")
            else:
                self._compare_clear("")
        else:
            if status == PhotoStatus.KEEPER:
                self._single_keep("")
            elif status == PhotoStatus.DELETE:
                self._single_reject("")
            else:
                self._single_clear("")
        self._notify_mode()

    def _perform_mark(
        self,
        paths: list[Path],
        status: PhotoStatus,
        transition: Callable[[], None],
    ) -> None:
        """Apply a mark, run its view transition, and record undo state.

        Ordering matters: statuses first, then the view transition, then
        the strip notification - notifying the strip earlier would let its
        filter refresh drop the selection and empty the view before the
        transition runs.

        Args:
            paths: Photos to mark.
            status: Status to apply to all of them.
            transition: View change to perform after marking (advance,
                tile removal, or a no-op).
        """
        marks = tuple((p, self._session.get_status(p), status) for p in paths)
        selection_before = tuple(w.path for w in self._viewing_area.image_widgets)
        focus_before = self._viewing_area.focused_index

        for path in paths:
            self._session.set_status(path, status)
        transition()
        for path in paths:
            self._strip.on_photo_status_changed(path)

        if any(old != new for _, old, new in marks):
            self.undo_stack.push(
                MarkOp(
                    marks=marks,
                    selection_before=selection_before,
                    selection_after=tuple(
                        w.path for w in self._viewing_area.image_widgets
                    ),
                    focus_before=focus_before,
                    focus_after=self._viewing_area.focused_index,
                )
            )
        self._refresh_overlays()

    def _refresh_overlays(self) -> None:
        """Sync every displayed tile's status overlay with the session."""
        for widget in self._viewing_area.image_widgets:
            widget.overlay.update_appearance()

    def _advance_after_mark(
        self,
        origin: Path,
        filtered_before: list[Path],
        collapse_to_single: bool = False,
    ) -> None:
        """Advance to the next photo still visible after a mark.

        One rule, identical to pressing l: next photo in the filtered
        strip, clamped at the end. When nothing follows, stay on the
        origin if it is still visible, otherwise fall back to the nearest
        earlier photo, otherwise show the empty state. Every clamped
        branch flashes a pass-complete notice.

        Args:
            origin: The photo that was just marked (for a visual span, the
                rightmost photo of the span).
            filtered_before: filtered_images() snapshot taken before the
                mark was applied.
            collapse_to_single: When the clamp lands on a still-visible
                origin, select it explicitly so a comparison grid folds to
                single view (visual operators need this; single view is
                already showing the origin).
        """
        filtered_after = set(self._session.filtered_images())
        index = filtered_before.index(origin) if origin in filtered_before else -1

        for path in filtered_before[index + 1 :]:
            if path in filtered_after:
                self._strip.handle_thumbnail_click(
                    path, ctrl_pressed=False, shift_pressed=False
                )
                return

        self._flash("End of strip - pass complete")
        if origin in filtered_after:
            if collapse_to_single:
                self._strip.handle_thumbnail_click(
                    origin, ctrl_pressed=False, shift_pressed=False
                )
            return
        for path in reversed(filtered_before[: max(index, 0)]):
            if path in filtered_after:
                self._strip.handle_thumbnail_click(
                    path, ctrl_pressed=False, shift_pressed=False
                )
                return
        self._viewing_area.set_images([])

    # -- Single view -------------------------------------------------------

    def _single_prev(self, _key: str) -> None:
        self._strip.navigate(-1)

    def _single_next(self, _key: str) -> None:
        self._strip.navigate(1)

    def _single_first(self, _key: str) -> None:
        visible = self._session.filtered_images()
        if visible:
            self._strip.handle_thumbnail_click(
                visible[0], ctrl_pressed=False, shift_pressed=False
            )

    def _single_last(self, _key: str) -> None:
        visible = self._session.filtered_images()
        if visible:
            self._strip.handle_thumbnail_click(
                visible[-1], ctrl_pressed=False, shift_pressed=False
            )

    def _mark_single(self, status: PhotoStatus) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        filtered_before = self._session.filtered_images()
        self._perform_mark(
            [path],
            status,
            transition=lambda: self._advance_after_mark(path, filtered_before),
        )

    def _single_keep(self, _key: str) -> None:
        self._mark_single(PhotoStatus.KEEPER)

    def _single_reject(self, _key: str) -> None:
        self._mark_single(PhotoStatus.DELETE)

    def _single_clear(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        self._perform_mark([path], PhotoStatus.UNMARKED, transition=lambda: None)

    # -- Comparison view ---------------------------------------------------

    def _compare_focus_left(self, _key: str) -> None:
        self._viewing_area.move_focus(dx=-1)

    def _compare_focus_right(self, _key: str) -> None:
        self._viewing_area.move_focus(dx=1)

    def _compare_focus_down(self, _key: str) -> None:
        self._viewing_area.move_focus(dy=1)

    def _compare_focus_up(self, _key: str) -> None:
        self._viewing_area.move_focus(dy=-1)

    def _focus_tile(self, key: str) -> None:
        self._viewing_area.set_focused_index(int(key) - 1)

    def _compare_keep(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        self._perform_mark(
            [path],
            PhotoStatus.KEEPER,
            transition=lambda: self._viewing_area.set_focused_index(
                self._viewing_area.focused_index + 1
            ),
        )

    def _compare_reject(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        remaining = [w.path for w in self._viewing_area.image_widgets if w.path != path]
        self._perform_mark(
            [path],
            PhotoStatus.DELETE,
            transition=lambda: self._viewing_area.set_images(remaining),
        )

    def _compare_clear(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        self._perform_mark([path], PhotoStatus.UNMARKED, transition=lambda: None)

    def _compare_exit(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is not None:
            self._strip.handle_thumbnail_click(
                path, ctrl_pressed=False, shift_pressed=False
            )

    # -- Visual mode -------------------------------------------------------

    def _enter_visual(self, _key: str) -> None:
        path = self._viewing_area.focused_path()
        if path is None:
            return
        self._visual = VisualState(anchor=path, cursor=path)

    def _on_external_selection(self, _paths: list) -> None:
        """A strip-driven selection change cancels any visual span."""
        self._visual = None
        self._notify_mode()

    def _visual_left(self, _key: str) -> None:
        self._visual_move(-1)

    def _visual_right(self, _key: str) -> None:
        self._visual_move(1)

    def _visual_move(self, delta: int) -> None:
        """Move the span's cursor through the filtered strip, clamped."""
        visual = self._visual
        visible = self._session.filtered_images()
        if (
            visual is None
            or visual.cursor not in visible
            or visual.anchor not in visible
        ):
            return
        index = visible.index(visual.cursor)
        target = max(0, min(len(visible) - 1, index + delta))
        if target == index:
            return
        visual.cursor = visible[target]
        self._show_visual_span()

    def _visual_span(self) -> list[Path]:
        """The anchor..cursor range over the filtered strip, in order."""
        visible = self._session.filtered_images()
        anchor = visible.index(self._visual.anchor)
        cursor = visible.index(self._visual.cursor)
        low, high = (anchor, cursor) if anchor <= cursor else (cursor, anchor)
        return visible[low : high + 1]

    def _show_visual_span(self) -> None:
        """Display the span (live compare grid) with the ring on the cursor."""
        span = self._visual_span()
        cursor = self._visual.cursor
        self._viewing_area.set_images(span)
        if cursor in span:
            self._viewing_area.set_focused_index(span.index(cursor))
        self._strip.scroll_to_path(cursor)

    def _visual_keep(self, _key: str) -> None:
        self._visual_operator(PhotoStatus.KEEPER)

    def _visual_reject(self, _key: str) -> None:
        self._visual_operator(PhotoStatus.DELETE)

    def _visual_operator(self, status: PhotoStatus) -> None:
        """Vim operator semantics: mark the whole span, exit visual, advance."""
        if self._visual is None:
            return
        span = [w.path for w in self._viewing_area.image_widgets]
        self._visual = None
        if not span:
            return
        filtered_before = self._session.filtered_images()
        origin = span[-1]
        self._perform_mark(
            span,
            status,
            transition=lambda: self._advance_after_mark(
                origin, filtered_before, collapse_to_single=True
            ),
        )

    def _visual_clear(self, _key: str) -> None:
        """Clear the whole span, exit visual, land on the cursor photo."""
        visual = self._visual
        if visual is None:
            return
        span = [w.path for w in self._viewing_area.image_widgets]
        self._visual = None
        if not span:
            return
        filtered_before = self._session.filtered_images()

        def land_on_cursor() -> None:
            if visual.cursor in self._session.filtered_images():
                self._strip.handle_thumbnail_click(
                    visual.cursor, ctrl_pressed=False, shift_pressed=False
                )
            else:
                self._advance_after_mark(
                    visual.cursor, filtered_before, collapse_to_single=True
                )

        self._perform_mark(span, PhotoStatus.UNMARKED, transition=land_on_cursor)

    def _visual_commit(self, _key: str) -> None:
        """Commit the span to a plain comparison, focus ring on the cursor."""
        visual = self._visual
        if visual is None:
            return
        self._visual = None
        span = [w.path for w in self._viewing_area.image_widgets]
        if visual.cursor in span:
            self._viewing_area.set_focused_index(span.index(visual.cursor))

    def _visual_cancel(self, _key: str) -> None:
        """Drop the span without marking; return to the cursor photo."""
        visual = self._visual
        if visual is None:
            return
        self._visual = None
        self._strip.handle_thumbnail_click(
            visual.cursor, ctrl_pressed=False, shift_pressed=False
        )

    # -- Zoom ---------------------------------------------------------------

    def _zoom_in(self, _key: str) -> None:
        self._viewing_area.zoom_overlay.on_zoom_in()

    def _zoom_out(self, _key: str) -> None:
        self._viewing_area.zoom_overlay.on_zoom_out()

    def _zoom_100(self, _key: str) -> None:
        self._viewing_area.zoom_overlay.on_zoom_to_100()

    def _zoom_fit(self, _key: str) -> None:
        self._viewing_area.zoom_overlay.on_zoom_to_fit()

    # -- Pan ------------------------------------------------------------

    def _pan_left(self, _key: str) -> None:
        self._viewing_area.pan_group(dx=-1, dy=0)

    def _pan_right(self, _key: str) -> None:
        self._viewing_area.pan_group(dx=1, dy=0)

    def _pan_down(self, _key: str) -> None:
        self._viewing_area.pan_group(dx=0, dy=1)

    def _pan_up(self, _key: str) -> None:
        self._viewing_area.pan_group(dx=0, dy=-1)

    def _align_left(self, _key: str) -> None:
        self._viewing_area.align_focused(dx=-1, dy=0)

    def _align_right(self, _key: str) -> None:
        self._viewing_area.align_focused(dx=1, dy=0)

    def _align_down(self, _key: str) -> None:
        self._viewing_area.align_focused(dx=0, dy=1)

    def _align_up(self, _key: str) -> None:
        self._viewing_area.align_focused(dx=0, dy=-1)

    def _align_reset(self, _key: str) -> None:
        self._viewing_area.reset_focused_alignment()

    # -- Filters ---------------------------------------------------------

    def _toggle_unmarked(self, _key: str) -> None:
        self._strip.unmarked_btn.click()

    def _toggle_keepers(self, _key: str) -> None:
        self._strip.keepers_btn.click()

    def _toggle_deletes(self, _key: str) -> None:
        self._strip.deletes_btn.click()

    def _toggle_sort_sharpness(self, _key: str) -> None:
        self._strip.sort_btn.click()

    # -- Undo / redo ------------------------------------------------------

    def _undo(self, _key: str) -> None:
        op = self.undo_stack.undo()
        if op is None:
            self._flash("Nothing to undo")
            return
        for path, old_status, _new_status in op.marks:
            self._session.set_status(path, old_status)
        self._restore_view(list(op.selection_before), op.focus_before, op)

    def _redo(self, _key: str) -> None:
        op = self.undo_stack.redo()
        if op is None:
            self._flash("Nothing to redo")
            return
        for path, _old_status, new_status in op.marks:
            self._session.set_status(path, new_status)
        self._restore_view(list(op.selection_after), op.focus_after, op)

    def _restore_view(self, selection: list[Path], focus: int, op: MarkOp) -> None:
        """Rebuild the view and strip from an undo/redo snapshot."""
        self._viewing_area.set_images(selection)
        self._viewing_area.set_focused_index(focus)
        for path, _old_status, _new_status in op.marks:
            self._strip.on_photo_status_changed(path)
        self._refresh_overlays()

    # -- Session ----------------------------------------------------------

    def _show_help(self, _key: str) -> None:
        """Open the cheat sheet; further keys are swallowed until closed."""
        self._help_visible = True
        self._window.help_overlay.show_overlay()

    def _hide_help(self) -> None:
        self._help_visible = False
        self._window.help_overlay.hide()

    def _on_help_dismissed(self) -> None:
        """The overlay was closed by mouse; drop the key suppression."""
        self._help_visible = False

    def _quit(self, _key: str) -> None:
        self._window.close()

    def _flash(self, message: str) -> None:
        """Show a transient status-bar notice."""
        self._window.statusBar().showMessage(message, 2000)
