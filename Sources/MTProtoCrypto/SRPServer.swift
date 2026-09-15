import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension SRP {
  /// The server half of two-step verification: the challenge a stored verifier
  /// answers with, and the check a client's `inputCheckPasswordSRP` has to pass.
  ///
  /// ``SRP/Client`` is the other half; the shared group, password hash and
  /// verifier live on ``SRP`` itself.
  public enum Server {
    // MARK: - Login challenge

    /// The server's public value `B := (k*v + pow(g, b)) mod p`, 256 bytes, where
    /// `v` is the stored verifier and `b` the fresh per-challenge server secret.
    public static func srpB(group: Group, verifier v: Data, serverSecret b: Data) -> Data {
      let vBig = BigUInt(bigEndianBytes: v)
      let gb = group.gBig.power(BigUInt(bigEndianBytes: b), modulus: group.p)
      let kv = (group.k * vBig) % group.p
      return ((kv + gb) % group.p).bigEndianBytes(byteCount: SRP.size)
    }

    /// Verifies a client's `inputCheckPasswordSRP`: recomputes the server proof
    /// `M2` from the stored verifier `v`, the challenge secret `b` and the salts,
    /// and constant-time compares it to the client's `M1`.
    ///
    /// Server session key (spec §"Server"): `S = pow(g_a * pow(v, u), b) mod p`,
    /// `M2 = H(H(p) xor H(g) | H(salt1) | H(salt2) | g_a | g_b | H(S))`. `g_a` is
    /// the client's `A` exactly as received (256 bytes); `g_b` the `B` we sent.
    public static func verifyClientProof(
      group: Group, salt1: Data, salt2: Data, verifier v: Data, serverSecret b: Data,
      a clientA: Data, m1: Data
    ) -> Bool {
      // Reject malformed wire values before allocating bignums or doing any
      // modular exponentiations. SRP hashes group elements padded to 2048 bits.
      guard clientA.count == SRP.size, m1.count == SHA256.byteCount else { return false }
      let p = group.p
      let aBig = BigUInt(bigEndianBytes: clientA)
      // Reject A outside (1, p-1): the spec/tdlib guard against the degenerate
      // values that would force a known session key.
      guard aBig > BigUInt(1), aBig < p - BigUInt(1) else { return false }

      let bBytes = srpB(group: group, verifier: v, serverSecret: b)
      let u = BigUInt(bigEndianBytes: SRP.h(clientA + bBytes))
      guard !u.isZero else { return false }

      let vBig = BigUInt(bigEndianBytes: v)
      // S = (A * v^u)^b mod p.
      let base = (aBig * vBig.power(u, modulus: p)) % p
      let s = base.power(BigUInt(bigEndianBytes: b), modulus: p)
      let kA = SRP.h(s.bigEndianBytes(byteCount: SRP.size))

      let m2 = SRP.h(
        SRP.xor(SRP.h(group.pBytes), SRP.h(group.gBytes)) + SRP.h(salt1) + SRP.h(salt2)
          + clientA + bBytes + kA)
      return MTProtoConstantTime.equals(m2, m1)
    }
  }
}
