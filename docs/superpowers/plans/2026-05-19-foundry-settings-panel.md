# Foundry Settings Panel — Implementation Plan (Phase 7)

**Spec:** `docs/superpowers/specs/2026-05-19-foundry-settings-panel-design.md`
**Status:** in-progress
**Date:** 2026-05-19
**Owner:** rtkchahal (fork)
**Branch:** `feature/foundry-provider` (continues from Phase 6 `31aa72b9`)
**Build host:** Office Mac via SSH (`ssh office`), `~/projects/CodexBar`

## Overview

Add SwiftUI Settings pane for Foundry provider so API keys + ARM resource ids can be set without `launchctl setenv`. Three sub-phases, each ending with `swift test` green.

## Phase tracker

Legend: `[ ]` todo • `[~]` in progress • `[x]` done • `[!]` blocked

### Phase 7a — Storage + resolver (no UI yet)
- [ ] Add `Sources/CodexBar/Providers/Foundry/FoundrySettingsStore.swift` with per-provider-key accessors (apiKey, resourceID)
- [ ] Persist into existing `providerConfig(for: .foundry)` map under `providerKeys` dictionary
- [ ] Add `FoundryCredentialResolver` (settings → env → nil precedence)
- [ ] Wire `FoundryProbeFetchStrategy` + `FoundryMonitorFetchStrategy` to use resolver instead of reading env directly
- [ ] Tests: `FoundrySettingsStoreTests`, `FoundryCredentialResolverTests`
- [ ] `swift test` green (target: 75+ tests passing)
- [ ] Commit: `Phase 7a: persistent Foundry credentials + resolver (settings > env)`

### Phase 7b — Settings UI
- [ ] `FoundryProviderImplementation.settingsFields(context:)` emits dynamic descriptors per discovered provider key
- [ ] Empty-state descriptor when no deployments found
- [ ] Add discovery cache with 60s TTL invoked from `settingsFields`
- [ ] Screenshot of Settings → Azure AI Foundry pane (committed under `docs/screenshots/foundry-settings.png`)
- [ ] Manual smoke: open Settings pane, paste key + resource id for `pmi-foundry-project`, close, reopen, value persists
- [ ] Commit: `Phase 7b: dynamic Foundry settings descriptors + empty state`

### Phase 7c — Docs + polish
- [ ] Update `docs/foundry.md`: "env vars now optional; UI takes precedence"
- [ ] Update top-level README provider matrix (Foundry status: Settings UI ✅)
- [ ] Note `launchctl setenv` only needed for legacy env-var workflow
- [ ] Commit: `Phase 7c: Foundry docs — Settings UI is now first-class`
- [ ] Push branch, update PR description on `rtkchahal/CodexBar`

## Out of scope (deferred)

- Genericize `pmi-*` → `AzureOpenAIProvider` before upstream PR
- swiftformat / swiftlint pass
- Per-deployment overrides
- OAuth flow (replace `az` CLI)

## Verification

After each phase:
```
ssh office 'cd ~/projects/CodexBar && swift test 2>&1 | tail -20'
```

After 7b also:
```
ssh office 'cd ~/projects/CodexBar && swift build -c release 2>&1 | tail -10'
```

## Rollback

Phase 7a is additive (new types, resolver wraps existing reads). To revert: `git revert <phase-7a-sha>` — strategies fall back to env-only.
Phase 7b touches one method (`settingsFields`) — revert in isolation.
