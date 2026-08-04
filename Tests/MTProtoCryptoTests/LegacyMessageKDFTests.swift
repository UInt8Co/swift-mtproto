import Crypto
import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// Cross-checks the MTProto 1.0 ("old") message KDF against mtcute's published
/// test vectors (`packages/core/src/utils/crypto/mtproto.test.ts`), so the
/// derivation used to decrypt `auth.bindTempAuthKey`'s inner container is
/// byte-for-byte interoperable with a real client.
@Suite("Legacy (MTProto 1.0) message KDF")
struct LegacyMessageKDFTests {
  /// mtcute's fixture: the auth key is 8 repetitions of a 32-byte chunk.
  private let authKey = Data(
    repeatElement(
      hex("98cb29c6ffa89e79da695a54f572e6cb101e81c688b63a4bf73c3622dec230e0"),
      count: 8
    ).joined())
  private let msgKey = hex("25d701f2a29205526757825a99eb2d32")

  @Test func clientKeyIV() {
    let (key, iv) = MTProtoMessageCrypto.legacyAESKeyIV(
      authKey: authKey, msgKey: msgKey, direction: .fromClient)
    #expect(key == hex("1fc7b40b1d9ffbdaf4d652525a748864259698f89214abf27c0d36cb9d4cd5db"))
    #expect(iv == hex("7251fbda39ec5e6e089f15ded5963b03d6d8d0f7078898431fc7b40b1d9ffbda"))
  }

  @Test func serverKeyIV() {
    let (key, iv) = MTProtoMessageCrypto.legacyAESKeyIV(
      authKey: authKey, msgKey: msgKey, direction: .fromServer)
    #expect(key == hex("af0e4e01318654be40ab42b125909d43b44bdeef571ff1a5dfb81474ae26d467"))
    #expect(iv == hex("15c9ba6021d2c5cf04f0842540ae216a970b4eac8f46ef01af0e4e01318654be"))
  }

  @Test func messageKeyIsSHA1Slice() {
    // msg_key = SHA1(plaintext)[4..20].
    let plaintext = Data("the quick brown fox".utf8)
    let key = MTProtoMessageCrypto.legacyMessageKey(plaintext: plaintext)
    #expect(key.count == 16)
    #expect(key == sha1(plaintext).subdata(in: 4..<20))
  }
}

// MARK: - helpers

private func hex(_ string: String) -> Data {
  var bytes = [UInt8]()
  var index = string.startIndex
  while index < string.endIndex {
    let next = string.index(index, offsetBy: 2)
    bytes.append(UInt8(string[index..<next], radix: 16)!)
    index = next
  }
  return Data(bytes)
}

private func sha1(_ data: Data) -> Data {
  Data(Insecure.SHA1.hash(data: data))
}
