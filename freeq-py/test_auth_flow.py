#!/usr/bin/env python3
"""Test script to verify AuthCompleted flow without full OAuth dance."""

import asyncio
import sys
sys.path.insert(0, '/home/nandi/code/freeq/freeq-py')

from src.generated.app import FreeQApp
from src.generated.widgets.authentication import AuthenticationWidget

# Create app instance
app = FreeQApp()

# Simulate what happens after OAuth completes
print("=" * 60)
print("TEST: Simulating AuthCompleted message")
print("=" * 60)

# Create mock AuthCompleted event
class MockEvent:
    handle = "test.bsky.social"
    did = "did:plc:abc123"
    nick = "test"
    broker_token = "mock_token_12345"
    session_data = {}

event = MockEvent()

print(f"\nMock event: handle={event.handle}, did={event.did}, broker_token={event.broker_token}")

# Check if the handler exists
handler_name = 'on_authentication_widget_auth_completed'
has_handler = hasattr(app, handler_name)
print(f"\nHandler '{handler_name}' exists: {has_handler}")

if has_handler:
    handler = getattr(app, handler_name)
    print(f"Handler callable: {callable(handler)}")
    
    # Check the method signature
    import inspect
    sig = inspect.signature(handler)
    print(f"Handler signature: {sig}")
    
    # Try to call it (this may fail due to TUI not being fully initialized)
    print("\nTrying to call handler...")
    try:
        handler(event)
        print("Handler executed successfully!")
    except Exception as e:
        print(f"Handler raised exception: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

print("\n" + "=" * 60)
print("Checking hide_authentication method...")
print("=" * 60)

if hasattr(app, 'hide_authentication'):
    print("hide_authentication method exists")
    try:
        app.hide_authentication()
        print("hide_authentication() executed successfully!")
    except Exception as e:
        print(f"hide_authentication() raised: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
else:
    print("ERROR: hide_authentication method NOT FOUND")

print("\n" + "=" * 60)
print("Checking CSS classes...")
print("=" * 60)

# Check if the CSS contains the right selectors
css_text = getattr(app, 'CSS', '')
has_hidden = '#auth-overlay.hidden' in css_text
has_visible = '#main-layout.visible' in css_text
print(f"CSS has #auth-overlay.hidden: {has_hidden}")
print(f"CSS has #main-layout.visible: {has_visible}")

if not has_hidden:
    print("  ERROR: Missing CSS for hiding auth overlay!")
if not has_visible:
    print("  ERROR: Missing CSS for showing main layout!")

print("\n" + "=" * 60)
print("Test complete")
print("=" * 60)
