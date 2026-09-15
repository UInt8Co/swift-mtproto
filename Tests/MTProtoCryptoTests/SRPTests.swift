import Crypto
import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Exercises the SRP-6a 2FA core (`SRP` and `SRP.Server`) end to end: a faithful
/// re-implementation of the *client* proof (mirroring tdlib's
/// `PasswordManager::get_input_check_password`) must be accepted by the server
/// verifier, and any tampering must be rejected. This is the known-answer guard
/// for the crypto the e2e (mtcute) relies on.
@Suite("SRP 2FA crypto")
struct SRPTests {
  /// A minimal reference client: given the password and the server's challenge
  /// (`B`, salts), produce `A` and `M1` exactly as the spec/tdlib prescribe.
  static let group = SRP.Group.telegram2048

  static func clientProof(
    password: Data, salt1: Data, salt2: Data, srpB: Data, a: Data
  ) -> (a: Data, m1: Data) {
    let p = group.p
    let g = group.gBig
    let size = SRP.size

    let bigA = g.power(BigUInt(bigEndianBytes: a), modulus: p).bigEndianBytes(byteCount: size)
    let x = BigUInt(
      bigEndianBytes: SRP.passwordHash(password: password, salt1: salt1, salt2: salt2))
    let v = g.power(x, modulus: p)

    let u = BigUInt(bigEndianBytes: SRP.h(bigA + srpB))
    let k = group.k
    let kv = (k * v) % p
    let bBig = BigUInt(bigEndianBytes: srpB)
    let kvMod = kv % p
    let t = bBig >= kvMod ? bBig - kvMod : (bBig + p) - kvMod
    let exp = BigUInt(bigEndianBytes: a) + u * x
    let s = t.power(exp, modulus: p).bigEndianBytes(byteCount: size)
    let kA = SRP.h(s)

    let m1 = SRP.h(
      SRP.xor(SRP.h(group.pBytes), SRP.h(group.gBytes)) + SRP.h(salt1) + SRP.h(salt2) + bigA + srpB
        + kA)
    return (bigA, m1)
  }

  /// Random bytes helper (the test's entropy needn't be deterministic).
  static func random(_ n: Int) -> Data {
    var rng = SystemRandomNumberGenerator()
    return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
  }

  @Test("client proof round-trips through the server verifier")
  func roundTrip() {
    let password = Data("correct horse battery staple".utf8)
    // Salts as they'd be stored: salt1 = server prefix + 32 client-random bytes.
    let salt1 = Self.random(8) + Self.random(32)
    let salt2 = Self.random(32)

    let x = SRP.passwordHash(password: password, salt1: salt1, salt2: salt2)
    let v = SRP.verifier(group: Self.group, passwordHash: x)
    #expect(v.count == 256)

    // Server challenge.
    let b = Self.random(256)
    let srpB = SRP.Server.srpB(group: Self.group, verifier: v, serverSecret: b)
    #expect(srpB.count == 256)

    // Client answers.
    let a = Self.random(256)
    let proof = Self.clientProof(password: password, salt1: salt1, salt2: salt2, srpB: srpB, a: a)
    #expect(proof.a.count == 256)

    #expect(
      SRP.Server.verifyClientProof(
        group: Self.group, salt1: salt1, salt2: salt2, verifier: v, serverSecret: b, a: proof.a,
        m1: proof.m1))
  }

  @Test("wrong password is rejected")
  func wrongPassword() {
    let salt1 = Self.random(40)
    let salt2 = Self.random(32)
    let v = SRP.verifier(
      group: Self.group,
      passwordHash: SRP.passwordHash(password: Data("hunter2".utf8), salt1: salt1, salt2: salt2))
    let b = Self.random(256)
    let srpB = SRP.Server.srpB(group: Self.group, verifier: v, serverSecret: b)
    let a = Self.random(256)
    // Client proves a *different* password against the same challenge.
    let proof = Self.clientProof(
      password: Data("wrong".utf8), salt1: salt1, salt2: salt2, srpB: srpB, a: a)
    #expect(
      !SRP.Server.verifyClientProof(
        group: Self.group, salt1: salt1, salt2: salt2, verifier: v, serverSecret: b, a: proof.a,
        m1: proof.m1))
  }

  @Test("a tampered M1 is rejected")
  func tamperedM1() {
    let salt1 = Self.random(40)
    let salt2 = Self.random(32)
    let v = SRP.verifier(
      group: Self.group,
      passwordHash: SRP.passwordHash(password: Data("pw".utf8), salt1: salt1, salt2: salt2))
    let b = Self.random(256)
    let srpB = SRP.Server.srpB(group: Self.group, verifier: v, serverSecret: b)
    let a = Self.random(256)
    var proof = Self.clientProof(
      password: Data("pw".utf8), salt1: salt1, salt2: salt2, srpB: srpB, a: a)
    proof.m1[0] ^= 0xFF
    #expect(
      !SRP.Server.verifyClientProof(
        group: Self.group, salt1: salt1, salt2: salt2, verifier: v, serverSecret: b, a: proof.a,
        m1: proof.m1))
  }

  @Test("degenerate A values are rejected")
  func degenerateA() {
    let salt1 = Self.random(40)
    let salt2 = Self.random(32)
    let v = SRP.verifier(
      group: Self.group,
      passwordHash: SRP.passwordHash(password: Data("pw".utf8), salt1: salt1, salt2: salt2))
    let b = Self.random(256)
    let m1 = Self.random(32)
    for bad in [BigUInt(0), BigUInt(1), Self.group.p - BigUInt(1), Self.group.p] {
      let a = bad.bigEndianBytes(byteCount: 256)
      #expect(
        !SRP.Server.verifyClientProof(
          group: Self.group, salt1: salt1, salt2: salt2, verifier: v, serverSecret: b, a: a, m1: m1)
      )
    }
  }

  @Test("the prime is the canonical 2048-bit group")
  func primeShape() {
    #expect(Self.group.pBytes.count == 256)
    #expect(Self.group.pBytes.first == 0xC7)
    #expect(Self.group.g == 3)
  }

  @Test("malformed proof widths are rejected before exponentiation")
  func malformedProofWidths() {
    let validA = BigUInt(2).bigEndianBytes(byteCount: SRP.size)
    let m1 = Data(repeating: 0, count: 32)
    for badA in [Data(), Data([2]), Data(repeating: 0, count: 1024 * 1024) + validA] {
      #expect(
        !SRP.Server.verifyClientProof(
          group: Self.group, salt1: Data(), salt2: Data(), verifier: Data(),
          serverSecret: Data(), a: badA, m1: m1))
    }
    for badM1 in [Data(), Data(repeating: 0, count: 31), Data(repeating: 0, count: 33)] {
      #expect(
        !SRP.Server.verifyClientProof(
          group: Self.group, salt1: Data(), salt2: Data(), verifier: Data(),
          serverSecret: Data(), a: validA, m1: badM1))
    }
  }

  @Test("a valid proof cannot use oversized zero-padded A")
  func oversizedAWithMatchingProof() {
    let a = Data(repeating: 0, count: 1024 * 1024) + Data([2])
    // With test-only v = 0 and b = 0 the server computes B = S = 1. Construct
    // the matching proof, including the oversized A, so a verifier without
    // the width check would actually accept it after all the unnecessary work.
    let one = BigUInt(1).bigEndianBytes(byteCount: SRP.size)
    let proof = SRP.h(
      SRP.xor(SRP.h(Self.group.pBytes), SRP.h(Self.group.gBytes))
        + SRP.h(Data()) + SRP.h(Data()) + a + one + SRP.h(one))
    #expect(
      !SRP.Server.verifyClientProof(
        group: Self.group, salt1: Data(), salt2: Data(), verifier: Data(),
        serverSecret: Data(), a: a, m1: proof))
  }
}
