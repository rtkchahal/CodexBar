# Foundry Usage UI Rebuild — Design

**Status:** draft
**Date:** 2026-05-16
**Owner:** rtkchahal (fork)
**Phase:** 5 (post-V1)

## Problem

Phase 4 wires Foundry MTD totals into the existing `RateWindow.primary`
slot, which renders as a percent progress bar with a "Resets in Nd" label.
That UI primitive assumes a capped plan (Claude/Codex consumer tiers).
Foundry is consumption-billed: there is no monthly cap, so "100% left" is
nonsensical and the bar gives the wrong mental model.

Goal: replace the progress bar with a Foundry-shaped panel that shows raw
counters across daily / weekly / monthly windows, split by input vs output
and broken down by deployment.

## Non-goals

- Cost rendering. Azure Monitor doesn't expose $; would need Cost
  Management API (different RBAC). Park.
- Per-minute TPM/RPM windows. Too noisy for a menu bar tile.
- Replacing CodexBar's stock provider settings panel. The redesign lives
  in a custom Foundry card view; settings stay generic.

## Constraints / context

Azure Monitor metrics call already proven for our resource:

```
GET /providers/Microsoft.Insights/metrics
    ?metricnames=InputTokens,OutputTokens,ModelRequests
    &aggregation=Total
    &interval=P1D
    &timespan=<start>/<end>
    &$filter=ModelDeploymentName eq '*'
```

- The dimension filter `ModelDeploymentName eq '*'` returns one timeseries
  per active deployment in the window.
- `interval=P1D` returns daily buckets — enough for Today / Week / Month
  derivations.
- TotalTokens metric exists but we ignore it; sum `InputTokens +
  OutputTokens` for consistency.

CodexBar UI plumbing options:

1. Hijack `extraRateWindows: [NamedRateWindow]` — quickest, renders as a
   list of named percent bars. Still bar-shaped. Reject.
2. Custom Foundry card via the existing presentation hook
   (`ProviderImplementation.presentation`). Bedrock has a custom cost
   view; Claude has stacked token-account cards. Same path.

We'll go with (2).

## Architecture

### Data model

`FoundryDailyBucket`:
```swift
struct FoundryDailyBucket: Sendable, Codable {
    let date: Date              // start of UTC day
    let deployment: String      // ModelDeploymentName
    let inputTokens: Double
    let outputTokens: Double
    let modelRequests: Double
}
```

`FoundryUsageRollup` (computed on snapshot):
```swift
struct FoundryUsageRollup: Sendable, Codable {
    let today: FoundryWindowTotals
    let week: FoundryWindowTotals        // last 7 days incl. today
    let month: FoundryWindowTotals       // current calendar month MTD
    let perDeployment: [String: FoundryWindowTotals]  // MTD per model
    let monthResetAt: Date
    let updatedAt: Date
}

struct FoundryWindowTotals: Sendable, Codable {
    let inputTokens: Double
    let outputTokens: Double
    let modelRequests: Double
    var totalTokens: Double { inputTokens + outputTokens }
}
```

### Fetcher

- `FoundryMonitorFetcher.fetchReport` extended to call with
  `interval=P1D`, `$filter=ModelDeploymentName eq '*'`, capture
  `metadatavalues` per timeseries to identify the deployment.
- Returns `FoundryMonitorReport` carrying `[FoundryDailyBucket]` plus the
  same totals already exposed.
- Rollups computed in `FoundryUsageRollup.from(_:now:)`.

### Snapshot

`FoundryUsageSnapshot` gains:
- `rollup: FoundryUsageRollup?`
- `monitorReports` retained for backward compat / persistence.

`toUsageSnapshot()` no longer fakes a `RateWindow.primary` for MTD. The
identity line keeps the per-provider-group count summary; raw rollup data
is passed to a new custom card view.

### Custom Foundry card

New file: `Sources/CodexBar/Providers/Foundry/FoundryUsageCardView.swift`.
SwiftUI view rendered through the existing `ProviderImplementation`
presentation seam (mirrors `BedrockCostCardView` pattern).

Layout sketch (Preferences pane + status menu):

```
Azure AI Foundry                                   ↻
discovery · just now

State    Enabled
Source   monitor
Plan     anthropic-foundry: 6 · pmi-foundry-project: 1 · ...

Usage (month resets in 15d 1h)
                  Input        Output       Requests
Today           1,234,567       45,678          234
Week (7d)      14,800,000      380,000        1,820
Month MTD     291,141,032    6,820,418      16,744

Per model (MTD)
  claude-opus-4-7        120M In ·   2.1M Out · 4,200 req
  claude-sonnet-4-6      150M In ·   3.8M Out · 9,300 req
  gpt-5.5-1               18M In ·   780K Out · 2,800 req
  gpt-5.4-pro              3M In ·   140K Out · 444 req
```

Menu bar tile compressed line:
```
Foundry MTD 297M tk · 16.7K req
```

### Tests

- `FoundryUsageRollupTests` — fixture with 3 deployments × 8 days,
  assert today / week / month sums and per-deployment ordering.
- `FoundryMonitorFetcherTests` — extend with dimension-filter payload
  fixture, assert per-deployment bucket extraction.
- `FoundryUsageCardViewTests` — snapshot/render assertions where feasible.

## Open questions

1. How long does Foundry retain daily buckets? Azure Monitor default is
   93 days. 7d + MTD windows are well within; no concern.
2. anthropic-foundry probe noise: we still report `0/6 ok` because the
   probe URL doesn't fit Anthropic-on-Azure. Drop it from the card or
   replace with a benign `POST /messages` test? Park to a follow-up;
   probes are nice-to-have, MTD is the point.

## Risk register

| Risk | Mitigation |
| --- | --- |
| Dimension filter quota / rate-limited | Cache rollup for 5 min in `UsageStore`; refresh respects existing throttling. |
| Some deployments not emitting per-name metrics | Tolerate missing dimensions; surface as `"unknown"` deployment. |
| CodexBar custom views require touching `MenuDescriptor` plumbing | If too invasive, ship as Settings pane only first, status menu second. |
