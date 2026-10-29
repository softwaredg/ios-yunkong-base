import Foundation

/// TVH4 framing — same wire format as PC agent `agent/VIDEO.md` (Annex-B payload).
enum TVH4 {
    static let magic = Data([0x54, 0x56, 0x48, 0x34]) // "TVH4"
    static let headerSize = 20
    static let flagKey: UInt8 = 0x01
    static let flagConfig: UInt8 = 0x02

    /// Build one TVH4 packet. `payload` must already be Annex-B (`00 00 00 01…`).
    static func build(flags: UInt8, ptsUs: UInt64, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(magic)
        out.append(flags)
        out.append(contentsOf: [0, 0, 0]) // reserved
        var ts = ptsUs.bigEndian
        withUnsafeBytes(of: &ts) { out.append(contentsOf: $0) }
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// AVCC (4-byte length NALs) → Annex-B.
    static func avccToAnnexB(_ avcc: Data) -> Data {
        var out = Data()
        var i = 0
        let start = Data([0, 0, 0, 1])
        while i + 4 <= avcc.count {
            let n =
                (Int(avcc[i]) << 24)
                | (Int(avcc[i + 1]) << 16)
                | (Int(avcc[i + 2]) << 8)
                | Int(avcc[i + 3])
            i += 4
            guard n >= 0, i + n <= avcc.count else { break }
            out.append(start)
            out.append(avcc.subdata(in: i ..< (i + n)))
            i += n
        }
        return out
    }

    /// SPS+PPS → Annex-B config payload (for flagConfig).
    static func annexBConfig(sps: Data, pps: Data) -> Data {
        var out = Data()
        let start = Data([0, 0, 0, 1])
        out.append(start)
        out.append(sps)
        out.append(start)
        out.append(pps)
        return out
    }
}
