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

## IU-d17053e0: Phoenix Domain (CRITICAL)

**Description:** Implements phoenix functionality with 69 requirements

**Risk Tier:** critical (69 requirements)

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
- ... and 59 more

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

## Coverage Summary

- Total canonical nodes: 74
- Covered: 74
- Orphans: 0
