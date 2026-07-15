"""Undo stack for mark operations.

This module provides pure-Python undo/redo state for photo mark operations
(keeper/delete/clear). Each operation records the status changes it made and
the selection and focus state on both sides of the operation, so undo can
restore not just statuses but the user's position in the strip and the
comparison grid.

No Qt imports: the stack is plain state, applied by the keyboard controller.
"""

from dataclasses import dataclass
from pathlib import Path

from winnow.core.session import PhotoStatus


@dataclass(frozen=True)
class MarkOp:
    """A single undoable mark operation.

    Attributes:
        marks: Status changes made by the operation, as
            (path, old_status, new_status) tuples. Contains more than one
            entry for batch operations (visual-mode operators).
        selection_before: Selected paths before the operation.
        selection_after: Selected paths after the operation (post-advance,
            post-tile-removal).
        focus_before: Compare-grid focus index before the operation.
        focus_after: Compare-grid focus index after the operation.
    """

    marks: tuple[tuple[Path, PhotoStatus, PhotoStatus], ...]
    selection_before: tuple[Path, ...]
    selection_after: tuple[Path, ...]
    focus_before: int
    focus_after: int


class UndoStack:
    """Undo/redo history of mark operations.

    Undo and redo return the operation to apply; the caller is responsible
    for restoring session and view state from its snapshots.
    """

    def __init__(self) -> None:
        self._undo: list[MarkOp] = []
        self._redo: list[MarkOp] = []

    def push(self, op: MarkOp) -> None:
        """Record a new operation, clearing any redo history.

        Args:
            op: The operation that was just applied.
        """
        self._undo.append(op)
        self._redo.clear()

    def undo(self) -> MarkOp | None:
        """Pop the most recent operation for reversal.

        Returns:
            The operation to reverse, or None if there is nothing to undo.
        """
        if not self._undo:
            return None
        op = self._undo.pop()
        self._redo.append(op)
        return op

    def redo(self) -> MarkOp | None:
        """Pop the most recently undone operation for replay.

        Returns:
            The operation to replay, or None if there is nothing to redo.
        """
        if not self._redo:
            return None
        op = self._redo.pop()
        self._undo.append(op)
        return op

    def can_undo(self) -> bool:
        """Return True if there is an operation to undo."""
        return bool(self._undo)

    def can_redo(self) -> bool:
        """Return True if there is an operation to redo."""
        return bool(self._redo)
