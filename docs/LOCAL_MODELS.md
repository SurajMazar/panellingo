# Local models

Everything below runs on your Mac. After the one-time downloads, no internet connection is needed.

## Apple Translation (built in)

- Uses the system Translation framework. Background translation needs **macOS 26**.
- Language pairs must be downloaded once: **Settings › Local Models › Apple Translation language packs › Download…** shows the system prompt. Alternatively, use System Settings › General › Language & Region › Translation Languages.
- Bubbles are translated one at a time (no dialogue context), and glossary spellings are applied afterwards. For natural dialogue with context, use a local LLM.
- If a pair isn't installed or isn't supported, the translate stage fails with a clear message and earlier results are kept.

## Ollama (recommended local LLM)

1. Install from <https://ollama.com> and launch it. The server listens on `http://localhost:11434`.
2. In **Settings › Local Models**, type a model name and click **Download** (progress is shown), or run `ollama pull <model>`.
3. Choose **Ollama** as the provider in the project inspector, then pick the model.

Suggested models:

| Model | Disk | RAM needed | Notes |
|---|---|---|---|
| `qwen3-vl:8b-instruct` | ~6 GB | ~8–10 GB | Good JA/KO/ZH→EN dialogue; vision-capable (AI Vision OCR) |
| `qwen3-vl:4b-instruct` | ~3 GB | ~5 GB | For 8 GB Macs; vision-capable |
| `qwen2.5:7b` / `llama3.1:8b` | ~4–5 GB | ~8 GB | Text-only translation |

PanelLingo sends a JSON schema via Ollama's `format` field, so responses come back as structured JSON. Local models process one page at a time by default (**Settings › Processing**).

The sample page in the README was translated with `qwen3-vl:8b-instruct` in about 50 seconds on an M-series Mac with 16 GB of memory, covering detection, OCR, translation, cleanup and typesetting.

## LM Studio

Start the local server in LM Studio (Developer tab, default `http://localhost:1234/v1`), load a model, then pick **LM Studio** in PanelLingo and use **Test Connection** to list models. Structured output uses `response_format: json_schema`.

## Custom OpenAI-compatible servers

llama.cpp `server`, vLLM, LocalAI and similar servers work through **Custom OpenAI-compatible**. A `localhost` endpoint counts as local, so it still works in Local-only mode.

## AI Vision OCR

Set **OCR** to *AI Vision model* in the project inspector to read crops with the project's provider model. You need a vision model such as `qwen3-vl`. This helps with handwritten or stylised lettering and with scripts Apple Vision doesn't read (for example Hindi and Nepali). With a cloud provider it requires *Allow sending images*.

## Neural inpainting

No neural inpainting model is bundled, because of size and licensing. *Quality* cleanup mode currently uses diffusion inpainting and says so in the region's cleanup status. The `CoreMLInpainter` hook expects a model at `~/Library/Application Support/PanelLingo/Models/Inpainting.mlmodelc`, but that integration is not finished.

## MLX

In-process MLX Swift inference is not implemented. Ollama and LM Studio both run MLX/GGUF models efficiently on Apple Silicon.
