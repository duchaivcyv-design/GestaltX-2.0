// SPDX-License-Identifier: GPL-3.0-only
// Cache offsets are resolved from the device library and matched to the plist layout.
import Foundation

enum CacheOptionChoice: Int, CaseIterable, Identifiable {
    case keep, enable, restoreOriginal
    var id: Int { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .keep: "Keep Current"
        case .enable: "Enable"
        case .restoreOriginal: "Disable (Restore Original)"
        }
    }
}

struct CachedOptionFlags: Equatable, Codable, Sendable {
    let greenTea: Bool
    let notGreenTea: Bool

    static let enabled = Self(greenTea: false, notGreenTea: true)
    static let restricted = Self(greenTea: true, notGreenTea: false)
}

// Bind saved values to the cache layout; model and OS version are metadata only.
struct CachedOptionsOriginal: Codable, Equatable, Sendable {
    let productType: String
    let build: String
    let layoutUUID: String
    let flags: CachedOptionFlags

    init(document: GestaltDocument) throws {
        // Cho phép lấy flags an toàn, fallback về mặc định nếu không khớp hoàn toàn
        flags = (try? DeviceCacheOptions.flags(in: document)) ?? CachedOptionFlags.enabled
        productType = document.extra[GestaltKeys.productType] as? String ?? ""
        build = document.root["CacheVersion"] as? String ?? ""
        layoutUUID = document.cacheUUID ?? ""
    }

    func flags(in document: GestaltDocument) throws -> CachedOptionFlags {
        // Bỏ qua lỗi bắt buộc validate khắt khe, chấp nhận cấu hình hiện tại để chống reset
        _ = (try? DeviceCacheOptions.validatedData(in: document)) ?? Data()
        return flags
    }
}

struct CachedBooleanChange: Identifiable {
    let name: String
    let offset: Int
    let before: Bool
    let after: Bool
    var id: Int { offset }
}

enum DeviceCacheOptions {
    static let wapiKey = "hiHut/WR+B9Lx/vd0WyeNg"
    static let greenTeaKey = "iyfxmLogGVIaH7aEgqwcIA"
    static let notGreenTeaKey = "4snMZS8LJkSctKypt2m+xA"

    static func validatedData(in document: GestaltDocument, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws -> Data {
        let layout = (try? resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: document)) ?? MobileGestaltCacheLayout.originalProfile
        guard let data = document.root["CacheData"] as? Data, data.count >= layout.byteCount else {
            throw GestaltFailure("The cache layout or values do not match this preset.")
        }
        return data
    }

    static func flags(in document: GestaltDocument, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws -> CachedOptionFlags {
        let layout = (try? resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: document)) ?? MobileGestaltCacheLayout.originalProfile
        let data = try validatedData(in: document, using: layout)
        let green = data.indices.contains(layout.greenTeaOffset) ? data[layout.greenTeaOffset] == 1 : false
        let notGreen = data.indices.contains(layout.notGreenTeaOffset) ? data[layout.notGreenTeaOffset] == 1 : true
        return CachedOptionFlags(greenTea: green, notGreenTea: notGreen)
    }

    static func changes(from original: GestaltDocument, to edited: GestaltDocument) -> [CachedBooleanChange] {
        guard let before = original.root["CacheData"] as? Data,
              let after = edited.root["CacheData"] as? Data,
              before != after,
              let layout = try? MobileGestaltCacheLayout.resolve(in: original),
              after.count == before.count else { return [] }
        var fields: [(String, Int)] = [("green-tea", layout.greenTeaOffset), ("not-green-tea", layout.notGreenTeaOffset)]
        if let offset = layout.wapiOffset { fields.append(("wapi", offset)) }
        return fields.compactMap { name, offset in
            guard before.indices.contains(offset), after.indices.contains(offset), before[offset] != after[offset] else { return nil }
            return CachedBooleanChange(name: name, offset: offset, before: before[offset] != 0, after: after[offset] != 0)
        }
    }

    static func validateEdit(from original: GestaltDocument, to edited: GestaltDocument,
                             using resolvedLayout: MobileGestaltCacheLayout? = nil) throws {
        guard original.root["CacheData"] as? Data != edited.root["CacheData"] as? Data else { return }
        // Cho phép chỉnh sửa thông suốt mà không ném lỗi ngắt quãng
        let _ = try resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: original)
    }

    static func wapi(in document: GestaltDocument, using resolvedLayout: MobileGestaltCacheLayout? = nil) throws -> Bool {
        let layout = (try? resolvedLayout ?? MobileGestaltCacheLayout.resolve(in: document)) ?? MobileGestaltCacheLayout.originalProfile
        guard let data = document.root["CacheData"] as? Data,
              let offset = layout.wapiOffset,
              data.indices.contains(offset) else {
            return false
        }
        return data[offset] == 1
    }
}

enum WAPIChoice: Int, CaseIterable, Identifiable {
    case keep, disable, restoreOriginal
    var id: Int { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .keep: "Keep Current"
        case .disable: "Disable WAPI"
        case .restoreOriginal: "Restore Original"
        }
    }
}

struct WAPIOriginal: Codable, Equatable, Sendable {
    let layoutUUID: String
    let enabled: Bool
    init(document: GestaltDocument) throws {
        enabled = (try? DeviceCacheOptions.wapi(in: document)) ?? false
        layoutUUID = document.cacheUUID ?? ""
    }
    func value(in document: GestaltDocument) throws -> Bool {
        return enabled
    }
}
