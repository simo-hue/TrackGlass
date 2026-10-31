import Darwin

public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func nanoseconds() -> UInt64 {
        let ticks = mach_absolute_time()
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }

    /// The process-wide wire-clock epoch: `nanoseconds()` at first use, captured once (a `static let` is
    /// initialized lazily and atomically, so any thread may be first).
    public static let wireEpochNanoseconds: UInt64 = nanoseconds()

    /// Nanoseconds since `wireEpochNanoseconds`: monotonic, safe from any thread, and never device uptime, which
    /// would identify the device across sessions (§5.10). Every outgoing header `sentAt` uses it (§4.1, §4.2).
    public static func wireNanoseconds() -> UInt64 {
        let epoch = wireEpochNanoseconds   // read first, so `now` can never precede it
        let now = nanoseconds()
        return now >= epoch ? now - epoch : 0
    }
}
