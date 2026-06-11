import Testing
import Foundation
import AppKit
@testable import MarpleKit

// MARK: - image indexing (QUA-175)
//
// marple is a pure consumer of the Quasi `image` schema contract. These tests
// pin the field mapping the indexer applies — creator→author, date→created,
// source→source — and the index-time technical-field derivation (width /
// height / file size from original.<ext> via ImageProbe, including the EXIF
// orientation swap the old runtime probe missed).

@Suite("ImageIndexing")
struct ImageIndexingTests {

    private func build(text: String, rel: String) -> BuildOutcome {
        buildIndexedEntry(text: text, rel: rel, fileStem: "image", sourceSlugs: [], mtimeMs: nil)
    }

    @Test("image: creator→author, date→created, source/themes/rating pass through")
    func imageFields() throws {
        let text = """
        ---
        type: image
        title: Micrometer
        creator:
          - Henry Maudslay
        date: 2024-11-08
        source: https://en.wikipedia.org/wiki/Micrometer_(device)
        themes:
          - measurement
        rating: 4
        ---

        A bench micrometer built for the Science Museum.
        """
        let outcome = build(text: text, rel: "vault/images/micrometer/image.md")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.entryType == "image")
        #expect(entry.title == "Micrometer")
        #expect(entry.author == ["Henry Maudslay"])            // creator → author
        #expect(entry.created == "2024-11-08")                  // date → created
        #expect(entry.source == "https://en.wikipedia.org/wiki/Micrometer_(device)")
        #expect(entry.themes?.contains("measurement") == true)
        #expect(entry.ratingScore == 4)
        // Technical fields are NOT parsed from frontmatter — derivation only.
        #expect(entry.width == nil)
        #expect(entry.height == nil)
    }

    @Test("image: minimal frontmatter (type+title) still indexes")
    func imageMinimal() throws {
        let text = """
        ---
        type: image
        title: Micrometer
        ---
        """
        let outcome = build(text: text, rel: "vault/images/micrometer/image.md")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.author.isEmpty)
        #expect(entry.created == nil)
    }

    @Test("creator key is image-only: a paper with `creator:` does not fold it into author")
    func creatorIsImageOnly() throws {
        let text = """
        ---
        type: paper
        title: Some Paper
        creator:
          - Not An Author
        ---
        """
        let outcome = build(text: text, rel: "vault/papers/some-paper.md")
        guard case .indexed(let entry) = outcome else {
            Issue.record("expected .indexed, got \(outcome)")
            return
        }
        #expect(entry.author.isEmpty)
    }

    // MARK: ImageProbe

    /// Write a `wph`-pixel PNG (and optionally a JPEG carrying an EXIF
    /// orientation tag) into a fresh image-entry directory; return its image.md path.
    private func makeImageEntryDir(width: Int, height: Int,
                                   ext: String = "png",
                                   orientation: Int? = nil) throws -> String {
        let dir = NSTemporaryDirectory() + "marple-image-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = rep.cgImage!
        let url = URL(fileURLWithPath: dir + "/original.\(ext)")
        let type = (ext == "png" ? "public.png" : "public.jpeg") as CFString
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return dir + "/image.md"
    }

    @Test("ImageProbe: reads pixel dimensions and file size from original.<ext>")
    func probeBasics() throws {
        let mdPath = try makeImageEntryDir(width: 64, height: 48)
        let dims = try #require(ImageProbe.probe(imageEntryAbsPath: mdPath))
        #expect(dims.width == 64)
        #expect(dims.height == 48)
        #expect(dims.fileSize > 0)
    }

    @Test("ImageProbe: EXIF orientation 6 (90° rotation) swaps width/height")
    func probeOrientation() throws {
        let mdPath = try makeImageEntryDir(width: 64, height: 48, ext: "jpg", orientation: 6)
        let dims = try #require(ImageProbe.probe(imageEntryAbsPath: mdPath))
        #expect(dims.width == 48)
        #expect(dims.height == 64)
    }

    @Test("ImageProbe: missing original → nil (entry still indexes without dims)")
    func probeMissing() throws {
        let dir = NSTemporaryDirectory() + "marple-image-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(ImageProbe.probe(imageEntryAbsPath: dir + "/image.md") == nil)
    }
}
