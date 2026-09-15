import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The client half of two-step verification, checked against the server half.
///
/// `SRP` implements what a server does with a password: stores a verifier,
/// offers a `B`, and accepts or rejects the proof. That makes it an independent
/// oracle for `TelegramSRP` — the two were written from the spec separately, so
/// a proof this produces and that accepts is evidence about both, which no
/// self-consistency test could give.
@Suite struct TelegramSRPTests {
  private static let group = SRP.Group.telegram2048
  private static let password = "correct horse battery staple"
  private static let salt1 = Data(repeating: 0x11, count: 32)
  private static let salt2 = Data(repeating: 0x22, count: 32)
  /// The server's per-challenge secret `b`, and the client's `a`. Fixed so the
  /// whole exchange is a known-answer test rather than a flaky one.
  private static let serverSecret = Data(repeating: 0x33, count: 256)
  private static let clientSecret = Data(repeating: 0x44, count: 256)

  private static func challenge(
    serverSecret b: Data = serverSecret
  ) -> (challenge: TelegramSRP.Challenge, verifier: Data) {
    let x = SRP.passwordHash(password: Data(password.utf8), salt1: salt1, salt2: salt2)
    let verifier = SRP.verifier(group: group, passwordHash: x)
    let srpB = SRP.srpB(group: group, verifier: verifier, serverSecret: b)
    return (
      TelegramSRP.Challenge(
        group: group, salt1: salt1, salt2: salt2, srpB: srpB, srpID: 7),
      verifier
    )
  }

  @Test("the server accepts the proof the client computes")
  func proofVerifies() throws {
    let (challenge, verifier) = Self.challenge()
    let proof = try TelegramSRP.proof(
      for: Self.password, challenge: challenge, secret: Self.clientSecret)

    #expect(proof.a.count == TelegramSRP.size, "A travels padded to the group size")
    #expect(proof.m1.count == 32)
    #expect(
      SRP.verifyClientProof(
        group: Self.group, salt1: Self.salt1, salt2: Self.salt2, verifier: verifier,
        serverSecret: Self.serverSecret, a: proof.a, m1: proof.m1))
  }

  @Test("the server rejects the proof for a different password")
  func wrongPasswordFails() throws {
    let (challenge, verifier) = Self.challenge()
    let proof = try TelegramSRP.proof(
      for: "not the password", challenge: challenge, secret: Self.clientSecret)

    #expect(
      !SRP.verifyClientProof(
        group: Self.group, salt1: Self.salt1, salt2: Self.salt2, verifier: verifier,
        serverSecret: Self.serverSecret, a: proof.a, m1: proof.m1))
  }

  @Test("a proof is bound to the challenge it answers")
  func proofIsPerChallenge() throws {
    let (first, verifier) = Self.challenge()
    let proof = try TelegramSRP.proof(
      for: Self.password, challenge: first, secret: Self.clientSecret)
    // The same password and the same client secret, replayed against a server
    // that offered a different `B`: the session key differs, so M1 does not
    // verify. This is what stops a captured proof being reused.
    let otherSecret = Data(repeating: 0x55, count: 256)

    #expect(
      !SRP.verifyClientProof(
        group: Self.group, salt1: Self.salt1, salt2: Self.salt2, verifier: verifier,
        serverSecret: otherSecret, a: proof.a, m1: proof.m1))
  }

  @Test("the client refuses a degenerate server value")
  func rejectsBadServerValues() {
    let zero = TelegramSRP.Challenge(
      group: Self.group, salt1: Self.salt1, salt2: Self.salt2,
      srpB: Data(repeating: 0, count: 256), srpID: 1)
    #expect(throws: TelegramSRPError.invalidServerValue) {
      try TelegramSRP.proof(for: Self.password, challenge: zero, secret: Self.clientSecret)
    }

    // `B` must be shorter than the modulus; `p` itself reduces to zero.
    let modulus = TelegramSRP.Challenge(
      group: Self.group, salt1: Self.salt1, salt2: Self.salt2,
      srpB: Self.group.pBytes, srpID: 1)
    #expect(throws: TelegramSRPError.invalidServerValue) {
      try TelegramSRP.proof(for: Self.password, challenge: modulus, secret: Self.clientSecret)
    }
  }

  @Test("a fresh secret is used when none is supplied")
  func randomSecretPerProof() throws {
    let (challenge, verifier) = Self.challenge()
    let first = try TelegramSRP.proof(for: Self.password, challenge: challenge)
    let second = try TelegramSRP.proof(for: Self.password, challenge: challenge)

    #expect(first.a != second.a, "the per-login secret must not repeat")
    for proof in [first, second] {
      #expect(
        SRP.verifyClientProof(
          group: Self.group, salt1: Self.salt1, salt2: Self.salt2, verifier: verifier,
          serverSecret: Self.serverSecret, a: proof.a, m1: proof.m1))
    }
  }
}
