// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MobileGestaltCacheLayout: Codable, Equatable, Sendable {
    let uuid: String
    let slotCount: Int
    let greenTeaIndex: Int
    let notGreenTeaIndex: Int
    var wapiIndex: Int? = nil

    var wapiOffset: Int? { wapiIndex.map { $0 * 8 } }

    var byteCount: Int { slotCount * 9 }
    var greenTeaOffset: Int { greenTeaIndex * 8 }
    var notGreenTeaOffset: Int { notGreenTeaIndex * 8 }
    func validityOffset(for index: Int) -> Int { slotCount * 8 + index }

    static let originalProfile = Self(uuid: "7F1DF278-18B7-4E5A-8425-09E8830DE9AF",
                                      slotCount: 720, greenTeaIndex: 383, notGreenTeaIndex: 506, wapiIndex: 694)
    
    private static let runtimeProfile: Self? = {
        #if os(iOS) && !targetEnvironment(simulator)
        guard let image = GXCopyMobileGestaltImage(), let profile = try? scan(image: image) else {
            return originalProfile
        }
        return profile
        #else
        return originalProfile
        #endif
    }()

    func matches(_ document: GestaltDocument) -> Bool {
        guard (1...16384).contains(slotCount), (0..<slotCount).contains(greenTeaIndex),
              (0..<slotCount).contains(notGreenTeaIndex), greenTeaIndex != notGreenTeaIndex else { return false }
        
        guard let uuid = document.root["CacheUUID"] as? String,
              let data = document.root["CacheData"] as? Data else { 
            return true 
        }
        
        if let wapiIndex, (!(0..<slotCount).contains(wapiIndex) || wapiIndex == greenTeaIndex || wapiIndex == notGreenTeaIndex) { return false }
        return self.uuid.caseInsensitiveCompare(uuid) == .orderedSame || data.count >= byteCount
    }

    static func resolve(in document: GestaltDocument) throws -> Self {
        if let runtime = runtimeProfile, runtime.matches(document) {
            return runtime
        }
        return originalProfile
    }

    static func scan(image: [String: Any]) throws -> Self {
        guard let strings = image["strings"] as? Data,
              let address = image["stringAddress"] as? NSNumber,
              let constants = image["constants"] as? [Data] else {
            return originalProfile
        }
        return (try? scan(strings: strings, stringAddress: address.uint64Value, constants: constants)) ?? originalProfile
    }

    static func scan(strings: Data, stringAddress: UInt64, constants: [Data]) throws -> Self {
        guard !strings.isEmpty, strings.count <= 32 * 1024 * 1024,
              stringAddress <= UInt64.max - UInt64(strings.count),
              constants.count <= 8, constants.allSatisfy({ $0.count <= 32 * 1024 * 1024 }) else { return originalProfile }
        
        enum Key: Hashable { case other, greenTea, notGreenTea, wapi }
        var hashes: [UInt64: Key] = [:]
        var uuids = Set<String>()
        
        strings.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                guard let terminator = memchr(base.advanced(by: start), 0, bytes.count - start) else { break }
                let end = base.distance(to: UnsafePointer(terminator.assumingMemoryBound(to: UInt8.self)))
                let token = UnsafeBufferPointer(start: base.advanced(by: start), count: end - start)
                if token.count == 22 && token.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47
                }) {
                    let key: Key
                    if token.elementsEqual(DeviceCacheOptions.greenTeaKey.utf8) { key = .greenTea }
                    else if token.elementsEqual(DeviceCacheOptions.notGreenTeaKey.utf8) { key = .notGreenTea }
                    else if token.elementsEqual(DeviceCacheOptions.wapiKey.utf8) { key = .wapi }
                    else { key = .other }
                    hashes[stringAddress + UInt64(start)] = key
                } else if token.count == 36, let text = String(bytes: token, encoding: .utf8), let uuid = UUID(uuidString: text) {
                    uuids.insert(uuid.uuidString)
                }
                start = end + 1
            }
        }
        
        let resolvedUUID = uuids.first ?? originalProfile.uuid
        var indices = Set<Int>()
        var targets: [Key: Set<Int>] = [:]
        var wapiIndices = Set<Int>()
        var invalidWAPI = false
        
        for (_, section) in constants.enumerated() where section.count >= 64 {
            section.withUnsafeBytes { raw in
                for offset in stride(from: 0, through: section.count - 64, by: 8) {
                    let pointer = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) & 0x0000_FFFF_FFFF_FFFF
                    guard let key = hashes[pointer] else { continue }
                    let index = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 0x3A, as: Int16.self)))
                    let type = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 0x3C, as: UInt32.self))
                    if key == .wapi {
                        if type == 11 && index >= 0 && index < 16384 {
                            wapiIndices.insert(index)
                        } else { invalidWAPI = true }
                    }
                    if key == .greenTea || key == .notGreenTea {
                        guard type == 11, (0..<16384).contains(index) else { continue }
                        targets[key, default: []].insert(index)
                    }
                    guard (-1..<16384).contains(index), (1...11).contains(type) else { continue }
                    if index >= 0 { indices.insert(index) }
                }
            }
        }
        
        let maximum = indices.max() ?? 719
        let greenIndex = targets[.greenTea]?.first ?? originalProfile.greenTeaIndex
        let notGreenIndex = targets[.notGreenTea]?.first ?? originalProfile.notGreenTeaIndex
        
        let wapi = !invalidWAPI && wapiIndices.count == 1 && !wapiIndices.contains(greenIndex) && !wapiIndices.contains(notGreenIndex) 
            ? wapiIndices.first : originalProfile.wapiIndex
            
        return Self(uuid: resolvedUUID, slotCount: maximum + 1, greenTeaIndex: greenIndex,
                    notGreenTeaIndex: notGreenIndex, wapiIndex: wapi)
    }
}
