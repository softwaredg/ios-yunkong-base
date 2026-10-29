import Foundation
import CommonCrypto

enum WSAccept {
    static func accept(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = magic.utf8CString.withUnsafeBufferPointer { buf in
            // exclude trailing NUL
            CC_SHA1(buf.baseAddress, CC_LONG(buf.count - 1), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
