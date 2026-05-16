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
- [ ] Smoke build: `swift build` clean from a fresh checkout
- [ ] Smoke test: `swift test` baseline green before any code change

### Phase 1 — Static descriptor + auto-discovery (no network)
- [ ] Add `ProviderID.foundry` (find enum + extend with branding tokens)
- [ ] Create `Sources/CodexBarCore/Providers/Foundry/` skeleton
  - [ ] `FoundryDeployment.swift`
  - [ ] `FoundrySettingsReader.swift` (parse `models.json`, parse manual
        config, merge + de-dup)
  - [ ] `FoundryProviderDescriptor.swift` (registration, metadata, branding,
        empty fetch pipeline returning an "auto-discovered" snapshot)
  - [ ] `FoundryUsageSnapshot.swift`
- [ ] Add provider icon asset `ProviderIcon-foundry` (Azure-blue mark)
- [ ] Wire toggle into Settings (no Azure Monitor section yet)
- [ ] Tests:
  - [ ] `FoundrySettingsReaderTests` — fixtures with the real
        `models.json` shape captured from
        `~/.openclaw/agents/main/agent/models.json` (redact keys)
  - [ ] `FoundryProviderDescriptorTests` — descriptor identity + default
        disabled
- [ ] `make check` + `swift test`
- [ ] Manual smoke: launch app, confirm Foundry tile shows "N
      deployments discovered (no usage data yet)"

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

- **Last touched:** Phase 0 → ready to start Phase 1
- **Next action:** baseline `swift build` + `swift test`, then scaffold
  `Sources/CodexBarCore/Providers/Foundry/` and capture a redacted fixture
  of `~/.openclaw/agents/main/agent/models.json` for parser tests.

## Risks / blockers (running list)

- Need to confirm Anthropic-foundry endpoint shape exposes a
  `models`-style listing. If not, probe falls back to a benign
  health-check (e.g. completions with `max_tokens=1`). Decide in Phase 2.
- Azure Monitor metric names differ subtly between AOAI and "Azure AI
  Foundry" (newer) resources; resolve when we have a sample token from
  `az` in Phase 3.
