//
//  AppIdentity.swift
//  Screendrop
//
//  Names this fork owns on disk and in the system, kept apart from the
//  upstream Screendrop so both apps can be installed side by side: their
//  libraries, recordings, keychain items, and update feeds never overlap.
//

import Foundation

nonisolated enum AppIdentity {
    /// Folder name under Application Support, Pictures, and the temp
    /// directory. Upstream uses "Screendrop".
    static let storageFolderName = "Screendrop Voice"

    /// Keychain service for cloud credentials. Upstream uses
    /// "com.fayazahmed.Screendrop".
    static let keychainService = "com.cipherfy.ScreendropVoice"

    /// Sparkle stays off until this fork publishes its own appcast;
    /// upstream's feed would replace this build with the original app.
    static let updatesEnabled = false
}
