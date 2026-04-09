# Phoenix Code Generation Instruction

## Language Context

**Detected Language:** Python (Textual TUI)  
**Module System:** commonjs  
**File Extension:** .py

## Theory Mapping (ThIU → ThPythonTextualTUI)

This instruction includes a theory morphism that maps Implementation Units to Python (Textual TUI) constructs.

### IU → Language Function Mapping

- Requirements Domain (low):
  Classes:
    - WIDGET: RequirementsWidget
      (Main widget for Requirements Domain)
    - MODEL: RequirementsState
      (Data model for Requirements Domain)

- Definitions Domain (low):
  Classes:
    - WIDGET: DefinitionsWidget
      (Main widget for Definitions Domain)
    - MODEL: DefinitionsState
      (Data model for Definitions Domain)

- Phoenix Domain (critical):
  Classes:
    - WIDGET: PhoenixWidget
      (Main widget for Phoenix Domain)
    - MODEL: PhoenixState
      (Data model for Phoenix Domain)

### Constraint → Implementation Mapping

- UNMATCHED: "must not exceed limitation..." → manual review needed
- UNMATCHED: "must support minimum requirement..." → manual review needed
- UNMATCHED: "textuals input widget does not accept a multiline ..." → manual review needed
- UNMATCHED: "all textual messages must call superinit in their ..." → manual review needed
- UNMATCHED: "when importing both textuals message event class a..." → manual review needed
- UNMATCHED: "the apppy must include entry point block if name m..." → manual review needed

## Deliverable Structure

**Server Framework:** None (TUI application)  
**UI Pattern:** Textual widgets with CSS styling  
**State Management:** reactive attributes on Widget classes

**Output Structure:**
```
src/generated/
├── __init__.py                    # Module exports
├── models.py                      # Data classes (@dataclass(slots=True))
├── app.py                         # Main Textual App with @Binding keyboard shortcuts
└── widgets/                       # Textual widget modules
    ├── __init__.py
    ├── sidebar.py                 # BufferSidebar widget
    ├── message_list.py            # MessageList widget
    ├── message_item.py            # MessageItem widget
    ├── thread_panel.py            # ThreadPanel widget
    ├── user_list.py               # UserList widget
    ├── input_bar.py               # InputBar widget
    ├── emoji_picker.py            # EmojiPicker widget
    ├── debug_panel.py             # DebugPanel widget
    ├── loading_overlay.py         # LoadingOverlay widget
    └── context_menu.py            # ContextMenu widget
```

**File Responsibilities:**
- `models.py`: All @dataclass(slots=True) data models for 34 IUs
- `app.py`: Main FreeQApp class with compose(), keyboard @Binding, reactive state
- `widgets/*.py`: Individual Textual widgets with compose(), CSS, event handlers

## Your Task

Generate a complete Textual TUI application by implementing all 34 IUs from the theory mapping above.

### Step 1: Data Models (3 IUs)
Create `src/generated/models.py` with all data classes:
- For each IU, create a @dataclass(slots=True) model
- Include fields derived from the "Classes" section above
- Include traceability: `# @phoenix-canon: <iu-id>`

### Step 2: Widget Classes
Create widget files in `src/generated/widgets/`:
- Each widget is a Textual `Widget` subclass
- Implement `compose()` method yielding child widgets
- Add CSS styling with `DEFAULT_CSS`
- Implement methods from "Functions" section above
- Add reactive state with `textual.reactive.reactive()`
- Add keyboard bindings with `@Binding` decorator
- **CRITICAL:** Any `watch_state()` method must start with:
  ```python
  def watch_state(self, state):
      if not self.is_mounted:
          return
      # ... rest of method
  ```

### Step 3: Main App
Create `src/generated/app.py`:
- Main `FreeQApp(App)` class
- `compose()` method mounting all widgets
- Global keyboard shortcuts (Ctrl+C, Ctrl+L, etc.)
- Event handling with `@on(EventType)` decorators
- Connect to domain logic in models

### Traceability Requirements
- Every class must have: `# @phoenix-canon: <iu-id>`
- Every method must have: `# @phoenix-canon: <canon-node-id>`
- Include IU name in docstrings

### Logging & Tracing Requirements (AUTO-INJECTED)

**Every method must include automatic logging for traceability:**

1. **Method Entry Logging:**
   - First line of every method (after traceability comment) must log entry
   - Use structured prefix based on domain: `[AUTH]`, `[UI]`, `[BROKER]`, `[MOUNT]`, etc.
   - Include key parameter values (not sensitive data like full tokens)
   
   Example:
   ```python
   def on_auth_screen_auth_completed(self, event: AuthCompleted) -> None:
       # @phoenix-canon: node-2c760e46
       logger.info(f"[AUTH] AuthCompleted received for handle={event.handle}")
       # ... method implementation
   ```

2. **State Transition Logging:**
   - Log all critical state changes (authenticated=True/False, connected/disconnected)
   - Use format: `logger.info(f"[DOMAIN] State changed: {old} -> {new}")`
   
   Example:
   ```python
   self.app_state.session.authenticated = True
   logger.info(f"[AUTH] Session authenticated: handle={event.handle}")
   ```

3. **Lifecycle Event Logging:**
   - `on_mount()`: Log "[MOUNT] Starting {widget/app} initialization"
   - `compose()`: Log "[UI] Composing {widget} layout"
   - `watch_*()`: Log "[REACTIVE] {property} changed from {old} to {new}"
   - Event handlers: Log "[EVENT] {EventType} received"

4. **Auto-Login Specific Logging (CRITICAL):**
   - `[AUTH-MOUNT] Starting on_mount, checking for saved credentials...`
   - `[AUTH-MOUNT] load_saved_credentials returned: {True|False}`
   - `[AUTH-MOUNT] Saved credentials found, attempting auto-login`
   - `[AUTH-MOUNT] Session set: handle={h}, auth={auth}`
   - `[AUTH-MOUNT] Auto-login complete, main UI should be visible`
   - `[AUTH-MOUNT] No saved credentials found OR load failed, showing AuthScreen`

5. **Error & Warning Logging:**
   - All error paths must log with `logger.error()` or `logger.warning()`
   - Include exception details: `logger.error(f"[DOMAIN] Operation failed: {e}")`

6. **Success Logging:**
   - Key operations should log success: `logger.info("[DOMAIN] Operation completed successfully")`
   - Credential save: `logger.info("[AUTH] Credentials saved for auto-login")`
   - File operations: `logger.info("[IO] File saved: {path}")`

**Log Prefix Standards:**
- `[AUTH]` - Authentication flow (login, tokens, sessions)
- `[AUTH-MOUNT]` - Auth specifically in on_mount() auto-login
- `[UI]` - UI rendering, widget composition
- `[MOUNT]` - Widget/app lifecycle (on_mount, on_unmount)
- `[REACTIVE]` - Reactive state changes (watch_* methods)
- `[EVENT]` - Event handling
- `[BROKER]` - Broker communication
- `[IO]` - File/network operations
- `[STATE]` - App state changes
- `[ERROR]` - Error conditions (use logger.error)

### Language Patterns to Apply
- **keyboard shortcut**: @Binding(key, action, description) decorator
- **reactive state**: textual.reactive.reactive() decorator
- **async event**: async def with @on(EventType) decorator
- **css styling**: Textual CSS with widget IDs and classes
- **widget compose**: compose() method yielding child widgets
- **dataclass model**: @dataclass(slots=True) for data classes
- **watch_state lifecycle**: watch_state() MUST check is_mounted before accessing child widgets: if not self.is_mounted: return

### Reference Files
- Canonical requirements: `/home/nandi/code/freeq/freeq-py/.phoenix/graphs/canonical.json`
- Language theory: `/home/nandi/code/freeq/freeq-py/.phoenix/language-theory.json`
- Output directory: `/home/nandi/code/freeq/freeq-py/src/generated`

## Success Criteria

- [ ] All 34 IUs have corresponding code
- [ ] All functions from theory mapping are implemented
- [ ] Textual app can be imported without errors
- [ ] Traceability comments present on all major elements
- [ ] No circular imports
- [ ] Follows Textual best practices (reactive state, compose, CSS)

---
Generated: 2026-04-09T23:18:39.579Z
Language Variant: python-textual
