"""Messages panel widgets - containers for message display with/without thread panel."""

from textual.containers import Horizontal
from textual.widget import Widget

from .scrollable_log import ScrollableLog
from .thread_panel import ThreadMessage, ThreadPanel


class MessagesPanel(Widget):
    """Message log only (thread panel closed)."""

    DEFAULT_CSS = """
    MessagesPanel {
        width: 1fr;
    }
    """

    def compose(self):
        yield ScrollableLog(
            id="messages",
            highlight=True,
            markup=False,
            min_width=0,
            wrap=True,
            auto_scroll=False,
        )


class MessagesPanelWithThread(Widget):
    """Message log with thread panel side by side (thread panel open)."""

    DEFAULT_CSS = """
    MessagesPanelWithThread {
        width: 1fr;
    }

    #messages-and-thread {
        width: 1fr;
    }
    """

    def __init__(self, thread_root: str, thread_messages: list[ThreadMessage], formatter, **kwargs) -> None:
        # Force unique ID
        kwargs["id"] = "messages-panel-with-thread"
        super().__init__(**kwargs)
        self._thread_root = thread_root
        self._thread_messages = thread_messages
        self._formatter = formatter

    def compose(self):
        with Horizontal(id="messages-and-thread"):
            yield ScrollableLog(
                id="messages",
                highlight=True,
                markup=False,
                min_width=0,
                wrap=True,
                auto_scroll=False,
            )
            yield ThreadPanel(
                self._thread_root,
                self._thread_messages,
                self._formatter,
                id="thread-panel",
            )

    def refresh_thread_messages(self, messages: list[ThreadMessage]) -> None:
        """Refresh the thread panel with new messages."""
        panel = self.query_one("#thread-panel", ThreadPanel)
        panel.refresh_messages(messages)