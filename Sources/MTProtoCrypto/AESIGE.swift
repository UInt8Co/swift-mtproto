import Crypto
import CryptoExtras

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// AES-256 in **IGE** (Infinite Garble Extension) mode, which MTProto uses for
/// both `server_DH_inner_data` and the encrypted message layer.
///
/// Each block chains with the previous ciphertext *and* plaintext block, seeding
/// `c_{-1}` / `p_{-1}` from the two halves of the 32-byte IV:
///
/// ```
/// c_i = E_K(p_i ⊕ c_{i-1}) ⊕ p_{i-1}
/// p_i = D_K(c_i ⊕ p_{i-1}) ⊕ c_{i-1}
/// ```
///
/// swift-crypto does not expose IGE, so this builds on its single-block
/// `AES.permute` / `AES.inversePermute`.
public enum AESIGE {
  static let blockSize = 16

  /// Encrypts `plaintext` (whose length must be a multiple of 16) with a
  /// 32-byte `key` and 32-byte `iv`.
  public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
    try transform(plaintext, key: key, iv: iv, encrypting: true)
  }

  /// Decrypts `ciphertext` (whose length must be a multiple of 16) with a
  /// 32-byte `key` and 32-byte `iv`.
  public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
    try transform(ciphertext, key: key, iv: iv, encrypting: false)
  }

  private static func transform(
    _ input: Data, key: Data, iv: Data, encrypting: Bool
  ) throws -> Data {
    guard key.count == 32 else {
      throw MTProtoCryptoError.invalidKeySize(expected: 32, actual: key.count)
    }
    guard iv.count == 32 else {
      throw MTProtoCryptoError.invalidIVSize(expected: 32, actual: iv.count)
    }
    guard input.count % blockSize == 0 else {
      throw MTProtoCryptoError.invalidBlockAlignment(length: input.count)
    }

    let symmetricKey = SymmetricKey(data: key)
    let ivBytes = [UInt8](iv)
    // c_{-1} = iv[0..16], p_{-1} = iv[16..32].
    var prevCipher = Array(ivBytes[0..<16])
    var prevPlain = Array(ivBytes[16..<32])

    let bytes = [UInt8](input)
    var output = [UInt8]()
    output.reserveCapacity(bytes.count)

    var offset = 0
    while offset < bytes.count {
      let block = Array(bytes[offset..<offset + blockSize])
      if encrypting {
        var t = xor(block, prevCipher)
        try AES.permute(&t, key: symmetricKey)
        let cipher = xor(t, prevPlain)
        output.append(contentsOf: cipher)
        prevCipher = cipher
        prevPlain = block
      } else {
        var t = xor(block, prevPlain)
        try AES.inversePermute(&t, key: symmetricKey)
        let plain = xor(t, prevCipher)
        output.append(contentsOf: plain)
        prevCipher = block
        prevPlain = plain
      }
      offset += blockSize
    }
    return Data(output)
  }

  @inline(__always)
  private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var result = a
    for i in 0..<result.count { result[i] ^= b[i] }
    return result
  }
}
