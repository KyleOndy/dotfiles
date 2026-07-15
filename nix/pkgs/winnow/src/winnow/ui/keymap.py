"""Keyboard map for the culling workflow.

Single source of truth for every shortcut: the keyboard controller registers
QShortcuts from this table, the status-bar legend renders from it, and the
help overlay lists it. Changing a key here changes all three, so they cannot
drift.

The module deliberately imports no Qt: key strings are plain
QKeySequence-parseable text ("Space", "Shift+G", "T,U") consumed elsewhere.
"""

from dataclasses import dataclass
from enum import Enum


class Mode(Enum):
    """Keyboard context, derived from view state.

    SINGLE: one photo displayed (or none).
    VISUAL: building a selection with v / h / l.
    COMPARE: two or more photos displayed with a focused tile.
    """

    SINGLE = "single"
    VISUAL = "visual"
    COMPARE = "compare"


ALL_MODES = frozenset(Mode)
SINGLE = frozenset({Mode.SINGLE})
VISUAL = frozenset({Mode.VISUAL})
COMPARE = frozenset({Mode.COMPARE})


@dataclass(frozen=True)
class Binding:
    """One action's key binding.

    Attributes:
        keys: QKeySequence-parseable strings that trigger the action.
        label: Display label for the help overlay (e.g. "gg", "1-9").
        action: Action id dispatched by the keyboard controller.
        modes: Modes in which the binding is active.
        group: Help overlay section.
        help_text: One-line description for the help overlay.
        legend: Short status-bar legend fragment; None keeps the binding
            out of the legend.
        auto_repeat: Whether holding the key repeats the action.
    """

    keys: tuple[str, ...]
    label: str
    action: str
    modes: frozenset[Mode]
    group: str
    help_text: str
    legend: str | None = None
    auto_repeat: bool = True


# Table order is meaningful: the status-bar legend lists fragments in this
# order, so marks come first, then movement, then mode changes.
KEYMAP: tuple[Binding, ...] = (
    # Marking
    Binding(
        keys=("Space",),
        label="Space",
        action="single_keep",
        modes=SINGLE,
        group="Mark",
        help_text="Mark keeper and advance",
        legend="Space keep",
        auto_repeat=False,
    ),
    Binding(
        keys=("Space",),
        label="Space",
        action="visual_keep",
        modes=VISUAL,
        group="Mark",
        help_text="Mark whole selection keeper and leave visual",
        legend="Space keep all",
        auto_repeat=False,
    ),
    Binding(
        keys=("Space",),
        label="Space",
        action="compare_keep",
        modes=COMPARE,
        group="Mark",
        help_text="Mark focused tile keeper, focus next tile",
        legend="Space keep",
        auto_repeat=False,
    ),
    Binding(
        keys=("X",),
        label="x",
        action="single_reject",
        modes=SINGLE,
        group="Mark",
        help_text="Mark delete and advance",
        legend="x reject",
        auto_repeat=False,
    ),
    Binding(
        keys=("X",),
        label="x",
        action="visual_reject",
        modes=VISUAL,
        group="Mark",
        help_text="Mark whole selection delete and leave visual",
        legend="x reject all",
        auto_repeat=False,
    ),
    Binding(
        keys=("X",),
        label="x",
        action="compare_reject",
        modes=COMPARE,
        group="Mark",
        help_text="Mark focused tile delete and remove it",
        legend="x reject",
        auto_repeat=False,
    ),
    Binding(
        keys=("C",),
        label="c",
        action="single_clear",
        modes=SINGLE,
        group="Mark",
        help_text="Clear mark on current photo",
        auto_repeat=False,
    ),
    Binding(
        keys=("C",),
        label="c",
        action="visual_clear",
        modes=VISUAL,
        group="Mark",
        help_text="Clear marks on whole selection and leave visual",
        auto_repeat=False,
    ),
    Binding(
        keys=("C",),
        label="c",
        action="compare_clear",
        modes=COMPARE,
        group="Mark",
        help_text="Clear focused tile's mark",
        auto_repeat=False,
    ),
    # Navigation
    Binding(
        keys=("H", "Left"),
        label="h",
        action="single_prev",
        modes=SINGLE,
        group="Navigate",
        help_text="Previous photo",
    ),
    Binding(
        keys=("L", "Right"),
        label="l",
        action="single_next",
        modes=SINGLE,
        group="Navigate",
        help_text="Next photo",
        legend="h/l move",
    ),
    Binding(
        keys=("H", "Left"),
        label="h",
        action="visual_left",
        modes=VISUAL,
        group="Navigate",
        help_text="Grow or shrink selection leftward",
    ),
    Binding(
        keys=("L", "Right"),
        label="l",
        action="visual_right",
        modes=VISUAL,
        group="Navigate",
        help_text="Grow or shrink selection rightward",
        legend="h/l extend",
    ),
    Binding(
        keys=("H", "Left"),
        label="h",
        action="compare_focus_left",
        modes=COMPARE,
        group="Navigate",
        help_text="Focus tile to the left",
    ),
    Binding(
        keys=("L", "Right"),
        label="l",
        action="compare_focus_right",
        modes=COMPARE,
        group="Navigate",
        help_text="Focus tile to the right",
        legend="h/l/j/k focus",
    ),
    Binding(
        keys=("J",),
        label="j",
        action="compare_focus_down",
        modes=COMPARE,
        group="Navigate",
        help_text="Focus tile one grid row down",
    ),
    Binding(
        keys=("K",),
        label="k",
        action="compare_focus_up",
        modes=COMPARE,
        group="Navigate",
        help_text="Focus tile one grid row up",
    ),
    Binding(
        keys=("G,G",),
        label="gg",
        action="single_first",
        modes=SINGLE,
        group="Navigate",
        help_text="First photo",
        auto_repeat=False,
    ),
    Binding(
        keys=("Shift+G",),
        label="G",
        action="single_last",
        modes=SINGLE,
        group="Navigate",
        help_text="Last photo",
        auto_repeat=False,
    ),
    # Selection / comparison
    Binding(
        keys=("V",),
        label="v",
        action="enter_visual",
        modes=SINGLE,
        group="Compare",
        help_text="Start visual selection for comparison",
        legend="v compare",
        auto_repeat=False,
    ),
    Binding(
        keys=("Return", "Enter", "V"),
        label="Enter",
        action="visual_commit",
        modes=VISUAL,
        group="Compare",
        help_text="Commit selection to comparison",
        legend="Enter compare",
        auto_repeat=False,
    ),
    Binding(
        keys=("Escape",),
        label="Esc",
        action="visual_cancel",
        modes=VISUAL,
        group="Compare",
        help_text="Cancel visual selection",
        legend="Esc cancel",
        auto_repeat=False,
    ),
    Binding(
        keys=("Escape",),
        label="Esc",
        action="compare_exit",
        modes=COMPARE,
        group="Compare",
        help_text="Exit comparison to the focused photo",
        legend="Esc single",
        auto_repeat=False,
    ),
    Binding(
        keys=tuple(str(n) for n in range(1, 10)),
        label="1-9",
        action="focus_tile",
        modes=COMPARE,
        group="Compare",
        help_text="Jump focus to tile n",
        auto_repeat=False,
    ),
    # Zoom
    Binding(
        keys=("+", "="),
        label="+",
        action="zoom_in",
        modes=ALL_MODES,
        group="Zoom",
        help_text="Zoom in",
    ),
    Binding(
        keys=("-",),
        label="-",
        action="zoom_out",
        modes=ALL_MODES,
        group="Zoom",
        help_text="Zoom out",
    ),
    Binding(
        keys=("0",),
        label="0",
        action="zoom_100",
        modes=ALL_MODES,
        group="Zoom",
        help_text="Zoom to 100%",
    ),
    Binding(
        keys=("F",),
        label="f",
        action="zoom_fit",
        modes=ALL_MODES,
        group="Zoom",
        help_text="Zoom to fit",
    ),
    # Pan
    Binding(
        keys=("Shift+H",),
        label="H",
        action="pan_left",
        modes=ALL_MODES,
        group="Pan",
        help_text="Pan view left",
    ),
    Binding(
        keys=("Shift+L",),
        label="L",
        action="pan_right",
        modes=ALL_MODES,
        group="Pan",
        help_text="Pan view right",
    ),
    Binding(
        keys=("Shift+J",),
        label="J",
        action="pan_down",
        modes=ALL_MODES,
        group="Pan",
        help_text="Pan view down",
    ),
    Binding(
        keys=("Shift+K",),
        label="K",
        action="pan_up",
        modes=ALL_MODES,
        group="Pan",
        help_text="Pan view up",
    ),
    Binding(
        keys=("Ctrl+H",),
        label="Ctrl+h",
        action="align_left",
        modes=COMPARE,
        group="Pan",
        help_text="Nudge focused tile left to align it with the others",
    ),
    Binding(
        keys=("Ctrl+L",),
        label="Ctrl+l",
        action="align_right",
        modes=COMPARE,
        group="Pan",
        help_text="Nudge focused tile right to align it with the others",
    ),
    Binding(
        keys=("Ctrl+J",),
        label="Ctrl+j",
        action="align_down",
        modes=COMPARE,
        group="Pan",
        help_text="Nudge focused tile down to align it with the others",
    ),
    Binding(
        keys=("Ctrl+K",),
        label="Ctrl+k",
        action="align_up",
        modes=COMPARE,
        group="Pan",
        help_text="Nudge focused tile up to align it with the others",
    ),
    Binding(
        keys=("Ctrl+0",),
        label="Ctrl+0",
        action="align_reset",
        modes=COMPARE,
        group="Pan",
        help_text="Reset focused tile's alignment",
        auto_repeat=False,
    ),
    # Filters
    Binding(
        keys=("T,U",),
        label="tu",
        action="toggle_unmarked",
        modes=ALL_MODES,
        group="Filters",
        help_text="Toggle unmarked photos in the strip",
        auto_repeat=False,
    ),
    Binding(
        keys=("T,K",),
        label="tk",
        action="toggle_keepers",
        modes=ALL_MODES,
        group="Filters",
        help_text="Toggle keepers in the strip",
        auto_repeat=False,
    ),
    Binding(
        keys=("T,D",),
        label="td",
        action="toggle_deletes",
        modes=ALL_MODES,
        group="Filters",
        help_text="Toggle deletes in the strip",
        auto_repeat=False,
    ),
    Binding(
        keys=("T,S",),
        label="ts",
        action="toggle_sort_sharpness",
        modes=ALL_MODES,
        group="Filters",
        help_text="Toggle sorting the strip softest-focus-first",
        auto_repeat=False,
    ),
    # Session
    Binding(
        keys=("U",),
        label="u",
        action="undo",
        modes=ALL_MODES,
        group="Session",
        help_text="Undo last mark",
        legend="u undo",
        auto_repeat=False,
    ),
    Binding(
        keys=("Ctrl+R",),
        label="Ctrl+r",
        action="redo",
        modes=ALL_MODES,
        group="Session",
        help_text="Redo undone mark",
        auto_repeat=False,
    ),
    Binding(
        keys=("?",),
        label="?",
        action="toggle_help",
        modes=ALL_MODES,
        group="Session",
        help_text="Show or hide this help",
        legend="? keys",
        auto_repeat=False,
    ),
    Binding(
        keys=("Q",),
        label="q",
        action="quit",
        modes=ALL_MODES,
        group="Session",
        help_text="Quit (confirms when marks exist)",
        auto_repeat=False,
    ),
)


def build_lookup() -> dict[tuple[Mode, str], Binding]:
    """Build the (mode, key string) dispatch table.

    Returns:
        Mapping from (mode, key string) to the binding to run.

    Raises:
        ValueError: If two bindings claim the same key in the same mode.
    """
    lookup: dict[tuple[Mode, str], Binding] = {}
    for binding in KEYMAP:
        for mode in binding.modes:
            for key in binding.keys:
                entry = (mode, key)
                if entry in lookup:
                    raise ValueError(
                        f"Duplicate binding for {key!r} in {mode.value}: "
                        f"{lookup[entry].action} and {binding.action}"
                    )
                lookup[entry] = binding
    return lookup


def unique_key_strings() -> list[str]:
    """Return every distinct key string in table order.

    The controller registers exactly one QShortcut per entry; registering
    the same sequence twice would make both fire only activatedAmbiguously.
    """
    seen: dict[str, None] = {}
    for binding in KEYMAP:
        for key in binding.keys:
            seen.setdefault(key)
    return list(seen)


def auto_repeat_for(key: str) -> bool:
    """Return whether the QShortcut for a key string should auto-repeat.

    A key string shared by bindings that disagree on auto-repeat gets the
    most restrictive answer (no repeat), since QShortcut repeat is per
    shortcut, not per mode.
    """
    return all(binding.auto_repeat for binding in KEYMAP if key in binding.keys)


def legend_text(mode: Mode) -> str:
    """Render the status-bar legend for a mode from the table."""
    fragments = [
        binding.legend for binding in KEYMAP if mode in binding.modes and binding.legend
    ]
    return " · ".join(fragments)


@dataclass(frozen=True)
class ModeStyle:
    """Visual presentation for a keyboard mode.

    Attributes:
        label: Status-bar badge text.
        color: Accent hex color, shared by the badge background and the
            viewing-area frame.
    """

    label: str
    color: str


# Deliberately outside the photo-status palette (keeper green, delete red,
# selection blue reused for COMPARE, focus-ring amber) so the indicator never
# reads as a mark on the photo itself. VISUAL gets the loudest color since its
# marks are the most consequential: a single key marks the whole span.
MODE_STYLES: dict[Mode, ModeStyle] = {
    Mode.SINGLE: ModeStyle("SELECT", "#757575"),
    Mode.COMPARE: ModeStyle("COMPARE", "#2196F3"),
    Mode.VISUAL: ModeStyle("VISUAL", "#26A69A"),
}


def mode_style(mode: Mode) -> ModeStyle:
    """Badge label and accent color for a mode - single source of truth
    for the status-bar badge and the viewing-area frame.
    """
    return MODE_STYLES[mode]


def help_sections() -> list[tuple[str, list[tuple[str, str]]]]:
    """Group bindings for the help overlay.

    Returns:
        (group, rows) pairs in first-appearance order, where each row is
        (key label, help text). Bindings sharing a label and help text
        across modes appear once.
    """
    sections: dict[str, list[tuple[str, str]]] = {}
    for binding in KEYMAP:
        rows = sections.setdefault(binding.group, [])
        row = (binding.label, binding.help_text)
        if row not in rows:
            rows.append(row)
    return list(sections.items())
