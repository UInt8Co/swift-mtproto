import Foundation
import TLCoding
import Testing

/// A message-shaped constructor: fixed-width fields, strings, bytes, a nested
/// vector and a conditional.
@TLObject
private struct PerfMessage {
  @TLFlags var flags: UInt32 = 0
  var id: Int32
  var fromID: Int64
  var date: Int32
  var text: String
  var media: Data
  var entityOffsets: [Int64]
  @TLConditional(bit: 0) var replyTo: Int32?
}

/// TL serialization throughput. Opt-in (`MTPROTO_PERF=1`) and meaningful only
/// in a release build:
///
/// ```sh
/// MTPROTO_PERF=1 swift test -c release -Xswiftc -enable-testing --filter PerfTests
/// ```
///
/// Prints the median of several runs; never asserts on timing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MTPROTO_PERF"] != nil))
struct TLCodingPerfTests {
  @Test func vectorOfMessages() throws {
    let messages = (0..<20_000).map { i in
      PerfMessage(
        id: Int32(i), fromID: Int64(i) << 20, date: 1_700_000_000 + Int32(i),
        text: String(repeating: "message \(i) ", count: 1 + i % 8),
        media: Data(repeating: UInt8(truncatingIfNeeded: i), count: i % 300),
        entityOffsets: (0..<(i % 6)).map { Int64($0) },
        replyTo: i % 3 == 0 ? Int32(i - 1) : nil)
    }
    let ints = (0..<1_000_000).map { Int64($0) &* 0x9E37_79B9 }
    let serializedMessages = messages.tlSerialized()
    let serializedInts = ints.tlSerialized()

    let encodeMessages = medianMBps(bytes: serializedMessages.count) {
      _ = messages.tlSerialized()
    }
    let encodeInts = medianMBps(bytes: serializedInts.count) {
      _ = ints.tlSerialized()
    }
    let decodeMessages = try medianMBps(bytes: serializedMessages.count) {
      _ = try [PerfMessage](tlData: serializedMessages)
    }
    let decodeInts = try medianMBps(bytes: serializedInts.count) {
      _ = try [Int64](tlData: serializedInts)
    }
    print(
      "TL Vector<message> (\(serializedMessages.count) B): encode \(encodeMessages) MB/s, decode \(decodeMessages) MB/s"
    )
    print(
      "TL Vector<long> (\(serializedInts.count) B): encode \(encodeInts) MB/s, decode \(decodeInts) MB/s"
    )
  }
}

/// Median throughput of `runs` timed calls of `body`, each processing `bytes`.
private func medianMBps(bytes: Int, runs: Int = 7, _ body: () throws -> Void) rethrows -> Int {
  try body()  // warm-up
  var rates: [Double] = []
  for _ in 0..<runs {
    let elapsed = try ContinuousClock().measure(body)
    let seconds = Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    rates.append(Double(bytes) / seconds / 1e6)
  }
  return Int(rates.sorted()[runs / 2].rounded())
}
