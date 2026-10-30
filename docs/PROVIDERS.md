# AI providers

Configure providers in **Settings › AI Providers**. API keys are stored in the macOS Keychain (service `app.panellingo.providers`). They are never written to projects, exports or logs. For scripting, `panellingo-cli` also reads `PANELLINGO_<PROVIDER>_KEY`, for example `PANELLINGO_OPENAI_KEY`.

**Test Connection** lists the models available and checks the endpoint, key and model.

| Provider | Endpoint (default) | Wire format | Structured output | Images |
|---|---|---|---|---|
| Apple Translation | on-device | `TranslationSession` (macOS 26+) | n/a (per-bubble) | – |
| Ollama | `http://localhost:11434` | `/api/chat` | JSON schema via `format` | yes (vision models) |
| LM Studio | `http://localhost:1234/v1` | OpenAI chat completions | `json_schema` | yes (vision models) |
| OpenAI | `https://api.openai.com/v1` | chat completions | `json_schema` (strict) | yes |
| Anthropic | `https://api.anthropic.com` | `/v1/messages` | prompt contract + validation | yes |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | `generateContent` | `responseMimeType: application/json` | yes |
| OpenRouter | `https://openrouter.ai/api/v1` | OpenAI chat completions | prompt contract + validation | model-dependent |
| Custom | any URL | OpenAI chat completions | prompt contract + validation | model-dependent |
| DeepL | `api-free.deepl.com` / `api.deepl.com` (chosen from the key) | `/v2/translate` with `context` | n/a | – |

Remote endpoints must use HTTPS. Plain HTTP is accepted only for `localhost`, `127.0.0.1`, `::1` and `*.local`.

## What is sent

For LLM providers, a translation request contains:

- the system prompt (in `TranslationCore.swift`)
- source and target languages, tone and honorific policy, your custom instructions and story context
- the glossary entries relevant to the page, plus all character names
- the previous page's dialogue and the other dialogue on this page, as context
- the regions to translate, as `{region_id, type, text}` in reading order
- **only if** *Settings › Privacy › Allow sending images* and *Send page image as translation context* are both on: a JPEG of the page, at most 1536 px on its longest side

Apple Translation and DeepL get just the dialogue strings (DeepL also receives nearby dialogue as `context`). For non-LLM providers, glossary spellings are applied after translation.

## Validation

Every LLM response is parsed as `{"translations":[{"region_id", "original_text", "translated_text", "confidence", "review_required", "notes"}]}`:

- Responses with unknown or duplicated IDs, or empty translations, are rejected.
- Missing IDs are requested again, with the translations already received sent as context.
- Malformed JSON, timeouts, rate limits (honouring `Retry-After`) and 5xx errors are retried with exponential backoff (*Retries* setting).
- `review_required` and low self-reported confidence flag the region for review. Model confidence is shown separately from OCR confidence and is not treated as a probability.

## Limits and costs

Per provider you can set: request timeout, retry count, requests per minute, and maximum characters per request (larger pages are split into several requests). The first time in a session that a cloud provider would receive content, PanelLingo shows which provider it is, roughly how many characters will be sent, and whether images are included.

## Fallback

**Settings › AI Providers › Fallback** (copied into new projects) picks a second provider to use when the primary fails for a reason other than privacy settings or cancellation.
