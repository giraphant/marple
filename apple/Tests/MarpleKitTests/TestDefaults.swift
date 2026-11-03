import Foundation

/// A UserDefaults suite name backed by a plist in the temp directory.
/// `removePersistentDomain(forName:)` leaves an empty plist behind; with a plain
/// suite name that file lands in ~/Library/Preferences, one per test run.
func testDefaultsSuite(_ prefix: String) -> String {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("marple-test-defaults", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("\(prefix)\(UUID().uuidString)").path
}
