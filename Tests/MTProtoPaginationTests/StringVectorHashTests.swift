import Testing

@testable import MTProtoPagination

@Suite("VectorHash — string ids (MD5 → long)")
struct StringVectorHashTests {
  // Reference values: first 8 bytes of MD5(utf8), big-endian, signed; produced
  // by an independent implementation.
  @Test("longID matches the MD5 big-endian reference")
  func longIDReference() {
    #expect(VectorHash.longID(of: "👍") == 150_215_612_170_160_887)
    #expect(VectorHash.longID(of: "a") == 919_145_239_626_757_800)
    #expect(VectorHash.longID(of: "hello") == 6_719_722_671_305_337_462)
  }

  @Test("compute(strings:) folds the string longs")
  func computeStrings() {
    #expect(VectorHash.compute(strings: ["👍", "❤", "🔥"]) == 1_235_617_148_870_876_182)
  }

  @Test("String state participates in NotModified the same way")
  func stringState() {
    let emojis = ["👍", "❤"]
    let current = VectorHash.compute(strings: emojis)
    #expect(VectorHash.state(clientHash: current, overStrings: emojis) == .notModified)
    #expect(VectorHash.state(clientHash: 0, overStrings: emojis) == .modified(hash: current))
  }
}
