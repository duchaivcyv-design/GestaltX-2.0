// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum VersionSupport {
    // The app UI and local-document workflows target iOS 16 through iOS 27.
    // Private on-device SystemGroup access remains a separate, iOS 27-only path.
    static let minimumAppMajorVersion = 16
    static let maximumAppMajorVersion = 27
    static let range = "iOS 16–27.x"

    static func contains(_ version: OperatingSystemVersion) -> Bool {
        (minimumAppMajorVersion...maximumAppMajorVersion).contains(version.majorVersion)
    }

    static func supportsPrivateContainerAccess(_ version: OperatingSystemVersion) -> Bool {
        (26...27).contains(version.majorVersion)
    }

    static func supportsSystemGroupAccess(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion == 27
    }

    static var currentVersion: OperatingSystemVersion { ProcessInfo.processInfo.operatingSystemVersion }
    static var current: Bool { contains(currentVersion) }
    static var supportsCurrentPrivateContainerAccess: Bool { supportsPrivateContainerAccess(currentVersion) }
    static var supportsCurrentSystemGroupAccess: Bool { supportsSystemGroupAccess(currentVersion) }

    static var label: String { L(current ? "Supported" : "Unsupported") }

    static var privateContainerAccessLabel: String {
        guard current else { return L("Unsupported") }
        return L(supportsCurrentPrivateContainerAccess
            ? "iOS 26–27: private app-container access is attempted when signing permits it."
            : "iOS 16–25: private app-container features are disabled; local plist editing remains available.")
    }

    static var mobileGestaltAccessLabel: String {
        guard current else { return L("Unsupported") }
        return L(supportsCurrentSystemGroupAccess
            ? "iOS 27: access is checked on the device."
            : "iOS 16–26: SystemGroup access is not claimed by upstream. Local plist editing is available.")
    }
}
