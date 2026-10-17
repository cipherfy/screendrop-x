# Voice Bank

The app has no test target. The voice engine lives in its own Swift package, `Packages/VoiceKit`, and is checked two ways: package tests with known answers, and a bank of narration files with known problems compared against a committed baseline of their measurements.

```bash
scripts/voice-bank/generate.sh                    # build, measure, compare to baseline
scripts/voice-bank/generate.sh --update-baseline  # accept the current measurements
swift test -c release --package-path Packages/VoiceKit
```

A bank run takes a few seconds after the first build of the `voice-bank` tool. Everything it writes lives in `build/voice-bank/` (git-ignored); only `scripts/voice-bank/baseline.json` is committed. Run the bank before the tests: the tests that need narration read `build/voice-bank/variants` (or the folder in `VOICE_BANK`), and when it is missing they are skipped with a note saying so.

## Layout

| Path | What it holds |
|---|---|
| `Packages/VoiceKit/Sources/VoiceKit` | The engine, the only part the app links: `VoiceChain`, `VoiceMeasurement`, `VoiceProfile`, `RecordingAudioProcessing`, `RecordingVoiceAnalysis`, `RecordingVoiceIsolation`, `MicrophoneCheckAnalyzer` |
| `Packages/VoiceKit/Sources/VoiceKitTestSupport` | `AudioBench.swift`, shared by the tests and the tools: file reading and writing, movies written the way the recorder writes them, track reading, test signals, the chain run offline, the voice bank's location |
| `Packages/VoiceKit/Sources/VoiceBankTool` | The `voice-bank` tool behind `generate.sh` |
| `Packages/VoiceKit/Sources/RenderVoiceAB` | The `render-voice-ab` tool |
| `Packages/VoiceKit/Tests/VoiceKitTests` | One suite per area, below; `VoiceChainPresets.swift` holds the fixed Neutral and USB Condenser chains the tests use |

The package builds with the app's concurrency settings (Swift 5 mode, approachable concurrency). `swift test` without `-c release` passes too, but runs the DSP unoptimized and takes over ten minutes instead of about half a minute.

## What it builds

The bank synthesizes `scripts/voice-bank/script-es.txt`, a short Spanish tutorial narration, with the macOS voices Paulina, Mónica, and Eddy, normalizes each take to -26 LUFS (a typical raw level), and derives these variants with a fixed random seed, so runs are reproducible:

| Variant | Simulates |
|---|---|
| `clean` | The take as synthesized |
| `noisy` | Pink noise at -58 dBFS RMS (fans, preamp hiss) |
| `hum` | 60 Hz mains hum with harmonics at -66 dBFS |
| `keyboard` | Typing bursts: key clicks plus desk thumps |
| `room` | A small untreated room, about 0.45 s RT60 |
| `harsh` | +6 dB at 5 kHz, the presence peak of a USB condenser |
| `thin` | -7 dB low shelf at 250 Hz, a mic too far away |
| `boomy` | +8 dB low shelf at 160 Hz, proximity effect |
| `quiet` | -18 dB, low gain staging |
| `hot` | +16 dB, clipped at full scale |
| `usb-condenser-desk` | harsh + room + keyboard + noise + hum |
| `usb-condenser-desk-aac96` | The same, through AAC at 96 kbps, as Screendrop captures today |

Limits: synthetic voices are not a microphone. Paulina and Mónica reach about 11 kHz and Eddy about 8 kHz, so the `brilliance` and `air` bands say little about the voices themselves. Eddy is kept because it is the only low male voice installed by default.

## Your own recordings

Files in `voice-bank-local/` (git-ignored) are measured on every run and reported separately, but never enter the baseline. Nothing leaves the Mac.

## Measurements

`VoiceMeasurement.swift` in VoiceKit is the app's own meter; the tool links the same package:

- **Loudness** per ITU-R BS.1770-4 / EBU R128: integrated (gated), momentary and short-term maximum, and loudness range (EBU Tech 3342). Mono files read about 3 LU lower than the same signal as dual-mono stereo.
- **True peak** by 4x polyphase oversampling, plus sample peak.
- **Speech level and noise floor**: 95th and 10th percentiles of 50 ms RMS blocks. Their difference is the SNR, left blank when pauses are digital silence.
- **Clipping**: samples in runs of three or more at full scale.
- **Spectral balance** over speech frames only: energy per octave in voice bands (`rumble` 20-80 Hz, `body` 80-160, `warmth` 160-300, `mud` 300-600, `boxy` 600-1.2k, `clarity` 1.2-2.5k, `presence` 2.5-5k, `sibilance` 5-8k, `brilliance` 8-12k, `air` 12-20k), relative to the 100 Hz-10 kHz average.

Validated against EBU Tech 3341 (1 kHz at -23 dBFS stereo reads -23.0 LUFS), an fs/4 inter-sample test (true peak within 0.1 dB of theory), and ffmpeg's `ebur128` filter on the bank (integrated loudness and LRA match).

The tool also runs on its own:

```bash
build/voice-bank/bin/voice-bank analyze file.wav [--json out.json]
build/voice-bank/bin/voice-bank compare baseline.json current.json
build/voice-bank/bin/voice-bank degrade clean.wav out-dir [--lufs -26]
build/voice-bank/bin/voice-bank tone <sine-1k|intersample> out.wav
```

## Comparing

The JSON, and so the baseline, keeps each file's summary numbers and voice bands rounded to 0.01 dB; the third-octave spectrum is measured but not stored. `compare` reports per file any change beyond tolerance (0.5 LU integrated, 1 LU range, 0.5 dB true peak, 1 dB noise floor, SNR, or any voice band) and exits non-zero when a file newly exceeds -1 dBTP or clips more than before.

## Microphone capture check

Screendrop records the microphone track as 24-bit mono LPCM at 48 kHz (system audio stays AAC). `MicrophoneCaptureTests` writes a bank file the way the recorder does, with both the current and the previous AAC 96 kbps settings, and reads it back through Studio's paths: the mono-track rule transcription uses, the per-track processing mix behind playback and export, and the M4A export the speech transcriber reads.

```bash
swift test -c release --package-path Packages/VoiceKit --filter MicrophoneCaptureTests
```

The lossless track is bit-identical to its source; AAC at 96 kbps deviated by -42 dB on the same take. The cost is size: about 9.7 MB per minute with system audio, against 1.8 MB before (video not included).

## Audio processing check

Every audio track gets its own processing tap (`RecordingAudioProcessing.swift`): the mono narration track (or an imported replacement) and the stereo system track carry separate gains in dB, a look-ahead peak limiter at -1 dBFS replaces the old hard clip at full scale, and the exporters limit the summed mix as well. `AudioProcessingTests` renders a two-track recording the way the exporters do and checks:

- track roles, and migration of the old single 0-200% volume to both gains;
- that 0 dB renders the exact sum of the tracks, and -60 dB system audio is muted;
- that voice gain moves only the voice (+6 dB reads +6.00 LU);
- that at +24 dB the peak holds at -1 dBFS with voice processing on or off;
- that a +12 dB change mid-render glides without a click and lands at +12 dB.

```bash
swift test -c release --package-path Packages/VoiceKit --filter AudioProcessingTests
```

Latency: every tap delays its track by the same 184 frames at 48 kHz (3.8 ms: 40 for the voice chain's oversampling, 144 for the limiter's look-ahead), so voice and system audio stay aligned. Exports add the mix limiter's 3 ms, so exported audio lands about 7 ms after the picture, well below what can be perceived. Stages that need more look-ahead should share this budget rather than add to it.

## Voice chain check

`VoiceChain.swift` is the narration channel strip, run inside the voice track's tap in this order: input trim, high-pass (12 or 24 dB/oct), five EQ bands, a dynamic low band against proximity boom, a 2:1 downward expander for the room between words, a feed-forward soft-knee compressor, a split-band de-esser, and saturation at 4x oversampling with a warmth control for even harmonics. The fader and a true-peak limiter at -1 dBTP follow. Turning Voice Processing off plays the dry voice matched to the processed loudness, with the same latency, so an A/B compares sound rather than level. Neutral and USB Condenser chains remain as fixed test cases for this check, defined in the tests; the app resolves its chain from a voice profile.

`VoiceChainTests` checks each stage against signals with known answers and reports what the preset does to the bank's USB-condenser takes:

| Check | Result |
|---|---|
| Flat chain | Bit-transparent; delay, oversampler, and bypass all land at 40 frames |
| High-pass an octave below the corner | -12.3 dB (12 dB/oct), -24.1 dB (24 dB/oct), as Butterworth theory gives |
| EQ bell, shelf, cut | +5.99, +3.94, -2.73 dB for +6, +4, -3 settings |
| Compressor 3:1 at -24 dB | -6 dBFS in, -18.0 out; -30 in, -30.0 out |
| Expander 2:1 at -45 dB, 8 dB range | -50 in, -54.9 out; -70 in, -77.7 out |
| De-esser and dynamic low band | Full range on loud bands, nothing on others |
| Aliasing, 9 kHz driven 12 dB | -91 dB with 4x oversampling, -13 dB without |
| Saturation passband | Within 0.00 dB from 1 to 18 kHz (a 161-tap Kaiser kernel; the first, 49-tap kernel took 9 dB off 10 kHz and dulled every voice with saturation on) |
| Limiter on inter-sample peaks | -1.16 dBTP with true-peak detection, +1.52 dBTP sample-based |
| A/B loudness | Within 0.03 LU |
| Speed | About 50x real time on one core with saturation on |

```bash
swift test -c release --package-path Packages/VoiceKit --filter VoiceChainTests
```

Compressor, expander, and de-esser thresholds are absolute, so they assume a typical raw narration level (around -26 LUFS). Input trim exists so loudness analysis can bring every take to that level first.

## Voice isolation check

Voice isolation (`RecordingVoiceIsolation.swift`) runs Apple's on-device AUSoundIsolation, high-quality model, over the narration track. It is too heavy for a playback tap, so it is rendered once, offline, into the project package (`voice-isolated-hq-v1-<amount>.caf`, 32-bit float mono), and playback and every export read a composition of the master with the narration track swapped for the render. The master is never modified, the voice chain still runs on the isolated track, and exports render a missing file on demand. An imported replacement soundtrack is not isolated. Amounts are 75%, 90%, and 100%: the blend is linear, so 75% lowers the room by about 12 dB and 90% by about 20 dB.

Two details matter for alignment. The unit's reported latency (4440 frames at 48 kHz) is measured and dropped from the render. And the unit pulls input ahead of the output it is asked for, so the renderer keeps two 4096-frame blocks queued in the player beyond what it renders; without that the player pads with silence and the narration comes out 4096 frames late.

`VoiceIsolationTests` builds a project package around a noisy narration and checks the render is aligned to the frame with the master's narration, how much it removes, partial amounts, the track swap, on-demand rendering for exports, and that a cancelled render leaves nothing behind:

```bash
swift test -c release --package-path Packages/VoiceKit --filter VoiceIsolationTests
```

On the bank's USB-condenser-at-a-desk take, full isolation took SNR from 23.4 to 45.6 dB and the noise floor from -43.8 to -66.6 dBFS, kept loudness within 0.7 LU, and ran at about 80x real time.

## Voice profile check

A voice profile (`VoiceProfile.swift`) is what the inspector asks for: a character (Clear, or Broadcast, which matches toward its own target curve averaged from two reference narrations, at 85% instead of 70%), how strongly to apply it, and a loudness target (-14 LUFS by default, where video platforms normalize, or -16 LUFS for spoken word). Match EQ is on by default; its switch lives in the channel strip. Projects start with voice isolation at 75%. `VoiceProfileResolver` turns the profile and an analysis of the take into the chain:

- **Input trim** brings the take to -26 LUFS, the level the chain's thresholds are written for.
- **Base corrections** for every voice (80 Hz high-pass, proximity control, de-esser, a gentle expander) apply in full, whatever the microphone. Mud and harshness are left to match EQ, which measures them.
- **Character** EQ, compression, and saturation scale with intensity. The body band sits just above the voice's fundamental, found by autocorrelation pitch tracking (the spectrum cannot find it: the first formant outweighs the fundamental).
- **Match EQ** pulls the long-term balance toward a target curve with six octave bells, at 70% of the measured difference, limited to -6 / +4.5 dB, and leaves alone bands with no content to speak of.
- **Loudness**: the voice gain that lands chain, fader, and true-peak limiter on the target, refined until what the limiter takes off is added back.

`RecordingVoiceAnalysis.swift` does the measuring offline on the narration the project plays (the isolation render when isolation is on): all of it up to three minutes, or six 30-second stretches spread from start to end of a longer recording. That keeps analysis and loudness matching near two seconds at any length (in a Release build; Debug runs the DSP 20-30x slower), and on a deliberately uneven 10- and 30-minute recording the sampled gain landed the whole recording within 0.25 LU of target. The analysis is saved in the project. The last profile used with each microphone is remembered; a microphone never seen before starts on the defaults.

The target curve is the average of the bank's clean studio voices, a starting point. Rebuild it from narration you like and paste the output into `VoiceTargetCurve`:

```bash
build/voice-bank/bin/voice-bank target reference-1.wav reference-2.wav
```

`VoiceProfileTests` checks profile resolution, pitch tracking, that match EQ answers a known coloration and moves every bank take closer to the target, and that normalization lands within 0.3 LU of -16 and -14 LUFS (0.15 LU in practice) at no more than -0.9 dBTP across 20 take, character, and target combinations. It then runs the whole pipeline on the USB-condenser takes:

| Take | LUFS | True peak | SNR | Distance to target |
|---|---|---|---|---|
| Paulina raw | -25.5 | -11.8 | 21.8 | 2.5 dB |
| Paulina, Broadcast | -14.1 | -1.1 | 26.8 | 1.6 dB |
| Mónica raw | -25.2 | -11.1 | 17.6 | 3.9 dB |
| Mónica, Clear | -14.1 | -1.1 | 22.5 | 2.8 dB |
| Eddy raw | -25.1 | -7.6 | 27.0 | 5.7 dB |
| Eddy, Clear | -14.1 | -1.1 | 32.5 | 5.4 dB |

(At the defaults: isolation 75%, match EQ, intensity 60%, -14 LUFS. At 90% isolation and -16 LUFS the same takes gained 8-15 dB of SNR instead of 4-6: less room gets through, and less gain lifts it. Eddy stops near 8 kHz, so match EQ leaves its top alone and its distance barely moves.)

```bash
swift test -c release --package-path Packages/VoiceKit --filter VoiceProfileTests
```

## Voice tools check

Studio's audio inspector shows what the voice chain is doing while the project plays:

- **Meters** (`Screendrop/VoiceMetersView.swift`, in the app): input and output peak with a 20 dB/s fall, gain reduction for the expander, compressor, de-esser, and limiter, and short-term loudness (EBU R128, 3 s) against the profile's target. The voice tap publishes after every buffer through atomics (`RecordingAudioMeters`); the view samples at 30 Hz and goes quiet when playback stops.
- **Channel strip** (`Screendrop/VoiceChannelStripView.swift`, in the app): every stage of the chain by hand, with the static EQ's response curve computed from the coefficients the chain runs. The first edit makes the chain custom (the profile's mic, character, intensity, and match controls pause; the loudness target keeps working); Reset to Profile hands control back.
- **Microphone check** (Check Microphone… in the recording bar's microphone menu): 2.5 s of room, then 6 s of reading a line, through the same AVCapture path the recorder uses. It reports level (peaks should sit between -12 and -6 dBFS), clipping, room noise, voice-to-noise distance, and mains hum, with plain advice. Nothing is written to disk.

`VoiceToolsTests` checks the curve against the chain's measured response (they agree to 0.000 dB from 60 Hz to 12 kHz), the live loudness meter against the offline one (-23.00 vs -23.00 LUFS), the gain reduction the chain reports, the custom chain, and the microphone check's advice for seven takes with known problems (good, quiet, clipping, hot, noisy room, hum, muted).

```bash
swift test -c release --package-path Packages/VoiceKit --filter VoiceToolsTests
```

## Comparing characters by ear

`render-voice-ab`, an executable in the package, renders a narration (a project package or any audio file) through Clear, Broadcast, and Broadcast as it was before being rebuilt from references, each at -14 LUFS through the true-peak limiter, with 75% isolation for a project. It writes WAVs only; the project is read, never changed.

```bash
swift run -c release --package-path Packages/VoiceKit render-voice-ab path/to/recording.screendroprec path/to/output
```
