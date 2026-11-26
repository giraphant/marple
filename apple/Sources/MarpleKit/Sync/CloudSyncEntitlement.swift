import Foundation
#if os(macOS)
import Security
#endif

/// Detects whether the current process actually carries the CloudKit entitlement
/// for `CloudSyncConstants.containerIdentifier` BEFORE calling `CKContainer(...)`.
///
/// Calling `CKContainer(identifier:)` in an unentitled process (such as ad-hoc
/// local dev builds or `swift test`) raises an uncatchable Objective-C exception.
public enum CloudSyncEntitlement {
    public static func isAvailable(containerID: String = CloudSyncConstants.containerIdentifier) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["MARPLE_DISABLE_CLOUDKIT"] == "1" {
            return false
        }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
        ) as? [String]
        guard let containers, containers.contains(containerID) else { return false }

        let servicesVal = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.icloud-services" as CFString, nil
        )
        if let list = servicesVal as? [String] {
            return list.contains { $0.caseInsensitiveCompare("CloudKit") == .orderedSame || $0 == "*" }
        }
        if let single = servicesVal as? String {
            return single.caseInsensitiveCompare("CloudKit") == .orderedSame || single == "*"
        }
        return false
        #elseif os(iOS)
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
        #else
        return false
        #endif
    }
}
