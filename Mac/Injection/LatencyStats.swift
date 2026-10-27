import Foundation

/// Pipeline latency histogram (SPEC §6.10): receive → post, in microseconds.
///
/// Keeps the last `capacity` samples in a preallocated ring buffer and derives
/// percentiles from a preallocated bucket histogram, so recording a sample and
/// reading percentiles never allocate. Confined to the input-pipeline queue.
struct LatencyStats {
    /// Microsecond resolution; samples at or above `bucketCount − 1` µs share the last bucket.
    static let bucketCount = 4_096
    let capacity: Int
    private var samples: [UInt32]
    private var buckets: [UInt32]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int = 1_000) {
        self.capacity = max(1, capacity)
        samples = [UInt32](repeating: 0, count: self.capacity)
        buckets = [UInt32](repeating: 0, count: Self.bucketCount)
    }

    var isEmpty: Bool { count == 0 }

    /// Records one pipeline duration. Durations longer than the histogram range are clamped.
    mutating func record(nanoseconds: UInt64) {
        let micros = UInt32(clamping: nanoseconds / 1_000)
        let bucket = Int(min(micros, UInt32(Self.bucketCount - 1)))
        if count == capacity {
            let evicted = Int(min(samples[next], UInt32(Self.bucketCount - 1)))
            buckets[evicted] &-= 1
        } else {
            count += 1
        }
        samples[next] = micros
        buckets[bucket] &+= 1
        next = (next + 1) % capacity
    }

    /// Nearest-rank percentile in microseconds (`fraction` 0…1); 0 when no sample was recorded.
    func percentileMicros(_ fraction: Double) -> UInt32 {
        guard count > 0 else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        let rank = max(1, Int((clamped * Double(count)).rounded(.up)))
        var seen = 0
        for bucket in 0..<Self.bucketCount {
            seen += Int(buckets[bucket])
            if seen >= rank { return UInt32(bucket) }
        }
        return UInt32(Self.bucketCount - 1)
    }

    var p50Micros: UInt32 { percentileMicros(0.5) }
    var p95Micros: UInt32 { percentileMicros(0.95) }

    mutating func reset() {
        for index in buckets.indices { buckets[index] = 0 }
        next = 0
        count = 0
    }
}
