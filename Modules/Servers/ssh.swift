import Cocoa
import Darwin
import Kit

internal enum SSHError: Error {
    case timeout
    case outputLimit
    case cancelled
    case commandFailed(String)

    var localizedDescription: String {
        switch self {
        case .timeout: return localizedString("SSH command timed out")
        case .outputLimit: return localizedString("SSH response exceeded the size limit")
        case .cancelled: return localizedString("SSH command was cancelled")
        case .commandFailed(let message): return message
        }
    }
}

internal struct SSHCommandResult {
    internal let output: String
    internal let latencyMS: Int
}

internal final class SSHClient {
    private let executablePath: String
    private let controlDirectory: URL
    private let lock = NSLock()
    private var processes: [String: Process] = [:]
    private var cancelled: Set<String> = []

    internal init(executablePath: String = "/usr/bin/ssh", controlDirectory: URL? = nil) {
        self.executablePath = executablePath
        self.controlDirectory = controlDirectory ?? URL(fileURLWithPath: "/tmp/StatsServers-\(getuid())", isDirectory: true)
    }

    internal func collect(_ config: ServerConfig, timeout: TimeInterval = 10) throws -> SSHCommandResult {
        try FileManager.default.createDirectory(at: self.controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let startedAt = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: self.executablePath)
        task.arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", "ControlPath=\(self.controlPath(for: config))",
            "--", config.sshAlias,
            "sh -s"
        ]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = error

        let exited = DispatchGroup()
        exited.enter()
        task.terminationHandler = { _ in exited.leave() }
        do {
            try task.run()
        } catch {
            task.terminationHandler = nil
            exited.leave()
            throw SSHError.commandFailed(error.localizedDescription)
        }
        self.register(task, id: config.id)
        defer { self.unregister(id: config.id) }

        let outputBuffer = LimitedBuffer(limit: 64 * 1024)
        let errorBuffer = LimitedBuffer(limit: 16 * 1024)
        let drained = DispatchGroup()
        self.drain(output.fileHandleForReading, into: outputBuffer, group: drained)
        self.drain(error.fileHandleForReading, into: errorBuffer, group: drained)

        try? input.fileHandleForWriting.write(contentsOf: Data(MetricsCommand.script.utf8))
        try? input.fileHandleForWriting.close()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            self.terminate(task)
        }
        _ = drained.wait(timeout: .now() + 2)
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? error.fileHandleForReading.close()

        if self.wasCancelled(id: config.id) { throw SSHError.cancelled }
        if timedOut { throw SSHError.timeout }
        if outputBuffer.exceeded || errorBuffer.exceeded { throw SSHError.outputLimit }
        guard task.terminationStatus == 0 else {
            let message = errorBuffer.string.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(message.isEmpty ? localizedString("SSH command failed") : String(message.prefix(500)))
        }
        return SSHCommandResult(output: outputBuffer.string, latencyMS: Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    internal func cancel(id: String) {
        self.lock.lock()
        self.cancelled.insert(id)
        let task = self.processes[id]
        self.lock.unlock()
        if let task { self.terminate(task) }
    }

    internal func cancelAll() {
        self.lock.lock()
        let tasks = self.processes
        self.cancelled.formUnion(tasks.keys)
        self.lock.unlock()
        tasks.values.forEach { self.terminate($0) }
    }

    private func controlPath(for config: ServerConfig) -> String {
        let safeID = String(config.id.filter { $0.isLetter || $0.isNumber }.prefix(16))
        return self.controlDirectory.appendingPathComponent("\(safeID.isEmpty ? "server" : safeID).sock").path
    }

    private func register(_ task: Process, id: String) {
        self.lock.lock()
        self.processes[id] = task
        self.cancelled.remove(id)
        self.lock.unlock()
    }

    private func unregister(id: String) {
        self.lock.lock()
        self.processes.removeValue(forKey: id)
        self.lock.unlock()
    }

    private func wasCancelled(id: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled.contains(id)
    }

    private func terminate(_ task: Process) {
        guard task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    private func drain(_ handle: FileHandle, into buffer: LimitedBuffer, group: DispatchGroup) {
        group.enter()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            buffer.append(data)
        }
    }
}

private final class LimitedBuffer {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var exceededValue = false

    init(limit: Int) {
        self.limit = limit
    }

    var exceeded: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.exceededValue
    }

    var string: String {
        self.lock.lock()
        defer { self.lock.unlock() }
        return String(data: self.data, encoding: .utf8) ?? ""
    }

    func append(_ chunk: Data) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let remaining = self.limit - self.data.count
        if remaining > 0 { self.data.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { self.exceededValue = true }
    }
}

internal enum MetricsCommand {
    internal static let script = """
    LC_ALL=C
    export LC_ALL
    ostype=$(uname -s 2>/dev/null || echo Unknown)
    if [ "$ostype" != "Linux" ]; then printf 'UNSUPPORTED_OS:%s\\n' "$ostype"; exit 0; fi
    cpuraw=$(awk '/^cpu / {total=0; for(i=2;i<=NF;i++) total+=$i; if(NF>=10) total-=$9+$10; printf "%d %d", total, $5+$6}' /proc/stat 2>/dev/null)
    meminfo=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2} /^SReclaimable:/{s=$2} END{if(a=="")a=f+b+c+s; printf "%d %d",t,a}' /proc/meminfo 2>/dev/null)
    disk=$(df -kP / 2>/dev/null | awk 'NR==2 {printf "%d %d",$2,$3}')
    net=$(awk 'NR>2 {gsub(/^[ \\t]+/, ""); split($0,a,":"); iface=a[1]; if(iface!="lo" && iface!~/^veth/ && iface!~/^docker/ && iface!~/^br-/ && iface!~/^virbr/ && iface!~/^cni/ && iface!~/^flannel/) {split(a[2],b); rx+=b[1]; tx+=b[9]}} END{printf "%d %d",rx,tx}' /proc/net/dev 2>/dev/null)
    host=$(hostname 2>/dev/null | tr '|:' '__')
    os=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); gsub(/[|:]/,"_",$2); print $2; exit}' /etc/os-release 2>/dev/null)
    uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)
    printf 'STATS_V1|CPURAW:%s|MEMINFO:%s|DISK:%s|NET:%s|HOST:%s|OS:%s|UPTIME:%s|LOAD:%s\\n' "$cpuraw" "$meminfo" "$disk" "$net" "$host" "$os" "$uptime" "$load"
    """
}

internal enum SSHConfigImporter {
    internal static func loadAliases(at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) throws -> [String] {
        self.aliases(from: try String(contentsOf: url, encoding: .utf8))
    }

    internal static func aliases(from contents: String) -> [String] {
        var seen: Set<String> = []
        var aliases: [String] = []
        for line in contents.components(separatedBy: .newlines) {
            let tokens = self.tokens(in: line)
            guard let first = tokens.first else { continue }
            let keyword = first.lowercased()
            var patterns: [String] = []
            if keyword == "host" {
                patterns = Array(tokens.dropFirst())
            } else if keyword.hasPrefix("host=") {
                patterns = [String(first.dropFirst(5))] + Array(tokens.dropFirst())
            } else {
                continue
            }
            for alias in patterns where alias != "=" && !alias.isEmpty {
                guard !alias.hasPrefix("!"), !alias.contains("*"), !alias.contains("?") else { continue }
                if seen.insert(alias).inserted { aliases.append(alias) }
            }
        }
        return aliases
    }

    internal static func newAliases(_ aliases: [String], existing: [ServerConfig]) -> [String] {
        let existing = Set(existing.map(\.sshAlias))
        return aliases.filter { !existing.contains($0) }
    }

    private static func tokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
