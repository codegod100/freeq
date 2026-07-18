# Freeq WinUI Design System

**Aesthetic direction:** Industrial/Protocol Precision

The right reference is Linear-meets-terminal, not Discord-meets-gaming. Freeq's users
are IRCv3 WG members and AT Protocol contributors — people who read RFCs and review PRs.
This is a protocol tool that happens to be beautiful, not a chat tool that's trying to
look serious.

The teal accent signals network output (think: tcpdump, Wireshark connection established).
The purple-shifted surfaces feel like a live display at 2am. Lean into that.

---

## Color

All tokens are defined in `Freeq.WinUI/Themes/Colors.xaml`.

### Background — 3-stop depth system

| Token | Hex | Use |
|-------|-----|-----|
| `BgColor` | `#0C0C0F` | Page/window base — the deepest layer |
| `BgSecondaryColor` | `#131318` | Sidebar, member list, panels |
| `BgTertiaryColor` | `#1C1C24` | Hover states, dividers |
| `SurfaceColor` | `#26263A` | Input boxes, selected channel, cards |

The purple shift in `SurfaceColor` is intentional — it makes the surface look like a
display screen, not just a dark rectangle.

### Borders — barely-there

| Token | Hex | Use |
|-------|-----|-----|
| `BorderColor` | `#1E1E2E` | Primary divider (sidebar/main, top bar) |
| `BorderBrightColor` | `#2A2A3E` | Input borders, active element outlines |

Borders exist to define structure, not to decorate. If you can remove a border and still
understand the layout, remove it.

### Foreground — 3-stop hierarchy

| Token | Hex | Use |
|-------|-----|-----|
| `FgColor` | `#E8E8ED` | Primary text — messages, channel name, headers |
| `FgMutedColor` | `#9898B0` | Secondary text — unread channel names, member nicks |
| `FgDimColor` | `#555570` | Tertiary — timestamps, section labels, placeholders |

### Accent — teal = trust, connection, verification

| Token | Hex | Use |
|-------|-----|-----|
| `AccentColor` | `#00D4AA` | Connection indicator, brand, links, verified badge |
| `AccentHoverColor` | `#00F0C0` | Hover state for accent elements |
| `AccentDimBrush` | `#3300D4AA` (20% opacity) | Accent-tinted backgrounds (logo, badge bg) |

Teal is the signal that something is real and connected. It appears on: the brand mark,
the connection status dot, the verified DID badge, and the user's own nick in messages.

### Semantic colors

| Token | Hex | Use |
|-------|-----|-----|
| `DangerColor` | `#FF5C5C` | Error states, ban indicators |
| `WarningColor` | `#FFB547` | Away indicator, warnings |
| `SuccessColor` | `#00D4AA` | Same as accent — success is connection |

### Nick colors — hash-assigned

IRC veterans expect nick colors. Use the existing palette to deterministically assign
a color to each nick based on a hash of the nick string. This makes conversations
scannable at a glance.

```
5 hues, rotate via: hash(nick) % 5
  0 → Purple  #B18CFF
  1 → Blue    #5C9EFF
  2 → Pink    #FF6EB4
  3 → Orange  #FF9547
  4 → Teal    #00D4AA  ← also used for the authenticated user's own nick
```

**Implementation note:** The authenticated user's own nick should always use the Teal
(`AccentColor`), regardless of hash value. This gives the user a clear sense of which
messages are theirs.

---

## Typography

### Font families

**Primary UI:** `Segoe UI Variable` (WinUI default on Windows 11)

Variable-weight, designed for Windows 11, renders perfectly at every size from 10px to
display scale. Do not override this with a custom font — the OS integration is the point.

**Technical/Identity:** `Cascadia Code` (built into Windows 11)

Used *only* for protocol-layer data: DID strings, msgid values, server addresses, and
technical identifiers. Every time Cascadia Code appears, it signals "you are looking at
the raw protocol layer." Use it sparingly. If it appeared everywhere, it would lose the
signal.

### Type scale

| Role | Family | Size | Weight | Notes |
|------|--------|------|--------|-------|
| Header | Segoe UI Variable | 18px | SemiBold | Channel name in TopBar |
| Body | Segoe UI Variable | 14px | Regular | Message text, channel list |
| Small | Segoe UI Variable | 12px | Regular | Secondary info |
| Section Label | Segoe UI Variable | 11px | Bold | `CharacterSpacing=120` (wide tracking), ALL CAPS |
| Tiny/Meta | Segoe UI Variable | 10px | Regular | Timestamps, "edited" indicator |
| Code/Identity | Cascadia Code | 13px | Regular | DID strings, msgids, addresses |

The `SectionHeaderFontSize=11` + `CharacterSpacing=120` + `FontWeight=Bold` combination
is already in use for sidebar section labels (CHANNELS, DIRECT MESSAGES). This is a
deliberate design pattern — document it, preserve it everywhere section labels appear.

---

## Spacing

**Base unit: 4px.** All spacing values are multiples of 4.

### Scale

```
4px   — micro (badge padding, icon insets)
8px   — small (channel item vertical padding, compose box padding)
12px  — base (sidebar horizontal padding)
16px  — medium (message horizontal padding, panel gutters)
24px  — large (section gaps)
32px  — xl (page-level padding)
48px  — 2xl (section breaks in documentation)
```

### Component-specific measurements

| Component | Padding | Notes |
|-----------|---------|-------|
| Sidebar channel item | `10/8` (h/v) | `ChannelItemPadding` |
| Message row | `16/6` (h/v) | `MessagePadding` — tight vertical rhythm |
| Sidebar header | `16/0` | `SidebarPadding` |
| Avatar | 36×36px, 18px radius | Circle, `SurfaceColor` background |
| Top bar | 56px height | Matches sidebar header height |

### Corner radii

| Token | Value | Use |
|-------|-------|-----|
| `SmallRadius` | 4px | Badges, status indicators, inline chips |
| `MediumRadius` | 8px | Buttons, input boxes, cards |
| `LargeRadius` | 12px | Panels, dialogs, larger cards |
| `CircleRadius` | 999px | Avatars, pill badges |

---

## Motion

**Principle: minimal-functional.** Motion aids comprehension, never decorates.

The WinUI Mica backdrop (`<MicaBackdrop />`) handles ambient depth and material feel —
do not fight it with layered decorative animations.

| Element | Spec | Rationale |
|---------|------|-----------|
| Sidebar channel selection | 150ms ease-out | Orients user spatially without distracting |
| Message appearance | Instant (0ms) | IRC is always-on. Entrance animations add latency theater. |
| Connection status dot | 1.4s ease-in-out pulse, loops | Signals "connecting" state. Stops immediately on connect. |
| Dialog open/close | Use WinUI default transitions | ContentDialog transitions are already correct for Windows 11 |

**Connection dot states:**
- Dim gray (`FgDimColor`) — disconnected
- Pulsing orange/warning — connecting
- Solid teal (`AccentColor`) + glow — connected and authenticated

---

## Verified DID Badge

The `✓` badge shown next to DID-verified nicks is the most important design element in
the message list. It is what makes Freeq different from every other IRC client.

**Current implementation:** TextBlock with `✓` character, `AccentBrush` color, 11px.

**Intent:** The badge should feel like a trust signal, not an afterthought. Design
principles:
- Use a chip/pill shape (rounded border, `AccentDimBrush` background) not just a bare checkmark
- Display the shortened DID inside the badge, rendered in `Cascadia Code`
- Example: `[✓ did:plc:abc1]` — the monospace rendering signals this is a real identifier

**Why this matters:** When an IRCv3 WG member sees the client, this badge is the demo.
It should be the most readable, most polished thing on screen. If someone asks "what is
that green tag?" the answer is "that's the AT Protocol DID that proved this user's
identity when they connected." Make the answer visible.

---

## Layout

**Three-pane layout:** sidebar / messages / members. Standard IRC muscle memory.

```
┌─────────────────────────────────────────────────────┐
│  56px top bar (title, connection status)             │
├──────────────┬──────────────────────┬───────────────┤
│  256px       │                      │  160px        │
│  Sidebar     │   Message list       │  Member list  │
│  (channels,  │   (scrollable)       │  (optional)   │
│   DMs)       │                      │               │
│              ├──────────────────────┤               │
│              │  Compose box         │               │
└──────────────┴──────────────────────┴───────────────┘
```

- Sidebar: 256px fixed width, `BgSecondaryColor`
- Message list: fills remaining space, `BgColor`
- Member list: 160px, `BgSecondaryColor`, collapsible
- Top bar: 56px, same background as sidebar for visual alignment

---

## WinUI-Specific Notes

### Mica backdrop
`<MicaBackdrop />` is applied at the window level. It provides a translucent material
effect that integrates with Windows 11's desktop wallpaper. This is a first-class
Windows 11 feature — use it. It does not require any theme-specific handling.

### Theme support
This design system is **dark-only**. Freeq's audience is developers who work in dark
mode. Do not implement a light theme. If WinUI's default light-mode fallback appears,
override it explicitly with the `BgBrush` tokens.

### System accent color
Windows 11 has a user-configurable system accent color. Do not use `SystemAccentColor`
for Freeq's accent. The teal (`#00D4AA`) is part of Freeq's identity — it should not
change when the user picks a different Windows accent color.

---

## Anti-patterns

Do not:
- Use `Inter`, `Roboto`, or `Segoe UI` (non-variable) as the primary font
- Use purple/violet gradients as a background treatment
- Add entrance animations to messages
- Use the Windows system accent color for Freeq's teal
- Render DID strings in the UI font — always use `Cascadia Code`
- Show the full DID string (`did:plc:abcdefghijklmnop`) in the message list — truncate to 8 chars after the prefix

---

## Design Files

Visual preview generated by `/design-consultation`:
`~/.gstack/projects/RobStand-freeq/designs/design-system-20260401/preview.html`

Open with any browser to see color swatches, typography specimens, spacing scale,
and a live component preview of the three-pane IRC layout.
