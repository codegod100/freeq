# Implementation Units

Planned from canonical requirements. Each IU groups related requirements by feature area.

---

## IU-517684c6: Requirements Domain (LOW)

**Description:** Implements requirements functionality with 4 requirements

**Risk Tier:** low (4 requirements)

**Canonical Requirements:**
- 03ef4d2524aa...
- 09daab1c07a9...
- 1f540d2c172a...
- 8330b04e652d...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: must not exceed limitation

**Output Files:**
- `src/generated/requirements/index.ts`
- `src/generated/requirements/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation

---

## IU-c40ae8a5: Definitions Domain (LOW)

**Description:** Implements definitions functionality with 1 requirements

**Risk Tier:** low (1 requirements)

**Canonical Requirements:**
- 6ab64ae1c2a1...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: Valid state transitions only, Type safety maintained

**Output Files:**
- `src/generated/definitions/index.ts`
- `src/generated/definitions/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation

---

## IU-fc13fe2f: Phoenix Domain (CRITICAL)

**Description:** Implements phoenix functionality with 73 requirements

**Risk Tier:** critical (73 requirements)

**Canonical Requirements:**
- 00609785d534...
- 06aa548a95ba...
- 0700ec73627d...
- 072adb642700...
- 0858367659ab...
- 0a5f52d49dc9...
- 0e79502838e0...
- 1626593bf32a...
- 165234442479...
- 17c03e585de1...
- ... and 63 more

**Contract:**
- Inputs: on authcompleted message the app must update state pop auth screen set all region widgets visibletrue and focus input bar, textuals input widget does not accept a multiline parameter do not pass multilinetruefalse to input
- Outputs: on app mount the onmount method must call loadsavedcredentials and if it returns valid data immediately set sessionauthenticatedtrue and populate session with stored handle did nick webtoken, the app must call widgetrefresh or update reactive properties after auth completes to trigger widget rerendering with new data, buffersidebar must implement watchbuffers to rerender when buffers change, when authentication completes the app must explicitly call sidebarupdatebuffersappstatebuffers to force the sidebar to rerender with the newly populated channel list, messagelist must implement watchmessages or watch the active buffer to rerender when messages change, userlist must implement watchusers to rerender when users change
- Invariants: the main ui layout sidebar main content user list must be hidden during authentication only the auth screen visible

**Output Files:**
- `src/generated/phoenix/index.ts`
- `src/generated/phoenix/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note
- static_analysis
- human_signoff

---

## IU-0ad7d2ab: App Domain (LOW)

**Description:** Implements app functionality with 4 requirements

**Risk Tier:** low (4 requirements)

**Canonical Requirements:**
- 0abc32622c36...
- 9b72066f57ae...
- c0fe61db5295...
- cfdb499e317a...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: freeqapp must reduce logging overhead by logging poll events at debug level instead of info level only log important irc events message privmsg notice join part at info level this prevents io blocking that was causing ui to freeze

**Output Files:**
- `src/generated/app/index.ts`
- `src/generated/app/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation

---

## IU-c26aa3c4: Part Domain (LOW)

**Description:** Implements part functionality with 1 requirements

**Risk Tier:** low (1 requirements)

**Canonical Requirements:**
- 7aa13656a8ed...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: Valid state transitions only, Type safety maintained

**Output Files:**
- `src/generated/part/index.ts`
- `src/generated/part/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation

---

## IU-208c47be: Message Domain (HIGH)

**Description:** Implements message functionality with 7 requirements

**Risk Tier:** high (7 requirements)

**Canonical Requirements:**
- 008da2678933...
- 1a5715cdc962...
- 47d3c4b7a48d...
- 9f60fc3faf0a...
- aaf8574e45a0...
- ab42a071587a...
- fbf0cc734cb0...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: the implementation must call renderactivebuffer immediately after appending the optimistic message
- Invariants: Valid state transitions only, Type safety maintained

**Output Files:**
- `src/generated/message/index.ts`
- `src/generated/message/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note

---

## IU-046b9cd0: MessageWidget Domain (HIGH)

**Description:** Implements messagewidget functionality with 4 requirements

**Risk Tier:** high (4 requirements)

**Canonical Requirements:**
- 500f5a091880...
- b42b35145bcf...
- def7c33f03e6...
- f68d1a91aa39...

**Contract:**
- Inputs: messagewidget must use static widget for avatar with richtext styling instead of label with style parameter textuals label widget does not accept a style parameter use statictextchar stylefbold white on color classesavatar instead of labelchar stylefbackground color
- Outputs: messagewidget must not use method name rendercontent as it conflicts with textuals internal widget rendering method use formatmessagecontent instead to avoid typeerror messagewidgetrendercontent missing 1 required positional argument error, messagewidget must extend widget not static when using compose with containers static is for simple content via render method containers like horizontalvertical require the widget base class with compose pattern
- Invariants: messagewidget must not use method name rendercontent as it conflicts with textuals internal widget rendering method use formatmessagecontent instead to avoid typeerror messagewidgetrendercontent missing 1 required positional argument error

**Output Files:**
- `src/generated/messagewidget/index.ts`
- `src/generated/messagewidget/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note

---

## IU-a9659342: Layout Domain (HIGH)

**Description:** Implements layout functionality with 5 requirements

**Risk Tier:** high (5 requirements)

**Canonical Requirements:**
- 3488aa1d915d...
- 6bcd6b4bbcc9...
- cb18d3273fdb...
- dbd65556ee47...
- f75dd72e09bf...

**Contract:**
- Inputs: messagelist css height must be 1fr not 100 using height 100 causes messagelist to take all available space in vertical container pushing inputbar out of view using height 1fr allows messagelist to take remaining space while inputbar gets its natural height
- Outputs: Processed results, Side effects
- Invariants: messagelist must implement incremental message updates in refreshmessages instead of removechildren remounting all widgets which blocks ui for 16 seconds with 20 messages only add new message widgets that dont exist yet preserve existing widgets and only mount new ones

**Output Files:**
- `src/generated/layout/index.ts`
- `src/generated/layout/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note

---

## IU-ca271b2e: Sidebar Domain (HIGH)

**Description:** Implements sidebar functionality with 1 requirements

**Risk Tier:** high (1 requirements)

**Canonical Requirements:**
- 5df2a61256d4...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: buffersidebar must prevent double in channel names when displaying channel type buffers only add prefix if buffername does not already start with this prevents test when buffername is already test

**Output Files:**
- `src/generated/sidebar/index.ts`
- `src/generated/sidebar/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note

---

## IU-624d5dcb: AuthScreen Domain (CRITICAL)

**Description:** Implements authscreen functionality with 2 requirements

**Risk Tier:** critical (2 requirements)

**Canonical Requirements:**
- 4ecf2de3cc12...
- c60d2e47a38a...

**Contract:**
- Inputs: Configuration, Data inputs
- Outputs: Processed results, Side effects
- Invariants: authscreen must not show remember login checkbox credentials must always be saved automatically after successful authentication no checkbox needed this simplifies ux and reduces user confusion

**Output Files:**
- `src/generated/authscreen/index.ts`
- `src/generated/authscreen/__tests__/index.test.ts`

**Evidence Required:**
- typecheck
- lint
- boundary_validation
- unit_tests
- property_tests
- threat_note
- static_analysis
- human_signoff

---

## Coverage Summary

- Total canonical nodes: 102
- Covered: 102
- Orphans: 0
