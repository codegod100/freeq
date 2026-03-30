"""Loading overlay with spinner."""

from textual.widget import Widget
from textual.widgets import Static


class LoadingOverlay(Widget):
    """Full-screen loading overlay with spinner."""

    DEFAULT_CSS = """
    LoadingOverlay {
        align: center middle;
        width: 100%;
        height: 100%;
        background: $surface;
    }

    LoadingOverlay .spinner {
        color: $primary;
        text-align: center;
    }
    """

    SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    _frame = 0

    def __init__(self, message: str = "Loading...", **kwargs) -> None:
        super().__init__(**kwargs)
        self._message = message
        self._spinner_text: Static | None = None

    def compose(self):
        self._spinner_text = Static(self._frame_text(), classes="spinner")
        yield self._spinner_text

    def _frame_text(self) -> str:
        frame = self.SPINNER_FRAMES[self._frame % len(self.SPINNER_FRAMES)]
        return f"\n\n{frame} {self._message}\n\n"

    def on_mount(self) -> None:
        # Animate spinner (NO TIMERS comment in layout_render.py applies to layout,
        # spinner animation is cosmetic, not layout-related)
        self.set_interval(0.08, self._advance_frame)

    def _advance_frame(self) -> None:
        self._frame += 1
        if self._spinner_text:
            self._spinner_text.update(self._frame_text())

    def update_message(self, message: str) -> None:
        """Update the loading message."""
        self._message = message
        if self._spinner_text:
            self._spinner_text.update(self._frame_text())