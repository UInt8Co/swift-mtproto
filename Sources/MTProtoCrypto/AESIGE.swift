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
/// Only the chaining is implemented here. The block cipher is BoringSSL's, from
/// the copy swift-crypto builds; see the module overview.
public enum AESIGE {
  static let blockSize = 16
  typealias Block = SIMD16<UInt8>

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

  static func transform(_ input: Data, key: Data, iv: Data, encrypting: Bool) throws -> Data {
    guard key.count == 32 else {
      throw MTProtoCryptoError.invalidKeySize(expected: 32, actual: key.count)
    }
    guard iv.count == 32 else {
      throw MTProtoCryptoError.invalidIVSize(expected: 32, actual: iv.count)
    }
    guard input.count % blockSize == 0 else {
      throw MTProtoCryptoError.invalidBlockAlignment(length: input.count)
    }
    guard !input.isEmpty else { return Data() }

    var output = Data(count: input.count)
    var schedule = AESKeySchedule()
    defer { schedule.erase() }
    schedule.expand(key.bytes, for: encrypting ? .encryption : .decryption)
    var out = output.mutableBytes
    if encrypting {
      encrypt(input.bytes, into: &out, schedule: &schedule, iv: iv.bytes)
    } else {
      decrypt(input.bytes, into: &out, schedule: &schedule, iv: iv.bytes)
    }
    return output
  }

  /// IGE encryption is CBC encryption in disguise: with `y_i = c_i ⊕ p_{i-1}`,
  /// `y_i = E_K(x_i ⊕ y_{i-1})` for `x_i = p_i ⊕ p_{i-2}` (`p_{-2} = 0`,
  /// `y_{-1} = c_{-1}`). So BoringSSL's CBC loop does the serial part, with a
  /// linear pass on either side, a cache-sized chunk at a time.
  private static func encrypt(
    _ plain: RawSpan, into output: inout MutableRawSpan, schedule: inout AESKeySchedule,
    iv: RawSpan
  ) {
    let chunkSize = 16 << 10
    var chain = iv.load(fromByteOffset: 0, as: Block.self)  // y_{i-1}
    var older = Block()  // p_{i-2}
    var previous = iv.load(fromByteOffset: 16, as: Block.self)  // p_{i-1}
    for start in stride(from: 0, to: plain.byteCount, by: chunkSize) {
      let end = min(start + chunkSize, plain.byteCount)
      let chunkPrevious = previous
      for offset in stride(from: start, to: end, by: blockSize) {
        let block = plain.load(fromByteOffset: offset, as: Block.self)
        output.storeBytes(of: block ^ older, toByteOffset: offset, as: Block.self)
        (older, previous) = (previous, block)
      }
      schedule.cbcEncrypt(&output, range: start..<end, chain: &chain)
      var mask = chunkPrevious
      for offset in stride(from: start, to: end, by: blockSize) {
        let block = output.load(fromByteOffset: offset, as: Block.self)
        output.storeBytes(of: block ^ mask, toByteOffset: offset, as: Block.self)
        mask = plain.load(fromByteOffset: offset, as: Block.self)
      }
    }
  }

  /// IGE decryption feeds each plaintext block into the next block's input,
  /// which no BoringSSL mode does, so this is one block call per block.
  private static func decrypt(
    _ cipher: RawSpan, into output: inout MutableRawSpan, schedule: inout AESKeySchedule,
    iv: RawSpan
  ) {
    var previousCipher = iv.load(fromByteOffset: 0, as: Block.self)
    var previousPlain = iv.load(fromByteOffset: 16, as: Block.self)
    for offset in stride(from: 0, to: cipher.byteCount, by: blockSize) {
      let block = cipher.load(fromByteOffset: offset, as: Block.self)
      let plain = schedule.decrypt(block ^ previousPlain) ^ previousCipher
      output.storeBytes(of: plain, toByteOffset: offset, as: Block.self)
      (previousCipher, previousPlain) = (block, plain)
    }
  }
}

/// An AES-256 key expanded into BoringSSL's `AES_KEY`, for one direction.
///
/// Noncopyable and only ever used in place, so Swift keeps no copies of the
/// expanded key; ``erase()`` clears it with `OPENSSL_cleanse`. That is the
/// whole of the erasure: BoringSSL's hardware routines keep round keys in this
/// storage and in vector registers, which are not scrubbed, and its software
/// fallback for CPUs without AES or SIMD instructions builds an uncleared copy
/// on its own stack.
///
/// This type is the module's only pointer boundary: each `unsafe` call below
/// hands BoringSSL `storage` and the blocks for the duration of that one call.
struct AESKeySchedule: ~Copyable {
  enum Direction { case encryption, decryption }

  // `AES_KEY` is 61 32-bit words with 4-byte alignment. SIMD64 is fixed-size
  // inline storage that still deploys to macOS 15.
  private var storage = SIMD64<UInt32>()

  mutating func expand(_ key: RawSpan, for direction: Direction) {
    precondition(key.byteCount == 32)
    let status = key.withUnsafeBytes { key in
      switch direction {
      case .encryption: unsafe boringSSLAESSetEncryptKey(key.baseAddress!, 256, &storage)
      case .decryption: unsafe boringSSLAESSetDecryptKey(key.baseAddress!, 256, &storage)
      }
    }
    precondition(status == 0)
  }

  /// The inverse cipher of `block`. Requires a `.decryption` schedule.
  @inline(__always)
  mutating func decrypt(_ block: AESIGE.Block) -> AESIGE.Block {
    var input = block
    var output = AESIGE.Block()
    unsafe boringSSLAESDecrypt(&input, &output, &storage)
    return output
  }

  /// CBC-encrypts `range` of `buffer` in place from the chaining value `chain`,
  /// which is left holding the last ciphertext block. Requires an `.encryption`
  /// schedule.
  mutating func cbcEncrypt(
    _ buffer: inout MutableRawSpan, range: Range<Int>, chain: inout AESIGE.Block
  ) {
    precondition(range.lowerBound >= 0 && range.upperBound <= buffer.byteCount)
    buffer.withUnsafeMutableBytes { buffer in
      let start = unsafe buffer.baseAddress! + range.lowerBound
      unsafe boringSSLAESCBCEncrypt(start, start, range.count, &storage, &chain, 1)
    }
  }

  mutating func erase() {
    unsafe boringSSLCleanse(&storage, MemoryLayout<SIMD64<UInt32>>.size)
  }

  /// For tests.
  func isErased() -> Bool { storage == .zero }
}

// BoringSSL's raw AES API (`<openssl/aes.h>`, `<openssl/mem.h>`). swift-crypto
// builds BoringSSL into `CryptoExtras` on every platform, with its symbols
// prefixed, but does not export the module; these bind those symbols. If
// swift-crypto ever renames them, linking fails rather than anything at run time.
// BoringSSL dispatches to the CPU's AES instructions when present and to
// constant-time code otherwise.

@_extern(c, "CCryptoBoringSSL_AES_set_encrypt_key")
private func boringSSLAESSetEncryptKey(
  _ key: UnsafeRawPointer, _ bits: CUnsignedInt, _ schedule: UnsafeMutableRawPointer
) -> CInt

@_extern(c, "CCryptoBoringSSL_AES_set_decrypt_key")
private func boringSSLAESSetDecryptKey(
  _ key: UnsafeRawPointer, _ bits: CUnsignedInt, _ schedule: UnsafeMutableRawPointer
) -> CInt

@_extern(c, "CCryptoBoringSSL_AES_decrypt")
private func boringSSLAESDecrypt(
  _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer, _ schedule: UnsafeRawPointer)

@_extern(c, "CCryptoBoringSSL_AES_cbc_encrypt")
private func boringSSLAESCBCEncrypt(
  _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer, _ length: Int,
  _ schedule: UnsafeRawPointer, _ iv: UnsafeMutableRawPointer, _ encrypt: CInt)

@_extern(c, "CCryptoBoringSSL_OPENSSL_cleanse")
private func boringSSLCleanse(_ buffer: UnsafeMutableRawPointer, _ length: Int)
