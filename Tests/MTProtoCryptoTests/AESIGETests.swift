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
