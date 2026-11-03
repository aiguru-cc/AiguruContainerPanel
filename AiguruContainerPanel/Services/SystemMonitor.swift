//
//  SystemMonitor.swift
//  ContainerPanel
//
//  系统监控服务，获取 Container 运行环境的关键变量，
//  如 API 版本、内核版本、存储驱动、容器运行时等。
//

import Foundation
import Combine

/// 系统信息结构体
struct SystemInfo {
    let apiVersion: String
    let kernelVersion: String
    let os: String
    let architecture: String
    let storageDriver: String
    let containerRuntime: String
    let totalContainers: Int
    let runningContainers: Int
    let stoppedContainers: Int
    let totalImages: Int
    let totalVolumes: Int
    let totalMachines: Int
    let pluginsCount: Int
}

/// 系统监控器（单例）
class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    private init() { refreshSystemInfo() }

    @Published var systemInfo: SystemInfo? = nil
    @Published var isLoading = false
    @Published var errorMessage: String? = nil

    // CPU
    @Published var userCPU: Double = 0
    @Published var systemCPU: Double = 0
    @Published var idleCPU: Double = 0
    @Published var cpuCores: String = ""
    @Published var cpuModel: String = ""

    // Memory (GB)
    @Published var totalMemory: String = ""
    @Published var usedMemory: String = ""
    @Published var freeMemory: String = ""
    @Published var memoryUsedPercent: Double = 0

    // Disk (GB)
    @Published var totalDisk: String = ""
    @Published var usedDisk: String = ""
    @Published var freeDisk: String = ""
    @Published var diskUsedPercent: Double = 0

    // Network
    @Published var networkDownload: String = ""
    @Published var networkUpload: String = ""
    @Published var networkConnections: String = ""
    @Published var localIP: String? = nil

    // System
    @Published var hostname: String = ""
    @Published var osVersion: String = ""
    @Published var uptime: String = ""
    @Published var kernelVersion: String = ""

    private let cliService = CLIService.shared
    private let logService = LogService.shared
    private var cancellables = Set<AnyCancellable>()

    /// 刷新系统信息
    func refreshSystemInfo() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            // CPU info
            let cpuInfo = Self.run("/bin/sh", "-c", "top -l 1 -n 0 | head -5")
            let cpuLines = cpuInfo.split(separator: "\n")
            if cpuLines.count >= 3 {
                let loadLine = String(cpuLines[2])
                let parts = loadLine.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 3 {
                    let user = Double(parts[0]) ?? 0
                    let sys  = Double(parts[1]) ?? 0
                    let idle = Double(parts[2]) ?? 0
                    DispatchQueue.main.async {
                        self.userCPU = user; self.systemCPU = sys; self.idleCPU = idle
                    }
                }
            }
            let cores = Self.run("/usr/sbin/sysctl", "-n", "hw.ncpu")
            let model = Self.run("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string")

            // Memory
            let memTotal = Self.run("/usr/sbin/sysctl", "-n", "hw.memsize")
            let vmStats = Self.run("/usr/bin/vm_stat")
            var pageSize: UInt64 = 4096
            var freePages: UInt64 = 0
            var usedPages: UInt64 = 0
            for line in vmStats.split(separator: "\n") {
                let s = String(line)
                if s.contains("page size") { pageSize = UInt64(s.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "4096") ?? 4096 }
                if s.contains("Pages free") { freePages = UInt64(s.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0 }
                if s.contains("Pages wired") || s.contains("Pages active") {
                    usedPages += UInt64(s.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
                }
            }
            let totalBytes = UInt64(memTotal.trimmingCharacters(in: .whitespaces)) ?? 0
            let freeBytes = freePages * pageSize
            let usedBytes = totalBytes > freeBytes ? totalBytes - freeBytes : 0

            // Disk
            let diskInfo = Self.run("/bin/df", "-g", "/")
            let diskLines = diskInfo.split(separator: "\n")
            var diskTotal: UInt64 = 0, diskUsed: UInt64 = 0, diskFree: UInt64 = 0
            if diskLines.count >= 2 {
                let parts = diskLines[1].split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 4 {
                    diskTotal = UInt64(parts[1]) ?? 0
                    diskUsed  = UInt64(parts[2]) ?? 0
                    diskFree  = UInt64(parts[3]) ?? 0
                }
            }

            // Network & system
            let ip = Self.run("/usr/sbin/ifconfig", "en0").split(separator: "\n")
                .first(where: { $0.contains("inet ") })?
                .split(separator: " ").drop(while: { $0 != "inet" }).dropFirst().first.map(String.init)
            let host = Self.run("/bin/hostname")
            let osV  = Self.run("/usr/bin/sw_vers", "-productVersion")
            let up   = Self.run("/usr/bin/uptime")
            let kern = Self.run("/usr/bin/uname", "-r")

            DispatchQueue.main.async {
                self.cpuCores = cores.trimmingCharacters(in: .whitespacesAndNewlines)
                self.cpuModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

                self.totalMemory = Self.formatBytes(totalBytes)
                self.usedMemory  = Self.formatBytes(usedBytes)
                self.freeMemory  = Self.formatBytes(freeBytes)
                self.memoryUsedPercent = totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) * 100 : 0

                self.totalDisk = "\(diskTotal) GB"
                self.usedDisk  = "\(diskUsed) GB"
                self.freeDisk  = "\(diskFree) GB"
                self.diskUsedPercent = diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0

                self.localIP = ip?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.networkDownload = "-"
                self.networkUpload = "-"
                self.networkConnections = "-"

                self.hostname = host.trimmingCharacters(in: .whitespacesAndNewlines)
                self.osVersion = osV.trimmingCharacters(in: .whitespacesAndNewlines)
                self.uptime = up.trimmingCharacters(in: .whitespacesAndNewlines)
                self.kernelVersion = kern.trimmingCharacters(in: .whitespacesAndNewlines)

                self.isLoading = false
            }
        }
    }

    private static func run(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        return "\(bytes) B"
    }

    /// 获取容器常规变量（可通过 container inspect 或 config 获取）
    func fetchContainerVariables(containerName: String) -> [String: String] {
        // 实际调用 container inspect 并解析
        // 这里返回模拟数据
        return [
            "ContainerID": "abc123def456",
            "Image": "nginx:latest",
            "Created": "2026-07-27T10:00:00Z",
            "State": "running",
            "PID": "12345",
            "ExposedPorts": "80/tcp, 443/tcp",
            "Mounts": "/host/conf:/etc/nginx/conf.d"
        ]
    }
}
