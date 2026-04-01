"""Messages panel widgets - containers for message display with/without thread panel.

WE'RE ALL FRIENDS HERE! These widgets are registered in components/all.py
"""

from textual.containers import Horizontal
from textual.widget import Widget

from .layout_render import RenderablePanel

# Import for type hints and compose() - friends can still import friends!
from .scrollable_log import ScrollableLog
from .slotted_message_list import SlottedMessageList
from .thread_panel import ThreadMessage, ThreadPanel


class MessagesPanel(Widget, RenderablePanel):
    """Message log only (thread panel closed).
    
    Supports both ScrollableLog (text-based) and SlottedMessageList (widget-based with slots).
    """

    # REGRESSION FIX: height: 1fr is REQUIRED
    # Without explicit height, the panel collapses to 0 width during render
    # even though width: 1fr is set. This caused "black rectangle" bug where
    # messages were created but invisible due to zero-width parent.
    # See: proactive logging check "WIDGET: messages has zero size (0x25)"
    # TESTS REQUIRED: Any CSS changes to width/height must verify widget
    # renders with non-zero size. See tests/test_messages_panel_regression.py
    DEFAULT_CSS = """
    MessagesPanel {
        width: 1fr;
        height: 1fr;
    }
    """

    def __init__(self, use_slots: bool = False, **kwargs) -> None:
        super().__init__(**kwargs)
        self._use_slots = use_slots

    def on_mount(self) -> None:
        # Trigger render after layout is computed
        self.trigger_app_render()

    def compose(self):
        if self._use_slots:
            yield SlottedMessageList(id="messages")
        else:
            yield ScrollableLog(
                id="messages",
                highlight=True,
                markup=False,
                min_width=0,
                wrap=True,
                auto_scroll=False,
            )


class MessagesPanelWithThread(Widget, RenderablePanel):
    """Message log with thread panel side by side (thread panel open).
    
    Supports both ScrollableLog (text-based) and SlottedMessageList (widget-based with slots).
    """

    # REGRESSION FIX: height: 1fr is REQUIRED for both container and inner layout
    # Without explicit height, the panel collapses causing zero-width renders.
    # This mirrors the MessagesPanel regression - both need explicit height.
    # TESTS REQUIRED: See tests/test_messages_panel_regression.py
    DEFAULT_CSS = """
    MessagesPanelWithThread {
        width: 1fr;
        height: 1fr;
    }

    #messages-and-thread {
        width: 1fr;
        height: 1fr;
    }
    """

    def __init__(self, thread_root: str, thread_messages: list[ThreadMessage], formatter, use_slots: bool = False, **kwargs) -> None:
        # Force unique ID
        kwargs["id"] = "messages-panel-with-thread"
        super().__init__(**kwargs)
        self._thread_root = thread_root
        self._thread_messages = thread_messages
        self._formatter = formatter
        self._use_slots = use_slots

    def on_mount(self) -> None:
        # Trigger render after layout is computed
        self.trigger_app_render()

    def compose(self):
        with Horizontal(id="messages-and-thread"):
            if self._use_slots:
                yield SlottedMessageList(id="messages")
            else:
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