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

  /// Encrypts one message into storage the caller owns: computes `msg_key`
  /// over `head ‖ body ‖ tail`, derives the key and IV from it and writes the
  /// AES-256-IGE ciphertext to the first `head + body + tail` bytes of
  /// `output`, which must not overlap them. Returns the 16-byte `msg_key`.
  ///
  /// The plaintext comes in three pieces so that none has to be copied next to
  /// the others first: the envelope header a session writes, the message body
  /// as it was serialized, and the random padding. Only their total length has
  /// to be a multiple of 16.
  public static func encrypt(
    head: RawSpan, body: RawSpan, tail: RawSpan, into output: inout MutableRawSpan,
    authKey: Data, direction: Direction
  ) throws -> Data {
    let length = head.byteCount + body.byteCount + tail.byteCount
    guard length % AESIGE.blockSize == 0 else {
      throw MTProtoCryptoError.invalidBlockAlignment(length: length)
    }
    precondition(output.byteCount >= length, "output is shorter than the plaintext")
    var hasher = SHA256()
    hasher.update(data: authKey.subdata(in: (88 + direction.x)..<(88 + direction.x + 32)))
    head.withUnsafeBytes { unsafe hasher.update(bufferPointer: $0) }
    body.withUnsafeBytes { unsafe hasher.update(bufferPointer: $0) }
    tail.withUnsafeBytes { unsafe hasher.update(bufferPointer: $0) }
    let msgKey = Data(hasher.finalize()).subdata(in: 8..<24)
    let (key, iv) = aesKeyIV(authKey: authKey, msgKey: msgKey, direction: direction)
    var encryptor = AESIGE.Encryptor(key: key.bytes, iv: iv.bytes)
    encryptor.update(head, into: &output)
    encryptor.update(body, into: &output)
    encryptor.update(tail, into: &output)
    encryptor.finish()
    return msgKey
  }

  /// Decrypts one message into storage the caller owns and authenticates it:
  /// writes the plaintext to the first `ciphertext.byteCount` bytes of
  /// `output`, which must not overlap `ciphertext`, and returns whether its
  /// `msg_key` is `msgKey`. The comparison is constant-time. When this returns
  /// `false` the message is not authentic and what was written must not be used.
  public static func decrypt(
    _ ciphertext: RawSpan, msgKey: Data, into output: inout MutableRawSpan,
    authKey: Data, direction: Direction
  ) throws -> Bool {
    let (key, iv) = aesKeyIV(authKey: authKey, msgKey: msgKey, direction: direction)
    try AESIGE.decrypt(ciphertext, into: &output, key: key, iv: iv)
    var hasher = SHA256()
    hasher.update(data: authKey.subdata(in: (88 + direction.x)..<(88 + direction.x + 32)))
    let length = ciphertext.byteCount
    output.withUnsafeBytes {
      unsafe hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<length]))
    }
    return MTProtoConstantTime.equals(Data(hasher.finalize()).subdata(in: 8..<24), msgKey)
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
