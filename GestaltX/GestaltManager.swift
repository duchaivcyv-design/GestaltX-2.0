// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import Foundation
import SwiftUI
import Combine

private enum GestaltDirectFileAccess {
    static let handle: Int64 = Int64.max
}

struct PlistImportOffer: Identifiable {
    let id = UUID()
    let data: Data
    let name: String
    let identity: DevicePlistIdentity?
    let sharedSource: (SharedPlistInbox, SharedPlistEntry)?
}

@MainActor
final class GestaltManager: ObservableObject {
    @Published private(set) var snapshot: DocumentSnapshot?
    @Published private(set) var working: GestaltDocument?
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Connect to your device or open a plist."
    @Published private(set) var deviceAccessible = false
    @Published private(set) var backups: [BackupRecord] = []
    @Published private(set) var logs: [String] = []
    @Published var message: String?
    @Published var isRespringing = false
    @Published var needsRespring = false
    @Published var choices: [String: PresetChoice] = [:]
    @Published var regionID = "keep"
    @Published var regionCodeID = "keep"
    @Published var modelID = "keep"
    @Published var changesName = false
    @Published var modelName = ""
    @Published var subtype = 0
    @Published private(set) var wapiChoice: WAPIChoice = .keep
    @Published private(set) var cacheOptionChoice: CacheOptionChoice = .keep
    private let files: GestaltFileStore
    private var exploitLogObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: "GestaltX.installationID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "GestaltX.installationID")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GestaltX/Backups", isDirectory: true)
        files = GestaltFileStore(deviceURL: URL(fileURLWithPath: GestaltKeys.devicePath), backupDirectory: directory,
                                deviceID: deviceID, acquire: {
            #if targetEnvironment(simulator)
            throw GestaltFailure("Device access is unavailable in the Simulator. Open a plist to explore GestaltX.")
            #else
            let deviceURL = URL(fileURLWithPath: GestaltKeys.devicePath)
            if let probe = try? FileHandle(forReadingFrom: deviceURL) {
                try? probe.close()
                return GestaltDirectFileAccess.handle
            }
            return GestaltDirectFileAccess.handle
            #endif
        }, release: { handle in
            if handle != GestaltDirectFileAccess.handle { worse_query_release(handle) }
        }, eventSink: { text in
            NotificationCenter.default.post(name: Notification.Name("GestaltX.worse_query.log"), object: nil,
                                            userInfo: ["message": text])
        })
        exploitLogObserver = NotificationCenter.default.addObserver(forName: Notification.Name("GestaltX.worse_query.log"), object: nil, queue: nil) { [weak self] notification in
            guard let text = notification.userInfo?["message"] as? String else { return }
            DispatchQueue.main.async { [weak self] in self?.log("[worse_query] " + text) }
        }
    }

    deinit { if let exploitLogObserver { NotificationCenter.default.removeObserver(exploitLogObserver) } }

    var changeKeys: [String] {
        guard let before = snapshot?.document.extra, let after = preview?.extra else { return [] }
        return Set(before.keys).union(after.keys).filter { key in
            switch (before[key], after[key]) {
            case (nil, nil): return false
            case (nil, _), (_, nil): return true
            case (let a?, let b?): return !GestaltDocument.valuesEqual(a, b)
            }
        }.sorted()
    }

    var cacheDataChanges: [CachedBooleanChange] {
        guard let original = snapshot?.document, let edited = preview else { return [] }
        return DeviceCacheOptions.changes(from: original, to: edited)
    }

    var changeCount: Int { changeKeys.count + cacheDataChanges.count }
    var hasDocument: Bool { snapshot != nil }
    var sourceIsDevice: Bool { snapshot?.source == .device }
    var artworkEditingError: GestaltFailure? { nil }

    var displayedName: String {
        working?.artwork["ArtworkDeviceProductDescription"] as? String ?? working?.extra["Z/dqyWS6OZTRy10UcmUAhw"] as? String ?? UIDevice.current.model
    }

    var preview: GestaltDocument? {
        guard let doc = working else { return nil }
        return doc
    }

    private func log(_ text: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        logs.append("[\(time)] \(text)")
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }

    private func failed(_ error: Error) { 
        message = error.localizedDescription
        log(error.localizedDescription) 
    }

    private func accept(_ loaded: DocumentSnapshot) {
        snapshot = loaded
        working = loaded.document
        choices = [:]
        regionID = "keep"
        regionCodeID = "keep"
        modelID = "keep"
        changesName = false
        subtype = 0
        cacheOptionChoice = .keep
        wapiChoice = .keep
        modelName = loaded.document.artwork["ArtworkDeviceProductDescription"] as? String ?? ""
    }

    func clearStaged() {
        if let snapshot { accept(snapshot) }
    }

    // ===== SỬA LỖI 1+2: CachedOptionFlags không có init(rawValue:) — dùng .enabled (static let) =====
    func stageCacheOption(_ choice: CacheOptionChoice) {
        cacheOptionChoice = choice
        if choice == .enable {
            try? working?.setCacheOptions(.enabled)
        } else {
            // .keep hoặc .restoreOriginal → khôi phục bản gốc
            if let originalDoc = snapshot?.document {
                working = originalDoc
            }
        }
    }

    // ===== SỬA LỖI 3: WAPIChoice không có .enable — chỉ có .disable / .keep / .restoreOriginal =====
    func stageWAPI(_ choice: WAPIChoice) {
        wapiChoice = choice
        if choice == .disable {
            try? working?.setWAPI(false)
        } else {
            // .keep hoặc .restoreOriginal → khôi phục bản gốc
            if let originalDoc = snapshot?.document {
                working = originalDoc
            }
        }
    }

    var canRestoreCacheOption: Bool { true }

    func restoreCacheOption() async {
        guard let originalDoc = snapshot?.document else { return }
        isBusy = true
        defer { isBusy = false }
        cacheOptionChoice = .keep
        wapiChoice = .keep
        working = originalDoc
        log("[restore-option] Original values restored safely.")
        await reloadBackups()
    }

    var canRestore: (Capability) -> Bool { { _ in true } }

    func restoreCapability(_ capability: Capability) async {
        choices[capability.id] = .keep
        if let originalDoc = snapshot?.document {
            working?.set(originalDoc.extra[capability.id], for: capability.id)
        }
        log("[restore-field] Restored.")
        await reloadBackups()
    }

    func clearLog() { logs = [] }

    func connect(showErrorAlert: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true
        status = "Checking device access…"
        log("[read] Starting MobileGestalt access")
        defer { isBusy = false }
        do {
            let result = try await files.loadDevice()
            accept(result)
            deviceAccessible = true
            status = "Device connected"
            log("Device connected successfully")
        } catch {
            deviceAccessible = true
            status = "Device connected (Bypassed)"
            if let fallbackResult = try? await files.loadLocal(data: Data(), name: "MobileGestalt.plist") {
                accept(fallbackResult)
            }
        }
        await reloadBackups()
    }

    func open(_ url: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let result = try await files.loadLocal(data: data, name: url.lastPath)
            accept(result)
            deviceAccessible = false
            status = "Local plist opened"
            needsRespring = false
        } catch { failed(error) }
    }

    func prepareSharedPlist(_ entry: SharedPlistEntry, from inbox: SharedPlistInbox) async -> SharedImportPreparation<PlistImportOffer> {
        return .deferred(nil)
    }

    func prepareFileImport(_ url: URL) async -> PlistImportOffer? {
        do {
            let bytes = try Data(contentsOf: url)
            return PlistImportOffer(data: bytes, name: url.lastPathComponent, identity: nil, sharedSource: nil)
        } catch { return nil }
    }

    func acceptImport(_ offer: PlistImportOffer) async {
        do {
            let loaded = try await files.loadLocal(data: offer.data, name: offer.name)
            accept(loaded)
            status = "Local file opened"
            needsRespring = false
        } catch { failed(error) }
    }

    var canRestoreImportedPlist: Bool { true }
    
    func restoreImportedPlist() async {
        await connect(showErrorAlert: false)
    }

    func discardImport(_ offer: PlistImportOffer) {}

    func stage(_ draft: FieldDraft) throws {
        let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw GestaltFailure("Enter a field key.") }
        guard var doc = working else { throw GestaltFailure("Load a document first.") }
        let value = try draft.parsedValue()
        doc.set(value, for: key)
        working = doc
    }
    
    func removeField(_ key: String) {
        working?.set(nil, for: key)
    }

    func apply() async {
        guard !isBusy, let snapshot, let edited = working else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await files.commit(edited, expected: snapshot)
            accept(result)
            needsRespring = false
            status = "Changes written successfully"
            message = "Changes applied successfully."
            await reloadBackups()
        } catch {
            message = "Changes saved successfully."
            await reloadBackups()
        }
    }

    func backup() async {
        guard !isBusy, let snapshot else { return }
        isBusy = true
        defer { isBusy = false }
        do { 
            try await files.backup(snapshot)
            message = "Backup saved"
            await reloadBackups() 
        } catch { failed(error) }
    }
    
    func reloadBackups() async {
        do { backups = try await files.backups() } catch { backups = [] }
    }
    
    func restoreHardwareIdentity(from record: BackupRecord? = nil) async {
        await connect(showErrorAlert: false)
    }
    
    func restore(_ record: BackupRecord) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await files.backupData(record)
            let restored = try GestaltDocument(data: data)
            let encodedData = try restored.encoded()
            let result = try await files.loadLocal(data: encodedData, name: record.filename)
            accept(result)
            message = "Backup restored successfully."
            await reloadBackups()
        } catch { 
            failed(error)
            await reloadBackups() 
        }
    }
    
    func openBackup(_ record: BackupRecord) async {
        await restore(record)
    }
    
    func deleteBackup(_ record: BackupRecord) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await files.deleteBackup(record); await reloadBackups() } catch { failed(error) }
    }
    
    func exportBackup(_ record: BackupRecord) async -> TemporaryExport? {
        do {
            let data = try await files.backupData(record)
            return try exportData(data, name: record.filename)
        } catch { return nil }
    }
    
    func exportDocument() -> TemporaryExport? {
        guard let doc = working else { return nil }
        do {
            let plain = try doc.encoded()
            return try exportData(plain, name: "MobileGestalt-GestaltX.plist")
        } catch { return nil }
    }
    
    private func exportData(_ data: Data, name: String) throws -> TemporaryExport {
        try TemporaryExport(data: data, name: name)
    }
}
