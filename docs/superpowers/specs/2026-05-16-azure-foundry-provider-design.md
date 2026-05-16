# Azure AI Foundry Provider — Design

**Status:** draft
**Date:** 2026-05-16
**Owner:** rtkchahal (fork)

## Problem

CodexBar tracks limits for consumer / coding-plan AI providers (Anthropic OAuth,
ChatGPT/Codex OAuth, Cursor cookies, Copilot device flow, …). Many users — me
included — access Anthropic Claude and OpenAI GPT models via **Azure AI
Foundry** deployments inside a corporate tenant. None of the existing CodexBar
strategies see these tokens: they're API keys against
`<resource>.cognitiveservices.azure.com` / `<resource>.openai.azure.com`, not a
consumer OAuth session.

Goal: a first-class **Foundry** provider that surfaces usage / cost / rate-limit
information for one or more Azure AI Foundry deployments configured outside
CodexBar (today: OpenClaw's `~/.openclaw/agents/<agent>/agent/models.json`).

## Non-goals

- Replacing OpenClaw as the auth or routing layer — CodexBar **reads** the
  same config OpenClaw already manages; it never writes auth there.
- Supporting non-Azure OpenAI/Anthropic deployments (handled by existing
  CodexBar providers).
- Calculating granular per-request cost using Azure billing pricing tables.
  V1 surfaces token counts + monthly request counters; cost is a stretch
  goal gated by Azure Monitor / Cost Management access.
- Mutating Azure resources. Read-only by design.

## Constraints / context

- Azure AI Foundry deployments expose two relevant surfaces:
  1. **Data-plane** (the same endpoint inference traffic hits) — Azure does
     not expose a public quota/usage endpoint here. Throttling shows up as
     `429` with `x-ratelimit-*` response headers.
  2. **Management-plane** via Azure Monitor:
     `GET https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}/providers/Microsoft.Insights/metrics?api-version=2024-02-01`
     Metrics of interest: `TokenTransaction`, `ProcessedPromptTokens`,
     `GeneratedCompletionTokens`, `ProcessedInferenceTokens`, `AzureOpenAIRequests`.
     Auth: Azure AD bearer (`az account get-access-token --resource
     https://management.azure.com`).
- Each Foundry deployment in OpenClaw is a `provider/model` pair, e.g.
  `anthropic-foundry/claude-opus-4-7`, `pmi-openai/gpt-5.4-pro`,
  `kimi-foundry/Kimi-K2.6-1`. A single Azure resource can host many
  deployments; usage rolls up per deployment.
- Tokens currently visible to me (read from `models.json`):
  - `anthropic-foundry` (7 deployments)
  - `pmi-openai` (1)
  - `pmi-foundry-project` (1)
  - `kimi-foundry` (1)
- We must not log/transport secrets. Read keys from local files only on the
  user's Mac; never send them anywhere except the configured Azure endpoint.

## User stories

1. **Local-only user (V1, no Azure CLI)**: I see one card per Foundry
   *provider group* (anthropic-foundry, pmi-openai, …) summarising
   deployment count + last-known status from a lightweight probe (model
   list call against the resource). No cost data; "Monitor: not configured".
2. **Azure CLI user (V2)**: After running `az login`, the card adds today's
   token counts and a monthly window with a reset countdown at the start of
   next UTC month.
3. **OpenClaw user (everyone on my setup)**: CodexBar auto-discovers
   deployments from `~/.openclaw/agents/main/agent/models.json` and offers a
   one-click "Enable all Foundry deployments" toggle in Settings.
4. **Privacy-conscious user**: Can disable auto-discovery and enter a
   resource + endpoint + key manually per deployment.

## Architecture

### Module layout

`Sources/CodexBarCore/Providers/Foundry/`

- `FoundryProviderDescriptor.swift` — `@ProviderDescriptorRegistration` entry,
  metadata, branding (icon style `.foundry`, Azure blue), fetch plan with two
  ordered strategies (`FoundryMonitorStrategy` → `FoundryProbeStrategy`).
- `FoundryDeployment.swift` — Sendable struct: `id` (composite
  `<provider>/<deployment>`), `provider`, `deployment`, `endpoint`, `apiKey`
  reference (NOT the raw key — Keychain handle), `resourceId?`, `region?`.
- `FoundrySettingsReader.swift` — discovery + persistence:
  - Auto-discovery: parse `~/.openclaw/agents/*/agent/models.json` (and
    respect `OPENCLAW_AGENT_DIR` env override) → emit `FoundryDeployment`s.
  - Manual config: `~/.codexbar/config.json` → `foundry.deployments[]`.
- `FoundryProbeFetcher.swift` — lightweight `/openai/models?api-version=…`
  or `/v1/models` call (depending on provider flavour) to confirm the key
  works and capture `x-ratelimit-*` headers when present.
- `FoundryMonitorFetcher.swift` — Azure Monitor metrics call (V2). Reuses
  `BedrockAWSSigner`'s pattern of a small typed request signer (here: an
  AAD token from `az account get-access-token`).
- `FoundryUsageSnapshot.swift` — Sendable Codable result: tokensIn/out for
  current month, request count, throttle counts, status, source label
  (`"openclaw-models.json"`, `"manual"`, `"monitor"`).

### Fetch plan

```
FoundryFetchPipeline(resolveStrategies:) =>
  if Azure CLI present AND deployment.resourceId != nil:
    [ FoundryMonitorStrategy(), FoundryProbeStrategy() ]
  else:
    [ FoundryProbeStrategy() ]
```

- `FoundryProbeStrategy` is always available when there is at least one
  enabled deployment with an endpoint + key.
- `FoundryMonitorStrategy` is available only when `az` is on PATH and an
  ADC-style cached token can be obtained without prompting (mirrors
  CodexBar's existing Vertex AI strategy that shells out to `gcloud`).

### Settings UI (Preferences → Providers → Foundry)

- Header: "Azure AI Foundry"
- Discovery row: `[✓] Auto-discover deployments from OpenClaw
  (~/.openclaw/agents/*/models.json)` — default ON. Disabling reveals a
  manual add panel.
- Deployments list: each row = checkbox + provider tag + deployment id +
  endpoint host + source (`openclaw`/`manual`). Disabled rows still show but
  greyed out.
- Azure Monitor block:
  - Status: "Not configured" / "Authenticated as <upn>" / error.
  - Button: "Authenticate (runs `az login`)" — opens Terminal, doesn't pipe
    auth through CodexBar.
  - Toggle: "Use Azure Monitor for cost & token counts" (off by default,
    enabled when auth succeeds).

### Menu rendering

- One stacked card per *provider group*, similar to Kilo's org stacking.
- Card title: provider id (e.g. `anthropic-foundry`). Subtitle: "N
  deployments".
- Body:
  - When only probe data: "✓ N/N deployments reachable" + last refresh.
  - When monitor data: "Tokens (MTD): <prompt>+<completion>" and "Requests:
    <count>" + "Resets <countdown to month rollover>".
- Tooltip / submenu: list deployments with individual status badges.

### Reset windows

- Foundry quotas in Azure are **per-minute** (TPM/RPM) at the deployment
  level. We do not surface per-minute windows in V1 (too noisy). We surface
  **monthly** as the user-facing reset (matches billing cycle).

## Open questions

1. Anthropic-foundry endpoints — does Azure return AOAI-compatible
   `/openai/deployments/{name}/models` or a different shape? Needs probe.
2. Is `kimi-foundry` actually a Foundry-hosted Kimi or Azure Marketplace
   third-party? Affects whether Azure Monitor metrics apply.
3. Can we obtain `resourceId` from the endpoint hostname alone, or do we
   need an explicit user-supplied subscription/RG mapping? Likely the
   latter for V2.

## Risk register

| Risk | Mitigation |
| --- | --- |
| OpenClaw `models.json` schema changes | Treat parser as best-effort, fall back to empty list and surface "auto-discovery failed" inline. Pin to a defensive Codable shape. |
| Leaking corporate API key in logs | Never log the key. Settings UI shows last-4 only. Probe response bodies stripped of headers/cookies before debug log. |
| Azure Monitor throttling | Cap to one request per 5 min per resource; share a single `az` token across deployments in the same resource. |
| Maintaining fork against fast upstream | Keep the Foundry module fully isolated under one directory and one descriptor file so rebases stay cheap. |
