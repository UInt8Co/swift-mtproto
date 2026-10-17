import Testing

@testable import MTProtoCrypto

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// AES-IGE throughput. Opt-in (`MTPROTO_PERF=1`) and meaningful only in a
/// release build:
///
/// ```sh
/// MTPROTO_PERF=1 swift test -c release -Xswiftc -enable-testing --filter PerfTests
/// ```
///
/// Prints the median of several runs; never asserts on timing.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MTPROTO_PERF"] != nil))
struct AESIGEPerfTests {
  @Test(arguments: [1 << 10, 64 << 10, 1 << 20])
  func throughput(size: Int) throws {
    let key = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
    let iv = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) })
    let plain = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let iterations = max(1, (16 << 20) / size)
    for backend in AESIGE.Backend.allCases where backend != .hardware || AESIGE.hardwareAvailable {
      let cipher = try AESIGE.transform(
        plain, key: key, iv: iv, encrypting: true, backend: backend)
      let encrypt = try medianMBps(bytes: size * iterations) {
        for _ in 0..<iterations {
          _ = try AESIGE.transform(plain, key: key, iv: iv, encrypting: true, backend: backend)
        }
      }
      let decrypt = try medianMBps(bytes: size * iterations) {
        for _ in 0..<iterations {
          _ = try AESIGE.transform(cipher, key: key, iv: iv, encrypting: false, backend: backend)
        }
      }
      print("AESIGE \(backend) \(size) B: encrypt \(encrypt) MB/s, decrypt \(decrypt) MB/s")
    }
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
