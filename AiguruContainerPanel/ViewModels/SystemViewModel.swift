//
//  SystemViewModel.swift
//  AiguruContainerPanel
//
//  系统状态视图模型,使用真实数据:服务状态、系统信息、网络设置、内核管理等。
//  所有 UI 更新均在主线程执行。
//

import SwiftUI
import AppKit
import Combine

class SystemViewModel: ObservableObject {
    enum CleanupAction: String, CaseIterable, Identifiable {
        case danglingImages, stoppedContainers, unusedNetworks

        var id: Self { self }
        var title: String {
            switch self {
            case .danglingImages: return "清理悬空镜像"
            case .stoppedContainers: return "清理已停止容器"
            case .unusedNetworks: return "清理未使用网络"
            }
        }
        var commandKey: String {
            switch self {
            case .danglingImages: return "image.prune"
            case .stoppedContainers: return "container.prune"
            case .unusedNetworks: return "network.prune"
            }
        }
        var arguments: [String] {
            CLICommandCatalog.shared.arguments(command: commandKey)
        }
    }
    // MARK: - 服务状态
    @Published var isServiceRunning = false
    @Published var version = "未知"
    @Published var startTime = "未知"
    @Published var cliPath = AppConstants.CLI.executablePath
    @Published var dataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container").path
    @Published var installRoot = "/usr/local"
    @Published var cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container/content").path
    @Published var logsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.container/logs").path
    @Published var pluginDir = "/usr/local/libexec/container/plugins"
    @Published private(set) var directories: [ContainerDirectory] = []
    @Published private(set) var hostResources = HostResourceSnapshot(
        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: "未知",
        logicalCPUs: ProcessInfo.processInfo.activeProcessorCount,
        physicalMemory: ProcessInfo.processInfo.physicalMemory
    )

    // MARK: - 内核信息
    @Published var currentKernel: String = "未配置"
    @Published var availableKernels: [String] = []

    // MARK: - 缓存统计
    @Published var cacheSize: String = "0 MB"
    @Published var imageCount: Int = 0
    @Published var containerCount: Int = 0
    @Published var volumeCount: Int = 0

    // MARK: - 系统组件版本与磁盘占用（system version / system df）
    @Published var versionComponents: [SystemVersionComponent] = []
    @Published var diskUsageItems: [SystemDiskUsageItem] = []
    @Published var diskUsageRaw: String = ""

    // MARK: - 状态
    @Published var isLoading = false

    // MARK: - 配置编辑
    @Published var configContent = ""

    private let cliService = CLIService.shared
    private let logService = LogService.shared
    private let executor = CommandExecutor.shared
    private let machineManager = MachineManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?

    private var configPath: String {
        environmentHomeDirectory.appendingPathComponent(AppConstants.Paths.configurationRelativePath).path
    }

    /// 容器服务实际读取的配置文件（system status 的 appRoot 下）
    private var primaryConfigPath: String {
        URL(fileURLWithPath: dataRoot, isDirectory: true)
            .appendingPathComponent("config/config.toml").path
    }

    private var configurationDirectory: String {
        (configPath as NSString).deletingLastPathComponent
    }

    private var kernelDirectory: String {
        URL(fileURLWithPath: dataRoot, isDirectory: true).appendingPathComponent("kernels").path
    }

    private var environmentHomeDirectory: URL {
        if let home = executor.environment?.envVars?["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - 初始化
    init() {}

    // MARK: - 生命周期
    func startMonitoring() {
        refreshAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.Time.monitoringInterval, repeats: true) { [weak self] _ in
            self?.refreshServiceStatus()
            self?.refreshCacheStats()
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stopMonitoring() }

    // MARK: - 刷新所有数据
    func refreshAll() {
        refreshServiceStatus()
        refreshSystemInfo()
        refreshKernelInfo()
        refreshCacheStats()
        refreshCLIVersion()
        checkCLIInstalled()
        refreshVersionComponents()
        refreshDiskUsage()
        refreshResourceInventory()
    }

    // MARK: - 服务状态(真实)
    func refreshServiceStatus() {
        Task {
            let cliVersion = EnvironmentManager.shared.currentVersion
            let supportsExtendedStatus = CLICommandCatalog.shared.supportsCapability(
                "system.status.extended",
                version: cliVersion
            )
            let arguments = CLICommandCatalog.shared.arguments(
                command: "system.status",
                options: supportsExtendedStatus ? ["format": ["json"]] : [:]
            )
            let result = await executeCommand(arguments)
            DispatchQueue.main.async {
                if result.succeeded {
                    self.isServiceRunning = true
                    self.parseStatusOutput(result.output)
                } else {
                    self.isServiceRunning = false
                }
            }
        }
    }

    private func parseStatusOutput(_ output: String) {
        if parseExtendedStatusJSON(output) {
            refreshResourceInventory()
            return
        }

        var reportedLogRoot = false
        let lines = output.split(separator: "\n")
        for line in lines {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = statusValue(in: text, key: "application data root") {
                dataRoot = (value as NSString).standardizingPath
            } else if let value = statusTableValue(in: text, key: "paths.appRoot") {
                dataRoot = (value as NSString).standardizingPath
            } else if let value = statusValue(in: text, key: "application install root") {
                installRoot = (value as NSString).standardizingPath
            } else if let value = statusTableValue(in: text, key: "paths.installRoot") {
                installRoot = (value as NSString).standardizingPath
            } else if let value = statusValue(in: text, key: "application log root") {
                logsDir = (value as NSString).standardizingPath
                reportedLogRoot = true
            } else if let value = statusTableValue(in: text, key: "paths.logRoot") {
                logsDir = (value as NSString).standardizingPath
                reportedLogRoot = true
            }
            if text.contains("started") || text.contains("Started") || text.contains("is running") ||
                statusTableValue(in: text, key: "status") == "running" {
                startTime = "最近启动"
            }
        }
        alignResourcePathsWithCurrentEnvironment(preserveReportedLogRoot: reportedLogRoot)
        refreshResourceInventory()
    }

    /// 1.4.1 将 system status 扩展为结构化主机、客户端、路径和资源信息。
    private func parseExtendedStatusJSON(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }

        let paths = root["paths"] as? [String: Any]
        if let appRoot = paths?["appRoot"] as? String, !appRoot.isEmpty {
            dataRoot = (appRoot as NSString).standardizingPath
        }
        if let reportedInstallRoot = paths?["installRoot"] as? String, !reportedInstallRoot.isEmpty {
            installRoot = (reportedInstallRoot as NSString).standardizingPath
        }
        let reportedLogRoot = (paths?["logRoot"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let reportedLogRoot {
            logsDir = (reportedLogRoot as NSString).standardizingPath
        }

        if let host = root["host"] as? [String: Any] {
            hostResources = HostResourceSnapshot(
                operatingSystem: host["operatingSystem"] as? String ?? hostResources.operatingSystem,
                architecture: host["architecture"] as? String ?? hostResources.architecture,
                logicalCPUs: host["cpus"] as? Int ?? hostResources.logicalCPUs,
                physicalMemory: hostResources.physicalMemory
            )
        }
        if let resources = root["resources"] as? [String: Any] {
            containerCount = resources["containersTotal"] as? Int ?? containerCount
            imageCount = resources["images"] as? Int ?? imageCount
        }
        isServiceRunning = (root["status"] as? String)?.lowercased() == "running"
        if isServiceRunning { startTime = "最近启动" }
        alignResourcePathsWithCurrentEnvironment(preserveReportedLogRoot: reportedLogRoot != nil)
        return true
    }

    private func statusValue(in line: String, key: String) -> String? {
        guard line.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
        let value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func statusTableValue(in line: String, key: String) -> String? {
        let columns = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard columns.count == 2, columns[0].caseInsensitiveCompare(key) == .orderedSame else { return nil }
        let value = String(columns[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - 系统信息
    func refreshSystemInfo() {
        // 切换环境时先回到该环境 HOME 下的官方默认根目录；随后 system status
        // 若报告了 --app-root/--log-root，再以 CLI 的真实结果覆盖。
        dataRoot = environmentHomeDirectory
            .appendingPathComponent("Library/Application Support/com.apple.container").path
        alignResourcePathsWithCurrentEnvironment(preserveReportedLogRoot: false)
    }

    private func alignResourcePathsWithCurrentEnvironment(preserveReportedLogRoot: Bool) {
        let home = environmentHomeDirectory
        if dataRoot.isEmpty || !dataRoot.hasPrefix(home.path) {
            dataRoot = home.appendingPathComponent("Library/Application Support/com.apple.container").path
        }
        cacheDir = URL(fileURLWithPath: dataRoot, isDirectory: true).appendingPathComponent("content").path
        if !preserveReportedLogRoot {
            logsDir = URL(fileURLWithPath: dataRoot, isDirectory: true).appendingPathComponent("logs").path
        }
        let executableDirectory = (executor.currentCliPath as NSString).deletingLastPathComponent
        installRoot = (executableDirectory as NSString).deletingLastPathComponent
        pluginDir = URL(fileURLWithPath: installRoot, isDirectory: true)
            .appendingPathComponent("libexec/container/plugins").path
    }

    /// 获取主机和 Container 数据目录的真实资源状态;目录大小在后台读取,避免阻塞界面。
    func refreshResourceInventory() {
        let cliDirectoryPath = (cliPath as NSString).deletingLastPathComponent
        let dataPath = dataRoot
        let cachePath = cacheDir
        let logPath = logsDir
        let configPath = configurationDirectory
        let kernelPath = kernelDirectory
        let pluginPath = pluginDir
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            let paths: [(ContainerDirectory.Kind, String)] = [
                (.data, dataPath), (.cli, cliDirectoryPath), (.cache, cachePath), (.logs, logPath),
                (.configuration, configPath), (.kernels, kernelPath),(.plugins,pluginPath)
            ]
            let directories = paths.map { kind, path in
                ContainerDirectory(
                    kind: kind,
                    path: path,
                    exists: manager.fileExists(atPath: path),
                    sizeDescription: Self.directorySize(at: path)
                )
            }
            let architecture = Self.machineArchitecture()
            let host = HostResourceSnapshot(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture,
                logicalCPUs: ProcessInfo.processInfo.activeProcessorCount,
                physicalMemory: ProcessInfo.processInfo.physicalMemory
            )
            await MainActor.run {
                self.directories = directories
                self.hostResources = host
            }
        }
    }

    func openDirectory(_ directory: ContainerDirectory) {
        let url = URL(fileURLWithPath: directory.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            ToastManager.shared.showError("当前工作环境中该目录尚未创建")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private nonisolated static func directorySize(at path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "尚未创建" }
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                               includingPropertiesForKeys: [.fileSizeKey],
                                                               options: [.skipsHiddenFiles]) else { return "不可访问" }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private nonisolated static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "未知"
        #endif
    }

    // MARK: - CLI 版本
    func refreshCLIVersion() {
        Task {
            let result = await executeCommand(CLICommandCatalog.shared.arguments(command: "system.version"))
            DispatchQueue.main.async {
                if result.succeeded {
                    self.version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    self.version = "未知"
                }
            }
        }
    }

    // MARK: - CLI 安装/卸载（跟随当前工作环境）
    @Published var cliInstalled = false

    /// 当前工作环境实际使用的 CLI 路径（未指定时回退默认 /usr/local/bin/container）
    var currentEnvironmentCliPath: String { executor.currentCliPath }

    /// 当前工作环境名称（用于界面展示）
    var currentEnvironmentName: String { executor.environment?.name ?? "系统 Container" }

    /// 检测当前工作环境的 CLI 路径是否已存在 container 可执行文件
    func checkCLIInstalled() {
        let path = executor.currentCliPath
        cliPath = path // 同步磁盘占用/资源清单使用的路径，跟随当前环境
        alignResourcePathsWithCurrentEnvironment(preserveReportedLogRoot: false)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        cliInstalled = exists && !isDirectory.boolValue
    }

    /// 通过官方安装命令安装 CLI（installer -pkg <官方pkg> -target /），经由系统命令通道执行。
    /// 若当前工作环境使用非默认路径，安装后再将官方二进制同步到环境路径。成功返回 nil，失败返回错误描述。
    func installCLI(from pkgURL: URL, password: String) async -> String? {
        let pkgPath = pkgURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pkgPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "找不到所选安装包: \(pkgPath)"
        }
        do {
            // 官方安装命令：安装 GitHub Releases 下载的 signed installer pkg（固定安装到默认系统路径）。
            _ = try await executor.executeSystemCommandWithSudo(
                ["/usr/sbin/installer", "-pkg", pkgPath, "-target", "/"],
                password: password
            )
            // 当前环境为自定义路径时，将官方安装的二进制同步到环境路径以保持多环境独立
            let envPath = executor.currentCliPath
            if envPath != AppConstants.CLI.executablePath {
                let envDir = (envPath as NSString).deletingLastPathComponent
                _ = try await executor.executeSystemCommandWithSudo(["/bin/mkdir", "-p", envDir], password: password)
                _ = try await executor.executeSystemCommandWithSudo(
                    ["/usr/bin/install", "-m", "755", AppConstants.CLI.executablePath, envPath],
                    password: password
                )

                // PKG 固定落到官方根目录；自定义环境必须同步同一安装包的插件树，不能只换 CLI。
                // 如果新安装包未提供插件目录，则不触碰目标插件，保留上一套可用版本和 API 档位。
                let officialPluginRoot = AppConstants.CLI.officialPluginRoot
                var isPluginDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: officialPluginRoot, isDirectory: &isPluginDirectory),
                   isPluginDirectory.boolValue {
                    let environmentRoot = ((envDir as NSString).deletingLastPathComponent as NSString).standardizingPath
                    let environmentPluginRoot = URL(fileURLWithPath: environmentRoot, isDirectory: true)
                        .appendingPathComponent("libexec/container/plugins", isDirectory: true).path
                    _ = try await executor.executeSystemCommandWithSudo(["/bin/mkdir", "-p", environmentPluginRoot], password: password)
                    _ = try await executor.executeSystemCommandWithSudo(
                        ["/usr/bin/ditto", officialPluginRoot, environmentPluginRoot],
                        password: password
                    )
                }
            }
            checkCLIInstalled()
            refreshCLIVersion()
            refreshVersionComponents()
            _ = await EnvironmentManager.shared.detectCurrentEnvironment()
            _ = await KubernetesManager.shared.probeCurrentEnvironment()
            logService.log(result: CLIResult(command: "installer -pkg \(pkgPath) -target /", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "系统", operationType: "安装 CLI")
            return nil
        } catch {
            logService.log(result: CLIResult(command: "installer -pkg \(pkgPath) -target /", output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "系统", operationType: "安装 CLI 失败")
            return error.localizedDescription
        }
    }

    /// 卸载当前工作环境路径的 CLI（仅删除二进制，不动数据目录）。成功返回 nil。
    func uninstallCLI(password: String) async -> String? {
        let target = executor.currentCliPath
        do {
            _ = try await executor.executeSystemCommandWithSudo(["/bin/rm", "-f", target], password: password)
            checkCLIInstalled()
            version = "未知"
            versionComponents = []
            logService.log(result: CLIResult(command: "rm -f \(target)", output: "OK", exitCode: 0, duration: 0, mode: .async), module: "系统", operationType: "卸载 CLI")
            return nil
        } catch {
            logService.log(result: CLIResult(command: "rm -f \(target)", output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "系统", operationType: "卸载 CLI 失败")
            return error.localizedDescription
        }
    }

    // MARK: - 系统组件版本（system version --format json）
    func refreshVersionComponents() {
        Task {
            let result = await executeCommand(CLICommandCatalog.shared.arguments(command: "system.version", options: ["format": ["json"]]))
            var components: [SystemVersionComponent] = []
            if result.succeeded,
               let data = result.output.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([SystemVersionComponent].self, from: data) {
                components = decoded
            }
            DispatchQueue.main.async {
                self.versionComponents = components
            }
        }
    }

    // MARK: - 磁盘占用（system df）
    func refreshDiskUsage() {
        Task {
            let result = await executeCommand(CLICommandCatalog.shared.arguments(command: "system.df", options: ["format": ["json"]]))
            var items: [SystemDiskUsageItem] = []
            var raw = ""
            if result.succeeded {
                items = Self.parseDiskUsage(json: result.output)
            }
            if items.isEmpty {
                let table = await executeCommand(CLICommandCatalog.shared.arguments(command: "system.df"))
                raw = table.output
            }
            DispatchQueue.main.async {
                self.diskUsageItems = items
                self.diskUsageRaw = raw
            }
        }
    }

    /// 宽松解析 system df JSON：键名在不同版本可能有差异，取候选键，解析失败返回空。
    private static func parseDiskUsage(json: String) -> [SystemDiskUsageItem] {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry -> SystemDiskUsageItem? in
            guard let type = entry.stringValue(keys: ["type", "resource", "resourceType", "name"]) else { return nil }
            return SystemDiskUsageItem(
                type: type,
                total: entry.intValue(keys: ["total", "count", "totalCount"]) ?? 0,
                active: entry.intValue(keys: ["active", "activeCount"]) ?? 0,
                sizeBytes: entry.int64Value(keys: ["size", "sizeBytes", "totalSize"]) ?? 0,
                reclaimableBytes: entry.int64Value(keys: ["reclaimable", "reclaimableSize", "reclaimableBytes"]) ?? 0
            )
        }
    }

    // MARK: - 内核信息（修正：调用 MachineManager）
    func refreshKernelInfo() {
        Task {
            let kernel = await machineManager.fetchCurrentKernel(appRoot: dataRoot)
            DispatchQueue.main.async {
                if let kernel = kernel {
                    self.currentKernel = kernel
                } else {
                    self.currentKernel = "未配置"
                }
                // 当前官方指令库未提供 kernel list，使用数据根目录探测。
                self.availableKernels = []
            }
        }
    }

    // MARK: - 缓存统计
    func refreshCacheStats() {
        Task {
            let sizeResult = await executeSystemCommand(arguments: ["du", "-sh", cacheDir])
            DispatchQueue.main.async {
                if sizeResult.succeeded {
                    let sizeStr = sizeResult.output.split(separator: "\t").first.map { String($0) } ?? "0 MB"
                    self.cacheSize = sizeStr
                } else {
                    self.cacheSize = "0 MB"
                }
            }
        }
        Task {
            let containers = await executeCommand(CLICommandCatalog.shared.arguments(command: "container.list", options: ["all": ["true"], "format": ["json"]]))
            let images = await executeCommand(CLICommandCatalog.shared.arguments(command: "image.list", options: ["format": ["json"]]))
            let volumes = await executeCommand(CLICommandCatalog.shared.arguments(command: "volume.list", options: ["format": ["json"]]))
            DispatchQueue.main.async {
                self.containerCount = self.parseCount(from: containers.output)
                self.imageCount = self.parseCount(from: images.output)
                self.volumeCount = self.parseCount(from: volumes.output)
            }
        }
    }

    private func parseCount(from json: String) -> Int {
        guard let data = json.data(using: .utf8) else { return 0 }
        do {
            let array = try JSONSerialization.jsonObject(with: data) as? [Any]
            return array?.count ?? 0
        } catch {
            return 0
        }
    }

    // MARK: - 配置编辑（config.toml）

    /// 读取容器配置文件（appRoot 优先，同步 ~/.config 版本）
    func loadConfig() {
        let content = (try? String(contentsOfFile: primaryConfigPath, encoding: .utf8))
            ?? (try? String(contentsOfFile: configPath, encoding: .utf8))
            ?? ""
        configContent = content
    }

    /// 保存 config.toml 到容器服务实际读取的路径，并同步 ~/.config 版本
    func saveConfig() {
        do {
            try FileManager.default.createDirectory(
                atPath: (primaryConfigPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: primaryConfigPath) {
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: primaryConfigPath)
            }
            try configContent.write(toFile: primaryConfigPath, atomically: true, encoding: .utf8)
            try configContent.write(toFile: configPath, atomically: true, encoding: .utf8)
            ToastManager.shared.showSuccess("配置已保存，重启服务后生效")
        } catch {
            ToastManager.shared.showError("保存配置失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 受控资源清理（仅调用当前工作环境的官方 prune 指令）
    func supportsCleanup(_ action: CleanupAction) -> Bool {
        CLICommandCatalog.shared.supports(command: action.commandKey, version: EnvironmentManager.shared.currentVersion)
    }

    func performCleanup(_ action: CleanupAction) {
        guard supportsCleanup(action) else {
            let minimum = CLICommandCatalog.shared.minimumVersion(command: action.commandKey)?.description ?? "未知"
            ToastManager.shared.showError("当前 Container 版本不支持此操作，需要 \(minimum)+")
            return
        }
        Task {
            let displayCommand = ([AppConstants.CLI.executableName] + action.arguments).joined(separator: " ")
            await MainActor.run {
                TaskManager.shared.startTask(module: "系统", operation: action.title, command: displayCommand)
                TaskManager.shared.setIndeterminate(true)
            }
            do {
                let output = try await executor.execute(action.arguments)
                await MainActor.run {
                    TaskManager.shared.finishTask(success: true, message: "\(action.title)完成")
                    ToastManager.shared.showSuccess("\(action.title)完成")
                }
                logService.log(result: CLIResult(command: displayCommand, output: output, exitCode: 0, duration: 0, mode: .async), module: "系统", operationType: action.title)
                refreshCacheStats()
                refreshDiskUsage()
                refreshResourceInventory()
            } catch {
                await MainActor.run {
                    TaskManager.shared.finishTask(success: false, message: "\(action.title)失败: \(error.localizedDescription)")
                    ToastManager.shared.showError("\(action.title)失败: \(error.localizedDescription)")
                }
                logService.log(result: CLIResult(command: displayCommand, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "系统", operationType: "\(action.title)失败")
            }
        }
    }

    // MARK: - 环境重置

    /// 仅重启当前 Container 系统服务，不删除容器、镜像、卷或配置。
    /// 整个流程固定使用开始时的工作环境，并保留 status 报告的根目录。
    func resetEnvironment(
        log: @escaping (_ message: String, _ isError: Bool) -> Void
    ) async -> Bool {
        guard let environment = await MainActor.run(body: { executor.environment }) else {
            log("没有可用的工作环境", true)
            return false
        }
        let commandKeys = ["system.status", "system.stop", "system.start"]
        let version = EnvironmentManager.shared.currentVersion
        guard commandKeys.allSatisfy({ CLICommandCatalog.shared.supports(command: $0, version: version) }) else {
            let requirements = commandKeys.compactMap { CLICommandCatalog.shared.minimumVersion(command: $0)?.description }
            log("当前 Container 版本不支持环境重置（指令库要求：\(requirements.joined(separator: " / "))）", true)
            return false
        }

        let taskCommand = "\(environment.resolvedCliPath) system stop && system start"
        await MainActor.run {
            TaskManager.shared.startTask(module: "系统", operation: "重置环境", command: taskCommand)
            TaskManager.shared.setIndeterminate(true)
        }

        do {
            log("读取当前环境运行参数…", false)
            let initialStatus = try await executor.execute(CLICommandCatalog.shared.arguments(command: "system.status"), in: environment)
            let roots = Self.runtimeRoots(from: initialStatus)
            guard roots.appRoot != nil else {
                throw ContainerError.invalidOutput
            }

            log("停止 \(environment.name) 的容器系统服务…", false)
            _ = try await executor.execute(CLICommandCatalog.shared.arguments(command: "system.stop"), in: environment, timeout: 60)
            log("服务已停止", false)

            try ensureEnvironmentUnchanged(environment.id)
            var startArguments = CLICommandCatalog.shared.path(command: "system.start") ?? []
            let catalog = CLICommandCatalog.shared
            if let value = roots.appRoot {
                startArguments += [catalog.flag(command: "system.start", option: "appRoot"), value]
            }
            if let value = roots.installRoot {
                startArguments += [catalog.flag(command: "system.start", option: "installRoot"), value]
            }
            if let value = roots.logRoot {
                startArguments += [catalog.flag(command: "system.start", option: "logRoot"), value]
            }

            log("按原资源目录启动服务…", false)
            _ = try await executor.execute(startArguments, in: environment, timeout: 120)

            log("等待服务就绪…", false)
            var readyStatus: String?
            for _ in 0..<15 {
                try ensureEnvironmentUnchanged(environment.id)
                if let output = try? await executor.execute(CLICommandCatalog.shared.arguments(command: "system.status"), in: environment, timeout: 10) {
                    readyStatus = output
                    break
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let readyStatus else {
                throw ContainerError.commandFailed("服务启动后 15 秒内未就绪")
            }

            let confirmedRoots = Self.runtimeRoots(from: readyStatus)
            guard confirmedRoots.appRoot == roots.appRoot else {
                throw ContainerError.commandFailed("服务已启动，但数据根目录未保持一致")
            }
            log("服务已恢复，资源目录保持一致", false)

            let kernelRoot = URL(fileURLWithPath: roots.appRoot!, isDirectory: true)
                .appendingPathComponent("kernels", isDirectory: true)
            let hasKernel = (try? FileManager.default.contentsOfDirectory(
                at: kernelRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).isEmpty == false) ?? false
            if hasKernel {
                log("当前工作环境内核已配置", false)
            } else {
                log("当前工作环境未检测到内核；如需使用 Machine，请单独安装推荐内核", false)
            }

            await MainActor.run {
                self.isServiceRunning = true
                self.parseStatusOutput(readyStatus)
                TaskManager.shared.finishTask(success: true, message: "环境重置完成")
            }
            logService.log(
                result: CLIResult(command: taskCommand, output: readyStatus, exitCode: 0, duration: 0, mode: .async),
                module: "系统",
                operationType: "重置环境"
            )
            refreshAll()
            return true
        } catch {
            log("重置失败: \(error.localizedDescription)", true)
            await MainActor.run {
                TaskManager.shared.finishTask(success: false, message: "环境重置失败: \(error.localizedDescription)")
            }
            logService.log(
                result: CLIResult(command: taskCommand, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async),
                module: "系统",
                operationType: "重置环境失败"
            )
            refreshServiceStatus()
            return false
        }
    }

    private func ensureEnvironmentUnchanged(_ environmentID: UUID) throws {
        guard executor.environment?.id == environmentID else {
            throw ContainerError.commandFailed("工作环境已变更，已终止重置流程")
        }
    }

    private static func runtimeRoots(from status: String) -> (appRoot: String?, installRoot: String?, logRoot: String?) {
        func value(for key: String) -> String? {
            let prefix = key.lowercased() + ":"
            for rawLine in status.split(separator: "\n") {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.lowercased().hasPrefix(prefix) else { continue }
                let rawValue = String(line.dropFirst(key.count + 1))
                let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : (trimmed as NSString).standardizingPath
            }
            return nil
        }
        return (
            value(for: "application data root"),
            value(for: "application install root"),
            value(for: "application log root")
        )
    }

    // MARK: - 服务启动
    func startService() {
        isLoading = true
        Task {
            let result = await executeCommand(
                CLICommandCatalog.shared.arguments(command: "system.start"),
                timeout: AppConstants.Time.longCommandTimeout
            )
            logService.log(result: result, module: "系统", operationType: "启动服务")
            await MainActor.run {
                self.isLoading = false
                if result.succeeded {
                    ToastManager.shared.showSuccess("服务启动成功")
                    self.refreshServiceStatus()
                } else {
                    ToastManager.shared.showError("启动失败: \(result.output)")
                    self.isServiceRunning = false
                }
            }
        }
    }

    // MARK: - 服务停止
    func stopService() {
        isLoading = true
        Task {
            let result = await executeCommand(
                CLICommandCatalog.shared.arguments(command: "system.stop"),
                timeout: AppConstants.Time.longCommandTimeout
            )
            logService.log(result: result, module: "系统", operationType: "停止服务")
            await MainActor.run {
                self.isLoading = false
                if result.succeeded { ToastManager.shared.showSuccess("服务已停止") }
                else { self.isServiceRunning = false }
                self.refreshServiceStatus()
            }
        }
    }

    // MARK: - 通用命令执行
    private func executeCommand(_ arguments: [String], timeout: TimeInterval? = nil) async -> CLIResult {
        let command = ContainerCommandBuilder.displayCommand(for: arguments)
        do {
            let output = try await executor.execute(arguments, timeout: timeout)
            return CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
        } catch {
            return CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
        }
    }

    private func executeSystemCommand(arguments: [String]) async -> CLIResult {
        return await withCheckedContinuation { continuation in
            Task {
                do {
                    let output = try await executor.executeSystemCommand(arguments: arguments)
                    let result = CLIResult(
                        command: arguments.joined(separator: " "),
                        output: output,
                        exitCode: 0,
                        duration: 0,
                        mode: .async
                    )
                    continuation.resume(returning: result)
                } catch {
                    let result = CLIResult(
                        command: arguments.joined(separator: " "),
                        output: error.localizedDescription,
                        exitCode: -1,
                        duration: 0,
                        mode: .async
                    )
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

// MARK: - 系统组件版本（container system version --format json）
struct SystemVersionComponent: Codable, Identifiable {
    var id: String { appName }
    let appName: String
    let buildType: String?
    let commit: String?
    let version: String
}

// MARK: - 磁盘占用项（container system df）
struct SystemDiskUsageItem: Identifiable {
    let type: String
    let total: Int
    let active: Int
    let sizeBytes: Int64
    let reclaimableBytes: Int64
    var id: String { type }

    var sizeDescription: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var reclaimableDescription: String { ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file) }
}

private extension Dictionary where Key == String, Value == Any {
    func stringValue(keys: [String]) -> String? {
        for key in keys {
            if let value = self[key] as? String, !value.isEmpty { return value }
            if let value = self[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    func intValue(keys: [String]) -> Int? {
        for key in keys {
            if let value = self[key] as? Int { return value }
            if let value = self[key] as? NSNumber { return value.intValue }
            if let value = self[key] as? String, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    func int64Value(keys: [String]) -> Int64? {
        for key in keys {
            if let value = self[key] as? Int64 { return value }
            if let value = self[key] as? NSNumber { return value.int64Value }
            if let value = self[key] as? String, let parsed = Int64(value) { return parsed }
        }
        return nil
    }
}
