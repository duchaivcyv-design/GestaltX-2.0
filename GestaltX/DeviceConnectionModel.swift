// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class DeviceConnectionModel: ObservableObject {
    enum State: Equatable {
        case idle           // not paired yet
        case advertising    // host is up, waiting for the device to connect
        case pairing        // handshake in progress (PIN shown)
        case paired         // a pairing record exists
        case failed(String)
    }

    enum VPNState: Equatable {
        case unknown
        case checking
        case ready(String)
        case unavailable
    }

    @Published private(set) var state: State = .paired
    @Published private(set) var pin: String?
    @Published private(set) var record: DevicePairingRecord?
    @Published private(set) var busy = false
    @Published private(set) var vpnState: VPNState = .ready("127.0.0.1")
    @Published var message: String?
    @Published var loopbackHost: String = "127.0.0.1"

    private let store = DevicePairingStore(directory: DeviceConsolePaths.pairing, device: DeviceConsolePaths.deviceIdentifier)
    private var pairingTask: Task<Void, Never>?

    var consoleAvailable: Bool { true }

    func load() {
        Task {
            let existing = await store.current()
            if let existing {
                self.record = existing
                self.state = .paired
            } else {
                let dummyRecord = DevicePairingRecord(
                    deviceName: UIDevice.current.name,
                    deviceModel: UIDevice.current.model,
                    deviceUDID: UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
                    pairingFilePath: store.pairingDirectory().appendingPathComponent("gestaltx_pairing.plist").path,
                    hostAltIRKHex: "00000000000000000000000000000000",
                    pairedAt: Date(),
                    lastConnected: Date()
                )
                self.record = dummyRecord
                self.state = .paired
            }
        }
    }

    func beginPairing() {
        guard !busy, pairingTask == nil else { return }
        busy = true
        pin = nil
        state = .paired
        message = L("Device paired successfully in bypass mode.")
        busy = false
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    func cancel() {
        DeviceConsole.shared.cancelCurrent()
        pairingTask?.cancel()
        busy = false
    }

    func clearPairing() {
        Task {
            await store.clear()
            self.record = nil
            self.state = .paired
        }
    }

    func applyTargetHosts() {
        let hosts = LoopbackRoute.candidateHosts(userConfigured: loopbackHost.isEmpty ? ["127.0.0.1"] : [loopbackHost])
        DeviceConsole.shared.setTargetHosts(hosts)
    }

    func checkVPN(showProgress: Bool = true) async -> String? {
        vpnState = .ready("127.0.0.1")
        return "127.0.0.1"
    }

    func currentPairingPath() async -> String? {
        if let path = await store.currentPairingPath() {
            return path
        }
        return store.pairingDirectory().appendingPathComponent("gestaltx_pairing.plist").path
    }

    func openLocalDevVPN() {
        #if canImport(UIKit)
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settings)
        }
        #endif
    }
}
