"""Full-keymap help overlay, toggled with ?.

Renders the keymap table as a dark overlay covering the viewing area,
following the existing overlay pattern (stylesheet child widget raised over
its parent, repositioned on resize). Content derives from keymap.py, so it
can never drift from the registered shortcuts.
"""

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QMouseEvent
from PySide6.QtWidgets import QLabel, QVBoxLayout, QWidget

from winnow.ui.keymap import help_sections


def _keymap_html() -> str:
    """Render the keymap as a single rich-text block."""
    parts = ["<h2 style='margin-bottom: 4px'>Keys</h2>"]
    for group, rows in help_sections():
        parts.append(f"<h3 style='margin-bottom: 2px'>{group}</h3>")
        parts.append("<table cellspacing='0' cellpadding='2'>")
        for label, help_text in rows:
            parts.append(
                f"<tr><td width='90'><b>{label}</b></td><td>{help_text}</td></tr>"
            )
        parts.append("</table>")
    parts.append("<p style='color: #aaaaaa'>? or Esc or click to close</p>")
    return "".join(parts)


class HelpOverlay(QWidget):
    """Dismissable cheat sheet listing every binding by group.

    Signals:
        dismissed(): Emitted when the overlay is closed by mouse click,
            so the keyboard controller can drop its key suppression.
    """

    dismissed = Signal()

    def __init__(self, parent: QWidget) -> None:
        """Build the overlay as a hidden child of parent.

        Args:
            parent: Widget the overlay covers when shown.
        """
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        self.setStyleSheet(
            """
            HelpOverlay {
                background-color: rgba(0, 0, 0, 220);
            }
            QLabel {
                color: white;
                font-size: 13px;
                background-color: transparent;
            }
        """
        )

        layout = QVBoxLayout(self)
        layout.setContentsMargins(40, 20, 40, 20)
        label = QLabel(_keymap_html())
        label.setTextFormat(Qt.TextFormat.RichText)
        label.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)
        layout.addWidget(label)

        self.hide()

    def show_overlay(self) -> None:
        """Size the overlay to its parent and raise it."""
        self.setGeometry(self.parentWidget().rect())
        self.show()
        self.raise_()

    def mousePressEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        """Any click dismisses the overlay."""
        del event
        self.hide()
        self.dismissed.emit()
