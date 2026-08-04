import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Key derivation for the MTProto auth-key handshake's `server_DH_inner_data`
/// encryption, as specified under *Presenting proof of work; Server authentication*
/// in <https://core.telegram.org/mtproto/auth_key>.
///
/// Given the 16-byte `server_nonce` and the 32-byte `new_nonce`:
///
/// ```
/// tmp_aes_key = SHA1(new_nonce ‖ server_nonce) ‖ SHA1(server_nonce ‖ new_nonce)[0..12]
/// tmp_aes_iv  = SHA1(server_nonce ‖ new_nonce)[12..20] ‖ SHA1(new_nonce ‖ new_nonce) ‖ new_nonce[0..4]
/// ```
public enum HandshakeKDF {
  public struct KeyIV: Sendable {
    /// 32-byte AES key.
    public let key: Data
    /// 32-byte AES-IGE IV.
    public let iv: Data
  }

  public static func tmpAESKeyIV(serverNonce: Data, newNonce: Data) -> KeyIV {
    func sha1(_ parts: Data...) -> Data {
      var hasher = Insecure.SHA1()
      for part in parts { hasher.update(data: part) }
      return Data(hasher.finalize())
    }

    let a = sha1(newNonce, serverNonce)  // 20
    let b = sha1(serverNonce, newNonce)  // 20
    let c = sha1(newNonce, newNonce)  // 20

    var key = Data()
    key.append(a)
    key.append(b.prefix(12))

    var iv = Data()
    iv.append(b[b.startIndex.advanced(by: 12)..<b.startIndex.advanced(by: 20)])
    iv.append(c)
    iv.append(newNonce.prefix(4))

    return KeyIV(key: key, iv: iv)
  }
}
