import Foundation

enum PHB1 {
    static let magic = Data([0x50, 0x48, 0x42, 0x31]) // PHB1

    enum Flags: UInt8 {
        case delta = 0
        case keyframe = 1
        case configuration = 2
    }

    static func packet(flags: Flags, timestampUs: UInt64, payload: Data) -> Data {
        var out = Data(capacity: 20 + payload.count)
        out.append(magic)
        out.append(1) // version
        out.append(flags.rawValue)
        out.append(0)
        out.append(0)
        var ts = timestampUs.bigEndian
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}
