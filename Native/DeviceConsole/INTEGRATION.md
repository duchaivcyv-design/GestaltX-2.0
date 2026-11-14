# Native device console build

The Xcode project is already wired to `Native/DeviceConsole/build/GXDeviceConsole.xcframework` and enables the `GXDEVICECONSOLE` Swift compilation condition. The XCFramework is intentionally git-ignored, so a clean source checkout does not contain the generated binary. Build it before opening/building the Xcode project, or use `.github/scripts/build-ipa.sh`, which now creates it when it is missing.

## Requirements

- macOS with Xcode and its command-line tools (`xcodebuild`, `lipo`)
- Rust/Cargo with the Apple targets installed
- CMake; `nasm` is also required on x86_64 build hosts

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
brew install cmake
# On an Intel Mac, also install nasm:
# brew install nasm

cd Native/DeviceConsole
./build-xcframework.sh
```

The script creates `Native/DeviceConsole/build/GXDeviceConsole.xcframework` for iOS devices and Apple Silicon simulators. It is not committed to the repository. The GitHub Actions workflow performs the same build and caches the result.

After the framework is generated, build the app normally in Xcode or run:

```bash
.github/scripts/build-ipa.sh
```

Do not add the framework or the `GXDEVICECONSOLE` flag a second time; both are already configured in `GestaltX.xcodeproj/project.pbxproj`. The generated framework is a static library and is linked, not embedded.

## Runtime support

Pairing and notification capture use the native remote-pairing/syslog backend and are only verified by this project for iOS 27. The app checks the OS version before starting those operations. On earlier supported app versions, local plist workflows remain available, while the device-console controls report that the native feature is not verified for that OS.

The app and its Share Extension require a common signed App Group for shared-file import. `Configuration/App-Info.plist` already declares the local-network and continued-processing identifiers used by the native console.
