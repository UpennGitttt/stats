import Foundation

internal struct LinuxSample {
    internal let cpuTotal: UInt64
    internal let cpuIdle: UInt64
    internal let memoryTotal: Int64
    internal let memoryUsed: Int64
    internal let diskTotal: Int64
    internal let diskUsed: Int64
    internal let networkRead: UInt64
    internal let networkWrite: UInt64
    internal let loadAverage: [Double]
    internal let uptime: TimeInterval
    internal let osName: String?
    internal let hostname: String?
    internal let collectedAt: Date
}

internal enum LinuxParseError: Error, Equatable {
    case unsupportedOS(String)
    case invalidOutput
    case missingField(String)
    case invalidField(String)
}

internal enum LinuxMetricsParser {
    internal static func parse(_ output: String, collectedAt: Date = Date()) throws -> LinuxSample {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("UNSUPPORTED_OS:") {
            throw LinuxParseError.unsupportedOS(String(text.dropFirst("UNSUPPORTED_OS:".count)))
        }

        var fields: [String: String] = [:]
        let parts = text.components(separatedBy: "|")
        guard parts.first == "STATS_V1" else { throw LinuxParseError.invalidOutput }
        for part in parts.dropFirst() {
            guard let separator = part.firstIndex(of: ":") else { throw LinuxParseError.invalidOutput }
            let key = String(part[..<separator])
            let value = String(part[part.index(after: separator)...])
            guard !key.isEmpty, fields[key] == nil else { throw LinuxParseError.invalidOutput }
            fields[key] = value
        }

        let cpu = try self.unsignedPair(fields, key: "CPURAW")
        let memory = try self.kilobytePair(fields, key: "MEMINFO")
        let disk = try self.kilobytePair(fields, key: "DISK")
        let network = try self.unsignedPair(fields, key: "NET")
        let uptime = try self.uptime(fields)
        let load = fields["LOAD"]?.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(3).compactMap { Double($0) } ?? []

        return LinuxSample(
            cpuTotal: cpu.0,
            cpuIdle: cpu.1,
            memoryTotal: memory.0,
            memoryUsed: max(0, memory.0 - memory.1),
            diskTotal: disk.0,
            diskUsed: disk.1,
            networkRead: network.0,
            networkWrite: network.1,
            loadAverage: load,
            uptime: uptime,
            osName: self.clean(fields["OS"]),
            hostname: self.clean(fields["HOST"]),
            collectedAt: collectedAt
        )
    }

    private static func unsignedPair(_ fields: [String: String], key: String) throws -> (UInt64, UInt64) {
        let values = try self.numericValues(fields, key: key).map(UInt64.init)
        guard values.count == 2, let first = values[0], let second = values[1] else {
            throw LinuxParseError.invalidField(key)
        }
        return (first, second)
    }

    private static func kilobytePair(_ fields: [String: String], key: String) throws -> (Int64, Int64) {
        let values = try self.numericValues(fields, key: key)
        guard values.count == 2, let first = Int64(values[0]), let second = Int64(values[1]),
              first <= Int64.max / 1024, second <= Int64.max / 1024 else {
            throw LinuxParseError.invalidField(key)
        }
        return (first * 1024, second * 1024)
    }

    private static func numericValues(_ fields: [String: String], key: String) throws -> [String] {
        guard let raw = fields[key] else { throw LinuxParseError.missingField(key) }
        let values = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw LinuxParseError.invalidField(key)
        }
        return values
    }

    private static func uptime(_ fields: [String: String]) throws -> TimeInterval {
        guard let raw = fields["UPTIME"] else { throw LinuxParseError.missingField("UPTIME") }
        guard let value = Double(raw), value.isFinite, value >= 0 else { throw LinuxParseError.invalidField("UPTIME") }
        return value
    }

    private static func clean(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

internal enum SampleCalculator {
    internal static func metrics(from sample: LinuxSample, previous: LinuxSample?, latencyMS: Int?) -> ServerMetrics {
        let memoryUsage = ratio(used: sample.memoryUsed, total: sample.memoryTotal)
        let diskUsage = ratio(used: sample.diskUsed, total: sample.diskTotal)
        var cpuUsage: Double? = nil
        var networkRead: Double? = nil
        var networkWrite: Double? = nil

        if let previous {
            let elapsed = sample.uptime - previous.uptime
            if elapsed > 0 {
                if sample.cpuTotal >= previous.cpuTotal, sample.cpuIdle >= previous.cpuIdle {
                    let totalDelta = sample.cpuTotal - previous.cpuTotal
                    let idleDelta = sample.cpuIdle - previous.cpuIdle
                    if totalDelta > 0, idleDelta <= totalDelta {
                        cpuUsage = min(1, max(0, 1 - Double(idleDelta) / Double(totalDelta)))
                    }
                }
                if sample.networkRead >= previous.networkRead {
                    networkRead = Double(sample.networkRead - previous.networkRead) / elapsed
                }
                if sample.networkWrite >= previous.networkWrite {
                    networkWrite = Double(sample.networkWrite - previous.networkWrite) / elapsed
                }
            }
        }

        return ServerMetrics(
            cpuUsage: cpuUsage,
            memoryUsage: memoryUsage,
            memoryUsed: sample.memoryUsed,
            memoryTotal: sample.memoryTotal,
            diskUsage: diskUsage,
            diskUsed: sample.diskUsed,
            diskTotal: sample.diskTotal,
            networkRead: networkRead,
            networkWrite: networkWrite,
            latencyMS: latencyMS,
            loadAverage: sample.loadAverage,
            uptime: sample.uptime,
            osName: sample.osName,
            hostname: sample.hostname,
            collectedAt: sample.collectedAt
        )
    }

    private static func ratio(used: Int64, total: Int64) -> Double? {
        guard total > 0, used >= 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}
