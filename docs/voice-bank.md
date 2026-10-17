# Voice Bank

Screendrop has no test target, so voice processing is checked against a bank of narration files with known problems and a committed baseline of their measurements.

```bash
scripts/voice-bank/generate.sh                    # build, measure, compare to baseline
scripts/voice-bank/generate.sh --update-baseline  # accept the current measurements
```

A run takes a few seconds. Everything it writes lives in `build/voice-bank/` (git-ignored); only `scripts/voice-bank/baseline.json` is committed.

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

`Screendrop/VoiceMeasurement.swift` is the app's own meter, compiled into the tool unchanged:

- **Loudness** per ITU-R BS.1770-4 / EBU R128: integrated (gated), momentary and short-term maximum, and loudness range (EBU Tech 3342). Mono files read about 3 LU lower than the same signal as dual-mono stereo.
- **True peak** by 4x polyphase oversampling, plus sample peak.
- **Speech level and noise floor**: 95th and 10th percentiles of 50 ms RMS blocks. Their difference is the SNR, left blank when pauses are digital silence.
- **Clipping**: samples in runs of three or more at full scale.
- **Spectral balance** over speech frames only: energy per octave in voice bands (`rumble` 20-80 Hz, `body` 80-160, `warmth` 160-300, `mud` 300-600, `boxy` 600-1.2k, `clarity` 1.2-2.5k, `presence` 2.5-5k, `sibilance` 5-8k, `brilliance` 8-12k, `air` 12-20k), relative to the 100 Hz-10 kHz average. The JSON also carries a third-octave spectrum.

Validated against EBU Tech 3341 (1 kHz at -23 dBFS stereo reads -23.0 LUFS), an fs/4 inter-sample test (true peak within 0.1 dB of theory), and ffmpeg's `ebur128` filter on the bank (integrated loudness and LRA match).

The tool also runs on its own:

```bash
build/voice-bank/bin/voice-bank analyze file.wav [--json out.json]
build/voice-bank/bin/voice-bank compare baseline.json current.json
build/voice-bank/bin/voice-bank degrade clean.wav out-dir [--lufs -26]
build/voice-bank/bin/voice-bank tone <sine-1k|intersample> out.wav
```

## Comparing

`compare` reports per file any change beyond tolerance (0.5 LU integrated, 1 LU range, 0.5 dB true peak, 1 dB noise floor, SNR, or any voice band) and exits non-zero when a file newly exceeds -1 dBTP or clips more than before.

## Microphone capture check

Screendrop records the microphone track as 24-bit mono LPCM at 48 kHz (system audio stays AAC). `scripts/check-microphone-capture.swift` writes a bank file the way the recorder does, with both the current and the previous AAC 96 kbps settings, and reads it back through Studio's paths: the mono-track rule transcription uses, the per-track processing mix behind playback and export, and the M4A export the speech transcriber reads.

```bash
xcrun swiftc -O Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift \
  scripts/check-microphone-capture.swift -o build/check-microphone-capture
build/check-microphone-capture build/voice-bank/variants/paulina-clean.wav
```

The lossless track is bit-identical to its source; AAC at 96 kbps deviated by -42 dB on the same take. The cost is size: about 9.7 MB per minute with system audio, against 1.8 MB before (video not included).

## Audio processing check

Every audio track gets its own processing tap (`Screendrop/RecordingAudioProcessing.swift`): the mono narration track (or an imported replacement) and the stereo system track carry separate gains in dB, a look-ahead peak limiter at -1 dBFS replaces the old hard clip at full scale, and the exporters limit the summed mix as well. `scripts/check-audio-processing.swift` renders a two-track recording the way the exporters do and checks:

- track roles, and migration of the old single 0-200% volume to both gains;
- that 0 dB renders the exact sum of the tracks, and -60 dB system audio is muted;
- that voice gain moves only the voice (+6 dB reads +6.00 LU);
- that at +24 dB the peak holds at -1 dBFS with voice processing on or off;
- that a +12 dB change mid-render glides without a click and lands at +12 dB.

```bash
xcrun swiftc -O Screendrop/RecordingAudioProcessing.swift Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift \
  scripts/check-audio-processing.swift -o build/check-audio-processing
build/check-audio-processing build/voice-bank/variants/paulina-clean.wav
```

Latency: every tap delays its track by the same 156 frames at 48 kHz (3.25 ms: 12 for the voice chain's oversampling, 144 for the limiter's look-ahead), so voice and system audio stay aligned. Exports add the mix limiter's 3 ms, so exported audio lands about 6 ms after the picture, well below what can be perceived. Stages that need more look-ahead should share this budget rather than add to it.

## Voice chain check

`Screendrop/VoiceChain.swift` is the narration channel strip, run inside the voice track's tap in this order: input trim, high-pass (12 or 24 dB/oct), five EQ bands, a dynamic low band against proximity boom, a 2:1 downward expander for the room between words, a feed-forward soft-knee compressor, a split-band de-esser, and saturation at 4x oversampling with a warmth control for even harmonics. The fader and a true-peak limiter at -1 dBTP follow. Turning Voice Processing off plays the dry voice matched to the processed loudness, with the same latency, so an A/B compares sound rather than level. The USB Condenser preset is a starting curve for a HyperX QuadCast-class microphone at a desk.

`scripts/check-voice-chain.swift` checks each stage against signals with known answers and reports what the preset does to the bank's USB-condenser takes:

| Check | Result |
|---|---|
| Flat chain | Bit-transparent; delay, oversampler, and bypass all land at 12 frames |
| High-pass an octave below the corner | -12.3 dB (12 dB/oct), -24.1 dB (24 dB/oct), as Butterworth theory gives |
| EQ bell, shelf, cut | +5.99, +3.94, -2.73 dB for +6, +4, -3 settings |
| Compressor 3:1 at -24 dB | -6 dBFS in, -18.0 out; -30 in, -30.0 out |
| Expander 2:1 at -45 dB, 8 dB range | -50 in, -54.9 out; -70 in, -77.7 out |
| De-esser and dynamic low band | Full range on loud bands, nothing on others |
| Aliasing, 9 kHz driven 12 dB | -88 dB with 4x oversampling, -13 dB without |
| Limiter on inter-sample peaks | -1.16 dBTP with true-peak detection, +1.52 dBTP sample-based |
| A/B loudness | Within 0.03 LU |
| Speed | About 100x real time on one core |

```bash
xcrun swiftc -O Screendrop/VoiceChain.swift Screendrop/RecordingAudioProcessing.swift \
  Screendrop/VoiceMeasurement.swift scripts/check-voice-chain.swift -o build/check-voice-chain
build/check-voice-chain build/voice-bank/variants
```

Compressor, expander, and de-esser thresholds are absolute, so they assume a typical raw narration level (around -26 LUFS). Input trim exists so loudness analysis can bring every take to that level first.

## Voice isolation check

Voice isolation (`Screendrop/RecordingVoiceIsolation.swift`) runs Apple's on-device AUSoundIsolation, high-quality model, over the narration track. It is too heavy for a playback tap, so it is rendered once, offline, into the project package (`voice-isolated-hq-v1-<amount>.caf`, 32-bit float mono), and playback and every export read a composition of the master with the narration track swapped for the render. The master is never modified, the voice chain still runs on the isolated track, and exports render a missing file on demand. An imported replacement soundtrack is not isolated. Amounts are 75%, 90%, and 100%: the blend is linear, so 75% lowers the room by about 12 dB and 90% by about 20 dB.

Two details matter for alignment. The unit's reported latency (4440 frames at 48 kHz) is measured and dropped from the render. And the unit pulls input ahead of the output it is asked for, so the renderer keeps two 4096-frame blocks queued in the player beyond what it renders; without that the player pads with silence and the narration comes out 4096 frames late.

`scripts/check-voice-isolation.swift` builds a project package around a noisy narration and checks the render is aligned to the frame with the master's narration, how much it removes, partial amounts, the track swap, on-demand rendering for exports, and that a cancelled render leaves nothing behind:

```bash
xcrun swiftc -O Screendrop/RecordingVoiceIsolation.swift Screendrop/RecordingAudioProcessing.swift \
  Screendrop/VoiceChain.swift Screendrop/VoiceMeasurement.swift scripts/check-voice-isolation.swift \
  -o build/check-voice-isolation
build/check-voice-isolation build/voice-bank/variants/paulina-usb-condenser-desk.wav
```

On the bank's USB-condenser-at-a-desk take, full isolation took SNR from 23.4 to 45.6 dB and the noise floor from -43.8 to -66.6 dBFS, kept loudness within 0.7 LU, and ran at about 80x real time.
