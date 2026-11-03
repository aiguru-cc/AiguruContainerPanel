import Foundation

/// 导出容器可移植部分：文件系统 tar、inspect 配置和备份说明。
/// 命名卷与 bind mount 属于容器文件系统之外，必须由用户单独备份。
final class ContainerBackupManager {
    static let shared = ContainerBackupManager()

    private let executor = CommandExecutor.shared
    private let catalog = CLICommandCatalog.shared
    private let taskManager = TaskManager.shared
    private let logService = LogService.shared

    private init() {}

    enum BackupError: LocalizedError {
        case invalidManifest
        case unsupportedFormat(Int)
        case missingFile(String)
        case invalidInspect

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "备份说明文件无效"
            case .unsupportedFormat(let version): return "不支持的容器备份格式版本：\(version)"
            case .missingFile(let name): return "备份文件不完整，缺少 \(name)"
            case .invalidInspect: return "无法从 inspect 配置恢复容器参数"
            }
        }
    }

    func createBackup(container: Container, archiveURL: URL) async throws {
        let baseURL = archiveURL.deletingPathExtension()
        let configURL = baseURL.appendingPathExtension("inspect.json")
        let manifestURL = baseURL.appendingPathExtension("backup.json")
        let command = "export \(container.id) --output \"\(archiveURL.path)\""

        await MainActor.run {
            taskManager.startTask(module: "容器备份", operation: "导出", command: command)
            taskManager.setIndeterminate(true)
            taskManager.appendOutput("正在导出容器文件系统…")
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "container.export", options: ["output": [archiveURL.path]], positionals: [container.id]), progressHandler: { line in
                Task { @MainActor in self.taskManager.appendOutput(line) }
            })

            await MainActor.run { taskManager.appendOutput("正在保存容器配置…") }
            let inspect = try await executor.execute(catalog.arguments(command: "container.inspect", positionals: [container.id]))
            try inspect.data(using: .utf8)?.write(to: configURL, options: .atomic)

            let manifest: [String: Any] = [
                "formatVersion": 1,
                "containerID": container.id,
                "containerName": container.displayName,
                "image": container.image,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "filesystemArchive": archiveURL.lastPathComponent,
                "inspectFile": configURL.lastPathComponent,
                "includesVolumes": false,
                "warning": "Named volumes and bind mounts are not included. Back them up separately."
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try manifestData.write(to: manifestURL, options: .atomic)

            await MainActor.run {
                taskManager.finishTask(success: true, message: "容器备份完成；卷数据未包含")
            }
            logService.log(result: CLIResult(command: command, output: "OK", exitCode: 0, duration: 0, mode: .stream), module: "容器备份", operationType: "导出")
        } catch {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: configURL)
            try? FileManager.default.removeItem(at: manifestURL)
            await MainActor.run {
                taskManager.finishTask(success: false, message: "容器备份失败: \(error.localizedDescription)")
            }
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream), module: "容器备份", operationType: "导出失败")
            throw error
        }
    }

    /// 从 `*.backup.json` 恢复。export 产物是 OCI 归档：先加载为镜像，再按 inspect
    /// 中可移植的配置重建容器。卷数据不在备份内，因此不会自动重新挂载。
    func restoreBackup(manifestURL: URL) async throws -> String {
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formatVersion = manifest["formatVersion"] as? Int,
              let archiveName = manifest["filesystemArchive"] as? String,
              let inspectName = manifest["inspectFile"] as? String,
              let originalName = manifest["containerName"] as? String,
              let originalImage = manifest["image"] as? String else {
            throw BackupError.invalidManifest
        }
        guard formatVersion == 1 else { throw BackupError.unsupportedFormat(formatVersion) }

        let directory = manifestURL.deletingLastPathComponent()
        let archiveURL = directory.appendingPathComponent(archiveName)
        let inspectURL = directory.appendingPathComponent(inspectName)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw BackupError.missingFile(archiveName)
        }
        guard FileManager.default.fileExists(atPath: inspectURL.path) else {
            throw BackupError.missingFile(inspectName)
        }

        let inspectData = try Data(contentsOf: inspectURL)
        guard let savedContainer = try? JSONDecoder().decode([Container].self, from: inspectData).first,
              let configuration = savedContainer.configuration else {
            throw BackupError.invalidInspect
        }

        let restoredName = await MainActor.run {
            uniqueRestoredName(originalName, existing: Set(ContainerManager.shared.containers.map(\.displayName)))
        }
        let command = "image load --input \"\(archiveURL.path)\" && run --name \"\(restoredName)\" \(originalImage)"
        await MainActor.run {
            taskManager.startTask(module: "容器备份", operation: "恢复", command: command)
            taskManager.setIndeterminate(true)
            taskManager.appendOutput("正在加载容器文件系统归档…")
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "image.load", options: ["input": [archiveURL.path]]), progressHandler: { line in
                Task { @MainActor in self.taskManager.appendOutput(line) }
            })
            await MainActor.run { taskManager.appendOutput("正在按备份配置创建容器 \(restoredName)…") }

            let ports = (configuration.publishedPorts ?? []).compactMap { port -> String? in
                guard let host = port.hostPortString else { return nil }
                return "\(host):\(port.containerPortString)/\(port.protocolType)"
            }
            let initProcess = configuration.initProcess
            var arguments = initProcess?.arguments ?? []
            let executable = initProcess?.executable
            if let executable, arguments.first == executable { arguments.removeFirst() }
            let user = initProcess?.user?.id
            let cpuLimit: String? = configuration.resources?.cpus.map { String($0) }
            let memoryLimit: String? = configuration.resources?.memoryInBytes.map { String($0) }
            let terminal = initProcess?.terminal ?? false
            let workingDirectory = initProcess?.workingDirectory
            let userID: String? = user?.uid.map { String($0) }
            let groupID: String? = user?.gid.map { String($0) }
            let nameservers = configuration.dns?.nameservers ?? []
            let searchDomains = configuration.dns?.searchDomains ?? []
            let dnsOptions = configuration.dns?.options ?? []
            let labels = configuration.labels ?? [:]
            let options = ContainerRunOptions(
                detach: true,
                interactive: false,
                tty: terminal,
                cpus: cpuLimit,
                memory: memoryLimit,
                entrypoint: executable,
                workdir: workingDirectory,
                user: nil,
                uid: userID,
                gid: groupID,
                initProcess: configuration.useInit ?? false,
                readOnly: configuration.readOnly ?? false,
                network: configuration.networks?.first?.network,
                dns: nameservers,
                dnsSearch: searchDomains,
                dnsOptions: dnsOptions,
                labels: labels,
                rosetta: configuration.rosetta ?? false,
                sshForward: configuration.ssh ?? false,
                virtualization: configuration.virtualization ?? false,
                command: arguments
            )
            _ = try await ContainerManager.shared.createContainer(
                name: restoredName,
                image: originalImage,
                detach: true,
                ports: ports,
                env: initProcess?.environment ?? [],
                volumes: [],
                options: options
            )
            await ContainerManager.shared.fetchContainers()
            await MainActor.run {
                taskManager.finishTask(success: true, message: "容器恢复完成：\(restoredName)；卷数据未恢复")
            }
            logService.log(result: CLIResult(command: command, output: restoredName, exitCode: 0, duration: 0, mode: .stream), module: "容器备份", operationType: "恢复")
            return restoredName
        } catch {
            await MainActor.run {
                taskManager.finishTask(success: false, message: "容器恢复失败: \(error.localizedDescription)")
            }
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream), module: "容器备份", operationType: "恢复失败")
            throw error
        }
    }

    private func uniqueRestoredName(_ original: String, existing: Set<String>) -> String {
        guard existing.contains(original) else { return original }
        var index = 1
        while existing.contains("\(original)-restored-\(index)") { index += 1 }
        return "\(original)-restored-\(index)"
    }
}
