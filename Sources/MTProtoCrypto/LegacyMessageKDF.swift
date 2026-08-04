import Crypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Key derivation for the *legacy MTProto 1.0* encrypted message layer
/// (<https://core.telegram.org/mtproto/description_v1>).
///
/// 2.0 supersedes it everywhere but one place: `auth.bindTempAuthKey`'s inner
/// `encrypted_message`, which Perfect Forward Secrecy
/// (<https://core.telegram.org/api/pfs>) requires to be 1.0-encrypted with the
/// permanent key. The `legacy`-prefixed names keep it out of reach otherwise.
extension MTProtoMessageCrypto {
  /// The MTProto 1.0 `msg_key`: `SHA1(plaintext)[4..20]`. It covers the message
  /// alone — no auth-key fragment — so it doubles as its integrity tag.
  public static func legacyMessageKey(plaintext: Data) -> Data {
    let digest = Array(Insecure.SHA1.hash(data: plaintext))  // 20 bytes
    return Data(digest[4..<20])
  }

  /// The MTProto 1.0 AES-256-IGE key/IV: four SHA-1 hashes of `msg_key`
  /// interleaved with auth-key slices, per *Defining AES Key and Initialization
  /// Vector* in <https://core.telegram.org/mtproto/description_v1>.
  ///
  /// ```
  /// sha1_a = SHA1(msg_key ‖ auth_key[x   .. x+32])
  /// sha1_b = SHA1(auth_key[x+32 .. x+48] ‖ msg_key ‖ auth_key[x+48 .. x+64])
  /// sha1_c = SHA1(auth_key[x+64 .. x+96] ‖ msg_key)
  /// sha1_d = SHA1(msg_key ‖ auth_key[x+96 .. x+128])
  /// aes_key = sha1_a[0..8]  ‖ sha1_b[8..20] ‖ sha1_c[4..16]
  /// aes_iv  = sha1_a[8..20] ‖ sha1_b[0..8]  ‖ sha1_c[16..20] ‖ sha1_d[0..8]
  /// ```
  ///
  /// `direction` selects `x` (0 for client→server, 8 for server→client) by the
  /// *message's* origin, so both ends of one message use the same value.
  public static func legacyAESKeyIV(
    authKey: Data, msgKey: Data, direction: Direction
  ) -> (key: Data, iv: Data) {
    let x = direction.x
    let ak = [UInt8](authKey)
    func slice(_ lo: Int, _ hi: Int) -> Data { Data(ak[(lo + x)..<(hi + x)]) }
    func sha1(_ parts: Data...) -> [UInt8] {
      var hasher = Insecure.SHA1()
      for part in parts { hasher.update(data: part) }
      return Array(hasher.finalize())
    }

    let a = sha1(msgKey, slice(0, 32))
    let b = sha1(slice(32, 48), msgKey, slice(48, 64))
    let c = sha1(slice(64, 96), msgKey)
    let d = sha1(msgKey, slice(96, 128))

    var key = Data()
    key.append(contentsOf: a[0..<8])
    key.append(contentsOf: b[8..<20])
    key.append(contentsOf: c[4..<16])

    var iv = Data()
    iv.append(contentsOf: a[8..<20])
    iv.append(contentsOf: b[0..<8])
    iv.append(contentsOf: c[16..<20])
    iv.append(contentsOf: d[0..<8])

    return (key, iv)
  }
}
