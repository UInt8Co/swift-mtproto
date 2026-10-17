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
    var chain = iv.loadBlock(at: 0)  // y_{i-1}
    var older = Block()  // p_{i-2}
    var previous = iv.loadBlock(at: 16)  // p_{i-1}
    for start in stride(from: 0, to: plain.byteCount, by: chunkSize) {
      let end = min(start + chunkSize, plain.byteCount)
      let chunkPrevious = previous
      for offset in stride(from: start, to: end, by: blockSize) {
        let block = plain.loadBlock(at: offset)
        output.storeBlock(block ^ older, at: offset)
        (older, previous) = (previous, block)
      }
      schedule.cbcEncrypt(&output, range: start..<end, chain: &chain)
      var mask = chunkPrevious
      for offset in stride(from: start, to: end, by: blockSize) {
        output.storeBlock(output.loadBlock(at: offset) ^ mask, at: offset)
        mask = plain.loadBlock(at: offset)
      }
    }
  }

  /// IGE decryption feeds each plaintext block into the next block's input,
  /// which no BoringSSL mode does, so this is one block call per block.
  private static func decrypt(
    _ cipher: RawSpan, into output: inout MutableRawSpan, schedule: inout AESKeySchedule,
    iv: RawSpan
  ) {
    var previousCipher = iv.loadBlock(at: 0)
    var previousPlain = iv.loadBlock(at: 16)
    for offset in stride(from: 0, to: cipher.byteCount, by: blockSize) {
      let block = cipher.loadBlock(at: offset)
      var state = block ^ previousPlain
      schedule.decrypt(&state)
      state ^= previousCipher
      output.storeBlock(state, at: offset)
      (previousCipher, previousPlain) = (block, state)
    }
  }
}

extension RawSpan {
  @inline(__always)
  fileprivate func loadBlock(at offset: Int) -> AESIGE.Block {
    unsafeLoadUnaligned(fromByteOffset: offset, as: AESIGE.Block.self)
  }
}

extension MutableRawSpan {
  @inline(__always)
  fileprivate func loadBlock(at offset: Int) -> AESIGE.Block {
    unsafeLoadUnaligned(fromByteOffset: offset, as: AESIGE.Block.self)
  }

  @inline(__always)
  fileprivate mutating func storeBlock(_ block: AESIGE.Block, at offset: Int) {
    storeBytes(of: block, toByteOffset: offset, as: AESIGE.Block.self)
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
struct AESKeySchedule: ~Copyable {
  enum Direction { case encryption, decryption }

  // `AES_KEY` is 61 32-bit words. SIMD64 is fixed-size inline storage that
  // still deploys to macOS 15; InlineArray needs the Swift 6.2 runtime.
  private var storage = SIMD64<UInt32>()

  mutating func expand(_ key: RawSpan, for direction: Direction) {
    precondition(key.byteCount == 32)
    let status = key.withUnsafeBytes { key in
      withUnsafeMutableBytes(of: &storage) { schedule in
        switch direction {
        case .encryption: boringSSLAESSetEncryptKey(key.baseAddress!, 256, schedule.baseAddress!)
        case .decryption: boringSSLAESSetDecryptKey(key.baseAddress!, 256, schedule.baseAddress!)
        }
      }
    }
    precondition(status == 0)
  }

  /// Applies the inverse cipher to `block`. Requires a `.decryption` schedule.
  @inline(__always)
  mutating func decrypt(_ block: inout AESIGE.Block) {
    withUnsafeMutableBytes(of: &block) { block in
      withUnsafeBytes(of: &storage) { schedule in
        boringSSLAESDecrypt(block.baseAddress!, block.baseAddress!, schedule.baseAddress!)
      }
    }
  }

  /// CBC-encrypts `range` of `buffer` in place from the chaining value `chain`,
  /// which is left holding the last ciphertext block. Requires an `.encryption`
  /// schedule.
  mutating func cbcEncrypt(
    _ buffer: inout MutableRawSpan, range: Range<Int>, chain: inout AESIGE.Block
  ) {
    precondition(range.lowerBound >= 0 && range.upperBound <= buffer.byteCount)
    buffer.withUnsafeMutableBytes { buffer in
      withUnsafeBytes(of: &storage) { schedule in
        withUnsafeMutableBytes(of: &chain) { chain in
          let start = buffer.baseAddress! + range.lowerBound
          boringSSLAESCBCEncrypt(
            start, start, range.count, schedule.baseAddress!, chain.baseAddress!, 1)
        }
      }
    }
  }

  mutating func erase() {
    withUnsafeMutableBytes(of: &storage) { boringSSLCleanse($0.baseAddress!, $0.count) }
  }

  /// For tests; reads the storage in place rather than copying it.
  mutating func isErased() -> Bool {
    withUnsafeBytes(of: &storage) { $0.allSatisfy { $0 == 0 } }
  }
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
