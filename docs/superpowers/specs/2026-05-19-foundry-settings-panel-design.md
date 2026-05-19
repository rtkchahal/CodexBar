# Azure AI Foundry — Settings Panel Design (Phase 7)

**Status:** draft
**Date:** 2026-05-19
**Owner:** rtkchahal (fork)
**Predecessor:** `2026-05-16-azure-foundry-provider-design.md`, Phases 0–6 shipped on `feature/foundry-provider`

## Problem

Foundry provider works end-to-end, but configuration is **env-var only**:

- `CODEXBAR_FOUNDRY_KEY_<PROVIDER>` — API key per provider (probe strategy)
- `CODEXBAR_FOUNDRY_RESOURCE_<PROVIDER>` — ARM resource id (monitor strategy)

In the menu-bar app context this is painful:

1. GUI apps don't inherit shell env. User must run `launchctl setenv …` then relaunch — documented but unfriendly.
2. Settings → Foundry pane is **blank** (Settings click feels broken). `FoundryProviderImplementation.settingsFields()` returns `[]`.
3. No way to discover which provider keys CodexBar found without checking logs.

Other providers (OpenRouter, ElevenLabs, Moonshot) already use `SettingsStore` + `ProviderSettingsFieldDescriptor` for keys persisted in `~/.codexbar/config.json`. Foundry should match.

## Goals

- Settings → Azure AI Foundry pane renders **per-discovered-provider** rows:
  - secret field for API key
  - text field for ARM resource id
  - status badge showing which strategy is active (monitor / probe / discovery-only)
- Persisted values take precedence over env vars but env vars remain a valid fallback (zero break for current setup).
- Refresh button re-runs discovery so new OpenClaw `models.json` entries surface without app restart.

## Non-goals

- OAuth / interactive `az login` flow (still rely on existing `az` CLI token).
- Per-deployment manual overrides (only per-provider-key config in this phase).
- Upstream PR to `steipete/CodexBar` (still pmi-* references; that's a separate cleanup).

## Design

### Settings storage

Add a Foundry section to `SettingsStore` via a new `FoundrySettingsStore.swift` (mirrors `OpenRouterSettingsStore.swift`).

```swift
extension SettingsStore {
    func foundryAPIKey(forProviderKey key: String) -> String { … }
    func setFoundryAPIKey(_ value: String, forProviderKey key: String) { … }
    func foundryResourceID(forProviderKey key: String) -> String { … }
    func setFoundryResourceID(_ value: String, forProviderKey key: String) { … }
}
```

Backing data is keyed by provider key (e.g. `pmi-foundry-project`) in the existing `providerConfig` map under `.foundry`, using new nested fields:

```jsonc
{
  "foundry": {
    "providerKeys": {
      "pmi-foundry-project": { "apiKey": "…", "resourceID": "/subscriptions/…" },
      "anthropic-foundry":   { "apiKey": "…", "resourceID": "/subscriptions/…" }
    }
  }
}
```

### Reader precedence

`FoundrySettingsReader` and the two fetch strategies already read env vars. Add a thin wrapper:

```swift
enum FoundryCredentialResolver {
    static func apiKey(for providerKey: String, settings: SettingsStore, environment: [String: String]) -> String?
    static func resourceID(for providerKey: String, settings: SettingsStore, environment: [String: String]) -> String?
}
```

Precedence: `SettingsStore` non-empty value → env var → nil. Strategies switch to call the resolver; **no behavioural change** when settings are empty.

### UI

`FoundryProviderImplementation.settingsFields(context:)` builds descriptors dynamically from discovered deployments:

1. Run `FoundrySettingsReader.discoverDeployments(environment:)` → unique provider keys
2. For each provider key, emit:
   - `ProviderSettingsFieldDescriptor(id: "foundry-key-<providerKey>", kind: .secure, …)`
   - `ProviderSettingsFieldDescriptor(id: "foundry-resource-<providerKey>", kind: .plain, placeholder: "/subscriptions/…/providers/Microsoft.CognitiveServices/accounts/…")`
3. Empty-state row when discovery returns nothing: "No Foundry deployments discovered. Configure OpenClaw or set `CODEXBAR_FOUNDRY_KEY_*` env vars."

Status badge per row uses `isVisible:` + `subtitle:` to indicate active strategy after the next refresh tick (rendered text, no live binding — keep this lean).

## Tests

- `FoundrySettingsStoreTests` — round-trip get/set for both fields across multiple provider keys; isolation between keys.
- `FoundryCredentialResolverTests` — precedence (settings > env > nil), empty-string treated as nil.
- `FoundryProviderImplementationTests` (new file) — descriptor generation for 0, 1, N discovered keys; secure vs plain field kind.

## Migration

Zero-migration: missing `providerKeys` map = empty config; existing env-var workflow continues. New `pre-1.0` config field, no version bump.

## Rollout

- Phase 7a: storage + resolver + tests (no UI change, no behavioural change)
- Phase 7b: settings UI + empty state + screenshot
- Phase 7c: README + `docs/foundry.md` updates ("env vars optional now")

## Risks

- **`ProviderSettingsContext` binding to dynamic keys.** Need to confirm `context.stringBinding(\.foo)` style works with computed accessors. Fallback: per-provider-key extension generated at runtime via a wrapper that exposes a `Binding<String>` directly.
- **Discovery race.** Settings pane opens before discovery has run → empty list. Mitigation: kick a discovery refresh from `settingsFields` if cache is older than 60s.
