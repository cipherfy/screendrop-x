# Recording Studio export performance

Studio draws the screen with Metal and overlaps GPU work with Core Graphics overlays. Export Options offers independent **30 / 60 fps** and **Motion blur** controls. Defaults remain **60 fps with blur enabled**, preserving the existing viewport geometry, one-frame shutter, adaptive 1–24 sample count, and running-average sample weights.

## Frame rate and motion blur

`RecordingExportTiming` supplies the actual output clock, frame count, and shutter samples to `RecordingStudioExporter`; the encoder's expected-frame-rate hint uses the same value. Writer timestamps use integer frame ticks to avoid floating-point conversion jitter. A one-minute export produces 1,800 frames at 30 fps or 3,600 at 60 fps. Duration, clip speed, audio timing, output resolution, and bitrate selection are independent of this choice. Capture and interactive Studio preview remain at their existing cadence.

- **Blur enabled:** the shutter spans one output frame, about 16.7 ms at 60 fps or 33.3 ms at 30 fps. The existing adaptive sampler can therefore choose more samples per moving frame at 30 fps. The Metal/Core Graphics selection policy remains the same.
- **Blur disabled:** the screen is drawn once at the exact output frame time, without shutter sampling. Zooms, pans, cursor effects, camera, and captions continue to animate at the selected output rate. This does not remove motion blur already baked into source footage.

Both choices are stored in the project's export settings, inherited by Share and on-demand Library rendering, and remembered for new recordings after confirmation. Missing settings fields decode as 60 fps and blur enabled. Equality treats omitted and explicit defaults identically, so old render stamps remain valid when the rendered settings are unchanged. A different frame rate or blur choice invalidates cached deliverables, including the container-only reuse path.

30 fps halves output-frame submissions, not every stage of the export. Source decoding, audio processing, and file delivery still do work; speedups for these options require measurement on representative recordings. With the existing bitrate policy, 30 fps does not inherently halve the file size.

## Rendering policy

- Settled and motion-blurred frames use Metal with the original shutter rectangles. The same spatial reconstruction filter applies throughout a move.
- An extreme size discontinuity within one shutter uses Core Graphics when the shared reduction texture cannot keep every sample's reconstruction footprint within its limit.
- When the decoded source buffer and viewport rectangle repeat, subsequent frames can reuse those exact screen/backdrop pixels. When all displayed overlays also match, the entire composed buffer can be reused without a copy.
- If Metal initialization, buffer mapping, geometry validation, or rendering fails, the export continues through Core Graphics. A GPU failure disables further GPU attempts for that export.

`StudioMotionBlur.metal` combines the shutter samples in one compute pass, using cubic reconstruction for magnification and scale-aware Lanczos reconstruction for reduction. For large reductions, one Metal Performance Shaders Lanczos prepass bounds the filter footprint while retaining up to twice the required resolution. The cached backdrop and rounded-card mask use the same Core Graphics drawing paths as the original compositor.

Reader and writer buffers are Metal-compatible IOSurfaces. GPU completion precedes the CPU lock, after which the existing pointer, press effects, camera, keystroke, subtitle, and karaoke rendering runs unchanged. Core Video texture wrappers remain alive until the command buffer completes, as required by [Apple's texture-cache documentation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)). The next frame's screen and settled-camera passes start before the previous frame receives its overlays and goes to the encoder. Resources belong to one compositor/export: two settled layouts, two alternating morph renderers, and a camera output pool limited to three buffers per scaler. Per-frame temporary objects drain inside autorelease pools.

Metal and Core Graphics spatial filtering are **not pixel-identical**. Keeping temporal sampling unchanged preserves the blur algorithm, but representative moving footage still needs visual comparison, especially small text during reductions and the transition between settled and moving frames.

## Settled screen reuse

Sparse screen recordings often hold one decoded frame for several output ticks. `StudioScreenLayerCache` retains one byte-exact snapshot of the settled screen and backdrop, taken **before** drawing the cursor, press effects, camera, keystrokes, subtitles, or karaoke. Changing overlays still render on every output tick at the selected 30 or 60 fps. A different source buffer, viewport rectangle, output size, or a motion-blurred frame prevents screen-layer reuse.

The exporter only takes a snapshot when the next tick can reuse it. This avoids an extra copy on continuously changing footage and moving viewports. Snapshots have a hard **64 MiB** limit; larger canvases render normally. The cache also retains its decoded source buffer to prevent a recycled buffer from producing a false hit. Both belong to the current export and are released with the compositor. This optimization does not alter filtering, blur samples, frame rate, or encoding settings; its complete-export speedup has not yet been measured on representative recordings.

## Quality-preserving reuse and overlap (October 13, 2026)

Screendrop uses the reuse and overlap principles within its native pipeline:

- **Composed-frame reuse:** `StudioComposedFrameCache` retains one immutable output buffer. Reuse requires exact equality of the screen/camera buffer identities, actual layout and viewport geometry, pointer and press state, keystroke animation, speed badge, subtitle text, and karaoke word state. Only settled, single-screen-sample frames qualify. A repeated frame avoids allocation, screen copying, and all overlay drawing. Every timestamp is still submitted to the encoder at the selected 30/60 fps; this does not introduce variable-frame-rate output.
- **Prefilter reuse during pans:** a renderer keeps its existing reduced source texture when the source buffer and reduction dimensions match. Translation and shutter reconstruction still run for each frame. The same Lanczos prefilter is used; a source or size change regenerates it. Queue ordering protects a prefilter still in flight, and retaining its source prevents decoder-pool recycling from causing a false match.
- **Settled-camera overlap:** camera Lanczos scaling starts with the screen pass instead of blocking inside overlay drawing. Submissions retain separate pooled outputs until completion. Consecutive ticks sharing a camera frame share its submission; clipping, borders, shadows, and fallback drawing stay the same. The pending frame retains its layout resources across eviction from the two-layout cache.

These changes leave resolution, cadence, sampling, reconstruction shaders, bitrate, codec settings, audio, and border drawing unchanged.

Measured on an Apple M4 Pro with optimized standalone code and synthetic images, 24 timed iterations after three warmup iterations:

| Operation | Before | After |
| --- | ---: | ---: |
| Repeated 8K source → 1080p screen pass during a pan | 6.395 ms | 1.894 ms (3.38×) |
| Repeated 4K screen snapshot copy vs composed-buffer lookup | 0.509 ms | 0.000084 ms |

The second row times only the copy and cache lookup; it excludes state evaluation and overlay drawing. These are **stage measurements**, not complete-export speedups. The camera overlap has not been timed on a complete export. Decoding, changing source content, timeline evaluation, encoding, audio, and file finalization can limit the overall gain.

The standalone regression benchmark compares pre-change and current screen/camera pixels exactly, including reduction-size/source invalidation and multiple in-flight shutter/camera passes. It checks the camera pool bound, frame-cache invalidation, and H.264/HEVC encoding of the same immutable buffer at all 60 timestamps with one-second output duration. It does not launch Screendrop or read user recordings.

Reproduce from the repository root, using the pre-change commit as the baseline:

```bash
mkdir -p /tmp/screendrop-export-baseline
git show 4eb4a4fa:Screendrop/StudioMetalScreenRenderer.swift | sed 's/StudioMetalScreenRenderer/BaselineMetalScreenRenderer/g' > /tmp/screendrop-export-baseline/BaselineMetalScreenRenderer.swift
git show 4eb4a4fa:Screendrop/StudioCameraBubbleScaler.swift | sed 's/StudioCameraBubbleScaler/BaselineCameraBubbleScaler/g' > /tmp/screendrop-export-baseline/BaselineCameraBubbleScaler.swift
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/StudioMetalScreenRenderer.swift Screendrop/StudioScreenLayerCache.swift \
  Screendrop/StudioComposedFrameCache.swift Screendrop/StudioCameraBubbleScaler.swift \
  /tmp/screendrop-export-baseline/BaselineMetalScreenRenderer.swift \
  /tmp/screendrop-export-baseline/BaselineCameraBubbleScaler.swift \
  scripts/benchmark-studio-export-reuse.swift -o /tmp/screendrop-export-reuse-benchmark
/tmp/screendrop-export-reuse-benchmark
```

## Camera cutout (October 14, 2026)

The Cutout layout segments the person from the camera with Vision's `VNGeneratePersonSegmentationRequest` at **balanced** quality, and `studioCutoutCamera` composites the camera through that matte for both the preview and the export. Measured on an Apple M4 Pro with a 1920×1080, 30 fps camera:

| Quality | Matte | Per frame |
| --- | ---: | ---: |
| fast | 256×192 | 2.7 ms |
| balanced | 512×384 | 8.3 ms |
| accurate | 2016×1512 | 30 ms |

Accurate's finer matte only matters when a cutout is drawn taller than about 768 pixels. The kernel tightens balanced's soft edge (smoothstep 0.45–0.85) at the drawn size, which removes the room-coloured fringe. Vision runs its model on the Neural Engine but scales its input on the GPU. Handing it a frame already 384 rows tall (decoder-scaled for exports, vImage-scaled for the preview, 0.7 ms) cuts a frame from about 12.9 ms to 7.5–8.2 ms. The resulting matte is within 0.5/255 of the full-size one.

During an export, Vision slows to about 11 ms a frame, because it competes with the screen pass for the GPU. A single stateful sequence is then the bottleneck: two parallel streams only reach 138 fps against 117, and they lose frame-to-frame matte coherence. Studio therefore segments the whole camera once in the background, as soon as a cutout appears on the timeline. It writes the mattes as the luma of a small HEVC movie (`camera-matte-v1.mov`, full-range 4:2:0 at quality 0.75), stamped with each camera frame's time. This is about 1.3 MB per minute of camera. Read back, the mattes average 0.06/255 off the originals, and their tightened alpha differs by 0.0001. The cache steps aside while an export or share runs and is valid only when it's newer than `camera.mov`. Without it, exports segment live on a second, decoder-scaled read of the camera. That read runs ahead of the frames being drawn and segments only the frames that will be shown cut out.

The 51-second sample recording, exported at 1080p, 60 fps, with motion blur (Debug build), is 41 seconds Cutout and 10 seconds corner camera:

| Export | Seconds |
| --- | ---: |
| Corner camera only (baseline) | 12.6 |
| Cutout, segmenting live | 17.4 |
| Cutout, reading the matte cache | 13.4 |

Building the cache took 12.5 s (about 123 fps) and produced 1.2 MB. Exports from the cache and from live segmentation average 0.14/255 apart. To reproduce, run the Debug binary with `-benchmarkMatteCache <path to .screendroprec>`, then `-benchmarkExport` on the same package. Delete `camera-matte-v1.mov` to time the live path. The log's `cutoutWaitSeconds` is the time finishing frames spent waiting for mattes.

## Measured blur-pass timings

Measured on an Apple M4 Pro, September 5, 2026. Synthetic zoom/pan, rounded clipping, text, one-pixel lines, and colored edges; **24 shutter samples**, four timed iterations after setup/warmup. Times include GPU completion and any reduction prepass.

| Source → output | Core Graphics | Metal | Blur-pass speedup |
| --- | ---: | ---: | ---: |
| 1920×1080 → 1920×1080 | 273.17 ms | 8.03 ms | 34.02× |
| 3840×2160 → 1920×1080 | 265.97 ms | 20.45 ms | 13.00× |
| 7680×4320 → 1920×1080 | 365.05 ms | 36.83 ms | 9.91× |
| 3840×2160 → 3840×2160 | 1087.57 ms | 16.67 ms | 65.24× |

These are **not complete-export speedups**. The harness excludes source decoding, pipeline creation, timeline evaluation, overlays, encoding, audio, and final file delivery. The CPU reference also reuses a prepared source CGImage. Codec throughput, the fraction of frames with blur, and fallback frames limit the overall improvement.

## Standalone check

From the repository root, with Xcode selected and access to the Mac's GPU:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/StudioMetalScreenRenderer.swift \
  Screendrop/StudioScreenLayerCache.swift \
  scripts/benchmark-studio-motion-blur.swift \
  -o /tmp/screendrop-motion-blur-benchmark-bin

/tmp/screendrop-motion-blur-benchmark-bin
```

The harness compiles the actual shader source, exercises 2/8/24-sample cases at 1080p and 4K with 1×/2×/4× input sizes, and reports Core Graphics fallback cases separately. For accelerated fixtures it asserts RGB mean absolute error below 4/255 and PSNR above 31 dB against the original compositor's screen pass. These are regression checks, not a perceptual-quality guarantee. PNG pairs are saved under `/tmp/screendrop-motion-blur-benchmark` for inspection.

It also writes and decodes six frames each through H.264 and HEVC, exercising the writer's pixel-buffer pool, GPU rendering, a settled Core Graphics frame, screen-layer reuse, a moving CPU-drawn overlay, and a Metal-compatible reader. It checks that the overlay survives in the correct position, does not remain at its old position, and that invalid rectangles are rejected. Use `--encode-only` to rerun just these integration checks. The harness does not launch Screendrop or access user recordings. The [editor resource checks](editor-performance.md#standalone-checks) additionally verify byte-identical screen reuse, overlay isolation, and the snapshot budget.

## Compare complete exports

For the frame-rate/blur options, compare the same saved recording in all four combinations: 30/off, 30/on, 60/off, and 60/on, keeping resolution, quality, and codec fixed. Check smoothness, blur trails, captions, clip boundaries, and audio synchronization in the resulting files; the interactive preview does not simulate the export's blur or frame-rate selection.

In **Edit Scheme → Run → Arguments → Environment Variables**, set:

| Variable | Value | Purpose |
| --- | --- | --- |
| `SCREENDROP_EXPORT_BYPASS_CACHE` | `1` | Render on every Export/Share instead of reusing the session's flattened deliverable. |
| `SCREENDROP_EXPORT_RENDERER` | `cpu` | Force the original Core Graphics renderer for a baseline. Unset for automatic Metal selection. |
| `SCREENDROP_EXPORT_BYPASS_SCREEN_CACHE` | `1` | Disable settled screen-layer reuse while retaining the selected renderer. |
| `SCREENDROP_EXPORT_BYPASS_FRAME_CACHE` | `1` | Disable immutable composed-frame reuse; still render every output timestamp. |

Run the same recording, edits, codec, resolution, and quality once with the CPU override and once without it, keeping deliverable cache bypass enabled for both. To isolate screen-layer reuse, keep the renderer setting unchanged, bypass the composed-frame cache for both runs, and toggle only `SCREENDROP_EXPORT_BYPASS_SCREEN_CACHE`. To reproduce the original Core Graphics rendering path, set the CPU override and both frame/screen cache bypasses. To isolate composed-frame reuse, keep all other settings fixed and toggle `SCREENDROP_EXPORT_BYPASS_FRAME_CACHE`. Keep baseline exports under separate filenames. Remove the overrides after measuring so normal render reuse resumes.

Filter the Xcode console or Console.app by `StudioExport`. The log reports:

- `frames` and `Metal blur frames`: how much of the export actually used the accelerated path.
- `fps` and `motionBlur`: the selected output cadence and shutter-sampling policy.
- `reusedScreenFrames`: output ticks that reused settled screen/backdrop pixels; overlays still rendered.
- `reusedComposedFrames`: output ticks that submitted the exact same immutable composed pixels without drawing again.
- `renderSeconds`: cumulative screen composition plus existing overlays, including first-use GPU setup.
- `metalSeconds`: time submitting GPU screen passes and any completion wait the CPU could not overlap.
- `decodeSeconds`: blocking screen-reader calls; camera decoding is not included in this counter.
- `writerWaitSeconds`: time waiting for the encoder input to accept a frame. Encoding also proceeds concurrently, so this is not total encoding time.
- `totalSeconds`: successful exporter duration including preparation, decoding, rendering, audio work, and writer finalization. It excludes the subsequent save/copy to the user's destination or cloud upload.

Compare zooms and pans, small text, rounded edges, crops/reframing, camera placement, cursor effects, subtitles, audio synchronization, and cancellation on representative projects. A successful build and the isolated checks do not establish complete-export performance or visual parity on those projects.

## Frame-rate and blur option checks

This standalone harness uses the production settings decoder and timing/sampling policy. It checks legacy settings, all four option combinations, cached-settings equality, the unchanged 60 fps shutter samples on analytical fixtures, and blur-off's single sample. It also writes and decodes synthetic H.264 and HEVC movies to verify frame counts, timestamps, nominal frame rates, and one-second playback duration. It does not launch Screendrop, exercise the complete Studio composition, or claim end-to-end export performance.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -O -swift-version 6 -strict-concurrency=complete -default-isolation MainActor \
  -module-cache-path /tmp/screendrop-metal-module-cache -parse-as-library \
  Screendrop/VideoCompressionModels.swift Screendrop/RecordingExportTiming.swift \
  scripts/check-recording-export-options.swift -o /tmp/screendrop-export-options-check
/tmp/screendrop-export-options-check
```
