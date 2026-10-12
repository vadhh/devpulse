import Foundation
import IOKit.ps

struct DevPulseSnapshot {
    let cpu: Int?
    let memory: Int?
    let memoryPressure: MemoryPressure
    let battery: Int?
    let onAC: Bool
    /// Plugged in *and* gaining charge (false when held at full).
    let charging: Bool
}

/// The kernel's own "is RAM a problem" signal, independent of how full it is.
enum MemoryPressure {
    case normal, warning, critical
}

/// Samples CPU, memory and battery through native Mach/IOKit calls.
///
/// No processes are spawned: a monitor that forks `top` every few seconds to
/// report CPU usage would mostly be measuring itself.
final class DevPulseMonitor {

    private let queue = DispatchQueue(
        label: "com.st4rdhoom.devpulse.monitor",
        qos: .utility
    )

    private let host = mach_host_self()

    /// CPU usage is a delta between two samples; only touched on `queue`.
    private var previousTicks: [UInt32]?

    func snapshot(completion: @escaping (DevPulseSnapshot) -> Void) {
        queue.async {
            let battery = Self.battery()

            completion(
                DevPulseSnapshot(
                    cpu: self.cpuUsage(),
                    memory: self.memoryUsage(),
                    memoryPressure: Self.memoryPressure(),
                    battery: battery?.percent,
                    onAC: battery?.onAC ?? false,
                    charging: battery?.charging ?? false
                )
            )
        }
    }

    /// Percent of non-idle ticks since the previous call. The first call only
    /// primes the baseline and returns `nil`.
    private func cpuUsage() -> Int? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3]
        defer { previousTicks = ticks }

        guard let previous = previousTicks else { return nil }

        // Counters are UInt32 and wrap; `&-` keeps the delta correct.
        let deltas = zip(ticks, previous).map { Double($0 &- $1) }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return nil }

        let idle = deltas[Int(CPU_STATE_IDLE)]
        return Int(((total - idle) / total * 100).rounded())
    }

    /// "Memory Used" as Activity Monitor defines it:
    /// app memory (internal − purgeable) + wired + compressed.
    private func memoryUsage() -> Int? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = Double(pages) * Double(vm_kernel_page_size)

        return Int((used / Double(ProcessInfo.processInfo.physicalMemory) * 100).rounded())
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        switch level {
        case 4:  return .critical
        case 2:  return .warning
        default: return .normal
        }
    }

    /// Internal battery charge, whether the Mac is plugged in, and whether it's charging.
    private static func battery() -> (percent: Int, onAC: Bool, charging: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0
            else { continue }

            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (current * 100 / max, state == kIOPSACPowerValue, charging)
        }

        return nil
    }
}
