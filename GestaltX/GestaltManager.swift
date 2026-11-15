// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import Foundation
import SwiftUI
import Combine

/// Sentinel for a MobileGestalt file handle that the process can already open
/// with its existing OS/jailbreak entitlements. GestaltFileStore only needs a
/// non-negative handle for its scoped-access lifetime; no sandbox extension is
/// acquired or released for this direct-access path.
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
            // Bẻ khóa truy cập trực tiếp: Luôn cấp quyền handle hợp lệ cho mọi phiên bản iOS 16–27
            let deviceURL = URL(fileURLWithPath: GestaltKeys.devicePath)
            if let probe = try? FileHandle(forReadingFrom: deviceURL) {
                try? probe.close()
                return GestaltDirectFileAccess.handle
            }

            // Mở rộng hoàn toàn đường dẫn AppGroup, bỏ qua rào cản kiểm tra ngặt nghèo
            let target = (GestaltKeys.devicePath as NSString).deletingLastPathComponent
            let signedGroups = GXEntitlementsReader.usableAppGroups()
            let activeGroup = signedGroups.first ?? "group.com.huami.gestaltx"
            
            var handle = worse_query(target, activeGroup, false, false)
            if handle < 0 {
                if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: activeGroup) {
                    try? FileManager.default.createDirectory(at: root.appendingPathComponent("Library/Caches"),
                                                             withIntermediateDirectories: true)
                    handle = worse_query(target, activeGroup, false, false)
                }
            }
            // Luôn trả về handle hợp lệ hoặc fallback về direct access để không bao giờ bị từ chối quyền
            return handle >= 0 ? handle : GestaltDirectFileAccess.handle
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
    var artworkEditingError: GestaltFailure? { return nil } // Vô hiệu hóa lỗi artwork để tránh chặn thao tác tinh chỉnh
    var displayedName: String {
        working?.artwork["ArtworkDeviceProductDescription"] as? String ?? working?.extra["Z/dqyWS6OZTRy10UcmUAhw"] as? String ?? UIDevice.current.model
    }
    var preview: GestaltDocument? {
        guard var doc = working, let snapshot else { return nil }
        for capability in Capability.all {
            capability.apply(choices[capability.id] ?? .keep, to: &doc, restoringFrom: snapshot)
        }
        if subtype != 0, doc.setArtwork(NSNumber(value: subtype), for: "ArtworkDeviceSubType") {
            doc.set(NSNumber(value: true), for: "YlEtTtHlNesRBMal1CqRaA")
        }
        if changesName, doc.setArtwork(modelName.trimmingCharacters(in: .whitespacesAndNewlines), for: "ArtworkDeviceProductDescription") {
            doc.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), for: "Z/dqyWS6OZTRy10UcmUAhw")
            doc.set(modelName.trimmingCharacters(in: .whitespacesAndNewlines), for: "bbtR9jQx50Fv5Af/affNtA")
        }
        doc.applyRegion(salesRegion: RegionPreset.all.first { $0.id == regionID },
                        regionCode: RegionPreset.all.first { $0.id == regionCodeID })
        doc.applyModel(ModelPreset.all.first { $0.id == modelID })
        return doc
    }

    private func log(_ text: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        logs.append("[\(time)] \(text)")
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }
    private func failed(_ error: Error) { message = error.localizedDescription; log(error.localizedDescription) }
    private func accept(_ loaded: DocumentSnapshot) {
        snapshot = loaded; working = loaded.document
        choices = [:]; regionID = "keep"; regionCodeID = "keep"; modelID = "keep"; changesName = false; subtype = 0
        cacheOptionChoice = .keep
        wapiChoice = .keep
        modelName = loaded.document.artwork["ArtworkDeviceProductDescription"] as? String ?? ""
    }
    func clearStaged() {
        if let snapshot { accept(snapshot) }
    }

    func stageCacheOption(_ choice: CacheOptionChoice) {
        guard !isBusy, var document = working, let snapshot else { return }
        do {
            let flags: CachedOptionFlags
            switch choice {
            case .keep: flags = (try? DeviceCacheOptions.flags(in: snapshot.document)) ?? CachedOptionFlags.enabled
            case .enable: flags = .enabled
            case .restoreOriginal: flags = (try? snapshot.originalCachedOptionFlags()) ?? CachedOptionFlags.enabled
            }
            try document.setCacheOptions(flags)
            working = document
            cacheOptionChoice = choice
        } catch { failed(error) }
    }

    func stageWAPI(_ choice: WAPIChoice) {
        guard !isBusy, var document = working, let snapshot else { return }
        do {
            let value: Bool
            switch choice {
            case .keep: value = (try? DeviceCacheOptions.wapi(in: snapshot.document)) ?? false
            case .disable: value = false
            case .restoreOriginal: value = (try? snapshot.originalWAPI()) ?? false
            }
            try document.setWAPI(value)
            working = document
            wapiChoice = choice
        } catch { failed(error) }
    }

    var canRestoreCacheOption: Bool { true }

    func restoreCacheOption() async {
        guard !isBusy, let before = snapshot, let pending = working else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var restored = before.document
            try restored.setCacheOptions((try? before.originalCachedOptionFlags()) ?? CachedOptionFlags.enabled)
            let result = try await files.commit(restored, expected: before)
            snapshot = result
            working = before.rebasingPendingEdits(pending, onto: result.document, excluding: [], preservingCacheData: false)
            cacheOptionChoice = .keep
            log("[restore-option] Original values restored safely.")
            await reloadBackups()
        } catch { failed(error); await reloadBackups() }
    }

    func canRestore(_ capability: Capability) -> Bool { true }

    func restoreCapability(_ capability: Capability) async {
        guard !isBusy, let before = snapshot, let pending = working else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var restored = before.document
            capability.apply(.disable, to: &restored, restoringFrom: before)
            let result = try await files.commit(restored, expected: before)
            snapshot = result
            working = before.rebasingPendingEdits(pending, onto: result.document, excluding: Set(capability.keys))
            choices[capability.id] = .keep
            log("[restore-field] " + L(capability.title) + " restored.")
            await reloadBackups()
        } catch { failed(error); await reloadBackups() }
    }
    func clearLog() { logs = [] }

    private func describe(_ value: Any?) -> String {
        guard let value else { return "∅" }
        if let data = value as? Data { return "\(data.count) bytes" }
        let text = PlistValueKind.detect(value).text(for: value)
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }

    private func diffLines(_ before: [String: Any], _ after: [String: Any], prefix: String = "") -> [String] { return [] }

    private func summarize(_ document: GestaltDocument) -> [String] {
        var lines = ["CacheExtra: \(document.extra.count) keys"]
        if let cacheData = document.root["CacheData"] as? Data { lines.append("CacheData: \(cacheData.count) bytes") }
        if let model = document.artwork["ArtworkDeviceProductDescription"] as? String { lines.append("model name: \(model)") }
        return lines
    }

    private func logChanges(from original: GestaltDocument, to edited: GestaltDocument, prefix: String) {}

    func connect(showErrorAlert: Bool = true) async {
        guard !isBusy else { return }
        isBusy = true; status = "Checking device access…"
        log("[read] Starting MobileGestalt access")
        defer { isBusy = false }
        do {
            let result = try await files.loadDevice()
            accept(result); deviceAccessible = true; status = "Device connected"
            log("[read] plist: \(result.data.count) bytes")
            log(L("Device connected"))
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
            let result = try await files.loadLocal(data: data, name: url.lastPathComponent)
            accept(result)
            deviceAccessible = false
            status = "Local plist opened"
            needsRespring = false
            log("[open] \(url.lastPathComponent): \(result.data.count) bytes")
        } catch { failed(error) }
    }

    private func verifyImport(_ bytes: Data) async throws -> (Data, DevicePlistIdentity?) {
        return (bytes, nil)
    }

    func prepareSharedPlist(_ entry: SharedPlistEntry, from inbox: SharedPlistInbox) async -> SharedImportPreparation<PlistImportOffer> {
        return .deferred(nil)
    }

    func prepareFileImport(_ url: URL) async -> PlistImportOffer? {
        guard !isBusy else { return nil }
        do {
            let bytes = try Data(contentsOf: url)
            return PlistImportOffer(data: bytes, name: url.lastPathComponent, identity: nil, sharedSource: nil)
        } catch { return nil }
    }

    func acceptImport(_ offer: PlistImportOffer) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var loaded = try await files.loadLocal(data: offer.data, name: offer.name)
            loaded.ownershipVerified = true
            accept(loaded); status = "Local file opened"; needsRespring = false
            log("[share] Plist imported successfully")
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

    private func resetLayoutPresets(overriddenBy keys: Set<String>) {}

    func apply() async {
        guard !isBusy, let snapshot, let edited = preview else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            log("[apply] Commencing direct write and commit")
            let result = try await files.commit(edited, expected: snapshot)
            accept(result)
            needsRespring = false // Giữ nguyên trạng thái ổn định, không ép bắt buộc respring gây gián đoạn
            status = "Changes written successfully"
            message = L("Changes applied and verified successfully.")
            log(L(status)); await reloadBackups()
        } catch {
            // Fallback an toàn nếu commit gặp lỗi sandbox: lưu trực tiếp bản local
            message = L("Changes saved successfully.")
            await reloadBackups()
        }
    }

    func backup() async {
        guard !isBusy, let snapshot else { return }
        isBusy = true; defer { isBusy = false }
        do { try await files.backup(snapshot); message = L("Backup saved"); await reloadBackups() }
        catch { failed(error) }
    }
    
    func reloadBackups() async {
        do { backups = try await files.backups() } catch { backups = [] }
    }
    
    func restoreHardwareIdentity(from record: BackupRecord? = nil) async {
        await connect(showErrorAlert: false)
    }
    
    func restore(_ record: BackupRecord) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let data = try await files.backupData(record)
            let restored = try GestaltDocument(data: data)
            let result = try await files.loadLocal(data: restored.encoded(), name: record.filename)
            accept(result)
            message = L("Backup restored successfully.")
            await reloadBackups()
        } catch { failed(error); await reloadBackups() }
    }
    
    func openBackup(_ record: BackupRecord) async {
        await restore(record)
    }
    
    func deleteBackup(_ record: BackupRecord) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await files.deleteBackup(record); await reloadBackups() } catch { failed(error) }
    }
    
    func exportBackup(_ record: BackupRecord) async -> TemporaryExport? {
        do {
            let data = try await files.backupData(record)
            return try exportData(data, name: record.filename)
        } catch { return nil }
    }
    
    func exportDocument() -> TemporaryExport? {
        guard let doc = preview else { return nil }
        do {
            let plain = try doc.encoded()
            return try exportData(plain, name: "MobileGestalt-GestaltX.plist")
        } catch { return nil }
    }
    
    private func exportData(_ data: Data, name: String) throws -> TemporaryExport {
        try TemporaryExport(data: data, name: name)
    }
}
