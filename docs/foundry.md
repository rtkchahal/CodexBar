# Azure AI Foundry

> Surfaces Azure AI Foundry deployment health and (optionally) month-to-date
> token usage in CodexBar's menu bar. Built for users who consume Claude /
> GPT / Kimi models through Azure AI Foundry instead of vendor consumer
> accounts.

## What it does

| Layer | Source | Surface in the menu |
| --- | --- | --- |
| Discovery | `~/.openclaw/agents/*/agent/models.json` | Per-provider-group deployment counts |
| Probe (optional) | `GET <baseURL>/{,openai/}models` | `N/N ok`, throttled/unauthorized hints, `x-ratelimit-*` headers |
| Azure Monitor (optional) | Azure Resource Manager metrics API via `az` | MTD prompt + completion tokens, request count, monthly reset |

## Auto-discovery

CodexBar parses every `models.json` it can reach and picks up provider keys
from the allow-list (`anthropic-foundry`, `pmi-openai`, `pmi-foundry-project`,
`kimi-foundry`, `azure-openai*`, `microsoft-foundry`). Generic
`anthropic`/`openai` consumer entries are deliberately ignored — they belong
to CodexBar's existing Claude/Codex providers.

You can override the discovery root with environment variables:

| Env var | Meaning |
| --- | --- |
| `OPENCLAW_AGENT_DIR` | Path to a single agent dir; CodexBar will look for `models.json` and `agent/models.json` underneath |
| `CODEXBAR_FOUNDRY_MODELS_JSON` | Explicit path to a `models.json` file |

If neither is set, CodexBar scans `~/.openclaw/agents/*/agent/models.json`.

## Probe (optional)

Set one env var per Foundry provider key to enable health probes:

```sh
export CODEXBAR_FOUNDRY_KEY_ANTHROPIC_FOUNDRY="<azure-key>"
export CODEXBAR_FOUNDRY_KEY_PMI_OPENAI="<azure-key>"
export CODEXBAR_FOUNDRY_KEY_KIMI_FOUNDRY="<azure-key>"
```

CodexBar:

- Sends both `api-key: <value>` and `Authorization: Bearer <value>` so it
  works against AOAI- and Anthropic-style Foundry deployments.
- Times out at 4s per probe, no retries.
- Maps `200 → ok`, `401/403 → unauthorized`, `404 → notFound`,
  `429 → throttled`, `5xx → serverError`, network timeouts → `network`,
  no key configured → `missingKey` (no network call).
- Captures `x-ratelimit-limit-requests`, `-limit-tokens`,
  `-remaining-requests`, `-remaining-tokens`, and reset hints
  (`x-ratelimit-reset-*` or `Retry-After`).

## Azure Monitor (optional)

For MTD token totals and a monthly reset countdown, expose each Cognitive
Services / AI Foundry resource id you want to monitor:

```sh
export CODEXBAR_FOUNDRY_RESOURCE_ANTHROPIC_FOUNDRY="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>"
export CODEXBAR_FOUNDRY_RESOURCE_PMI_OPENAI="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<name>"
```

Then run `az login` (Microsoft Azure CLI must be on PATH). CodexBar will
shell out to `az account get-access-token --resource https://management.azure.com`
to obtain a bearer token and call ARM:

```
GET /subscriptions/.../providers/Microsoft.Insights/metrics?
    api-version=2024-02-01&
    metricnames=ProcessedPromptTokens,GeneratedCompletionTokens,ProcessedInferenceTokens,AzureOpenAIRequests&
    aggregation=Total&
    timespan=<start-of-month>/<now>
```

The monthly reset is the first day of the next calendar month at 00:00 UTC.

CodexBar never writes Azure credentials to its config. Tokens live only in
the kernel-credential layer that `az` already manages.

## What's not in scope (yet)

- Per-deployment cost (needs Azure Cost Management which is a different
  permission set than Monitor)
- Per-minute TPM/RPM windows (Foundry's true quota granularity — too noisy
  for the menu bar in v1)
- Resource discovery from endpoint hostname (V1 requires an explicit
  resource id mapping)
- Settings UI: env-var only for the V1 fork; a Preferences panel is
  planned before upstream PR

## Troubleshooting

- "0 deployments discovered" → either `models.json` isn't where CodexBar
  expects, or every provider key in it is consumer-only. Set
  `CODEXBAR_FOUNDRY_MODELS_JSON` to point at the right file.
- "All probes return `missingKey`" → no `CODEXBAR_FOUNDRY_KEY_*` env vars
  are set. The discovery card will still render but with counts only.
- "Azure Monitor request failed (403): AuthorizationFailed" → the user
  signed in to `az` doesn't have `Microsoft.Insights/metrics/read` on the
  resource. Ask your Azure admin to grant `Monitoring Reader`.
- "Azure CLI (`az`) is not on PATH" → install from
  https://aka.ms/azcli or set the Monitor strategy aside (probe still
  works without `az`).
