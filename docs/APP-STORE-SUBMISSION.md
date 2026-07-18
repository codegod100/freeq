# App Store submission dossier (iOS)

Prepared 2026-07-05. Pairs with `DEVELOPER-ACCOUNT-TODO.md` (the signing /
provisioning half). This is the review-facing half: the guideline positions,
privacy declarations, and reviewer notes to paste into App Store Connect.

---

## Guideline 4.8 (Login Services) — position statement

**freeq does not use a third-party social login service.** Sign-in is the
AT Protocol's OAuth flow against the *user's own* identity provider (their
PDS — bsky.social or self-hosted). Key facts for review:

- AT Protocol identity is a **decentralized, user-owned identifier (DID)** —
  functionally analogous to Sign in with Apple's goals: the user controls the
  identity, can move it between providers, and no platform gatekeeps it.
- The login **does not collect email or personal data for advertising**; the
  broker exchanges OAuth tokens and never sees the password (App Passwords /
  OAuth only). No tracking of any kind (see privacy manifest:
  `NSPrivacyTracking = false`, zero tracking domains).
- **Guest mode is the no-account path**: anyone can use freeq without
  creating or linking any identity at all (Connect → "Continue as guest").
  This satisfies the "equivalent option without login" expectation.
- Login happens in an in-app `ASWebAuthenticationSession` sheet (no Safari
  bounce), scoped to the user's chosen provider.

If 4.8 is still raised: the fallback is adding Sign in with Apple mapped to a
guest+ profile, but the position above should stand — AT Proto OAuth is an
open standard, not a "third-party login service" in the 4.8 sense (it is the
app's *own* account system, federated).

## Guideline 1.2 (User-Generated Content) — compliance map

| Requirement | Implementation |
|---|---|
| Filter objectionable content | Server moderation (ops/kick/ban, moderation log); client hides content from blocked users |
| Report mechanism | Long-press any message → **Report…** (reason picker); profile → **Report**. Content hidden + author blocked immediately; report logged |
| Block mechanism | Message menu / profile → **Block** (DID-anchored, survives nick changes); Settings → Safety → **Blocked** to manage |
| Published contact | Settings → Safety → **Community Guidelines** + `abuse@freeq.at` |
| Terms consent | Onboarding footer: zero-tolerance agreement line |

## Privacy nutrition labels (App Store Connect answers)

Source of truth: `freeq-ios/freeq/PrivacyInfo.xcprivacy` (bundled manifest).

- **Data used to track you: none.**
- **Data linked to you** (all "App Functionality" only, no ads/analytics):
  - User ID (AT Protocol DID / handle / nickname)
  - Other User Content (messages, media, voice messages)
  - Audio Data (calls; transient relay)
- **Data not collected**: contacts, location, browsing, purchases, health,
  financial, identifiers-for-advertising — none touched.
- On-device only (never leaves the phone): Apple Intelligence summaries and
  smart replies (Foundation Models), voice-message transcription
  (`requiresOnDeviceRecognition = true`), Spotlight index.

## Export compliance (encryption)

- Uses standard encryption only (TLS; ed25519 signatures; optional E2EE for
  channels via passphrase). Answer **Yes** to "uses encryption", **exempt**
  under 5D992 mass-market / standard-crypto exemption; provide French
  declaration if distributing in France. No proprietary crypto.

## Reviewer notes (paste into App Store Connect)

> freeq is a decentralized chat app. Identity is optional: tap "Continue as
> guest" to use the app with no account. To test verified identity, sign in
> with any Bluesky account (OAuth in-app sheet; we never see the password).
> Safety: long-press any message → Report/Block; Settings → Safety for the
> blocked list, community guidelines, and abuse contact. Calls: join any
> channel → speaker icon. Apple Intelligence features (smart replies,
> catch-me-up summaries) run entirely on-device and appear only on
> AI-capable devices.

## Remaining pre-submission items (account-gated)

See `DEVELOPER-ACCOUNT-TODO.md`: TestFlight distribution cert, App Store
Connect record, screenshots (6.7" + 6.1"), app icon marketing sizes, age
rating questionnaire (expect 17+ or 12+ w/ moderated UGC), support URL.
