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

### Phase 2 — Probe strategy (per-deployment health)
- [ ] `FoundryProbeFetcher.swift` — `GET <endpoint>/openai/models` or
      `/v1/models` (provider-flavour switch), parse `x-ratelimit-*`
- [ ] `FoundryProbeStrategy` conforming to `ProviderFetchStrategy`
- [ ] Per-deployment status aggregation in snapshot
- [ ] Defensive: short timeout (4s), no retries, never log raw key
- [ ] Tests:
  - [ ] `FoundryProbeFetcherTests` with `URLProtocol`-stubbed fixtures
        for AOAI 200 / 401 / 429 / network error cases
- [ ] `make check` + `swift test`
- [ ] Manual smoke: tile shows `7/7 reachable` for anthropic-foundry

### Phase 3 — Azure Monitor strategy (V2, behind feature flag)
- [ ] Detect `az` CLI on PATH
- [ ] `FoundryMonitorFetcher` — shell out to
      `az account get-access-token --resource https://management.azure.com`,
      call metrics REST API
- [ ] Settings UI: Azure Monitor section (status, auth button, toggle)
- [ ] Persist resource mapping in `~/.codexbar/config.json`
- [ ] Tests:
  - [ ] `FoundryMonitorFetcherTests` with stubbed token + stubbed metrics
        JSON
- [ ] `make check` + `swift test`
- [ ] Manual smoke: tile shows MTD tokens + monthly reset

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
