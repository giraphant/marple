import Foundation
import Testing
@testable import MarpleKit

@Suite struct ImageAssetTests {
    @Test func originalPathUsesImageEntryDirectory() {
        let rel = ImageAsset.originalPath(
            forImageEntryPath: "vault/images/ai-agent-loop-diagram/image.md",
            existingFilenames: ["image.md", "original.png"]
        )
        #expect(rel == "vault/images/ai-agent-loop-diagram/original.png")
    }

    @Test func originalPathSupportsCommonImageExtensions() {
        let rel = ImageAsset.originalPath(
            forImageEntryPath: "vault/images/photo/image.md",
            existingFilenames: ["image.md", "original.webp"]
        )
        #expect(rel == "vault/images/photo/original.webp")
    }

    @Test func originalPathReturnsNilWhenNoOriginalImageExists() {
        let rel = ImageAsset.originalPath(
            forImageEntryPath: "vault/images/photo/image.md",
            existingFilenames: ["image.md", "notes.txt"]
        )
        #expect(rel == nil)
    }

    @Test func objectSlugComesFromParentDirectory() {
        #expect(ImageAsset.slug(forImageEntryPath: "vault/images/ai-agent-loop-diagram/image.md") == "ai-agent-loop-diagram")
    }

    @Test func slugFromTitleKeepsSemanticNameFilesystemSafe() {
        #expect(ImageAsset.slug(fromTitle: "AI Agent Loop Diagram") == "ai-agent-loop-diagram")
        #expect(ImageAsset.slug(fromTitle: "转导 图") == "转导-图")
        #expect(ImageAsset.slug(fromTitle: "A/B:C") == "a-b-c")
    }

    @Test func supportedImageURLUsesCaseInsensitiveExtension() {
        #expect(ImageAsset.isSupportedImageURL(URL(fileURLWithPath: "/tmp/Figure.PNG")))
        #expect(!ImageAsset.isSupportedImageURL(URL(fileURLWithPath: "/tmp/readme.md")))
    }
}
