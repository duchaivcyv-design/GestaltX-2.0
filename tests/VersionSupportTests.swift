import Foundation

func L(_ key: String) -> String { key }

@main
enum VersionSupportTests {
    static func main() {
        precondition(!VersionSupport.contains(OperatingSystemVersion(majorVersion: 15, minorVersion: 8, patchVersion: 0)))
        precondition(VersionSupport.contains(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)))
        precondition(VersionSupport.contains(OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0)))
        precondition(VersionSupport.contains(OperatingSystemVersion(majorVersion: 26, minorVersion: 9, patchVersion: 0)))
        precondition(VersionSupport.contains(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.contains(OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.supportsPrivateContainerAccess(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.supportsPrivateContainerAccess(OperatingSystemVersion(majorVersion: 25, minorVersion: 0, patchVersion: 0)))
        precondition(VersionSupport.supportsPrivateContainerAccess(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        precondition(VersionSupport.supportsPrivateContainerAccess(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.supportsPrivateContainerAccess(OperatingSystemVersion(majorVersion: 28, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.supportsSystemGroupAccess(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)))
        precondition(!VersionSupport.supportsSystemGroupAccess(OperatingSystemVersion(majorVersion: 26, minorVersion: 9, patchVersion: 0)))
        precondition(VersionSupport.supportsSystemGroupAccess(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        print("VersionSupport tests passed")
    }
}
