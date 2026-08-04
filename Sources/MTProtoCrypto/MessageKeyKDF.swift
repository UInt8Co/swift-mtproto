import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Key derivation and identifiers for the MTProto 2.0 encrypted message layer,
/// as specified at <https://core.telegram.org/mtproto/description>.
public enum MTProtoMessageCrypto {
  /// Which side produced the message, selecting the KDF's `x` offset into the
  /// auth key. Both ends of one message use the same value.
  public enum Direction: Sendable {
    /// Client→server: `x = 0`.
    case fromClient
    /// Server→client: `x = 8`.
    case fromServer

    var x: Int {
      switch self {
      case .fromClient: return 0
      case .fromServer: return 8
      }
    }
  }

  /// The 64-bit `auth_key_id`: the low 64 bits of `SHA1(auth_key)`,
  /// little-endian.
  public static func authKeyID(_ authKey: Data) -> Int64 {
    let digest = Array(Insecure.SHA1.hash(data: authKey))  // 20 bytes
    let last8 = digest[12..<20]
    var value: UInt64 = 0
    for (i, byte) in last8.enumerated() {
      value |= UInt64(byte) << (8 * i)
    }
    return Int64(bitPattern: value)
  }

  /// The `msg_key`: the middle 128 bits of
  /// `SHA256(substr(auth_key, 88 + x, 32) ‖ plaintext)`.
  public static func messageKey(authKey: Data, plaintext: Data, direction: Direction) -> Data {
    let x = direction.x
    let keyFragment = authKey.subdata(in: (88 + x)..<(88 + x + 32))
    var hasher = SHA256()
    hasher.update(data: keyFragment)
    hasher.update(data: plaintext)
    let digest = Data(hasher.finalize())  // 32 bytes
    return digest.subdata(in: 8..<24)  // middle 128 bits
  }

  /// The AES-256-IGE key/IV derived from `msg_key` and `auth_key`.
  public static func aesKeyIV(
    authKey: Data, msgKey: Data, direction: Direction
  ) -> (key: Data, iv: Data) {
    let x = direction.x
    func sha256(_ parts: Data...) -> Data {
      var hasher = SHA256()
      for part in parts { hasher.update(data: part) }
      return Data(hasher.finalize())
    }
    let a = sha256(msgKey, authKey.subdata(in: x..<(x + 36)))
    let b = sha256(authKey.subdata(in: (40 + x)..<(40 + x + 36)), msgKey)

    var key = Data()
    key.append(a.subdata(in: 0..<8))
    key.append(b.subdata(in: 8..<24))
    key.append(a.subdata(in: 24..<32))

    var iv = Data()
    iv.append(b.subdata(in: 0..<8))
    iv.append(a.subdata(in: 8..<24))
    iv.append(b.subdata(in: 24..<32))

    return (key, iv)
  }
}
