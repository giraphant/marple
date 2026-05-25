import CoreText
import Foundation

/// Registers the bundled reading fonts with CoreText at launch. The app runs via
/// `swift run` (no Info.plist / `ATSApplicationFontsPath`), so fonts shipped in
/// `Resources/Fonts` must be registered programmatically before any view renders;
/// only then can `Font.custom(_:size:)` resolve them by PostScript name.
enum FontRegistration {
    static func registerBundledFonts() {
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for url in urls where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                print("[marple] font register failed: \(url.lastPathComponent) — "
                      + "\(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
        }
    }
}
