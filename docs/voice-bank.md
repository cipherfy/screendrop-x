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

Screendrop records the microphone track as 24-bit mono LPCM at 48 kHz (system audio stays AAC). `scripts/check-microphone-capture.swift` writes a bank file the way the recorder does, with both the current and the previous AAC 96 kbps settings, and reads it back through Studio's paths: the mono-track rule transcription uses, the gain mix behind playback and export (including above 100%), and the M4A export the speech transcriber reads.

```bash
xcrun swiftc -O Screendrop/RecordingAudioGain.swift Screendrop/VoiceMeasurement.swift \
  scripts/check-microphone-capture.swift -o build/check-microphone-capture
build/check-microphone-capture build/voice-bank/variants/paulina-clean.wav
```

The lossless track is bit-identical to its source; AAC at 96 kbps deviated by -42 dB on the same take. The cost is size: about 9.7 MB per minute with system audio, against 1.8 MB before (video not included).
