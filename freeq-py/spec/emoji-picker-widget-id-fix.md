# /home/nandi/code/freeq/freeq Py/spec/emoji Picker Widget Id Fix


## Requirements

# Emoji Picker Widget ID Validation Fix

## Overview
Fix the EmojiPicker widget to use valid Textual widget identifiers that comply with the framework's identifier validation rules. Textual requires widget IDs to contain only letters, numbers, underscores, or hyphens, and prohibits emoji characters.

## Requirement: REQ-001 - Valid Widget Identifier Format
- Widget IDs SHALL contain only ASCII letters (a-z, A-Z), numbers (0-9), underscores (_), or hyphens (-)
- Widget IDs SHALL NOT contain emoji characters or other Unicode symbols
- Widget IDs SHALL NOT begin with a number
- The EmojiPicker SHALL use index-based identifiers (e.g., `emoji-0`, `emoji-1`) instead of embedding emoji characters

## Requirement: REQ-002 - Emoji-to-ID Mapping
- EmojiPicker SHALL maintain an internal mapping between index-based IDs and emoji characters
- The mapping SHALL be stored as a dictionary or parallel list structure
- The `EMOJIS` list order SHALL be preserved to ensure consistent ID-to-emoji mapping

## Requirement: REQ-003 - Compose Method Update
- The `compose()` method SHALL generate buttons with valid IDs using enumerate: `f"emoji-{index}"`
- Each button SHALL retain the emoji character as its label/display text
- Button classes SHALL remain as `emoji-button` for styling consistency

## Requirement: REQ-004 - Event Handler Update
- `on_button_pressed()` SHALL extract the index from the button ID (e.g., `emoji-5` → index 5)
- The handler SHALL look up the actual emoji character using the extracted index from the `EMOJIS` list
- The close button handling (`close-emoji`) SHALL remain unchanged
- Selected emoji SHALL be passed to the callback function as the actual emoji character, not the ID

## Requirement: REQ-005 - Backward Compatibility
- The public API (`on_emoji_selected` callback signature) SHALL remain unchanged
- The `EMOJIS` list content and order SHALL NOT change
- CSS styling rules SHALL remain valid (using classes, not IDs)

## Implementation Example
def compose(self):
    with Grid(classes="emoji-grid"):
        for index, emoji in enumerate(self.EMOJIS):
            yield Button(emoji, id=f"emoji-{index}", classes="emoji-button")

@on(Button.Pressed)
def on_button_pressed(self, event: Button.Pressed) -> None:
    button_id = event.button.id
    if button_id == "close-emoji":
        self.visible = False
    elif button_id and button_id.startswith("emoji-"):
        index = int(button_id[6:])  # Extract index from "emoji-{index}"
        emoji = self.EMOJIS[index]   # Look up emoji by index
        if self._on_emoji_selected:
            self._on_emoji_selected(emoji)
        self.visible = False

