# Safety Assistant candidate

Status: local source candidate for the R7.2 safety-assistance slice. This is a preflight and review aid, not an enforcement or emergency-access feature.

## Scope

The Safety Assistant is available from **Settings → Safety review**. It presents:

- a manual essentials checklist for Phone, Messages, Maps, password/authenticator, health/transit, and other owner needs;
- the saved restriction mode and an opaque selected-item count;
- actionable authorization, registration, allow-only, category, browser/website, and system/emergency coverage warnings; and
- a bounded, user-stopped test checklist for selected paths, browsers, categories, and system/emergency controls.

The test copy explicitly says not to place a call and not to infer an emergency-access or universal-enforcement guarantee. The assistant never applies, relaxes, or silently changes a policy, and it does not gate recovery or emergency reset.

## Privacy and versioning

Only `SafetyAssistantAcknowledgements` is persisted locally in the app's existing local defaults store. Its version and typed checklist/test-step acknowledgements contain no FamilyControls data, app names, bundle identifiers, URLs, messages, usage, tokens, network state, or account information. An unknown or corrupt acknowledgement record is discarded as review state only; policy and recovery state are untouched.

The pure audit model receives only `RuntimeMode`, `RuntimeSelectionSummary`, authorization state, and registration state. Selection summaries are not a substitute for enforcement verification. Category expansion, browser paths, and system/emergency paths remain device-specific checks.

## Acceptance boundary

This source candidate does not pass the R4/R7 product gates by itself. Device review must still cover VoiceOver, Dynamic Type, contrast, reduced motion, critical app/browser/system paths, and authorization/enforcement failures. A completed checklist is an acknowledgement that the owner reviewed the prompts, not evidence that Screen Time blocks every path.
