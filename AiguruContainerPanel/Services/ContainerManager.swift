//
//  ContainerManager.swift
//  AiguruContainerPanel
//
//  容器管理服务：增删改查、批量操作、日志、详情、编辑/重建。
//  支持创建容器进度实时反馈，所有操作均记录日志。
//

import Foundation
import Combine

private actor ContainerOperationCoordinator {
    private var activeContainerIDs = Set<String>()

    func begin(_ containerID: String) -> Bool {
        activeContainerIDs.insert(containerID).inserted
    }

    func end(_ containerID: String) {
        activeContainerIDs.remove(containerID)
    }
}

/// 容器管理器（单例）
class ContainerManager: ObservableObject {
    static let shared = ContainerManager()
    private init() {}

    public let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared
    private let operationCoordinator = ContainerOperationCoordinator()

    // MARK: - Published 状态（供 UI 绑定）
    @Published var containers: [Container] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentProgress: Double = 0.0
    @Published var currentProgressMessage: String = ""
    @Published var isProgressIndeterminate = false
    @Published var currentCommand: String = ""
    @Published var logs: [String] = []

    // MARK: - 获取容器列表
    func fetchContainers() async {
        await MainActor.run {
            // 刷新期间保留当前快照，避免所有依赖容器列表的页面瞬间清空、
            // selection 被重置以及列表反复闪烁。新结果返回后再原子替换。
            self.isLoading = true
        }

        let command = "list --all --format json"
        do {
            let output = try await executor.execute(catalog.arguments(command: "container.list", options: ["all": ["true"], "format": ["json"]]))
            print("📦 容器列表原始输出:\n\(output)")  // 调试日志
            
            guard !output.isEmpty else {
                await MainActor.run {
                    self.containers = []
                    self.isLoading = false
                    self.errorMessage = "容器列表为空"
                }
                let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
                logService.log(result: result, module: "容器", operationType: "列表刷新(空)")
                return
            }
            
            let data = output.data(using: .utf8) ?? Data()
            // 尝试解析 JSON，如果失败则抛出错误
            let decoded = try JSONDecoder().decode([Container].self, from: data)
            await MainActor.run {
                self.containers = decoded
                self.isLoading = false
                self.errorMessage = nil
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "列表刷新")
        } catch {
            // 如果 JSON 解析失败，尝试回退到纯文本解析
            print("⚠️ JSON 解析失败，尝试回退到文本: \(error)")
            await fallbackFetchContainers()
        }
    }

    /// 获取指定环境的容器快照，不改变列表加载状态。供后台守护轮询使用，
    /// 避免周期检查造成列表闪烁或覆盖用户刚切换后的环境。
    func fetchContainersSnapshot(in environment: ContainerEnvironment) async throws -> [Container] {
        let arguments = catalog.arguments(
            command: "container.list",
            options: ["all": ["true"], "format": ["json"]]
        )
        let output = try await executor.execute(arguments, in: environment)
        guard !output.isEmpty else { return [] }
        return try JSONDecoder().decode([Container].self, from: Data(output.utf8))
    }

    private func fallbackFetchContainers() async {
        await MainActor.run {
            // 保留 isLoading = true，由 fallback 内部管理结束
            self.isLoading = true
        }
        
        let command = "list --all"
        do {
            let output = try await executor.execute(catalog.arguments(command: "container.list", options: ["all": ["true"]]))
            print("📦 容器列表文本输出:\n\(output)")
            let lines = output.split(separator: "\n")
            guard lines.count > 1 else {
                await MainActor.run {
                    self.containers = []
                    self.isLoading = false
                    self.errorMessage = "没有容器"
                }
                let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
                logService.log(result: result, module: "容器", operationType: "列表刷新(回退-空)")
                return
            }
            var parsed: [Container] = []
            for line in lines.dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 5 {
                    let containerID = String(parts[0])
                    let image = String(parts[1])
                    let statusString = String(parts[4])
                    let state = ContainerState(rawValue: statusString) ?? .unknown
                    parsed.append(Container(
                        id: containerID,
                        name: containerID,
                        image: image,
                        state: state,
                        status: statusString,
                        createdAt: "",
                        ports: nil,
                        mounts: nil,
                        networkSettings: nil,
                        sizeRootFs: nil,
                        sizeRw: nil
                    ))
                }
            }
            await MainActor.run {
                self.containers = parsed
                self.isLoading = false
                self.errorMessage = nil
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "列表刷新(回退)")
        } catch {
            await MainActor.run {
                self.containers = []
                self.isLoading = false
                self.errorMessage = "获取容器列表失败: \(error.localizedDescription)"
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "列表刷新失败")
            print("❌ 容器列表回退错误: \(error)")
        }
    }

    // MARK: - 获取容器详情
    func fetchContainerDetails(id: String) async throws -> ContainerDetails {
        let output = try await executor.execute(catalog.arguments(command: "container.inspect", positionals: [id]))
        guard let data = output.data(using: .utf8),
              let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = jsonArray.first else {
            throw ContainerError.invalidOutput
        }
        let networkSettings = first["NetworkSettings"] as? [String: Any]
        let networks = networkSettings?["Networks"] as? [String: Any]
        let networkName = networks?.keys.first ?? "bridge"
        let created = first["Created"] as? String ?? "未知"
        let ip = networkSettings?["IPAddress"] as? String ?? ""
        var volumes: [VolumeMapping] = []
        if let config = first["configuration"] as? [String: Any],
           let mounts = config["mounts"] as? [[String: Any]] {
            for mount in mounts {
                let source = mount["source"] as? String ?? ""
                let destination = mount["destination"] as? String ?? ""
                if !source.isEmpty && !destination.isEmpty {
                    volumes.append(VolumeMapping(source: source, destination: destination))
                }
            }
        }
        if volumes.isEmpty, let mounts = first["Mounts"] as? [[String: Any]] {
            for mount in mounts {
                let source = mount["Source"] as? String ?? ""
                let destination = mount["Destination"] as? String ?? ""
                if !source.isEmpty && !destination.isEmpty {
                    volumes.append(VolumeMapping(source: source, destination: destination))
                }
            }
        }
        if volumes.isEmpty, let hostConfig = first["HostConfig"] as? [String: Any],
           let binds = hostConfig["Binds"] as? [String] {
            for bind in binds {
                let components = bind.split(separator: ":").map { String($0) }
                if components.count >= 2 {
                    let source = components[0]
                    let destination = components[1]
                    if !volumes.contains(where: { $0.source == source && $0.destination == destination }) {
                        volumes.append(VolumeMapping(source: source, destination: destination))
                    }
                }
            }
        }
        return ContainerDetails(
            network: networkName,
            volumes: volumes,
            createdAt: created,
            ipAddress: ip.isEmpty ? nil : ip
        )
    }

    // MARK: - 容器统计
    func fetchContainerStats(id: String) async throws -> ContainerStats {
        let output = try await executor.execute(catalog.arguments(command: "container.stats", options: ["noStream": ["true"]], positionals: [id]))
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { throw ContainerError.invalidOutput }

        let header = String(lines[0])
        let dataLine = String(lines.last ?? lines[1])

        // 从表头确定各列起止位置（6 列）
        let colNames = ["Container ID", "Cpu %", "Memory Usage", "Net Rx/Tx", "Block I/O", "Pids"]
        var colStarts: [Int] = []
        for name in colNames {
            if let r = header.range(of: name) {
                colStarts.append(header.distance(from: header.startIndex, to: r.lowerBound))
            }
        }
        guard colStarts.count == 6 else { throw ContainerError.invalidOutput }

        func col(_ idx: Int) -> String {
            let s = colStarts[idx]
            let e = idx + 1 < colStarts.count ? colStarts[idx + 1] : dataLine.count
            let si = dataLine.index(dataLine.startIndex, offsetBy: min(s, dataLine.count))
            let ei = dataLine.index(dataLine.startIndex, offsetBy: min(e, dataLine.count))
            return String(dataLine[si..<ei]).trimmingCharacters(in: .whitespaces)
        }

        let cpuPercent = col(1)  // "0.57%"

        let memFull = col(2)
        let memParts = memFull.components(separatedBy: " / ")
        let memUsageStr = memParts.first ?? memFull
        let memLimitStr = memParts.count > 1 ? memParts[1] : ""

        // 内存百分比：解析 "73.08 MiB / 4.00 GiB" 计算
        let memPercent: Double = {
            guard memParts.count >= 2 else { return 0 }
            func toBytes(_ s: String) -> Double {
                let p = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
                guard p.count >= 2, let v = Double(p[0]) else { return 0 }
                switch p[1].uppercased() {
                case "B": return v
                case "KIB", "KB": return v * 1024
                case "MIB", "MB": return v * 1024 * 1024
                case "GIB", "GB": return v * 1024 * 1024 * 1024
                default: return 0
                }
            }
            let total = toBytes(memParts[1])
            guard total > 0 else { return 0 }
            return min(100, (toBytes(memParts[0]) / total) * 100)
        }()

        let netIO = col(3)
        let blockIO = col(4)
        let pids = Int(col(5)) ?? 0

        return ContainerStats(
            containerID: id, name: "",
            cpuPercent: cpuPercent,
            memUsage: memUsageStr, memLimit: memLimitStr, memPercent: memPercent,
            netIO: netIO, blockIO: blockIO, pids: pids
        )
    }

    // MARK: - 获取容器配置（用于编辑）
    func inspectContainer(id: String) async throws -> ContainerConfig {
        let output = try await executor.execute(catalog.arguments(command: "container.inspect", positionals: [id]))
        let nativeData = output.data(using: .utf8) ?? Data()
        if let native = try? JSONDecoder().decode([Container].self, from: nativeData).first,
           native.configuration != nil {
            return nativeContainerConfig(from: native)
        }
        guard let data = output.data(using: .utf8),
              let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = jsonArray.first else {
            throw ContainerError.invalidOutput
        }
        let config = first["Config"] as? [String: Any] ?? [:]
        let hostConfig = first["HostConfig"] as? [String: Any] ?? [:]
        let networkSettings = first["NetworkSettings"] as? [String: Any]
        let networks = networkSettings?["Networks"] as? [String: Any]
        let networkName = networks?.keys.first ?? ""
        let image = config["Image"] as? String ?? ""
        let env = config["Env"] as? [String] ?? []
        let entrypoint = (config["Entrypoint"] as? [String])?.first ?? ""
        let workdir = config["WorkingDir"] as? String ?? ""
        let user = config["User"] as? String ?? ""
        let labels = config["Labels"] as? [String: String] ?? [:]
        let tty = config["Tty"] as? Bool ?? false
        let openStdin = config["OpenStdin"] as? Bool ?? false
        let portBindings = hostConfig["PortBindings"] as? [String: Any] ?? [:]
        var ports: [String] = []
        for (containerPort, binding) in portBindings {
            if let bindings = binding as? [[String: Any]], let firstBinding = bindings.first {
                let hostPort = firstBinding["HostPort"] as? String ?? ""
                if !hostPort.isEmpty {
                    ports.append("\(hostPort):\(containerPort)")
                }
            }
        }
        let mounts = first["Mounts"] as? [[String: Any]] ?? []
        var volumes: [VolumeMapping] = []
        for mount in mounts {
            let source = mount["Source"] as? String ?? ""
            let destination = mount["Destination"] as? String ?? ""
            volumes.append(VolumeMapping(source: source, destination: destination))
        }
        let dns = hostConfig["Dns"] as? [String] ?? []
        let dnsSearch = hostConfig["DnsSearch"] as? [String] ?? []
        let memory = hostConfig["Memory"] as? Int64
        let memoryStr = memory.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }
        let initProcess = hostConfig["Init"] as? Bool ?? false
        let readOnly = hostConfig["ReadonlyRootfs"] as? Bool ?? false
        let capAdd = hostConfig["CapAdd"] as? [String] ?? []
        let capDrop = hostConfig["CapDrop"] as? [String] ?? []

        let options = ContainerRunOptions(
            detach: true,
            rm: false,
            interactive: openStdin,
            tty: tty,
            cpus: nil,
            memory: memoryStr,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint,
            workdir: workdir.isEmpty ? nil : workdir,
            user: user.isEmpty ? nil : user,
            initProcess: initProcess,
            readOnly: readOnly,
            network: networkName.isEmpty ? nil : networkName,
            dns: dns,
            dnsSearch: dnsSearch,
            dnsDomain: nil,
            dnsOptions: [],
            noDNS: false,
            publishSockets: [],
            advancedMounts: [],
            tmpfsMounts: [],
            os: nil,
            arch: nil,
            capAdd: capAdd,
            capDrop: capDrop,
            labels: labels,
            kernel: nil,
            initImage: nil,
            cidfile: nil,
            sshForward: false,
            virtualization: false,
            scheme: nil,
            maxConcurrentDownloads: nil
        )
        return ContainerConfig(
            image: image,
            env: env,
            ports: ports,
            volumes: volumes,
            name: id,
            detach: true,
            options: options
        )
    }

    /// Container 1.2.x 的原生 inspect 结构。旧实现只识别 Docker 的
    /// Config/HostConfig/NetworkSettings，重建时会静默丢失网络和 DNS 注册信息。
    private func nativeContainerConfig(from container: Container) -> ContainerConfig {
        guard let configuration = container.configuration else {
            return ContainerConfig(image: container.image, env: [], ports: [], volumes: [],
                                   name: container.id, detach: true, options: ContainerRunOptions())
        }
        let process = configuration.initProcess
        let publishedPorts = (configuration.publishedPorts ?? []).map { port in
            let hostPort = port.hostPortString ?? port.containerPortString
            let endpoint = "\(hostPort):\(port.containerPortString)"
            let host = port.hostIP ?? ""
            let withHost = host.isEmpty || host == "0.0.0.0" ? endpoint : "\(host):\(endpoint)"
            return port.protocolType.lowercased() == "tcp" ? withHost : "\(withHost)/\(port.protocolType)"
        }
        let volumes = (configuration.mounts ?? []).map {
            VolumeMapping(source: $0.source, destination: $0.destination)
        }
        let user = process?.user?.id.flatMap { id -> String? in
            guard let uid = id.uid else { return nil }
            return id.gid.map { "\(uid):\($0)" } ?? String(uid)
        }
        let options = ContainerRunOptions(
            detach: true,
            rm: false,
            interactive: false,
            tty: process?.terminal ?? false,
            cpus: configuration.resources?.cpus.map { String($0) },
            memory: configuration.resources?.memoryInBytes.map(String.init),
            entrypoint: process?.executable,
            workdir: process?.workingDirectory,
            user: user,
            initProcess: configuration.useInit ?? false,
            readOnly: configuration.readOnly ?? false,
            network: configuration.networks?.first?.network,
            dns: configuration.dns?.nameservers ?? [],
            dnsSearch: configuration.dns?.searchDomains ?? [],
            dnsDomain: configuration.dns?.domain,
            dnsOptions: configuration.dns?.options ?? [],
            noDNS: false,
            publishSockets: [],
            advancedMounts: [],
            tmpfsMounts: [],
            os: nil,
            arch: nil,
            capAdd: configuration.capAdd ?? [],
            capDrop: configuration.capDrop ?? [],
            labels: configuration.labels ?? [:],
            kernel: nil,
            initImage: nil,
            rosetta: configuration.rosetta ?? false,
            cidfile: nil,
            sshForward: configuration.ssh ?? false,
            virtualization: configuration.virtualization ?? false,
            scheme: nil,
            maxConcurrentDownloads: nil,
            command: process?.arguments ?? []
        )
        return ContainerConfig(
            image: configuration.image?.reference ?? container.image,
            env: process?.environment ?? [],
            ports: publishedPorts,
            volumes: volumes,
            name: container.id,
            detach: true,
            options: options
        )
    }

    // MARK: - 启动容器
    @discardableResult
    func startContainer(
        id: String,
        operationType: String = "启动",
        reportErrorsToUI: Bool = true
    ) async -> Bool {
        guard await operationCoordinator.begin(id) else {
            if reportErrorsToUI {
                await reportOperationAlreadyRunning(id: id, action: operationType)
            }
            return false
        }
        let operationArguments = catalog.arguments(command: "container.start", positionals: [id])
        let command = ContainerCommandBuilder.displayCommand(for: operationArguments)
        do {
            guard let environment = EnvironmentManager.shared.activeEnvironment else {
                throw ContainerError.commandFailed("未选择工作环境")
            }
            let output = try await executor.execute(operationArguments, in: environment)
            await fetchContainers()
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: operationType)
            await operationCoordinator.end(id)
            return true
        } catch {
            if reportErrorsToUI {
                await MainActor.run {
                    self.errorMessage = "启动容器失败: \(error.localizedDescription)"
                }
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "\(operationType)失败")
            await operationCoordinator.end(id)
            return false
        }
    }

    // MARK: - 停止容器
    @discardableResult
    func stopContainer(id: String) async -> Bool {
        guard await operationCoordinator.begin(id) else {
            await reportOperationAlreadyRunning(id: id, action: "停止")
            return false
        }
        let operationArguments = catalog.arguments(command: "container.stop", positionals: [id])
        let command = ContainerCommandBuilder.displayCommand(for: operationArguments)
        do {
            guard let environment = EnvironmentManager.shared.activeEnvironment else {
                throw ContainerError.commandFailed("未选择工作环境")
            }
            // 停止运行中容器需要等待 guest 收到信号并释放网络/挂载资源，
            // 使用普通 10 秒超时会在 Container 1.5 上误报超时。
            let output = try await executor.execute(
                operationArguments,
                in: environment,
                timeout: AppConstants.Time.longCommandTimeout
            )
            await fetchContainers()
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "停止")
            await operationCoordinator.end(id)
            return true
        } catch {
            await MainActor.run {
                self.errorMessage = "停止容器失败: \(error.localizedDescription)"
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "停止失败")
            await operationCoordinator.end(id)
            return false
        }
    }

    private func reportOperationAlreadyRunning(id: String, action: String) async {
        await MainActor.run {
            self.errorMessage = "容器 \(id) 正在执行启停操作，请等待当前操作完成"
        }
        let result = CLIResult(
            command: "container \(action) \(id)",
            output: "已阻止同一容器的重复并发操作",
            exitCode: -1,
            duration: 0,
            mode: .async
        )
        logService.log(result: result, module: "容器", operationType: "重复操作已阻止")
    }

    // MARK: - 回收运行中容器的文件系统空闲空间（Container 1.4.1+）
    func cleanContainer(id: String) async {
        guard await operationCoordinator.begin(id) else {
            await reportOperationAlreadyRunning(id: id, action: "清理")
            return
        }
        let arguments = catalog.arguments(command: "container.clean", positionals: [id])
        let command = ContainerCommandBuilder.displayCommand(for: arguments)
        do {
            guard let environment = EnvironmentManager.shared.activeEnvironment else {
                throw ContainerError.commandFailed("未选择工作环境")
            }
            let versionOutput = try await executor.execute(catalog.arguments(command: "cli.version"), in: environment)
            let version = CLIVersion(versionOutput)
            guard catalog.supports(command: "container.clean", version: version) else {
                throw ContainerError.commandFailed("当前环境 Container \(version) 不支持 clean；最低要求为 1.4.1")
            }
            let output = try await executor.execute(arguments, in: environment, timeout: AppConstants.Time.longCommandTimeout)
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "回收文件系统空间")
            await MainActor.run { ToastManager.shared.showSuccess("容器空间回收完成：\(id)") }
        } catch {
            await MainActor.run {
                self.errorMessage = "回收容器空间失败: \(error.localizedDescription)"
                ToastManager.shared.showError(self.errorMessage ?? "回收容器空间失败")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "回收文件系统空间失败")
        }
        await operationCoordinator.end(id)
    }

    // MARK: - 删除容器
    func deleteContainer(id: String, refreshAfterDeletion: Bool = true) async {
        let operationArguments = catalog.arguments(command: "container.delete", options: ["force": ["true"]], positionals: [id])
        let command = ContainerCommandBuilder.displayCommand(for: operationArguments)
        do {
            // 删除运行中容器会等待 guest/runtime 清理挂载和网络资源，不能使用
            // 普通命令的 10 秒超时；否则执行器主动 SIGTERM 后会出现 status=143。
            let output = try await executor.execute(
                operationArguments,
                timeout: AppConstants.Time.longCommandTimeout
            )
            if refreshAfterDeletion {
                await fetchContainers()
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "删除")
        } catch {
            await MainActor.run {
                self.errorMessage = "删除容器失败: \(error.localizedDescription)"
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "删除失败")
        }
    }

    // MARK: - 创建容器（完整选项 + 进度反馈）
    func createContainer(
        name: String,
        image: String,
        detach: Bool = true,
        ports: [String] = [],
        env: [String] = [],
        volumes: [String] = [],
        options: ContainerRunOptions
    ) async throws -> String {
        var effectiveOptions = options
        effectiveOptions.detach = detach
        var cliVersion = await MainActor.run { EnvironmentManager.shared.currentVersion }
        if !cliVersion.isKnown {
            cliVersion = CLIVersion(try await executor.execute(catalog.arguments(command: "cli.version")))
        }
        guard cliVersion.isKnown else {
            throw ContainerError.commandFailed("无法识别当前工作环境的 Container CLI 版本")
        }
        // 系统元数据由管理层最终写入，避免调用方伪造创建环境版本。
        effectiveOptions.labels[AppConstants.ContainerLabel.cliVersion] = cliVersion.description
        effectiveOptions.labels[AppConstants.ContainerLabel.managedBy] = AppConstants.ContainerLabel.managedByValue
        let args = ContainerCommandBuilder.runArguments(
            image: image,
            name: name,
            ports: ports,
            environment: env,
            volumes: volumes,
            options: effectiveOptions
        )
        let command = ContainerCommandBuilder.displayCommand(for: args)

        let unsupported = CLICommandCatalog.shared.unsupportedFlags(
            in: args, command: "container.run", version: cliVersion
        )
        if let first = unsupported.first {
            throw ContainerError.commandFailed("当前工作环境为 Container \(cliVersion)，参数 \(first.0) 需要 \(first.1)+")
        }

        // 同步更新 TaskManager 和本地进度
        let taskManager = TaskManager.shared
        await MainActor.run {
            self.currentProgress = 0.0
            self.currentProgressMessage = "开始创建容器 \(name.isEmpty ? "未命名" : name)..."
            self.isProgressIndeterminate = true
            self.isLoading = true
            self.currentCommand = command
            taskManager.startTask(module: "容器", operation: "创建", command: command)
        }

        do {
            if let conflict = await publishedPortConflict(in: ports) {
                throw ContainerError.commandFailed(conflict)
            }
            await MainActor.run {
                taskManager.appendOutput("[预检] 宿主机发布端口可用")
            }
            let output = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    self.currentProgressMessage = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    taskManager.appendOutput(line)

                    if let percent = line.percentageProgress {
                        let prog = percent / 100.0
                        self.currentProgress = prog
                        taskManager.updateProgress(prog)
                        self.isProgressIndeterminate = false
                    } else if let (current, total) = line.blobProgress {
                        let base = 0.3
                        let range = 0.4
                        let prog = base + (Double(current) / Double(total)) * range
                        self.currentProgress = prog
                        taskManager.updateProgress(prog)
                        self.isProgressIndeterminate = false
                    } else if let (current, total) = line.layerProgress {
                        let base = 0.7
                        let range = 0.2
                        let prog = base + (Double(current) / Double(total)) * range
                        self.currentProgress = prog
                        taskManager.updateProgress(prog)
                        self.isProgressIndeterminate = false
                    } else if line.contains("Fetching image") || line.contains("Downloading") {
                        self.currentProgress = max(self.currentProgress, 0.05)
                        self.isProgressIndeterminate = true
                        taskManager.setIndeterminate(true)
                    } else if line.contains("Extracting") || line.contains("Unpacking") {
                        self.currentProgress = max(self.currentProgress, 0.5)
                        self.isProgressIndeterminate = true
                        taskManager.setIndeterminate(true)
                    } else if line.contains("Starting") || line.contains("Container started") {
                        self.currentProgress = 0.95
                        taskManager.updateProgress(0.95)
                        self.isProgressIndeterminate = false
                        taskManager.setIndeterminate(false)
                    }
                }
            })
            let containerID = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if containerID.isEmpty {
                throw ContainerError.commandFailed("容器创建失败，未返回 ID")
            }
            await MainActor.run {
                self.currentProgress = 1.0
                self.currentProgressMessage = "容器创建成功 ✅"
                self.isProgressIndeterminate = false
                self.isLoading = false
                taskManager.finishTask(success: true, message: "容器创建成功 ✅")
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(AppConstants.Time.taskPanelDismissDelay * 1_000_000_000))
                    await MainActor.run {
                        self.currentProgress = 0.0
                        self.currentProgressMessage = ""
                        self.isProgressIndeterminate = false
                        self.currentCommand = ""
                    }
                }
            }
            await fetchContainers()
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "容器", operationType: "创建")
            return containerID
        } catch {
            let reportedError = actionableCreationError(error, publishedPorts: ports)
            await MainActor.run {
                self.isLoading = false
                self.currentProgress = 0.0
                self.currentProgressMessage = "创建失败 ❌: \(reportedError.localizedDescription)"
                self.isProgressIndeterminate = false
                self.errorMessage = "创建容器失败: \(reportedError.localizedDescription)"
                taskManager.finishTask(success: false, message: "创建失败: \(reportedError.localizedDescription)")
            }
            let result = CLIResult(command: command, output: reportedError.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "容器", operationType: "创建失败")
            throw reportedError
        }
    }

    /// 所有创建入口（表单、模板、失败重试）共用的宿主机端口预检。
    /// `lsof` 无匹配时以退出码 1 结束，因此这里把执行失败视为“未发现监听者”；
    /// Apple Container 最终仍会执行 bind，并由下方错误归一化兜底。
    private func publishedPortConflict(in mappings: [String]) async -> String? {
        for endpoint in publishedHostEndpoints(from: mappings) {
            var arguments = ["/usr/sbin/lsof", "-nP", "-i\(endpoint.protocolName.uppercased()):\(endpoint.port)"]
            if endpoint.protocolName == "tcp" {
                arguments.append("-sTCP:LISTEN")
            }
            let output = try? await executor.executeSystemCommand(
                arguments: arguments
            )
            guard let output,
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let process = output.split(separator: "\n").dropFirst().first
                .flatMap { $0.split(whereSeparator: \Character.isWhitespace).first }
                .map(String.init) ?? "未知进程"
            return "宿主机 \(endpoint.protocolName.uppercased()) 端口 \(endpoint.port) 已被「\(process)」占用；请停止占用者或修改模板端口后重试"
        }
        return nil
    }

    private func hostPorts(from mappings: [String]) -> [Int] {
        Array(Set(publishedHostEndpoints(from: mappings).map(\.port))).sorted()
    }

    private func publishedHostEndpoints(from mappings: [String]) -> [(port: Int, protocolName: String)] {
        var seen = Set<String>()
        return mappings.compactMap { mapping in
            let protocolParts = mapping.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let value = String(protocolParts[0])
            let protocolName = protocolParts.count > 1 ? protocolParts[1].lowercased() : "tcp"
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            guard let port = Int(fields[fields.count - 2]), (1...65_535).contains(port) else { return nil }
            let normalizedProtocol = protocolName == "udp" ? "udp" : "tcp"
            guard seen.insert("\(normalizedProtocol):\(port)").inserted else { return nil }
            return (port, normalizedProtocol)
        }
    }

    private func actionableCreationError(_ error: Error, publishedPorts: [String]) -> Error {
        let message = error.localizedDescription
        guard message.localizedCaseInsensitiveContains("Address already in use")
                || message.localizedCaseInsensitiveContains("errno: 48") else { return error }
        let ports = hostPorts(from: publishedPorts).map(String.init).joined(separator: "、")
        let target = ports.isEmpty ? "配置的宿主机端口" : "宿主机端口 \(ports)"
        return ContainerError.commandFailed("\(target) 已被占用，Apple Container 无法建立端口转发；请停止占用者或修改模板端口后重试")
    }

    // MARK: - 获取容器日志
    func fetchContainerLogsRaw(id: String, boot: Bool = false, tail: Int? = nil) async throws -> String {
        let args = catalog.arguments(command: "container.logs", options: [
            "boot": boot ? ["true"] : [], "tail": tail.map { [String($0)] } ?? []
        ], positionals: [id])
        let command = "container \(args.joined(separator: " "))"
        do {
            let output = try await executor.execute(args)
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: boot ? "查看启动日志" : "查看日志")
            return output
        } catch {
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "容器", operationType: "查看日志失败")
            throw error
        }
    }

    // MARK: - 打开终端
    func openTerminal(for container: Container) {
        let terminalCommand = ContainerCommandBuilder.displayCommand(for: catalog.arguments(
            command: "container.exec",
            options: ["interactive": ["true"], "tty": ["true"]],
            positionals: [container.id, "sh"]
        ))
        let script = """
        tell application "Terminal"
            activate
            do script "\(terminalCommand)"
            activate
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = nil
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorMsg = String(data: errorData, encoding: .utf8) ?? "未知错误"
                print("AppleScript 执行失败: \(errorMsg)")
                fallbackOpenTerminal(container: container)
            } else {
                print("已通过 AppleScript 打开终端")
            }
        } catch {
            print("启动 osascript 失败: \(error)")
            fallbackOpenTerminal(container: container)
        }
    }

    private func fallbackOpenTerminal(container: Container) {
        let fallbackScript = """
        tell application "Terminal"
            activate
            set newTab to do script "echo '请运行: container exec -it \(container.id) sh'"
            set frontmost of window 1 to true
            activate
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", fallbackScript]
        try? task.run()
    }

    // MARK: - 批量操作
    func startAllContainers() async {
        let stopped = containers.filter { $0.state == .stopped || $0.state == .exited }
        guard !stopped.isEmpty else {
            await MainActor.run {
                self.errorMessage = "没有已停止的容器"
            }
            return
        }
        let taskManager = TaskManager.shared
        await MainActor.run {
            self.currentProgress = 0.0
            self.currentProgressMessage = "正在启动 \(stopped.count) 个容器..."
            self.isProgressIndeterminate = false
            taskManager.startTask(module: "容器", operation: "批量启动", command: "批量启动容器")
        }
        var successCount = 0
        for (index, container) in stopped.enumerated() {
            do {
                _ = try await executor.execute(catalog.arguments(command: "container.start", positionals: [container.id]))
                successCount += 1
                await MainActor.run {
                    self.currentProgress = Double(index + 1) / Double(stopped.count)
                    self.currentProgressMessage = "启动容器 \(container.displayName)... (\(index+1)/\(stopped.count))"
                    taskManager.updateProgress(self.currentProgress)
                }
            } catch {
                print("❌ 启动容器 \(container.displayName) 失败: \(error)")
            }
        }
        await MainActor.run {
            self.currentProgress = 1.0
            self.currentProgressMessage = "启动完成（成功 \(successCount)/\(stopped.count)）"
            taskManager.finishTask(success: successCount == stopped.count, message: "启动完成（成功 \(successCount)/\(stopped.count)）")
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.currentProgress = 0.0
                self.currentProgressMessage = ""
                self.isProgressIndeterminate = false
            }
        }
        await fetchContainers()
        logService.log(result: CLIResult(command: "批量启动容器", output: "成功 \(successCount)/\(stopped.count)", exitCode: successCount == stopped.count ? 0 : -1, duration: 0, mode: .async), module: "容器", operationType: "批量启动")
    }

    func stopAllContainers() async {
        let running = containers.filter { $0.state == .running }
        guard !running.isEmpty else {
            await MainActor.run {
                self.errorMessage = "没有运行中的容器"
            }
            return
        }
        let taskManager = TaskManager.shared
        await MainActor.run {
            self.currentProgress = 0.0
            self.currentProgressMessage = "正在停止 \(running.count) 个容器..."
            self.isProgressIndeterminate = false
            taskManager.startTask(module: "容器", operation: "批量停止", command: "批量停止容器")
        }
        var successCount = 0
        for (index, container) in running.enumerated() {
            do {
                _ = try await executor.execute(catalog.arguments(command: "container.stop", positionals: [container.id]))
                successCount += 1
                await MainActor.run {
                    self.currentProgress = Double(index + 1) / Double(running.count)
                    self.currentProgressMessage = "停止容器 \(container.displayName)... (\(index+1)/\(running.count))"
                    taskManager.updateProgress(self.currentProgress)
                }
            } catch {
                print("❌ 停止容器 \(container.displayName) 失败: \(error)")
            }
        }
        await MainActor.run {
            self.currentProgress = 1.0
            self.currentProgressMessage = "停止完成（成功 \(successCount)/\(running.count)）"
            taskManager.finishTask(success: successCount == running.count, message: "停止完成（成功 \(successCount)/\(running.count)）")
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.currentProgress = 0.0
                self.currentProgressMessage = ""
                self.isProgressIndeterminate = false
            }
        }
        await fetchContainers()
        logService.log(result: CLIResult(command: "批量停止容器", output: "成功 \(successCount)/\(running.count)", exitCode: successCount == running.count ? 0 : -1, duration: 0, mode: .async), module: "容器", operationType: "批量停止")
    }

    // MARK: - 重建容器（编辑后重建）
    func recreateContainer(with config: ContainerConfig, originalID: String) async throws {
        let oldName = config.name ?? originalID
        let taskManager = TaskManager.shared
        await MainActor.run {
            taskManager.startTask(module: "容器", operation: "编辑重建", command: "重建容器 \(oldName)")
        }
        // 停止
        do {
            _ = try await executor.execute(catalog.arguments(command: "container.stop", positionals: [oldName]))
        } catch {
            print("停止容器失败（可能已停止）: \(error)")
        }
        // 使用 1.2.x 正式删除指令，并等待同名容器及其网络租约完全释放。
        // 立即同名创建会与旧的 .local hostname 记录发生竞态。
        _ = try await executor.execute(catalog.arguments(command: "container.delete", options: ["force": ["true"]], positionals: [oldName]))
        for _ in 0..<20 {
            if (try? await executor.execute(catalog.arguments(command: "container.inspect", positionals: [oldName]))) == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        // 使用新配置创建
        let newID = try await createContainer(
            name: oldName,
            image: config.image,
            detach: config.detach,
            ports: config.ports,
            env: config.env,
            volumes: config.volumes.map { $0.source.isEmpty ? $0.destination : "\($0.source):\($0.destination)" },
            options: config.options
        )
        // DNS 是网络运行时状态，不以展示标签作为成功依据。等待 inspect 中
        // 的真实 hostname 重新出现后才结束重建流程。
        if let expectedDNS = config.options.labels[AppConstants.ContainerLabel.applicationDNSName] {
            var registered = false
            for _ in 0..<20 {
                if let output = try? await executor.execute(catalog.arguments(command: "container.inspect", positionals: [newID])),
                   let data = output.data(using: .utf8),
                   let inspected = try? JSONDecoder().decode([Container].self, from: data).first,
                   let runtimeHostname = inspected.hostname {
                    let expected = expectedDNS.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    let actual = runtimeHostname.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if actual.caseInsensitiveCompare(expected) == .orderedSame {
                        registered = true
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard registered else {
                throw ContainerError.commandFailed("容器已重建，但内部 DNS「\(expectedDNS)」尚未注册；请稍后重试启动，或检查容器是否仍连接 default 网络")
            }
        }
        await fetchContainers()
        await MainActor.run {
            taskManager.finishTask(success: true, message: "容器重建成功 ✅")
        }
    }
}
