#!/bin/zsh
# Builds the voice bank: synthetic narration with macOS voices, degraded
# variants of each, an AAC 96 kbps round trip (what Screendrop captures
# today), and a metrics file compared against the committed baseline.
#
#   scripts/voice-bank/generate.sh                  # build and compare
#   scripts/voice-bank/generate.sh --update-baseline
#
# Your own recordings go in voice-bank-local/ (git-ignored) and are
# measured too, but never enter the baseline.
set -euo pipefail

root="${0:A:h:h:h}"
out="$root/build/voice-bank"
bin="$out/bin/voice-bank"
script="$root/scripts/voice-bank/script-es.txt"
baseline="$root/scripts/voice-bank/baseline.json"
# Paulina and Mónica reach about 11 kHz; Eddy stops near 8 kHz but is the
# only low male voice installed by default, so it covers the body band.
voices=(
  "paulina|Paulina (Español (México))"
  "monica|Mónica"
  "eddy|Eddy (Español (México))"
)

mkdir -p "$out/bin" "$out/source" "$out/variants"
xcrun swiftc -O "$root/Screendrop/VoiceMeasurement.swift" "$root/Screendrop/VoiceChain.swift" \
  "$root/Screendrop/RecordingAudioProcessing.swift" "$root/Screendrop/VoiceProfile.swift" \
  "$root/scripts/voice-bank.swift" -o "$bin"

for entry in "${voices[@]}"; do
  name="${entry%%|*}"
  voice="${entry#*|}"
  say -v "$voice" -f "$script" -o "$out/source/$name.wav" --data-format=LEF32@48000
  "$bin" degrade "$out/source/$name.wav" "$out/variants" > /dev/null
  afconvert -f m4af -d aac -b 96000 "$out/variants/$name-usb-condenser-desk.wav" "$out/source/$name-aac.m4a"
  afconvert -f WAVE -d LEI24@48000 "$out/source/$name-aac.m4a" "$out/variants/$name-usb-condenser-desk-aac96.wav"
done

"$bin" analyze "$out"/variants/*.wav --json "$out/metrics.json"

local_files=("$root"/voice-bank-local/*.(wav|aif|aiff|m4a|caf)(N))
if (( ${#local_files} )); then
  echo "\nlocal recordings (not part of the baseline)"
  "$bin" analyze "${local_files[@]}" --json "$out/metrics-local.json"
fi

echo
if [[ "${1:-}" == "--update-baseline" ]]; then
  cp "$out/metrics.json" "$baseline"
  echo "baseline updated: $baseline"
elif [[ -f "$baseline" ]]; then
  "$bin" compare "$baseline" "$out/metrics.json"
else
  echo "no baseline yet; run with --update-baseline to record one"
fi
