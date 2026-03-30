"""Layout-aware rendering framework.

Ensures layout is always computed before any rendering happens.
Components call request_render() instead of calling render methods directly.
"""

from typing import Callable, TYPE_CHECKING

if TYPE_CHECKING:
    from textual.app import App


class LayoutAwareRender:
    """Mixin for apps that need layout-first rendering.

    Usage:
        class MyApp(App, LayoutAwareRender):
            def _render_active_buffer(self) -> None:
                # Actual rendering logic
                pass

            def some_handler(self):
                # Instead of: self._render_active_buffer()
                # Use: self.request_render(self._render_active_buffer)
                self.request_render(self._render_active_buffer)
    """

    _render_queued: bool = False
    _render_callback: Callable | None = None

    def request_render(self, callback: Callable | None = None) -> None:
        """Queue a render to happen after layout is computed.

        If callback is provided, that's the render function.
        If not provided, uses the last registered callback.
        """
        app: App = self  # type: ignore

        if callback:
            self._render_callback = callback

        if self._render_queued:
            # Already queued, don't double-schedule
            return

        self._render_queued = True
        app.call_later(self._execute_render)

    def _execute_render(self) -> None:
        """Execute the queued render callback."""
        self._render_queued = False
        if self._render_callback:
            # Log layout state before render
            from .debug import _dbg
            try:
                log = self.query_one("#messages")  # type: ignore
                _dbg(f"LayoutAwareRender: executing render, log.width={log.size.width}")
            except Exception:
                pass
            self._render_callback()

    def clear_render_queue(self) -> None:
        """Clear any pending render request."""
        self._render_queued = False


class RenderablePanel:
    """Mixin for panels that trigger app rendering on mount.

    Usage:
        class MessagesPanel(Widget, RenderablePanel):
            def on_mount(self) -> None:
                self.trigger_app_render()
    """

    def trigger_app_render(self) -> None:
        """Trigger the parent app's render after layout is ready."""
        from textual.widget import Widget
        from .debug import _dbg

        widget: Widget = self  # type: ignore
        app = widget.app

        _dbg(f"RenderablePanel.trigger_app_render: panel.width={widget.size.width}")

        # Look for LayoutAwareRender on the app
        if hasattr(app, "request_render"):
            # Get the render callback from app
            if hasattr(app, "_render_active_buffer"):
                app.request_render(app._render_active_buffer)  # type: ignore
            else:
                app.request_render()  # type: ignore
        elif hasattr(app, "_render_active_buffer"):
            # Fallback: direct call with call_later
            app.call_later(app._render_active_buffer)  # type: ignore