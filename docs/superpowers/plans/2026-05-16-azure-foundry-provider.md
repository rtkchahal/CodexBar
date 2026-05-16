# Azure AI Foundry Provider — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-05-16-azure-foundry-provider-design.md`
**Status:** in-progress
**Date:** 2026-05-16
**Owner:** rtkchahal (fork)

## Overview

Add a new `foundry` provider to CodexBar that surfaces Azure AI Foundry
deployment usage. Ship in three phases. Each phase ends with `make check` +
`swift test` green and a screenshot of the bar UI.

## Phase tracker

Legend: `[ ]` todo • `[~]` in progress • `[x]` done • `[!]` blocked

### Phase 0 — Fork bootstrap & repo intel
- [x] Fork `steipete/CodexBar` → `rtkchahal/CodexBar`
- [x] Clone to `~/projects/CodexBar`, add `upstream` remote
- [x] Branch `feature/foundry-provider`
- [x] Read `AGENTS.md`, `docs/superpowers/specs/*`, `Bedrock` provider as
      reference
- [x] Write spec (this PR's `docs/superpowers/specs/2026-05-16-…`)
- [x] Write plan (this file)
- [x] Office Mac dev environment ready (Xcode 26.2, Swift 6.2.3)
- [x] Smoke build: `swift build` clean (105s baseline)
- [x] Smoke test: `swift test` baseline green (48 tests)

### Phase 1 — Static descriptor + auto-discovery (no network) ✅
- [x] Add `UsageProvider.foundry` + `IconStyle.foundry`
- [x] Create `Sources/CodexBarCore/Providers/Foundry/` skeleton
  - [x] `FoundryDeployment.swift`
  - [x] `FoundrySettingsReader.swift` (parses real OpenClaw `models.json`
        with provider-key allow-list)
  - [x] `FoundryProviderDescriptor.swift` (registered, branded Azure blue)
  - [x] `FoundryUsageSnapshot.swift`
  - [x] `FoundryProviderImplementation.swift` (app-layer stub)
- [x] Add provider icon asset `ProviderIcon-foundry` (placeholder: Bedrock
      copy until real Azure-blue mark)
- [x] Extend all exhaustive `UsageProvider` switches (CostUsageScanner,
      UsageStore debug dict, widget views)
- [x] Tests: `FoundrySettingsReaderTests` (5 tests, includes parse +
      snapshot + malformed JSON cases)
- [x] `swift build` + `swift test` green (53/53 passing)
- [ ] Manual smoke: launch app, confirm Foundry tile shows discovered
      deployments (deferred — needs UI session on office Mac)

### Phase 2 — Probe strategy (per-deployment health) ✅
- [x] `FoundryProbeFetcher.swift` — GET against `/v1/models` or
      `/openai/models?api-version=...` depending on URL shape
- [x] `FoundryProbeFetchStrategy` conforming to `ProviderFetchStrategy`,
      registered before `FoundryDiscoveryFetchStrategy` so it wins when
      keys are configured but falls back gracefully
- [x] Per-deployment status (ok / unauthorized / notFound / throttled /
      serverError / network / missingKey) aggregated in snapshot
- [x] Defensive: 4s timeout, no retries, both `api-key` and `Authorization:
      Bearer` headers, never log raw key
- [x] Tests: `FoundryProbeFetcherTests` (8 cases incl. 200 w/ rate-limit
      headers, 401/403/404/429/500/503 mapping, network timeout, header
      assertions)
- [x] `swift build` + `swift test` green (61/61 passing)
- [ ] Manual smoke: tile shows `N/N ok` for anthropic-foundry (deferred —
      needs UI session + real API key in env)

### Phase 3 — Azure Monitor strategy (V2) ✅ (engine done; UI deferred)
- [x] Detect `az` CLI on PATH via injectable `azPath` runtime
- [x] `FoundryMonitorFetcher` — ARM metrics REST API client with
      ProcessedPromptTokens / GeneratedCompletionTokens /
      ProcessedInferenceTokens / AzureOpenAIRequests aggregations
- [x] `runAZForToken()` shells out to `az account get-access-token` only in
      production runtime; tests use injected stub token
- [x] `monthWindow` returns ISO calendar-month start, current end, and
      next-month reset for the menu countdown
- [x] Tests: `FoundryMonitorFetcherTests` (7 cases: window math, URL build,
      payload parse + multi-timeseries sum, success path with header check,
      missing-az, 403 request failure, empty resource id)
- [x] `swift build` + `swift test` green (68/68 passing)
- [ ] Wire Monitor strategy into descriptor pipeline (gated on resource id
      config; currently the fetcher is standalone and ready)
- [ ] Settings UI: Azure Monitor section (status, auth button, toggle)
- [ ] Persist resource mapping in `~/.codexbar/config.json`

### Phase 4 — Polish, docs, contribution prep
- [ ] `docs/foundry.md` — user-facing setup doc (mirrors `docs/bedrock.md`)
- [ ] README provider list + screenshots refreshed
- [ ] Run `swiftformat Sources Tests` + `swiftlint --strict`
- [ ] Open PR on fork → squashed commits, screenshots, test output
- [ ] Decide upstream PR: extract `PMI-*` names into config-driven
      "AzureOpenAIProvider" generic form before proposing upstream

## Work log

- 2026-05-16 11:30 IST — Fork created (`rtkchahal/CodexBar`), branch
  `feature/foundry-provider`. Repo cloned. Spec + plan committed below.

## Status checkpoints (auto-update each session)

- **Last touched:** 2026-05-16 — Phase 1 done
- **Next action:** Phase 2 (probe strategy). Pick a deployment per
  provider-key family, call `GET <baseURL>/models` (or AOAI equivalent),
  capture `x-ratelimit-*` headers, surface per-deployment status badges.
- **Open question:** anthropic-foundry endpoint — does
  `https://<resource>.services.ai.azure.com/v1/models` return a usable
  list? If not, fall back to a 1-token completion probe.

## Risks / blockers (running list)

- Need to confirm Anthropic-foundry endpoint shape exposes a
  `models`-style listing. If not, probe falls back to a benign
  health-check (e.g. completions with `max_tokens=1`). Decide in Phase 2.
- Azure Monitor metric names differ subtly between AOAI and "Azure AI
  Foundry" (newer) resources; resolve when we have a sample token from
  `az` in Phase 3.
