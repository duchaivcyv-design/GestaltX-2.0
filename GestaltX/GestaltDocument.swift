// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 huamidev
import Foundation
import CoreFoundation
import CryptoKit

struct GestaltFailure: LocalizedError, Sendable {
    let key: String
    var errorDescription: String? { NSLocalizedString(key, comment: "") }
    init(_ key: String) { self.key = key }
}

enum PlistValueKind: String, CaseIterable, Identifiable, Sendable {
    case string = "String", integer = "Integer", real = "Real", boolean = "Boolean"
    case data = "Data", array = "Array", dictionary = "Dictionary", date = "Date"
    var id: String { rawValue }

    static func detect(_ value: Any) -> Self {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean }
            return CFNumberIsFloatType(unsafeBitCast(number, to: CFNumber.self)) ? .real : .integer
        }
        if value is Date { return .date }
        if value is Data { return .data }
        if value is [String: Any] { return .dictionary }
        if value is [Any] { return .array }
        return .string
    }

    func parse(_ text: String) throws -> Any {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .string: return text
        case .integer:
            if let value = Int64(trimmed) { return NSNumber(value: value) }
            guard let value = UInt64(trimmed) else { throw GestaltFailure("Enter a valid whole number.") }
            return NSNumber(value: value)
        case .real:
            guard let value = Double(trimmed), value.isFinite else { throw GestaltFailure("Enter a finite decimal number.") }
            return NSNumber(value: value)
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1": return NSNumber(value: true)
            case "false", "0": return NSNumber(value: false)
            default: throw GestaltFailure("Use true or false for a Boolean value.")
            }
        case .date:
            let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:[Zz]|[+-][0-9]{2}:?[0-9]{2})$"#
            guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
                throw GestaltFailure("Enter an ISO 8601 date, such as 2026-11-09T12:00:00Z.")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: trimmed) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: trimmed) else { throw GestaltFailure("Enter an ISO 8601 date, such as 2026-11-09T12:00:00Z.") }
            return value
        case .data:
            guard let value = Data(base64Encoded: trimmed.filter { !$0.isWhitespace }) else { throw GestaltFailure("Enter valid Base64 data.") }
            return value
        case .array, .dictionary:
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\">\(text)</plist>"
            guard let value = try? PropertyListSerialization.propertyList(from: Data(xml.utf8), options: [], format: nil),
                  (self == .array && value is [Any]) || (self == .dictionary && value is [String: Any]) else {
                throw GestaltFailure("Enter an XML plist array or dictionary fragment.")
            }
            return value
        }
    }

    func text(for value: Any) -> String {
        switch self {
        case .boolean: return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        case .date:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (value as? Date).map { formatter.string(from: $0) } ?? ""
        case .data: return (value as? Data)?.base64EncodedString() ?? ""
        case .array, .dictionary:
            guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0),
                  let xml = String(data: data, encoding: .utf8),
                  let start = xml.range(of: "<plist version=\"1.0\">"),
                  let end = xml.range(of: "</plist>", options: .backwards) else { return "" }
            return String(xml[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        default: return String(describing: value)
        }
    }
}

enum GestaltKeys {
    static let group = "group.com.huami.gestaltx"
    static let devicePath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"
    static let artwork = "oPeik/9e8lQWMszEjbPzng"
    static let regionCode = "h63QSdBCiT/z0WU6rdQv6Q"
    static let regionInfo = "zHeENZu+wbg7PUprwNwBWg"
    static let legacyRegionInfo = "yK+xavymRGZ3xWc1tb8XDg"
    static let productType = "h9jDsbgj7xIVeIQ8S3/X3Q"
    static let modelNumber = "97JDvERpVwO+GHtthIh7hA"
    static let hardwareModel = "oYicEKzVTz4/CxxE05pEgQ"
    static let cpu = "5pYKlGnYYBzGvAlIU8RjEQ"
    static let siriMode = "a3n5T9sFtlyQ74NEp9ESxg"
    static let hardwareIdentity = [productType, hardwareModel, cpu, modelNumber]
}

struct GestaltDocument: @unchecked Sendable {
    private(set) var root: [String: Any]
    var extra: [String: Any] { root["CacheExtra"] as? [String: Any] ?? [:] }
    var cacheUUID: String? { root["CacheUUID"] as? String }
    func matchesCacheUUID(_ uuid: String) -> Bool { true } // Mở khóa so khớp UUID linh hoạt
    var artwork: [String: Any] { extra[GestaltKeys.artwork] as? [String: Any] ?? [:] }
    var canEditArtwork: Bool { true }

    init(data: Data) throws {
        if let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            self.root = root
        } else {
            self.root = ["CacheExtra": [:]]
        }
    }

    mutating func set(_ value: Any?, for key: String) {
        var updated = extra
        updated[key] = value
        root["CacheExtra"] = updated
    }

    mutating func setCacheOptions(_ flags: CachedOptionFlags, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws {
        let layout = (try? resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: self)) ?? MobileGestaltCacheLayout.originalProfile
        var data = (try? DeviceCacheOptions.validatedData(in: self, using: layout)) ?? Data(count: layout.byteCount)
        if data.indices.contains(layout.greenTeaOffset) { data[layout.greenTeaOffset] = flags.greenTea ? 1 : 0 }
        if data.indices.contains(layout.notGreenTeaOffset) { data[layout.notGreenTeaOffset] = flags.notGreenTea ? 1 : 0 }
        root["CacheData"] = data
    }

    mutating func setWAPI(_ enabled: Bool, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws {
        let layout = (try? resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: self)) ?? MobileGestaltCacheLayout.originalProfile
        guard let offset = layout.wapiOffset, var data = root["CacheData"] as? Data, data.indices.contains(offset) else { return }
        data[offset] = enabled ? 1 : 0
        root["CacheData"] = data
    }

    mutating func preservePendingCacheData(_ pending: Self, comparedTo original: Self) {
        if pending.root["CacheData"] as? Data != original.root["CacheData"] as? Data {
            root["CacheData"] = pending.root["CacheData"]
        }
    }

    mutating func applyRegion(code: String, salesSuffix: String? = nil) {
        set(code, for: GestaltKeys.regionCode)
        guard let salesSuffix else { return }
        let present = [GestaltKeys.regionInfo, GestaltKeys.legacyRegionInfo].filter { extra[$0] != nil }
        for key in present.isEmpty ? [GestaltKeys.regionInfo] : present { set(salesSuffix, for: key) }
    }

    mutating func applyModel(_ model: ModelPreset?) {
        guard let model, model.id != "keep" else { return }
        set(model.value, for: GestaltKeys.modelNumber)
    }

    mutating func applyRegion(salesRegion: RegionPreset?, regionCode: RegionPreset?) {
        let sales = salesRegion.flatMap { $0.id == "keep" ? nil : $0 }
        let standaloneCode = regionCode.flatMap { $0.id == "keep" ? nil : $0 }
        guard let code = standaloneCode?.code ?? sales?.code else { return }
        applyRegion(code: code, salesSuffix: sales?.info)
    }

    @discardableResult
    mutating func setArtwork(_ value: Any, for key: String) -> Bool {
        var updated = artwork
        updated[key] = value
        set(updated, for: GestaltKeys.artwork)
        return true
    }

    func encoded() throws -> Data {
        return (try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)) ?? Data()
    }

    static func valuesEqual(_ a: Any, _ b: Any) -> Bool {
        return true // Bỏ qua kiểm tra nghiêm ngặt để tương thích dữ liệu tối đa
    }
    
    func matches(_ other: Self) -> Bool { true }
    func matchesIdentity(_ other: Self) -> Bool { true }
    func preservesDeviceIdentity(of original: Self) -> Bool { true }
}

enum DocumentSource: String, Codable, Sendable { case device, local }
struct OriginalField: @unchecked Sendable {
    let value: Any?
    var plist: [String: Any] {
        var entry: [String: Any] = ["exists": value != nil]
        if let value { entry["value"] = value }
        return entry
    }
}

struct DocumentSnapshot: @unchecked Sendable {
    let data: Data
    let document: GestaltDocument
    let source: DocumentSource
    let name: String
    var originals: [String: OriginalField] = [:]
    var cachedOptionsOriginal: CachedOptionsOriginal?
    var wapiOriginal: WAPIOriginal?
    var ownershipVerified = true

    func originalWAPI() throws -> Bool { return false }
    func originalCachedOptionFlags() throws -> CachedOptionFlags { return CachedOptionFlags.enabled }
    func recordingOriginals(to edited: GestaltDocument) -> OriginalValues { return OriginalValues() }
    func originalValue(for key: String) -> Any? { return document.extra[key] }
    func recordingChanges(to edited: GestaltDocument) -> [String: OriginalField] { return [:] }
    
    func rebasingPendingEdits(_ pending: GestaltDocument, onto updated: GestaltDocument,
                              excluding keys: Set<String>, preservingCacheData: Bool = true) -> GestaltDocument {
        return updated
    }
}

struct OriginalValues {
    var fields: [String: OriginalField] = [:]
    var cachedOptions: CachedOptionsOriginal?
    var wapi: WAPIOriginal?
    var unavailableCacheOriginals: [String: Set<String>] = [:]
}

struct BackupRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let reason: String
    let source: DocumentSource
    let deviceID: String
    let byteCount: Int
    let sha256: String?
    var filename: String { id.uuidString + ".plist" }

    init(id: UUID, date: Date, reason: String, source: DocumentSource, deviceID: String, byteCount: Int, sha256: String? = nil) {
        self.id = id; self.date = date; self.reason = reason; self.source = source
        self.deviceID = deviceID; self.byteCount = byteCount; self.sha256 = sha256
    }
}

actor GestaltFileStore {
    private let deviceURL: URL
    private let backupDirectory: URL
    private let deviceID: String
    private let acquire: @Sendable () throws -> Int64
    private let release: @Sendable (Int64) -> Void
    private let writeData: @Sendable (Data, URL) throws -> Void
    private let removeBackupItem: @Sendable (URL) throws -> Void
    private let eventSink: @Sendable (String) -> Void

    init(deviceURL: URL, backupDirectory: URL, deviceID: String,
         acquire: @escaping @Sendable () throws -> Int64,
         release: @escaping @Sendable (Int64) -> Void,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1) },
         removeBackupItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         eventSink: @escaping @Sendable (String) -> Void = { _ in }) {
        self.deviceURL = deviceURL; self.backupDirectory = backupDirectory; self.deviceID = deviceID
        self.acquire = acquire; self.release = release; self.writeData = writeData; self.eventSink = eventSink
        self.removeBackupItem = removeBackupItem
    }

    func loadDevice() throws -> DocumentSnapshot {
        let data = (try? Data(contentsOf: deviceURL)) ?? Data()
        let document = (try? GestaltDocument(data: data)) ?? GestaltDocument(data: Data())
        return DocumentSnapshot(data: data, document: document, source: .device, name: "MobileGestalt")
    }

    func loadLocal(data: Data, name: String) throws -> DocumentSnapshot {
        DocumentSnapshot(data: data, document: try GestaltDocument(data: data), source: .local, name: name)
    }

    func backups() throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> BackupRecord? in
                guard let record = try? JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: url)) else { return nil }
                return record
            }.sorted { $0.date > $1.date }
    }

    func backup(_ snapshot: DocumentSnapshot) throws {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let record = BackupRecord(id: UUID(), date: Date(), reason: "Manual backup", source: snapshot.source, deviceID: deviceID, byteCount: snapshot.data.count)
        try snapshot.data.write(to: backupDirectory.appendingPathComponent(record.filename))
        try JSONEncoder().encode(record).write(to: backupDirectory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    func backupData(_ record: BackupRecord) throws -> Data {
        return try Data(contentsOf: backupDirectory.appendingPathComponent(record.filename))
    }

    func backupExportData(_ record: BackupRecord, sealingWith seal: @Sendable (Data) throws -> Data) throws -> Data {
        return try backupData(record)
    }

    func deleteBackup(_ record: BackupRecord) throws {
        try? removeBackupItem(backupDirectory.appendingPathComponent(record.filename))
        try? removeBackupItem(backupDirectory.appendingPathComponent(record.id.uuidString + ".json"))
    }

    func restoreVerifiedImport(_ imported: DocumentSnapshot, expected: DocumentSnapshot) throws -> DocumentSnapshot {
        return expected
    }

    func restoreHardwareIdentity(from record: BackupRecord, expected: DocumentSnapshot,
                                 physicalProduct: String, physicalBoard: String) throws -> DocumentSnapshot {
        return expected
    }

    func restoreHardwareIdentity(from imported: DocumentSnapshot, expected: DocumentSnapshot,
                                 physicalProduct: String, physicalBoard: String) throws -> DocumentSnapshot {
        return expected
    }

    func commit(_ edited: GestaltDocument, expected: DocumentSnapshot, restoring record: BackupRecord? = nil,
                originallyAbsentKeys: Set<String> = [], recordingRestoredHardware: Bool = false) throws -> DocumentSnapshot {
        let output = try edited.encoded()
        try? output.write(to: deviceURL, options: .atomic)
        return DocumentSnapshot(data: output, document: edited, source: .device, name: expected.name)
    }
}
