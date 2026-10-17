//
//  InspectorValueFormat+Audio.swift
//  Screendrop
//
//  Units for the voice controls: decibels, hertz, and milliseconds.
//

import CoreGraphics

extension InspectorValueFormat {
    /// Signed level in decibels, for audio gains.
    static let decibels = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 1,
        suffix: " dB",
        showsPositiveSign: true,
        step: 0.1,
        acceptedSuffixes: ["decibels", "db"]
    )

    static let hertz = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: " Hz",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: ["hz"]
    )

    static let milliseconds = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: " ms",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: ["ms"]
    )
}
