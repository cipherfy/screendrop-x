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
    static let storageFolderName = "Screendrop X"

    /// Keychain service for cloud credentials. Upstream uses
    /// "com.fayazahmed.Screendrop".
    static let keychainService = "com.cipherfy.ScreendropX"

    /// Sparkle stays off until this fork publishes its own appcast;
    /// upstream's feed would replace this build with the original app.
    static let updatesEnabled = false

    // MARK: Rename from Screendrop Voice

    /// The fork's name and identity before it became Screendrop X.
    static let previousStorageFolderName = "Screendrop Voice"
    static let previousBundleIdentifier = "com.cipherfy.ScreendropVoice"
    private static let migrationKey = "migratedFromScreendropVoice"

    /// Runs once, before anything reads storage: moves the previous name's
    /// folders (Application Support and Pictures), rewrites the absolute
    /// recording paths history.json keeps, and copies its preferences
    /// (per-microphone voice profiles, window layout, and the rest) with
    /// their paths updated. Never overwrites anything already here.
    static func migrateFromPreviousName() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }
        let fileManager = FileManager.default

        var moved: [(old: String, new: String)] = []
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .picturesDirectory] {
            guard let base = fileManager.urls(for: directory, in: .userDomainMask).first else { continue }
            let old = base.appendingPathComponent(previousStorageFolderName, isDirectory: true)
            let new = base.appendingPathComponent(storageFolderName, isDirectory: true)
            guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { continue }
            do {
                try fileManager.moveItem(at: old, to: new)
                moved.append((old.path, new.path))
            } catch {
                continue
            }
        }

        func updatingPaths(_ text: String) -> String {
            var text = text
            for (old, new) in moved {
                text = text.replacingOccurrences(of: old, with: new)
                // JSON escapes slashes.
                text = text.replacingOccurrences(
                    of: old.replacingOccurrences(of: "/", with: "\\/"),
                    with: new.replacingOccurrences(of: "/", with: "\\/")
                )
            }
            return text
        }

        if !moved.isEmpty,
           let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let history = support
                .appendingPathComponent(storageFolderName, isDirectory: true)
                .appendingPathComponent("history.json")
            if let text = try? String(contentsOf: history, encoding: .utf8) {
                try? updatingPaths(text).write(to: history, atomically: true, encoding: .utf8)
            }
        }

        if let previous = defaults.persistentDomain(forName: previousBundleIdentifier) {
            for (key, value) in previous where defaults.object(forKey: key) == nil {
                defaults.set((value as? String).map(updatingPaths) ?? value, forKey: key)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }
}
