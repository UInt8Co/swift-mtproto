import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Cross-checks the MTProto crypto primitives against precomputed vectors: the
/// key-independent ones in `Schemas/crypto-test-vectors.json` (computed
/// independently in Deno/Node), and the key-dependent ones embedded in
/// `Schemas/test-rsa-key.json` by the generator that produced that key.
@Suite("MTProto crypto vectors")
struct MTProtoCryptoTests {
  struct Vectors: Decodable {
    struct ModPow: Decodable {
      let base: String
      let exp: String
      let mod: String
      let result: String
    }
    struct IGE: Decodable {
      let key: String
      let iv: String
      let plain: String
      let cipher: String
    }
    let modpow: ModPow
    let ige: IGE
  }

  /// The committed test key, which carries its own key-dependent vectors.
  struct KeyJSON: Decodable {
    struct RSAVector: Decodable {
      let cHex: String
      let mHex: String
    }
    let n: String
    let e: String
    let d: String
    let fingerprintInt64: String
    let pkcs1Pem: String
    let rsaVector: RSAVector
  }

  /// Repository root, derived from this source file's path.
  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // MTProtoCryptoTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
  }

  func loadVectors() throws -> Vectors {
    let url = Self.repoRoot.appendingPathComponent("Schemas/crypto-test-vectors.json")
    return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
  }

  func loadKey() throws -> KeyJSON {
    let url = Self.repoRoot.appendingPathComponent("Schemas/test-rsa-key.json")
    return try JSONDecoder().decode(KeyJSON.self, from: Data(contentsOf: url))
  }

  // MARK: - BigUInt

  @Test func modPowVector() throws {
    let v = try loadVectors().modpow
    let base = BigUInt(bigEndianBytes: [UInt8](hex: v.base)!)
    let exp = BigUInt(bigEndianBytes: [UInt8](hex: v.exp)!)
    let mod = BigUInt(bigEndianBytes: [UInt8](hex: v.mod)!)
    let result = base.power(exp, modulus: mod)
    #expect(result.bigEndianBytes() == Data([UInt8](hex: pad(v.result))!))
  }

  @Test func bigUIntArithmetic() {
    // (2^64 + 5) * (2^32 + 1) and a few divisions, checked against Swift's own
    // 128-bit-free reasoning via round-tripping.
    let a = BigUInt(bigEndianBytes: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05])
    let b = BigUInt(bigEndianBytes: [0x01, 0x00, 0x00, 0x00, 0x01])
    let product = a * b
    let (q, r) = product.quotientAndRemainder(dividingBy: b)
    #expect(q == a)
    #expect(r.isZero)
    let (q2, r2) = product.quotientAndRemainder(dividingBy: a)
    #expect(q2 == b)
    #expect(r2.isZero)
  }

  @Test func bigUIntRoundTripBytes() {
    let bytes: [UInt8] = (0..<37).map { UInt8($0 &* 7 &+ 3) }
    let value = BigUInt(bigEndianBytes: bytes)
    // Leading byte is nonzero, so the minimal form matches the input.
    #expect([UInt8](value.bigEndianBytes()) == bytes)
    #expect([UInt8](value.bigEndianBytes(byteCount: 40)) == [0, 0, 0] + bytes)
  }

  // MARK: - RSA

  @Test func rsaRawDecryptVector() throws {
    let key = try loadKey()
    let rsa = RSAPrivateKey(
      modulusHex: key.n, publicExponentHex: key.e, privateExponentHex: key.d)!
    let ciphertext = Data([UInt8](hex: key.rsaVector.cHex)!)
    let recovered = rsa.rawDecrypt(ciphertext)
    #expect([UInt8](recovered) == [UInt8](hex: key.rsaVector.mHex)!)
  }

  @Test func rsaKeyIsConsistent() throws {
    let key = try loadKey()
    let rsa = RSAPrivateKey(
      modulusHex: key.n, publicExponentHex: key.e, privateExponentHex: key.d)!
    #expect(rsa.isConsistent())
  }

  @Test func rsaKeyWithMismatchedPrivateExponentIsInconsistent() throws {
    // A key whose modulus/exponent are real but whose `d` belongs to a different
    // key: it still produces a valid fingerprint but cannot decrypt. This is the
    // failure mode `isConsistent()` exists to catch.
    let key = try loadKey()
    var tampered = [UInt8](hex: key.d)!
    tampered[tampered.count - 1] ^= 0x01  // perturb d so it no longer inverts e
    let rsa = RSAPrivateKey(
      modulusBytes: [UInt8](hex: key.n)!,
      publicExponentBytes: [UInt8](hex: key.e)!,
      privateExponentBytes: tampered)
    #expect(!rsa.isConsistent())
    // The fingerprint (n/e only) is unaffected — exactly why a bad `d` is silent
    // without this check.
    let good = RSAPrivateKey(
      modulusHex: key.n, publicExponentHex: key.e, privateExponentHex: key.d)!
    #expect(rsa.fingerprint == good.fingerprint)
  }

  @Test func rsaFingerprintVector() throws {
    let key = try loadKey()
    let expected = Int64(key.fingerprintInt64)!
    let rsa = RSAPrivateKey(
      modulusHex: key.n, publicExponentHex: key.e, privateExponentHex: key.d)!
    #expect(rsa.fingerprint == expected)
  }

  @Test func rsaPublicKeyPKCS1PEMMatchesGenerator() throws {
    // The key file embeds `pkcs1Pem` from swift-crypto; our hand-rolled DER
    // encoder must reproduce it byte-for-byte.
    let key = try loadKey()
    let rsa = RSAPrivateKey(
      modulusHex: key.n, publicExponentHex: key.e, privateExponentHex: key.d)!
    #expect(rsa.pkcs1PublicKeyPEM == key.pkcs1Pem)
  }

  // MARK: - AES-IGE

  @Test func aesIGEVector() throws {
    let v = try loadVectors().ige
    let key = Data([UInt8](hex: v.key)!)
    let iv = Data([UInt8](hex: v.iv)!)
    let plain = Data([UInt8](hex: v.plain)!)
    let expectedCipher = Data([UInt8](hex: v.cipher)!)

    let cipher = try AESIGE.encrypt(plain, key: key, iv: iv)
    #expect(cipher == expectedCipher)

    let decrypted = try AESIGE.decrypt(expectedCipher, key: key, iv: iv)
    #expect(decrypted == plain)
  }

  // MARK: - PQ

  @Test func pqChallengeFactorsArePrime() {
    let pq = PQChallenge.random()
    #expect(PQChallenge.isPrime(pq.p))
    #expect(PQChallenge.isPrime(pq.q))
    #expect(pq.p < pq.q)
    #expect(pq.pq == UInt64(pq.p) * UInt64(pq.q))
  }

  @Test func messageKeyRoundTrip() throws {
    // Only the IGE/KDF pair is checked here: the message-layer KDF is exercised
    // end-to-end against a real client elsewhere.
    let authKey = Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })
    let plaintext = Data((0..<96).map { UInt8($0) })
    let msgKey = MTProtoMessageCrypto.messageKey(
      authKey: authKey, plaintext: plaintext, direction: .fromServer)
    #expect(msgKey.count == 16)
    let (k, iv) = MTProtoMessageCrypto.aesKeyIV(
      authKey: authKey, msgKey: msgKey, direction: .fromServer)
    let cipher = try AESIGE.encrypt(plaintext, key: k, iv: iv)
    let back = try AESIGE.decrypt(cipher, key: k, iv: iv)
    #expect(back == plaintext)
  }

  /// Left-pads an odd-length hex string to an even length.
  private func pad(_ hex: String) -> String {
    hex.count % 2 == 0 ? hex : "0" + hex
  }
}
