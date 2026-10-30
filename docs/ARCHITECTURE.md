# Architecture

PanelLingo keeps all processing in a UI-independent library (`PanelLingoKit`). The SwiftUI/AppKit app (`PanelLingo`) and the command-line tool (`panellingo-cli`) are thin layers on top of it.

```
Sources/
├── PanelLingoKit/
│   ├── Core/
│   │   ├── Models/          ComicPage, TextRegion, OCRResult, TranslationRecord, TextStyle, ProjectSettings…
│   │   ├── Geometry/        PixelRect/PixelPoint (source-pixel, top-left), Vision/CG conversion, polygons
│   │   ├── ImageProcessing/ GrayImage, BitMask (morphology, hole filling, contours), ComponentLabels, RGBAImage
│   │   ├── Persistence/     ProjectStore (.panellingo package), PageHistory (undo)
│   │   ├── Networking/      HTTPClient (error mapping, redaction), KeychainStore
│   │   └── Utilities/       errors, natural sort, hashing, atomic IO, AsyncLimiter, RateLimiter
│   ├── Import/              ComicImportService (images, PDF, CBZ/ZIP, CBR, folders, clipboard)
│   ├── Detection/           PanelDetector, BubbleDetector, VisionTextDetector, RegionAssembler, ReadingOrder
│   ├── OCR/                 VisionOCRProvider (+ VerticalReflow), AIVisionOCRProvider
│   ├── Translation/         TranslationCore (prompt, schema, validation), LLM/DeepL/Apple providers,
│   │                        TranslationEngine (privacy, chunking, retries, fallback), Glossary IO, OllamaManager
│   ├── Cleanup/             TextMaskBuilder, Inpainting (flat, diffusion, Core ML hook), CleanupService
│   ├── Typesetting/         CoreTextLayoutEngine (shape-aware auto-fit), PageRenderer, presets
│   ├── Export/              ComicExportService (PNG/JPEG/PDF/CBZ/JSON/Markdown/package)
│   ├── Pipeline/            PipelineEngine (stage orchestration), BatchQueue
│   └── Sample/              SampleComic (procedurally drawn original fixtures)
├── PanelLingo/              SwiftUI app: AppState, Workspace, Canvas, Inspector, Settings, Onboarding…
└── panellingo-cli/          headless pipeline
```

## Replaceable components

| Protocol | Default implementation |
|---|---|
| `TextDetectionProvider` | `HybridTextDetector` (Vision + bubble analysis + panels) |
| `OCRProvider` | `VisionOCRProvider`, `AIVisionOCRProvider` |
| `TranslationProvider` | `AppleTranslationProvider`, `LLMTranslationProvider` (Ollama, LM Studio, OpenAI, Anthropic, Gemini, OpenRouter, custom), `DeepLTranslationProvider` |
| `InpaintingProvider` | `FlatFillInpainter`, `DiffusionInpainter`, `CoreMLInpainter` (unavailable until a model is installed) |
| `TextRenderingService` | `CoreTextLayoutEngine` |
| `ComicImportService` / `ComicExportService` | `DefaultComicImportService` / `DefaultComicExportService` |

`PipelineEngine` accepts an injected detector, OCR override and translation-provider factory. The tests use this to run the real pipeline with a deterministic translator.

## Pipeline

```
Import → decode (EXIF-normalised) → Panel detection → Text/bubble detection → Reading order
      → OCR (+ language identification, spurious-region filter) → Contextual translation
      → Text mask → Inpainting → Auto-fit layout → Render → Review → Export
```

- Each stage reads typed inputs from the `ComicPage`, writes only its own outputs, and records itself in `completedStages`. The page is saved atomically after every stage.
- Stages never overwrite data a person owns: `correctedText` (OCR correction), `translationLocked` (approved or edited translation), `cleanup.manualMask`, and `locked` or `isManual` regions.
- `PipelineRequest` selects stages, regions and whether to force a re-run. Editing a translation only re-runs layout, never OCR or cleanup.
- Errors are tagged with their stage (`StageError`). Retrying resumes from the failed stage.
- Detection runs at full resolution up to `maxWorkingPixels` (40 MP by default); beyond that it works on a scaled copy and maps every rect back to source pixels. Cleanup and rendering always run at full resolution.

## Detection details

1. **Panels**: recursive X–Y cuts along blank gutters, alternating horizontal and vertical splits. Splits are ordered for the reading direction, so the panel order is the reading order.
2. **Bubbles**: label bright connected components (≥ 200 grey), fill their holes, and treat the holes as candidate glyphs. Each candidate is scored on glyph count, size consistency, darkness and position, and nested duplicates are removed.
3. **Vision lines**: `VNRecognizeTextRequest` (accurate). Very tall webtoon images are split into overlapping tiles.
4. **Assembly**: Vision lines inside a bubble's shape belong to that bubble. The rest are grouped into paragraph blocks (free text or SFX). Regions are deduplicated, keeping enclosing bubbles over inner blocks.
5. **Reading order**: assign each region to the panel it overlaps most, order the panels, then read in bands within each panel (top band first; right-to-left for manga).

## Library layout

```
<library folder>/                 (Settings › General › Project location; default ~/Documents/PanelLingo)
  <Series>/
    series.json                   SeriesInfo: name, alternate names, summary, translation defaults,
                                  story context, series glossary, related series [(id, kind, shareGlossary)]
    <chapter>.panellingo          one project per chapter
  <chapter>.panellingo            unsorted chapter
```

`SeriesLibrary` scans this layout, creates and renames series, moves chapters, and keeps relations two-way (`kind.inverse` is stored on the other series). When translating, the glossary is the chapter's entries first, then the series', then those of related series that share theirs. The series story context and the list of related series are prepended to the chapter's context.

## Data model and project format

Coordinates are always **source-image pixels with a top-left origin**. View transforms live only in the canvas: the canvas content is laid out at image pixel size inside a magnifying `NSScrollView`, so overlay coordinates equal image coordinates.

```
MyComic.panellingo/              (UTType app.panellingo.project, a package)
  manifest.json   formatVersion, title, ordered pageIDs, app version
  settings.json   languages, direction, provider/model, tone, honorifics, context, cleanup, default style
  glossary.json
  originals/<page>.<ext>         exact imported bytes (EXIF-rotated images normalised to PNG once)
  pages/<page>.json              ComicPage: panels, regions (OCR, translation, style, cleanup, layout, review)
  masks/<page>/<region>.png      8-bit lettering mask covering cleanup.maskRect
  cleaned/<page>/<region>.png    cleaned RGBA patch for the same rect
  previews/<page>.jpg            thumbnail of the translated page
```

When rendering, the original is drawn first. Each cleaned patch is then drawn **clipped to its mask**, so pixels outside the masks are never written. The integration test checks this pixel by pixel. Translated lettering is drawn only where the source text was removed (or as an outlined overlay for SFX and text on artwork), so a skipped cleanup never produces text drawn on top of text.

Undo stores whole previous `ComicPage` values (and the bytes of mask and patch files for mask edits) on the window's `UndoManager`.

## Concurrency and memory

- The pipeline is `async` and runs off the main actor. UI state (`AppState`) is `@MainActor @Observable`.
- `BatchQueue` is an actor with a bounded number of workers (default 2 for cloud or Apple, 1 for local LLMs).
- `ProjectStore` keeps at most three full-resolution originals decoded in an LRU cache. Thumbnails come from ImageIO.
