import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The RSA private key the auth-key handshake's `p_q_inner_data` is encrypted to
/// (<https://core.telegram.org/mtproto/auth_key>).
///
/// MTProto uses no standard padding here: the payload is raised to the public
/// exponent modulo `n`, and recovered by a plain modular exponentiation with `d`.
/// swift-crypto only exposes OAEP, so the raw operation runs on ``BigUInt``.
///
/// Clients differ in which of the two layouts they use, so both
/// ``recoverPlaintextBlock(_:)`` ("old") and ``recoverDataFromRSAPad(_:)``
/// (RSA_PAD, summer 2021) are provided.
public struct RSAPrivateKey: Sendable {
  /// Modulus `n`.
  public let modulus: BigUInt
  /// Public exponent `e` (usually 65537).
  public let publicExponent: BigUInt
  /// Private exponent `d`.
  public let privateExponent: BigUInt
  /// Size of the modulus in bytes (256 for a 2048-bit key).
  public let modulusByteCount: Int

  public init(modulus: BigUInt, publicExponent: BigUInt, privateExponent: BigUInt) {
    self.modulus = modulus
    self.publicExponent = publicExponent
    self.privateExponent = privateExponent
    self.modulusByteCount = (modulus.bitWidth + 7) / 8
  }

  /// Builds a key from big-endian byte representations of `n`, `e`, `d`.
  public init(
    modulusBytes: some Collection<UInt8>,
    publicExponentBytes: some Collection<UInt8>,
    privateExponentBytes: some Collection<UInt8>
  ) {
    self.init(
      modulus: BigUInt(bigEndianBytes: modulusBytes),
      publicExponent: BigUInt(bigEndianBytes: publicExponentBytes),
      privateExponent: BigUInt(bigEndianBytes: privateExponentBytes))
  }

  /// Builds a key from hexadecimal big-endian representations of `n`, `e`, `d`.
  public init?(modulusHex: String, publicExponentHex: String, privateExponentHex: String) {
    guard let n = [UInt8](hex: modulusHex),
      let e = [UInt8](hex: publicExponentHex),
      let d = [UInt8](hex: privateExponentHex)
    else { return nil }
    self.init(modulusBytes: n, publicExponentBytes: e, privateExponentBytes: d)
  }

  // MARK: - Fingerprint

  /// The MTProto public-key fingerprint clients look the key up by: the low 64
  /// bits of `SHA1(bytes(n) ‖ bytes(e))`, little-endian, where `bytes(·)` is the
  /// TL `bytes` serialization of the minimal big-endian integer.
  public var fingerprint: Int64 {
    var writer = TLBytesWriter()
    writer.writeBytes(modulus.bigEndianBytes())
    writer.writeBytes(publicExponent.bigEndianBytes())
    let digest = Insecure.SHA1.hash(data: writer.data)
    let bytes = Array(digest)  // 20 bytes
    let last8 = bytes[12..<20]
    var value: UInt64 = 0
    for (i, byte) in last8.enumerated() {
      value |= UInt64(byte) << (8 * i)
    }
    return Int64(bitPattern: value)
  }

  // MARK: - Public-key PEM

  /// The PKCS#1 `RSAPublicKey` PEM (`-----BEGIN RSA PUBLIC KEY-----`) of this
  /// key's public half — the form clients handshake against.
  ///
  /// DER is `SEQUENCE { INTEGER modulus, INTEGER publicExponent }`, base64
  /// wrapped at 64 columns, no trailing newline: byte-identical to
  /// swift-crypto's `pkcs1PEMRepresentation`.
  public var pkcs1PublicKeyPEM: String {
    func derLength(_ n: Int) -> [UInt8] {
      if n < 0x80 { return [UInt8(n)] }
      var v = n
      var bytes: [UInt8] = []
      while v > 0 {
        bytes.insert(UInt8(v & 0xff), at: 0)
        v >>= 8
      }
      return [0x80 | UInt8(bytes.count)] + bytes
    }
    func derInteger(_ magnitude: [UInt8]) -> [UInt8] {
      var body = magnitude
      while body.count > 1 && body.first == 0 { body.removeFirst() }
      if let first = body.first, first & 0x80 != 0 { body.insert(0, at: 0) }  // keep positive
      return [0x02] + derLength(body.count) + body
    }
    let content =
      derInteger([UInt8](modulus.bigEndianBytes()))
      + derInteger([UInt8](publicExponent.bigEndianBytes()))
    let der = [UInt8(0x30)] + derLength(content.count) + content
    let b64 = Data(der).base64EncodedString()
    var lines: [Substring] = []
    var i = b64.startIndex
    while i < b64.endIndex {
      let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
      lines.append(b64[i..<j])
      i = j
    }
    return
      "-----BEGIN RSA PUBLIC KEY-----\n\(lines.joined(separator: "\n"))\n-----END RSA PUBLIC KEY-----"
  }

  // MARK: - Raw RSA

  /// Raw RSA private-key operation: `ciphertext^d mod n`, returning the
  /// `modulusByteCount`-byte big-endian result.
  /// This is a low-level operation; validate untrusted ciphertext first, or use
  /// the MTProto recovery methods, which enforce its 2048-bit block bounds.
  public func rawDecrypt(_ ciphertext: Data) -> Data {
    let c = BigUInt(bigEndianBytes: ciphertext)
    let m = c.power(privateExponent, modulus: modulus)
    return m.bigEndianBytes(byteCount: modulusByteCount)
  }

  /// Recovers the "old"-style plaintext block — `SHA1(data) ‖ data ‖ random`, 255
  /// bytes — from `encrypted_data`.
  ///
  /// Decode the embedded `data` (a self-delimiting `p_q_inner_data` at offset 20)
  /// to learn its length, then validate with
  /// ``verifyOldStyleHash(plaintextBlock:dataLength:)``.
  /// Returns empty data for an invalid MTProto RSA block.
  public func recoverPlaintextBlock(_ encryptedData: Data) -> Data {
    guard isValidEncryptedBlock(encryptedData) else { return Data() }
    let decrypted = rawDecrypt(encryptedData)
    guard decrypted.first == 0 else { return Data() }
    return Data(decrypted.suffix(255))
  }

  /// Recovers the **RSA_PAD** plaintext from `encrypted_data`: an AES-256-IGE /
  /// SHA-256 wrapping that keeps the block below the modulus (`rsaPad` in a
  /// client).
  ///
  /// ```
  /// key_aes_encrypted = encrypted_data^d mod n            (256 bytes, big-endian)
  /// temp_key_xor      = key_aes_encrypted[0..<32]
  /// aes_encrypted     = key_aes_encrypted[32..<256]       (224 bytes)
  /// temp_key          = temp_key_xor XOR SHA256(aes_encrypted)
  /// data_with_hash    = AES256_IGE_decrypt(aes_encrypted, key: temp_key, iv: 0)
  /// data_pad_reversed = data_with_hash[0..<192]
  /// hash              = data_with_hash[192..<224]
  /// data_with_padding = reverse(data_pad_reversed)        (192 bytes; data ‖ random)
  /// ```
  ///
  /// Returns `data_with_padding` — the embedded `p_q_inner_data` followed by
  /// random bytes — iff `SHA256(temp_key ‖ data_with_padding) == hash`, and `nil`
  /// otherwise: the block was not RSA_PAD, so try the old layout.
  public func recoverDataFromRSAPad(_ encryptedData: Data) -> Data? {
    guard isValidEncryptedBlock(encryptedData) else { return nil }
    let keyAesEncrypted = [UInt8](rawDecrypt(encryptedData))
    guard keyAesEncrypted.count == 256 else { return nil }
    let aesEncrypted = Data(keyAesEncrypted[32..<256])
    let aesHash = Array(SHA256.hash(data: aesEncrypted))
    var tempKey = Array(keyAesEncrypted[0..<32])
    for i in 0..<32 { tempKey[i] ^= aesHash[i] }

    guard
      let dataWithHash = try? AESIGE.decrypt(
        aesEncrypted, key: Data(tempKey), iv: Data(repeating: 0, count: 32))
    else { return nil }
    let dwh = [UInt8](dataWithHash)
    guard dwh.count == 224 else { return nil }
    let dataWithPadding = Data(dwh[0..<192].reversed())
    let hash = Data(dwh[192..<224])

    let expected = Data(SHA256.hash(data: Data(tempKey) + dataWithPadding))
    guard MTProtoConstantTime.equals(expected, hash) else { return nil }
    return dataWithPadding
  }

  private func isValidEncryptedBlock(_ encryptedData: Data) -> Bool {
    guard modulusByteCount == 256, encryptedData.count == 256 else { return false }
    return BigUInt(bigEndianBytes: encryptedData) < modulus
  }

  /// Whether `d` inverts `e` for this modulus: `(probe^e)^d mod n == probe`.
  ///
  /// Worth checking at startup — a key whose `d` belongs elsewhere still
  /// advertises a correct fingerprint, and fails much further downstream.
  public func isConsistent() -> Bool {
    let probe = BigUInt(bigEndianBytes: [
      0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
      0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    ])
    guard probe < modulus else { return false }  // degenerate/tiny modulus
    let cipher = probe.power(publicExponent, modulus: modulus)
    return cipher.power(privateExponent, modulus: modulus) == probe
  }

  /// Verifies that the 20-byte SHA-1 prefix of `plaintextBlock` matches
  /// `SHA1(data)`, where `data` is the `dataLength` bytes following the prefix.
  public func verifyOldStyleHash(plaintextBlock: Data, dataLength: Int) -> Bool {
    let bytes = [UInt8](plaintextBlock)
    guard dataLength >= 0, bytes.count >= 20, dataLength <= bytes.count - 20 else {
      return false
    }
    let expected = Data(bytes[0..<20])
    let data = Data(bytes[20..<20 + dataLength])
    let actual = Data(Insecure.SHA1.hash(data: data))
    return MTProtoConstantTime.equals(expected, actual)
  }
}

/// A tiny TL `bytes` serializer, just for the fingerprint computation (so this
/// module needn't depend on TLCoding).
struct TLBytesWriter {
  var data = Data()

  mutating func writeBytes(_ payload: Data) {
    let count = payload.count
    let headerSize: Int
    if count <= 253 {
      data.append(UInt8(count))
      headerSize = 1
    } else {
      data.append(0xFE)
      data.append(UInt8(truncatingIfNeeded: count))
      data.append(UInt8(truncatingIfNeeded: count >> 8))
      data.append(UInt8(truncatingIfNeeded: count >> 16))
      headerSize = 4
    }
    data.append(payload)
    let padding = (4 - (headerSize + count) % 4) % 4
    data.append(contentsOf: [UInt8](repeating: 0, count: padding))
  }
}

extension [UInt8] {
  /// Parses a hexadecimal string (no `0x`, even length) into bytes.
  init?(hex: String) {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var pendingHigh: Int? = nil
    for character in hex {
      guard let value = character.hexDigitValue else { return nil }
      if let high = pendingHigh {
        bytes.append(UInt8(high << 4 | value))
        pendingHigh = nil
      } else {
        pendingHigh = value
      }
    }
    guard pendingHigh == nil else { return nil }
    self = bytes
  }
}
