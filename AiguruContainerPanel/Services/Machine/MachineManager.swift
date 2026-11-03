//
//  MachineManager.swift
//  AiguruContainerPanel
//
//  Machine 管理服务；命令能力由 CLICommandCatalog 按 Apple Container 版本驱动。
//  内核安装方法增加日志记录。
//

import Foundation
import Combine

class MachineManager: ObservableObject {
    static let shared = MachineManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared

    @Published var machines: [ContainerMachine] = []
    @Published var defaultMachine: ContainerMachine?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 列表
    func fetchMachines() async {
        await MainActor.run { self.isLoading = true }
        let command = "machine list --format json"
        do {
            let output = try await executor.execute(catalog.arguments(command: "machine.list", options: ["format": ["json"]]))
            guard !output.isEmpty else {
                await MainActor.run {
                    self.machines = []
                    self.isLoading = false
                }
                return
            }
            let data = output.data(using: .utf8) ?? Data()
            let decoded = try JSONDecoder().decode([ContainerMachine].self, from: data)
            print("🖥️ fetchMachines 解析成功: \(decoded.map { "\($0.name)=\($0.state.rawValue)" }.joined(separator: ", "))")
            await MainActor.run {
                self.machines = decoded
                self.errorMessage = nil
                self.isLoading = false
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "列表刷新")
        } catch {
            print("🖥️ fetchMachines JSON 解析失败: \(error.localizedDescription)，回退纯文本解析")
            await fallbackFetchMachines()
        }
    }

    private func fallbackFetchMachines() async {
        let command = "machine list"
        do {
            let output = try await executor.execute(catalog.arguments(command: "machine.list"))
            let lines = output.split(separator: "\n")
            guard lines.count > 1 else {
                await MainActor.run {
                    self.machines = []
                    self.isLoading = false
                }
                return
            }
            var parsed: [ContainerMachine] = []
            let regex = try NSRegularExpression(pattern: "\\s{2,}")
            for line in lines.dropFirst() {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                let parts = regex.stringByReplacingMatches(in: trimmed, range: NSRange(0..<trimmed.utf16.count), withTemplate: "\t").split(separator: "\t")
                // columns: NAME, CREATED, IP, CPUS, MEMORY, DISK, STATE, DEFAULT
                guard parts.count >= 7 else { continue }
                let name = String(parts[0])
                let stateRaw = String(parts[6])
                let state = MachineState(rawValue: stateRaw) ?? .unknown
                print("🖥️ fallbackFetchMachines: \(name) stateRaw='\(stateRaw)' → \(state)")
                let machine = ContainerMachine(
                    id: name, state: state
                )
                parsed.append(machine)
            }
            await MainActor.run {
                self.machines = parsed
                self.errorMessage = nil
                self.isLoading = false
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "列表刷新(回退)")
        } catch {
            await MainActor.run {
                self.machines = []
                self.isLoading = false
                self.errorMessage = "获取 Machine 列表失败: \(error.localizedDescription)"
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "列表刷新失败")
        }
    }
    // MARK: - 查询当前内核
    /// 轮询 machine ls 确认指定名称的 Machine 是否已存在（不触碰 isLoading/errorMessage）
    /// 用于创建命令返回后校验真实结果：CLI 可能报错/超时，但后台 daemon 仍完成了创建
    private func machineExists(name: String, attempts: Int = 5, delayNanoseconds: UInt64 = 1_000_000_000) async -> Bool {
        for _ in 0..<attempts {
            if let output = try? await executor.execute(catalog.arguments(command: "machine.list", options: ["format": ["json"]])),
               let data = output.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([ContainerMachine].self, from: data),
               decoded.contains(where: { $0.name == name }) {
                return true
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return false
    }

    func fetchCurrentKernel(appRoot: String? = nil) async -> String? {
        let resolvedAppRoot: String
        if let appRoot, !appRoot.isEmpty {
            resolvedAppRoot = appRoot
        } else {
            let home = executor.environment?.envVars?["HOME"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
            resolvedAppRoot = home
                .appendingPathComponent("Library/Application Support/com.apple.container", isDirectory: true).path
        }
        let kernelDirectory = URL(fileURLWithPath: resolvedAppRoot, isDirectory: true)
            .appendingPathComponent("kernels", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: kernelDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), !entries.isEmpty else { return nil }
        return "已配置内核 (\(entries.count) 项)"
    }

    /// 卸载当前工作环境中由 Apple Container 管理的全部内核。
    ///
    /// 官方 CLI 目前只提供 `system kernel set`，没有 delete 子命令。为避免服务仍持有
    /// 内核文件，先停止当前环境的服务，再将 kernels 目录中的内容移入废纸篓。
    /// 调用方应先确认没有运行中的容器或 Machine。
    func uninstallKernels(appRoot: String) async throws -> Int {
        let trimmedRoot = appRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            throw ContainerError.commandFailed("无法确定当前工作环境的数据根目录")
        }

        let rootURL = URL(fileURLWithPath: trimmedRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let kernelDirectory = rootURL
            .appendingPathComponent("kernels", isDirectory: true)
            .standardizedFileURL
        guard kernelDirectory.deletingLastPathComponent() == rootURL else {
            throw ContainerError.commandFailed("内核目录校验失败，已取消卸载")
        }

        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: kernelDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: []
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return 0
        }
        guard !entries.isEmpty else { return 0 }

        let taskManager = TaskManager.shared
        let command = "container system stop && move <app-root>/kernels/* to Trash"
        await MainActor.run {
            taskManager.startTask(
                module: "系统",
                operation: "卸载内核",
                command: command,
                timeout: AppConstants.Time.standardCommandTimeout
            )
            self.isLoading = true
        }

        do {
            await MainActor.run { taskManager.appendOutput("正在停止 Apple Container 服务…") }
            _ = try await executor.execute(catalog.arguments(command: "system.stop"))

            var removedCount = 0
            for entry in entries {
                // 再次约束每个目标必须是 kernels 的直接子项，避免路径或符号链接越界。
                guard entry.standardizedFileURL.deletingLastPathComponent() == kernelDirectory else {
                    throw ContainerError.commandFailed("发现不安全的内核路径：\(entry.lastPathComponent)")
                }
                var trashedURL: NSURL?
                try fileManager.trashItem(at: entry, resultingItemURL: &trashedURL)
                removedCount += 1
                await MainActor.run {
                    taskManager.appendOutput("已移到废纸篓：\(entry.lastPathComponent)")
                }
            }

            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "已卸载 \(removedCount) 项内核资源")
            }
            logService.log(
                result: CLIResult(command: command, output: "已移到废纸篓 \(removedCount) 项", exitCode: 0, duration: 0, mode: .async),
                module: "系统",
                operationType: "卸载内核"
            )
            return removedCount
        } catch {
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: false, message: "内核卸载失败：\(error.localizedDescription)")
            }
            logService.log(
                result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async),
                module: "系统",
                operationType: "卸载内核失败"
            )
            throw error
        }
    }
    
    /// 获取已安装的内核列表（当前版本无直接命令）
        func fetchKernels() async -> [String] {
            return []
        }
    
    
    // MARK: - 创建 Machine
    func createMachine(_ configuration: MachineCreateConfiguration) async throws {
        let taskManager = TaskManager.shared
        let validatedConfiguration: MachineCreateConfiguration
        switch configuration.validated {
        case .success(let value): validatedConfiguration = value
        case .failure(let error): throw error
        }
        let args = MachineCommandBuilder.createArguments(for: validatedConfiguration)
        let fullCommand = ContainerCommandBuilder.displayCommand(for: args)
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "创建", command: fullCommand, timeout: AppConstants.Time.streamingCommandTimeout)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if line.contains("Fetching") || line.contains("Downloading") {
                        taskManager.setIndeterminate(true)
                    } else if line.contains("Created") || line.contains("done") {
                        taskManager.updateProgress(0.8)
                    } else if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    }
                }
            })
            // 创建命令返回成功，延时确认机器已在列表中可见（CLI 可能已返回但 daemon 尚未落盘）
            let confirmed = await machineExists(name: validatedConfiguration.name, attempts: 5)
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: confirmed ? "Machine 创建成功 ✅" : "Machine 创建成功，等待列表刷新 ⏳")
            }
            await fetchMachines()
            let result = CLIResult(command: fullCommand, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "Machine", operationType: "创建")
        } catch {
            // 命令报错时先校验真实结果：CLI 可能已创建成功却返回错误（如 "Error: container"）
            // 或报"已存在"，此时机器实际已在列表中，应视为创建成功而非失败
            if await machineExists(name: validatedConfiguration.name, attempts: 3) {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = nil
                    taskManager.finishTask(success: true, message: "Machine 已创建（存在同名实例）✅")
                }
                await fetchMachines()
                let result = CLIResult(command: fullCommand, output: "machine exists", exitCode: 0, duration: 0, mode: .stream)
                logService.log(result: result, module: "Machine", operationType: "创建(确认已存在)")
                return
            }
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "创建 Machine 失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "创建失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: fullCommand, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "Machine", operationType: "创建失败")
            throw error
        }
    }

    // MARK: - 运行命令（重试）
    func runCommand(in machine: ContainerMachine, command: String? = nil) async throws -> String {
        let taskManager = TaskManager.shared
        let name = machine.name
        var args = catalog.arguments(command: "machine.run", options: ["name": [name]])
        if let cmd = command, !cmd.isEmpty {
            args.append(cmd)
        }
        let fullCommand = args.joined(separator: " ")
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "运行命令", command: fullCommand)
        }

        var lastError: Error?
        for attempt in 1...3 {
            do {
                let output = try await executor.execute(args, progressHandler: { line in
                    Task { @MainActor in
                        taskManager.appendOutput(line)
                        if line.contains("done") || line.contains("success") {
                            taskManager.updateProgress(1.0)
                        }
                    }
                })
                await MainActor.run {
                    taskManager.finishTask(success: true, message: "执行完成 ✅")
                }
                return output
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
            }
        }
        await MainActor.run {
            self.errorMessage = "执行失败: \(lastError?.localizedDescription ?? "未知错误")"
            taskManager.finishTask(success: false, message: "执行失败: \(lastError?.localizedDescription ?? "未知错误")")
        }
        throw lastError ?? ContainerError.commandFailed("执行失败")
    }

    // MARK: - 启动 Machine（machine start 不存在，用 run 启动）
    func startMachine(_ machine: ContainerMachine) async throws {
        let taskManager = TaskManager.shared
        let command = "machine run -n \(machine.name) echo ok"
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "启动", command: command)
            self.isLoading = true
        }

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                // run 不带命令会进入交互式 shell；用 echo ok 触发启动并返回
                _ = try await executor.execute(catalog.arguments(command: "machine.run", options: ["name": [machine.name]], positionals: ["echo", "ok"]))
                await MainActor.run {
                    self.isLoading = false
                    taskManager.finishTask(success: true, message: "\(machine.name) 已启动 ✅")
                }
                try await Task.sleep(nanoseconds: 800_000_000)
                await fetchMachines()
                try await Task.sleep(nanoseconds: 1_200_000_000)
                await fetchMachines()
                logService.log(result: CLIResult(command: command, output: "OK", exitCode: 0, duration: 0, mode: .async), module: "Machine", operationType: "启动")
                return
            } catch {
                lastError = error
                print("🖥️ startMachine 尝试 \(attempt + 1)/3 失败: \(error.localizedDescription)")
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        await MainActor.run {
            self.isLoading = false
            self.errorMessage = "启动失败: \(lastError?.localizedDescription ?? "")"
            taskManager.finishTask(success: false, message: "启动失败: \(lastError?.localizedDescription ?? "")")
        }
        throw lastError ?? ContainerError.commandFailed("启动失败")
    }

    // MARK: - 停止 Machine
    func stopMachine(_ machine: ContainerMachine) async throws {
        let taskManager = TaskManager.shared
        let command = "machine stop \(machine.name)"
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "停止", command: command)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "machine.stop", positionals: [machine.name]))
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "已停止 ✅")
            }
            await fetchMachines()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "停止")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "停止失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "停止失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "停止失败")
            throw error
        }
    }

    // MARK: - 删除 Machine
    func deleteMachine(_ machine: ContainerMachine) async throws {
        let taskManager = TaskManager.shared
        let command = "machine delete \(machine.name)"
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "删除", command: command)
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "machine.delete", positionals: [machine.name]))
            await MainActor.run {
                taskManager.finishTask(success: true, message: "删除成功 ✅")
            }
            await fetchMachines()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "删除")
        } catch {
            await MainActor.run {
                self.errorMessage = "删除失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "删除失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "删除失败")
            throw error
        }
    }

    // MARK: - 设置默认 Machine
    func setDefaultMachine(_ machine: ContainerMachine) async throws {
        let taskManager = TaskManager.shared
        let command = "machine set-default \(machine.name)"
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "设置默认", command: command)
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "machine.setDefault", positionals: [machine.name]))
            await MainActor.run {
                taskManager.finishTask(success: true, message: "设置默认成功 ✅")
            }
            await fetchMachines()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "设置默认")
        } catch {
            await MainActor.run {
                self.errorMessage = "设置默认失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "设置默认失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "设置默认失败")
            throw error
        }
    }

    // MARK: - 更新 Machine 配置
    func updateMachine(_ machine: ContainerMachine, config: MachineConfig) async throws {
        let taskManager = TaskManager.shared
        var args = catalog.arguments(command: "machine.set", options: ["name": [machine.name]])
        if let cpus = config.cpus { args.append(contentsOf: ["cpus=\(cpus)"]) }
        if let memory = config.memory, !memory.isEmpty { args.append(contentsOf: ["memory=\(memory)"]) }
        if let homeMount = config.homeMount, !homeMount.isEmpty { args.append(contentsOf: ["home-mount=\(homeMount)"]) }
        if let virtualization = config.virtualization { args.append("virtualization=\(virtualization ? "true" : "false")") }
        if let kernel = config.kernel, !kernel.isEmpty { args.append(contentsOf: ["kernel=\(kernel)"]) }

        let fullCommand = args.joined(separator: " ")
        await MainActor.run {
            taskManager.startTask(module: "Machine", operation: "更新配置", command: fullCommand)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(args)
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "更新完成 ✅")
            }
            await fetchMachines()
            let result = CLIResult(command: fullCommand, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "更新配置")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "更新失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "更新失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: fullCommand, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "更新配置失败")
            throw error
        }
    }

    // MARK: - 查看详情
    func inspectMachine(_ machine: ContainerMachine) async throws -> String {
        let command = "machine inspect \(machine.name)"
        do {
            let output = try await executor.execute(catalog.arguments(command: "machine.inspect", positionals: [machine.name]))
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "查看详情")
            return output
        } catch {
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "查看详情失败")
            throw error
        }
    }

    // MARK: - 获取 Machine 日志
    func fetchMachineLogs(_ machine: ContainerMachine, boot: Bool = false, tail: Int? = nil) async throws -> String {
        let args = catalog.arguments(command: "machine.logs", options: [
            "boot": boot ? ["true"] : [], "tail": tail.map { [String($0)] } ?? []
        ], positionals: [machine.name])
        let command = "container \(args.joined(separator: " "))"
        do {
            let output = try await executor.execute(args)
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: boot ? "查看启动日志" : "查看日志")
            return output
        } catch {
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "Machine", operationType: "查看日志失败")
            throw error
        }
    }

    /// 通过 `machine inspect` 获取镜像引用，更新到 machines 列表
    func fetchImage(for machine: ContainerMachine) async {
        do {
            let output = try await executor.execute(catalog.arguments(command: "machine.inspect", positionals: [machine.name]))
            guard let data = output.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let info = json.first,
                  let imageDict = info["image"] as? [String: Any],
                  let ref = imageDict["reference"] as? String else { return }
            await MainActor.run {
                if let idx = self.machines.firstIndex(where: { $0.id == machine.id }) {
                    self.machines[idx].image = ref
                }
            }
        } catch {
            print("🖥️ fetchImage 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 获取默认 Machine
    func fetchDefaultMachine() async -> ContainerMachine? {
        await fetchMachines()
        // `machine set-default` only sets a value and requires an ID; current CLI has
        // no separate getter. The list JSON marks the default machine directly.
        return machines.first(where: { $0.isDefault })
    }

    //MARK: - 安装推荐内核
    func installRecommendedKernel() async throws {
        let taskManager = TaskManager.shared
        let catalog = CLICommandCatalog.shared
        let version = EnvironmentManager.shared.currentVersion
        guard let commandPath = catalog.path(command: "system.kernel.set", version: version) else {
            let required = catalog.minimumVersion(command: "system.kernel.set")?.description ?? "未知"
            throw ContainerError.commandFailed("当前工作环境 Container \(version.description) 不支持安装内核（需要 \(required)+）")
        }
        let recommendedFlag = catalog.flag(command: "system.kernel.set", option: "recommended")
        var args = commandPath + [recommendedFlag]
        let supportsForce = catalog.supports(
            command: "system.kernel.set",
            option: "force",
            version: version
        )
        if supportsForce {
            args.append(catalog.flag(command: "system.kernel.set", option: "force"))
        }
        let command = ContainerCommandBuilder.displayCommand(for: args)
        await MainActor.run {
            taskManager.startTask(module: "系统", operation: "安装推荐内核", command: command, timeout: AppConstants.Time.streamingCommandTimeout)
            self.isLoading = true
        }

        let startResult = CLIResult(command: command, output: "开始安装推荐内核", exitCode: 0, duration: 0, mode: .async)
        logService.log(result: startResult, module: "系统", operationType: "安装推荐内核")

        do {
            await MainActor.run {
                taskManager.appendOutput("已在应用中确认安装；如 CLI 请求 [Y/n]，将自动回答 y。")
                if supportsForce {
                    taskManager.appendOutput("当前指令档位支持 --force；发现同名内核时将由 CLI 安全覆盖。")
                }
                taskManager.setIndeterminate(true)
            }
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    }
                }
            }, stdinData: AppConstants.CLI.affirmativeInput)
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "推荐内核安装成功 ✅")
            }
            let successResult = CLIResult(command: command, output: "推荐内核安装成功", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: successResult, module: "系统", operationType: "安装推荐内核成功")
        } catch {
            let rawMessage = error.localizedDescription
            let isExistingKernelConflict = rawMessage.contains("NSCocoaErrorDomain Code=516")
                || rawMessage.contains("NSPOSIXErrorDomain Code=17")
                || rawMessage.localizedCaseInsensitiveContains("already exists")
            let displayedError: Error
            if isExistingKernelConflict && !supportsForce {
                displayedError = ContainerError.commandFailed(
                    "当前 CLI 指令档位不支持 --force，且 kernels 目录已有同名内核。请先在“内核管理”中卸载旧内核，再重新安装推荐内核。"
                )
            } else if isExistingKernelConflict {
                displayedError = ContainerError.commandFailed(
                    "CLI 使用 --force 后仍无法覆盖同名内核。请先在“内核管理”中卸载现有内核，再重新安装。原始错误：\(rawMessage)"
                )
            } else {
                displayedError = error
            }
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: false, message: "内核安装失败: \(displayedError.localizedDescription)")
            }
            let failResult = CLIResult(command: command, output: displayedError.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: failResult, module: "系统", operationType: "安装推荐内核失败")
            throw displayedError
        }
    }

   
    // MARK: - 安装自定义内核
        /// - Parameters:
        ///   - fileURL: 内核文件或压缩包 URL
        ///   - binaryName: 内核二进制文件名（可选），仅当文件为压缩包时有效
        func installCustomKernel(fileURL: URL, binaryName: String? = nil) async throws {
            let taskManager = TaskManager.shared
            let filePath = fileURL.path
            let fileExtension = fileURL.pathExtension.lowercased()
            let isArchive = ["tar", "tgz", "tzst", "tar.zst", "zip"].contains(fileExtension)

            var kernelOptions: [String: [String]] = [:]

            if isArchive {
                // 需要指定二进制文件名
                var finalBinaryName = binaryName
                if finalBinaryName == nil {
                    // 无法在提交命令前探测归档成员，使用官方常见默认名称。
                    finalBinaryName = "vmlinux"
                }
                guard let binary = finalBinaryName else {
                    throw ContainerError.commandFailed("未指定内核二进制文件名，且无法自动探测。请指定二进制文件名。")
                }
                kernelOptions["tar"] = [filePath]
                kernelOptions["binary"] = [binary]
            } else {
                // 直接作为二进制文件
                kernelOptions["binary"] = [filePath]
            }

            let args = catalog.arguments(command: "system.kernel.set", options: kernelOptions)

            let command = "container " + args.joined(separator: " ")
            await MainActor.run {
                taskManager.startTask(module: "系统", operation: "安装自定义内核", command: command, timeout: AppConstants.Time.streamingCommandTimeout)
                self.isLoading = true
            }

            let startResult = CLIResult(command: command, output: "开始安装自定义内核: \(filePath)", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: startResult, module: "系统", operationType: "安装自定义内核")

            do {
                _ = try await executor.execute(args, progressHandler: { line in
                    Task { @MainActor in
                        taskManager.appendOutput(line)
                        if let percent = line.percentageProgress {
                            taskManager.updateProgress(percent / 100.0)
                        }
                    }
                })
                await MainActor.run {
                    self.isLoading = false
                    taskManager.finishTask(success: true, message: "自定义内核安装成功 ✅")
                }
                let successResult = CLIResult(command: command, output: "自定义内核安装成功", exitCode: 0, duration: 0, mode: .async)
                logService.log(result: successResult, module: "系统", operationType: "安装自定义内核成功")
            } catch {
                // 如果错误是 "kernel not found in archive"，尝试其他常见名称
                if let containerError = error as? ContainerError,
                   containerError.localizedDescription.contains("kernel not found in archive") {
                    // 尝试用 vmlinux 重试
                    let retryArgs = catalog.arguments(command: "system.kernel.set", options: [
                        "tar": [filePath], "binary": ["vmlinux"]
                    ])
                    do {
                        _ = try await executor.execute(retryArgs, progressHandler: { line in
                            Task { @MainActor in
                                taskManager.appendOutput(line)
                                if let percent = line.percentageProgress {
                                    taskManager.updateProgress(percent / 100.0)
                                }
                            }
                        })
                        await MainActor.run {
                            self.isLoading = false
                            taskManager.finishTask(success: true, message: "自定义内核安装成功 ✅ (使用 vmlinux)")
                        }
                        let successResult = CLIResult(command: command, output: "自定义内核安装成功 (使用 vmlinux)", exitCode: 0, duration: 0, mode: .async)
                        logService.log(result: successResult, module: "系统", operationType: "安装自定义内核成功")
                        return
                    } catch {
                        // 重试失败，抛出原始错误
                    }
                }
                await MainActor.run {
                    self.isLoading = false
                    taskManager.finishTask(success: false, message: "自定义内核安装失败: \(error.localizedDescription)")
                }
                let failResult = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
                logService.log(result: failResult, module: "系统", operationType: "安装自定义内核失败")
                throw error
            }
        }

    
    

}
