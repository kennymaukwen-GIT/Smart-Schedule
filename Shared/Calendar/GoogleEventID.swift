import CryptoKit
import Foundation

/// Client-generated Google Calendar event ids.
///
/// Calendar API lets the client choose `id` (base32hex: a–v, 0–9, length 5–1024). Deriving it from a stable
/// seed makes inserts idempotent: a retried request after a timeout returns 409 instead of a duplicate
/// "Gym" series. That matters for plans that fan out to ~20 inserts over a flaky mobile connection.
enum GoogleEventID {
    private static let alphabet = Array("0123456789abcdefghijklmnopqrstuv")

    static func make(seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "ss" + base32hex(Array(digest.prefix(16))) // "ss" prefix is itself valid base32hex
    }

    static func newPlanID() -> String {
        String(make(seed: UUID().uuidString).prefix(12))
    }

    private static func base32hex(_ bytes: [UInt8]) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 0x1F])
                bits -= 5
            }
            buffer &= (1 << bits) - 1 // keep only unconsumed bits
        }
        if bits > 0 { output.append(alphabet[(buffer << (5 - bits)) & 0x1F]) }
        return output
    }
}
