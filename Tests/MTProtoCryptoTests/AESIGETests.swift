import CMTProtoAESIGE
import CMTProtoAESIGETestSupport
import Crypto
import CryptoExtras
import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Every ``AESIGE`` backend against known answers and against the plain
/// block-by-block construction over swift-crypto.
struct AESIGETests {
  static let backends = AESIGE.Backend.allCases.filter {
    $0 != .hardware || AESIGE.hardwareAvailable
  }

  @Test func hardwareDetectionMatchesCPU() {
    let supported = cmtproto_test_cpu_supports_aes()
    if supported >= 0 {
      #expect(
        AESIGE.hardwareAvailable == (supported == 1),
        "AES detection disagrees with the host CPU; hardware tests must not silently disappear")
      #expect((cmtproto_aes_hw_available() != 0) == (supported == 1))
      #expect(AESIGE.defaultBackend == (supported == 1 ? .hardware : .swiftCrypto))
    }
  }

  /// FIPS-197 Appendix C.3: with a zero IV a single IGE block is the bare cipher.
  @Test(arguments: backends)
  func fips197SingleBlock(backend: AESIGE.Backend) throws {
    let key = Data((0..<32).map { UInt8($0) })
    let plain = Data([UInt8](hex: "00112233445566778899aabbccddeeff")!)
    let cipher = Data([UInt8](hex: "8ea2b7ca516745bfeafc49904b496089")!)
    let iv = Data(count: 32)
    #expect(
      try AESIGE.transform(plain, key: key, iv: iv, encrypting: true, backend: backend) == cipher)
    #expect(
      try AESIGE.transform(cipher, key: key, iv: iv, encrypting: false, backend: backend) == plain)
  }

  @Test(arguments: backends)
  func matchesBlockByBlockReference(backend: AESIGE.Backend) throws {
    var rng = SplitMix64(seed: 0x6D74_7072_6F74_6F)
    let lengths = Array(0...40) + [255, 256, 1024, 4096]
    for (index, blocks) in (lengths + lengths).enumerated() {
      let key = rng.data(count: 32)
      let iv = rng.data(count: 32)
      let input = rng.data(count: blocks * 16)
      let cipher = try AESIGE.transform(
        input, key: key, iv: iv, encrypting: true, backend: backend)
      #expect(cipher == (try referenceIGE(input, key: key, iv: iv, encrypting: true)), "\(index)")
      #expect(
        try AESIGE.transform(cipher, key: key, iv: iv, encrypting: false, backend: backend)
          == input, "\(index)")
      // Arbitrary ciphertext, not only ciphertext this backend produced.
      #expect(
        try AESIGE.transform(input, key: key, iv: iv, encrypting: false, backend: backend)
          == (try referenceIGE(input, key: key, iv: iv, encrypting: false)), "\(index)")
    }
  }

  /// Inputs that are slices of a larger buffer start at a nonzero index.
  @Test(arguments: backends)
  func acceptsDataSlices(backend: AESIGE.Backend) throws {
    var rng = SplitMix64(seed: 7)
    let pool = rng.data(count: 32 + 32 + 160 + 3)
    let key = pool[1..<33]
    let iv = pool[33..<65]
    let input = pool[67..<227]
    let expected = try referenceIGE(Data(input), key: Data(key), iv: Data(iv), encrypting: true)
    #expect(
      try AESIGE.transform(input, key: key, iv: iv, encrypting: true, backend: backend)
        == expected)
    let cipherPool = Data([0xA5, 0x5A, 0xA5]) + expected + Data([0x5A])
    let cipherSlice = cipherPool[3..<3 + expected.count]
    #expect(cipherSlice.startIndex == 3)
    #expect(
      try AESIGE.transform(
        cipherSlice, key: key, iv: iv, encrypting: false, backend: backend) == Data(input))
  }

  @Test(.enabled(if: AESIGE.hardwareAvailable), arguments: [false, true], [0, 1, 7, 15])
  func cBuffersPreserveBoundariesAndIV(inPlace: Bool, misalignment: Int) throws {
    var rng = SplitMix64(seed: 42)
    for length in [0, 16, 32, 160, 65536] {
      let key = rng.data(count: 32)
      let iv = rng.data(count: 32)
      let plain = rng.data(count: length)
      let cipher = try referenceIGE(plain, key: key, iv: iv, encrypting: true)
      for encrypting in [true, false] {
        let source = encrypting ? plain : cipher
        let expected = encrypting ? cipher : plain
        let keyBuffer = GuardedBuffer(key, misalignment: misalignment)
        let ivBuffer = GuardedBuffer(iv, misalignment: misalignment)
        let input = GuardedBuffer(source, misalignment: misalignment)
        let output = inPlace ? input : GuardedBuffer(Data(count: length), misalignment: misalignment)
        #expect(Int(bitPattern: input.bytes) % 16 == misalignment)
        let transform = encrypting ? cmtproto_aes256_ige_encrypt : cmtproto_aes256_ige_decrypt
        transform(keyBuffer.bytes, ivBuffer.bytes, input.bytes, output.bytes, length)
        #expect(output.data == expected)
        #expect(keyBuffer.data == key)
        #expect(ivBuffer.data == iv)
        if !inPlace { #expect(input.data == source) }
        for buffer in [keyBuffer, ivBuffer, input, output] {
          #expect(buffer.canariesIntact)
        }
      }
    }
  }

  @Test(arguments: backends)
  func rejectsInvalidSizes(backend: AESIGE.Backend) throws {
    let block = Data(count: 16)
    #expect(throws: MTProtoCryptoError.invalidKeySize(expected: 32, actual: 16)) {
      try AESIGE.transform(block, key: Data(count: 16), iv: Data(count: 32), encrypting: true, backend: backend)
    }
    #expect(throws: MTProtoCryptoError.invalidIVSize(expected: 32, actual: 16)) {
      try AESIGE.transform(block, key: Data(count: 32), iv: Data(count: 16), encrypting: false, backend: backend)
    }
    #expect(throws: MTProtoCryptoError.invalidBlockAlignment(length: 15)) {
      try AESIGE.transform(Data(count: 15), key: Data(count: 32), iv: Data(count: 32), encrypting: true, backend: backend)
    }
    #expect(
      try AESIGE.transform(Data(), key: Data(count: 32), iv: Data(count: 32), encrypting: true, backend: backend)
        .isEmpty)
  }
}

/// Explicit alignment and guard bytes, independent of Foundation's allocation
/// and copy-on-write behavior. The C calls see the actual storage we inspect.
private final class GuardedBuffer {
  private let storage: UnsafeMutableRawPointer
  private let prefixCount: Int
  private let count: Int
  let bytes: UnsafeMutablePointer<UInt8>

  init(_ data: Data, misalignment: Int) {
    count = data.count
    prefixCount = 16 + misalignment
    storage = .allocate(byteCount: prefixCount + count + 16, alignment: 16)
    storage.initializeMemory(as: UInt8.self, repeating: 0xA5, count: prefixCount + count + 16)
    bytes = storage.advanced(by: prefixCount).assumingMemoryBound(to: UInt8.self)
    data.copyBytes(to: bytes, count: count)
  }

  deinit { storage.deallocate() }

  var data: Data { Data(bytes: bytes, count: count) }

  var canariesIntact: Bool {
    let prefix = UnsafeBufferPointer(
      start: storage.assumingMemoryBound(to: UInt8.self), count: prefixCount)
    let suffix = UnsafeBufferPointer(start: bytes.advanced(by: count), count: 16)
    return prefix.allSatisfy { $0 == 0xA5 } && suffix.allSatisfy { $0 == 0xA5 }
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
