"""Tests for the keymap definition table."""

from PySide6.QtGui import QKeySequence

from winnow.ui.keymap import (
    KEYMAP,
    Mode,
    auto_repeat_for,
    build_lookup,
    help_sections,
    legend_text,
    unique_key_strings,
)


def test_no_duplicate_bindings_per_mode():
    """No two bindings claim the same key in the same mode."""
    build_lookup()  # Raises ValueError on a duplicate


def test_action_ids_are_unique():
    """Each binding has its own action id."""
    actions = [binding.action for binding in KEYMAP]

    assert len(actions) == len(set(actions))


def test_every_key_string_is_a_valid_sequence():
    """All key strings parse to non-empty QKeySequences."""
    for key in unique_key_strings():
        sequence = QKeySequence(key)
        assert sequence.count() >= 1, f"{key!r} did not parse"
        assert sequence.toString(), f"{key!r} did not parse"


def test_unique_key_strings_have_no_duplicates():
    """The registration list contains each sequence exactly once."""
    keys = unique_key_strings()

    assert len(keys) == len(set(keys))


def test_single_mode_legend():
    """The single-view legend leads with the marking rhythm."""
    assert legend_text(Mode.SINGLE) == (
        "Space keep · x reject · h/l move · v compare · u undo · ? keys"
    )


def test_visual_mode_legend():
    """The visual-mode legend shows batch operators and exits."""
    assert legend_text(Mode.VISUAL) == (
        "Space keep all · x reject all · h/l extend · Enter compare · Esc cancel · u undo · ? keys"
    )


def test_compare_mode_legend():
    """The compare legend shows focus movement and per-tile marks."""
    assert legend_text(Mode.COMPARE) == (
        "Space keep · x reject · h/l/j/k focus · Esc single · u undo · ? keys"
    )


def test_help_sections_cover_every_binding():
    """Every binding's label appears in its help section."""
    sections = dict(help_sections())

    for binding in KEYMAP:
        rows = sections[binding.group]
        assert (binding.label, binding.help_text) in rows


def test_help_sections_dedupe_shared_rows():
    """A label/help pair repeated across modes appears once per group."""
    for _group, rows in help_sections():
        assert len(rows) == len(set(rows))


def test_marks_do_not_auto_repeat_but_navigation_does():
    """Held keys must not mass-mark; held h/l should keep moving."""
    assert auto_repeat_for("Space") is False
    assert auto_repeat_for("X") is False
    assert auto_repeat_for("C") is False
    assert auto_repeat_for("U") is False
    assert auto_repeat_for("H") is True
    assert auto_repeat_for("L") is True


def test_digits_bound_only_in_compare_mode():
    """1-9 jump tiles in compare and stay free elsewhere."""
    lookup = build_lookup()

    for n in range(1, 10):
        assert (Mode.COMPARE, str(n)) in lookup
        assert (Mode.SINGLE, str(n)) not in lookup
        assert (Mode.VISUAL, str(n)) not in lookup
