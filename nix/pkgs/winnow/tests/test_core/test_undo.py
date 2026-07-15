"""Tests for the undo module."""

from pathlib import Path

from winnow.core.session import PhotoStatus
from winnow.core.undo import MarkOp, UndoStack


def make_op(name: str) -> MarkOp:
    """Build a minimal MarkOp for a photo with the given file name."""
    path = Path(f"/photos/{name}.jpg")
    return MarkOp(
        marks=((path, PhotoStatus.UNMARKED, PhotoStatus.KEEPER),),
        selection_before=(path,),
        selection_after=(path,),
        focus_before=0,
        focus_after=0,
    )


def test_empty_stack_has_nothing_to_undo_or_redo():
    """A fresh stack reports no undo/redo and returns None from both."""
    stack = UndoStack()

    assert not stack.can_undo()
    assert not stack.can_redo()
    assert stack.undo() is None
    assert stack.redo() is None


def test_undo_returns_ops_in_reverse_order():
    """Undo pops the most recent operation first."""
    stack = UndoStack()
    first = make_op("a")
    second = make_op("b")
    stack.push(first)
    stack.push(second)

    assert stack.undo() is second
    assert stack.undo() is first
    assert stack.undo() is None


def test_redo_replays_undone_ops_in_original_order():
    """Redo replays undone operations oldest-undo first."""
    stack = UndoStack()
    first = make_op("a")
    second = make_op("b")
    stack.push(first)
    stack.push(second)
    stack.undo()
    stack.undo()

    assert stack.redo() is first
    assert stack.redo() is second
    assert stack.redo() is None


def test_undo_after_redo_returns_same_op():
    """An op moves back onto the undo stack when redone."""
    stack = UndoStack()
    op = make_op("a")
    stack.push(op)
    stack.undo()
    stack.redo()

    assert stack.can_undo()
    assert stack.undo() is op


def test_push_clears_redo_history():
    """A new operation invalidates anything that was undone."""
    stack = UndoStack()
    stack.push(make_op("a"))
    stack.undo()
    assert stack.can_redo()

    stack.push(make_op("b"))

    assert not stack.can_redo()
    assert stack.redo() is None


def test_batch_op_preserves_all_marks():
    """MarkOp holds multiple status changes for batch operations."""
    paths = [Path(f"/photos/{n}.jpg") for n in ("a", "b", "c")]
    op = MarkOp(
        marks=tuple((p, PhotoStatus.UNMARKED, PhotoStatus.DELETE) for p in paths),
        selection_before=tuple(paths),
        selection_after=(Path("/photos/d.jpg"),),
        focus_before=1,
        focus_after=0,
    )
    stack = UndoStack()
    stack.push(op)

    popped = stack.undo()

    assert popped is op
    assert len(popped.marks) == 3
    assert popped.selection_before == tuple(paths)
    assert popped.focus_before == 1
