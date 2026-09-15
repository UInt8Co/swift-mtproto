#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension SRP {
  /// The client half of two-step verification: turns a password and the server's
  /// challenge into the `inputCheckPasswordSRP` values, per
  /// <https://core.telegram.org/api/srp>.
  ///
  /// ``SRP/Server`` is the other half — the `B` it offers and the proof it
  /// checks; the shared group, password hash and verifier live on ``SRP`` itself.
  ///
  /// Every function is pure; the only entropy is the caller-supplied secret `a`,
  /// which is what makes a known-answer test of a login possible at all.
  public enum Client {
    /// The client's challenge answer.
    public struct Proof: Equatable, Sendable {
      /// `A := pow(g, a) mod p`, 256 bytes.
      public var a: Data
      /// `M1`, the 32-byte client proof.
      public var m1: Data
    }

    /// The values a password check is computed from, as `account.getPassword`
    /// reports them.
    public struct Challenge: Equatable, Sendable {
      public var group: SRP.Group
      public var salt1: Data
      public var salt2: Data
      /// The server's public value `B`.
      public var srpB: Data
      public var srpID: Int64

      public init(group: SRP.Group, salt1: Data, salt2: Data, srpB: Data, srpID: Int64) {
        self.group = group
        self.salt1 = salt1
        self.salt2 = salt2
        self.srpB = srpB
        self.srpID = srpID
      }
    }

    /// Answers `challenge` for `password`.
    ///
    /// `secret` is the per-login secret `a`; leave it out and 256 fresh random
    /// bytes are used. Supplying it is for tests — reusing one against a live
    /// server would leak the password to anyone who has seen an earlier exchange.
    ///
    /// Spec §"Client": `u = H(A | B)`, `x = PH2(password, salt1, salt2)`,
    /// `v = pow(g, x) mod p`, `k = H(p | g)`, `S = pow(B - k*v, a + u*x) mod p`,
    /// `M1 = H(H(p) xor H(g) | H(salt1) | H(salt2) | A | B | H(S))`.
    public static func proof(
      for password: String, challenge: Challenge, secret: Data? = nil
    ) throws -> Proof {
      let group = challenge.group
      let p = group.p
      let bBig = BigUInt(bigEndianBytes: challenge.srpB)
      // The spec requires rejecting a `B` outside (0, p): both degenerate values
      // force a session key an observer can predict.
      guard challenge.srpB.count == SRP.size, !bBig.isZero, bBig < p else {
        throw SRPError.invalidServerValue
      }
      let secret = secret ?? Data((0..<SRP.size).map { _ in UInt8.random(in: .min ... .max) })

      let aBig = BigUInt(bigEndianBytes: secret)
      let aBytes = group.gBig.power(aBig, modulus: p).bigEndianBytes(byteCount: SRP.size)

      let u = BigUInt(bigEndianBytes: SRP.h(aBytes + challenge.srpB))
      guard !u.isZero else { throw SRPError.invalidServerValue }

      let x = SRP.passwordHash(
        password: Data(password.utf8), salt1: challenge.salt1, salt2: challenge.salt2)
      let xBig = BigUInt(bigEndianBytes: x)
      let v = BigUInt(bigEndianBytes: SRP.verifier(group: group, passwordHash: x))

      // `B - k*v` in a modulus without signed arithmetic: reduce `k*v` first, then
      // add a whole `p` before subtracting so the difference never goes negative.
      let kv = (group.k * v) % p
      let base = ((bBig % p) + p - kv) % p
      let s = base.power(aBig + u * xBig, modulus: p)

      let m1 = SRP.h(
        SRP.xor(SRP.h(group.pBytes), SRP.h(group.gBytes)) + SRP.h(challenge.salt1)
          + SRP.h(challenge.salt2) + aBytes + challenge.srpB
          + SRP.h(s.bigEndianBytes(byteCount: SRP.size)))
      return Proof(a: aBytes, m1: m1)
    }
  }
}

public enum SRPError: Error, Equatable, Sendable, CustomStringConvertible {
  /// The server offered a `B` outside the range the spec allows, or a `u` of
  /// zero — either way, a challenge that cannot be answered safely.
  case invalidServerValue
  /// The account uses a password KDF this build does not implement. Telegram
  /// has only ever published one, so this means the server has moved on.
  case unsupportedPasswordAlgorithm
  /// The account has no password set, so there is nothing to check.
  case noPasswordSet

  public var description: String {
    switch self {
    case .invalidServerValue: "the server's SRP challenge is not usable"
    case .unsupportedPasswordAlgorithm: "the account uses an unsupported password algorithm"
    case .noPasswordSet: "the account has no two-step verification password"
    }
  }
}
