import Foundation

public enum CloudSyncCodecError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidRecordName(String)
    case mismatchedSpaceID(recordName: String, payloadID: UUID)
    case invalidPath(String)
}

/// Pure JSON encoder/decoder + path validation for `CloudSyncRecord`.
public enum CloudSyncCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func encode(_ record: CloudSyncRecord) throws -> (recordName: String, schemaVersion: Int, payload: Data) {
        let encoder = makeEncoder()
        let data: Data
        switch record {
        case .space(let s):
            try validate(space: s)
            data = try encoder.encode(s)
        case .libraryMeta(let m):
            data = try encoder.encode(m)
        case .settings(let s):
            data = try encoder.encode(s)
        case .activeSession(let a):
            for path in a.activePathBySpace.values {
                try validateRelativePath(path)
            }
            data = try encoder.encode(a)
        }
        return (record.recordName, CloudSyncConstants.currentSchemaVersion, data)
    }

    /// Decode a CloudKit record's payload. Returns `nil` for unknown record names
    /// (forward compatibility with future record kinds). Throws for unsupported
    /// schema versions, corrupt JSON, or invalid paths.
    public static func decode(recordName: String, schemaVersion: Int, payload: Data) throws -> CloudSyncRecord? {
        guard schemaVersion <= CloudSyncConstants.currentSchemaVersion else {
            throw CloudSyncCodecError.unsupportedSchemaVersion(schemaVersion)
        }
        let decoder = JSONDecoder()
        if recordName.hasPrefix(CloudSyncConstants.spaceRecordPrefix) {
            let suffix = String(recordName.dropFirst(CloudSyncConstants.spaceRecordPrefix.count))
            guard let expectedID = UUID(uuidString: suffix) else {
                throw CloudSyncCodecError.invalidRecordName(recordName)
            }
            let space = try decoder.decode(SyncedSpacePayload.self, from: payload)
            guard space.id == expectedID else {
                throw CloudSyncCodecError.mismatchedSpaceID(recordName: recordName, payloadID: space.id)
            }
            try validate(space: space)
            return .space(space)
        }
        switch recordName {
        case CloudSyncConstants.libraryMetaRecordName:
            let meta = try decoder.decode(SyncedLibraryMeta.self, from: payload)
            return .libraryMeta(meta)
        case CloudSyncConstants.settingsRecordName:
            let settings = try decoder.decode(SyncedSettings.self, from: payload)
            return .settings(SyncedSettings(
                balancedTermExpansion: settings.balancedTermExpansion,
                deepTermExpansion: settings.deepTermExpansion,
                termExpansionDepth: settings.termExpansionDepth,
                theme: settings.theme,
                readingFontFamily: settings.readingFontFamily,
                readingFontSize: settings.readingFontSize,
                readingLineHeight: settings.readingLineHeight,
                readingLetterSpacing: settings.readingLetterSpacing,
                citationFormat: settings.citationFormat,
                citationClickAction: settings.citationClickAction,
                originalClickAction: settings.originalClickAction
            ))
        case CloudSyncConstants.activeSessionRecordName:
            let session = try decoder.decode(SyncedActiveSession.self, from: payload)
            for path in session.activePathBySpace.values {
                try validateRelativePath(path)
            }
            return .activeSession(session)
        default:
            return nil
        }
    }

    private static func validate(space: SyncedSpacePayload) throws {
        for item in space.definition.items {
            if let path = item.home.openPath {
                try validateRelativePath(path)
            }
        }
        for tab in space.temporaryTabs {
            if let path = tab.openPath {
                try validateRelativePath(path)
            }
        }
    }

    /// Reject absolute paths, home-relative paths, URLs, or parent-traversal
    /// segments so local filesystem paths can never leak or escape the vault.
    public static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("://") else {
            throw CloudSyncCodecError.invalidPath(path)
        }
        let components = path.split(separator: "/")
        if components.contains("..") {
            throw CloudSyncCodecError.invalidPath(path)
        }
    }
}
