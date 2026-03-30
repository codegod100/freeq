"""Base spinner component and concrete implementations."""

from textual.widget import Widget
from textual.widgets import Static
from textual.reactive import reactive


class BaseSpinner(Widget):
    """Base class for animated spinner widgets.
    
    Provides:
    - Configurable spinner frames
    - Reactive message property
    - Animation lifecycle (start/stop)
    
    Subclasses should:
    - Define DEFAULT_CSS
    - Implement compose() to yield the spinner Static
    - Optionally override _frame_text() for custom formatting
    """

    DEFAULT_SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    
    # Reactive message - updates display when changed
    message: reactive[str] = reactive("Loading...")
    
    # Animation state
    _frame: int = 0
    _animating: bool = False
    _spinner_text: "Static | None" = None
    
    def __init__(self, message: str = "Loading...", *, spinner_frames: list[str] | None = None, **kwargs) -> None:
        super().__init__(**kwargs)
        self.message = message
        self._spinner_frames = spinner_frames or self.DEFAULT_SPINNER_FRAMES
    
    def compose(self):
        """Yield the spinner Static. Override in subclass for different layouts."""
        self._spinner_text = Static(self._frame_text(), classes="spinner")
        yield self._spinner_text
    
    def _frame_text(self) -> str:
        """Format the current frame. Override for custom formatting."""
        frame = self._spinner_frames[self._frame % len(self._spinner_frames)]
        return f"{frame} {self.message}"
    
    def _advance_frame(self) -> None:
        """Advance animation by one frame."""
        if not self._animating:
            return
        self._frame += 1
        if self._spinner_text:
            self._spinner_text.update(self._frame_text())
    
    def watch_message(self, old: str, new: str) -> None:
        """Update display when message changes."""
        if self._spinner_text:
            self._spinner_text.update(self._frame_text())
    
    def start(self) -> None:
        """Start the animation."""
        if self._animating:
            return
        self._animating = True
        self.set_interval(0.08, self._advance_frame)
    
    def stop(self) -> None:
        """Stop the animation."""
        self._animating = False
    
    def on_mount(self) -> None:
        """Start animation when mounted."""
        self.start()


class LoadingOverlay(BaseSpinner):
    """Full-screen loading overlay with spinner.
    
    Mounted when loading, removed when done.
    Docks on top of content with semi-transparent background.
    """

    DEFAULT_CSS = """
    LoadingOverlay {
        dock: top;
        align: center middle;
        width: 100%;
        height: 100%;
        background: $surface;
        layer: overlay;
    }

    LoadingOverlay .spinner {
        color: $primary;
        text-align: center;
    }
    """

    def _frame_text(self) -> str:
        """Format with extra padding for centering."""
        frame = self._spinner_frames[self._frame % len(self._spinner_frames)]
        return f"\n\n{frame} {self.message}\n\n"


class InlineSpinner(BaseSpinner):
    """Inline spinner for loading indicators within content.
    
    Use for:
    - Infinite scroll "loading older messages"
    - Per-widget loading states
    - Inline action feedback
    
    Docks at top of parent container.
    """

    DEFAULT_CSS = """
    InlineSpinner {
        dock: top;
        width: 100%;
        height: 1;
        content-align: center middle;
        background: $surface;
        color: $primary;
    }

    InlineSpinner .spinner {
        color: $primary;
    }
    """

    def _frame_text(self) -> str:
        """Compact single-line format."""
        frame = self._spinner_frames[self._frame % len(self._spinner_frames)]
        return f"{frame} {self.message}"