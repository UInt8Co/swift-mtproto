import Crypto
import CryptoExtras
import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// ``AESIGE`` against known answers and against the plain block-by-block
/// construction over swift-crypto.
struct AESIGETests {
  /// FIPS-197 Appendix C.3: with a zero IV a single IGE block is the bare cipher.
  @Test func fips197SingleBlock() throws {
    let key = Data((0..<32).map { UInt8($0) })
    let plain = Data([UInt8](hex: "00112233445566778899aabbccddeeff")!)
    let cipher = Data([UInt8](hex: "8ea2b7ca516745bfeafc49904b496089")!)
    let iv = Data(count: 32)
    #expect(try AESIGE.encrypt(plain, key: key, iv: iv) == cipher)
    #expect(try AESIGE.decrypt(cipher, key: key, iv: iv) == plain)
  }

  @Test func matchesBlockByBlockReference() throws {
    var rng = SplitMix64(seed: 0x6D74_7072_6F74_6F)
    // Encryption works in 1024-block chunks; cover a short final chunk too.
    let lengths = Array(0...40) + [255, 256, 1023, 1024, 1025, 2049, 4096]
    for (index, blocks) in (lengths + lengths).enumerated() {
      let key = rng.data(count: 32)
      let iv = rng.data(count: 32)
      let input = rng.data(count: blocks * 16)
      let cipher = try AESIGE.encrypt(input, key: key, iv: iv)
      #expect(cipher == (try referenceIGE(input, key: key, iv: iv, encrypting: true)), "\(index)")
      #expect(try AESIGE.decrypt(cipher, key: key, iv: iv) == input, "\(index)")
      // Arbitrary ciphertext, not only ciphertext this implementation produced.
      #expect(
        try AESIGE.decrypt(input, key: key, iv: iv)
          == (try referenceIGE(input, key: key, iv: iv, encrypting: false)), "\(index)")
    }
  }

  /// The span forms write the same bytes into storage the caller owns, and
  /// leave what lies past the result alone.
  @Test func spanFormsMatchTheDataForms() throws {
    var rng = SplitMix64(seed: 0x5350_414E)
    for blocks in [0, 1, 2, 3, 17, 1023, 1024, 1025, 2049] {
      let key = rng.data(count: 32)
      let iv = rng.data(count: 32)
      let input = rng.data(count: blocks * 16)
      let cipher = try AESIGE.encrypt(input, key: key, iv: iv)
      var encrypted = Data(repeating: 0xEE, count: input.count + 5)
      var decrypted = Data(repeating: 0xDD, count: input.count + 5)
      do {
        var out = encrypted.mutableBytes
        try AESIGE.encrypt(input.bytes, into: &out, key: key, iv: iv)
      }
      do {
        var out = decrypted.mutableBytes
        try AESIGE.decrypt(cipher.bytes, into: &out, key: key, iv: iv)
      }
      #expect(encrypted == cipher + Data(repeating: 0xEE, count: 5), "\(blocks)")
      #expect(decrypted == input + Data(repeating: 0xDD, count: 5), "\(blocks)")
    }
    #expect(
      Self.spanFailure(length: 17, keyLength: 32, ivLength: 32)
        == .invalidBlockAlignment(length: 17))
    #expect(
      Self.spanFailure(length: 16, keyLength: 31, ivLength: 32)
        == .invalidKeySize(expected: 32, actual: 31))
    #expect(
      Self.spanFailure(length: 16, keyLength: 32, ivLength: 33)
        == .invalidIVSize(expected: 32, actual: 33))
  }

  /// What both span forms throw for these lengths; `nil` when either accepts
  /// them or they disagree.
  private static func spanFailure(length: Int, keyLength: Int, ivLength: Int) -> MTProtoCryptoError? {
    let input = Data(count: length)
    let key = Data(count: keyLength)
    let iv = Data(count: ivLength)
    var output = Data(count: length + 16)
    var out = output.mutableBytes
    var failures: [MTProtoCryptoError] = []
    do { try AESIGE.encrypt(input.bytes, into: &out, key: key, iv: iv) } catch {
      if let error = error as? MTProtoCryptoError { failures.append(error) }
    }
    do { try AESIGE.decrypt(input.bytes, into: &out, key: key, iv: iv) } catch {
      if let error = error as? MTProtoCryptoError { failures.append(error) }
    }
    return failures.count == 2 && failures[0] == failures[1] ? failures[0] : nil
  }

  /// A plaintext handed over in pieces encrypts as it does in one piece,
  /// wherever the pieces are cut — inside a block or across a chunk.
  @Test func piecewiseEncryptionMatchesOnePiece() throws {
    var rng = SplitMix64(seed: 0x5049_4543)
    let key = rng.data(count: 32)
    let iv = rng.data(count: 32)
    for length in [16, 48, 4096, (16 << 10) + 32, (48 << 10) + 16] {
      let input = rng.data(count: length)
      let expected = try AESIGE.encrypt(input, key: key, iv: iv)
      let cuts = [0, 1, 15, 16, 17, 31, 32, 33, length / 2, length / 2 + 7, length - 1, length]
      for first in cuts where first <= length {
        for second in cuts where second >= first && second <= length {
          let (output, written) = Self.encryptInPieces(
            input, cutAt: first, second, key: key, iv: iv)
          #expect(written == length)
          #expect(output == expected, "\(length) cut at \(first), \(second)")
        }
      }
    }
  }

  private static func encryptInPieces(
    _ input: Data, cutAt first: Int, _ second: Int, key: Data, iv: Data
  ) -> (output: Data, written: Int) {
    var output = Data(count: input.count)
    var out = output.mutableBytes
    var encryptor = AESIGE.Encryptor(key: key.bytes, iv: iv.bytes)
    encryptor.update(input[..<first].bytes, into: &out)
    encryptor.update(input[first..<second].bytes, into: &out)
    encryptor.update(input[second...].bytes, into: &out)
    let written = encryptor.written
    encryptor.finish()
    return (output, written)
  }

  /// Inputs that are slices of a larger buffer start at a nonzero, unaligned
  /// index; none of the arguments may change.
  @Test(arguments: [0, 1, 7, 15])
  func acceptsUnalignedSlicesAndLeavesArgumentsIntact(misalignment: Int) throws {
    var rng = SplitMix64(seed: 7)
    let pool = rng.data(count: misalignment + 32 + 32 + (16 << 10) + 48)
    let key = pool[misalignment..<misalignment + 32]
    let iv = pool[misalignment + 32..<misalignment + 64]
    let input = pool[(misalignment + 64)...]
    let expected = try referenceIGE(Data(input), key: Data(key), iv: Data(iv), encrypting: true)
    #expect(try AESIGE.encrypt(input, key: key, iv: iv) == expected)
    let cipherPool = Data(repeating: 0xA5, count: misalignment) + expected + Data([0x5A])
    let cipherSlice = cipherPool[misalignment..<misalignment + expected.count]
    #expect(cipherSlice.startIndex == misalignment)
    #expect(try AESIGE.decrypt(cipherSlice, key: key, iv: iv) == Data(input))
    var replay = SplitMix64(seed: 7)
    #expect(pool == replay.data(count: pool.count))
    #expect(cipherPool.prefix(misalignment).allSatisfy { $0 == 0xA5 } && cipherPool.last == 0x5A)
  }

  @Test func rejectsInvalidSizes() throws {
    let block = Data(count: 16)
    #expect(throws: MTProtoCryptoError.invalidKeySize(expected: 32, actual: 16)) {
      try AESIGE.encrypt(block, key: Data(count: 16), iv: Data(count: 32))
    }
    #expect(throws: MTProtoCryptoError.invalidIVSize(expected: 32, actual: 16)) {
      try AESIGE.decrypt(block, key: Data(count: 32), iv: Data(count: 16))
    }
    #expect(throws: MTProtoCryptoError.invalidBlockAlignment(length: 15)) {
      try AESIGE.encrypt(Data(count: 15), key: Data(count: 32), iv: Data(count: 32))
    }
    #expect(try AESIGE.encrypt(Data(), key: Data(count: 32), iv: Data(count: 32)).isEmpty)
  }

  @Test func eraseClearsTheKeySchedule() {
    var schedule = AESKeySchedule()
    let key = Data(repeating: 0x5C, count: 32)
    schedule.expand(key.bytes, for: .decryption)
    let expanded = !schedule.isErased()
    schedule.erase()
    let erased = schedule.isErased()
    #expect(expanded && erased)
  }
}

/// The original implementation: one swift-crypto block permutation per block.
private func referenceIGE(_ input: Data, key: Data, iv: Data, encrypting: Bool) throws -> Data {
  let symmetricKey = SymmetricKey(data: key)
  var prevCipher = [UInt8](iv.prefix(16))
  var prevPlain = [UInt8](iv.suffix(16))
  let bytes = [UInt8](input)
  var output = [UInt8]()
  for offset in stride(from: 0, to: bytes.count, by: 16) {
    let block = Array(bytes[offset..<offset + 16])
    if encrypting {
      var t = zip(block, prevCipher).map { $0 ^ $1 }
      try AES.permute(&t, key: symmetricKey)
      let cipher = zip(t, prevPlain).map { $0 ^ $1 }
      output += cipher
      (prevCipher, prevPlain) = (cipher, block)
    } else {
      var t = zip(block, prevPlain).map { $0 ^ $1 }
      try AES.inversePermute(&t, key: symmetricKey)
      let plain = zip(t, prevCipher).map { $0 ^ $1 }
      output += plain
      (prevCipher, prevPlain) = (block, plain)
    }
  }
  return Data(output)
}

/// A seeded generator, so a failing case can be replayed.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func data(count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &self) })
  }
}
