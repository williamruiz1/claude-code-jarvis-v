import Foundation

/// Thin wrapper around the macOS `security` CLI for reading/writing
/// generic-password Keychain items. We shell out instead of linking
/// SecKeychain directly because (a) the CLI is the same surface the
/// voicemode wrapper uses, so the storage convention stays unified;
/// (b) it sidesteps the entitlement / private-API churn of the
/// modern Keychain Services API for an unsigned/dev build.
///
/// **Storage convention:** `service` is the logical name (e.g.
/// `elevenlabs-api-key`), `account` is `$USER`. Same shape used by
/// the OPENAI_API_KEY wrapper already in production.
enum KeychainHelper {

    /// Read a secret. Returns nil if not found / permission denied / any error.
    /// Never logs the secret.
    static func read(service: String, account: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        guard let data = try? stdout.fileHandleForReading.readToEnd(),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write/update a secret. Uses `-U` to upsert (replace if exists).
    /// Returns true on success.
    @discardableResult
    static func write(service: String, account: String, secret: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", secret,
            "-U", // update if it exists
        ]
        // Discard output — we never want secrets to land in any pipe we
        // could accidentally read from elsewhere.
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return task.terminationStatus == 0
    }

    /// Delete a secret. Returns true on success (also true if it didn't exist).
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["delete-generic-password", "-s", service, "-a", account]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        // Status 44 means "item not found" — treat as success for delete.
        return task.terminationStatus == 0 || task.terminationStatus == 44
    }

    // MARK: ElevenLabs convenience

    static let elevenLabsService = "elevenlabs-api-key"

    static var currentUser: String {
        return ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    static func readElevenLabsKey() -> String? {
        return read(service: elevenLabsService, account: currentUser)
    }

    static func writeElevenLabsKey(_ key: String) -> Bool {
        return write(service: elevenLabsService, account: currentUser, secret: key)
    }
}
