//
//  ImageArchiveManager.swift
//  AiguruContainerPanel
//
//  镜像归档管理器：基于 image save/load 的归档创建、导入、删除。
//

import Foundation
import Combine

@MainActor
final class ImageArchiveManager: ObservableObject {
    static let shared = ImageArchiveManager()

    @Published var archives: [ImageArchive] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let taskManager = TaskManager.shared
    private let catalog = CLICommandCatalog.shared

    private init() {
        loadArchives()
    }

    /// 新归档存储目录；不读取旧 ImageSnapshots 数据。
    var archivesDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AiguruContainerPanel/ImageArchives")
    }

    private var indexURL: URL {
        archivesDirectory.appendingPathComponent("archives.json")
    }

    // MARK: - 读取索引

    func loadArchives() {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([ImageArchive].self, from: data) else {
            archives = []
            return
        }
        archives = decoded
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(archives) {
            try? data.write(to: indexURL)
        }
    }

    // MARK: - 某镜像的归档（按时间倒序）

    func archives(for imageName: String) -> [ImageArchive] {
        archives
            .filter { $0.imageName == imageName }
            .sorted { $0.timestamp > $1.timestamp }
    }

    func hasArchive(_ imageName: String) -> Bool {
        !archives(for: imageName).isEmpty
    }

    // MARK: - 创建归档（image save）

    func createArchive(of image: SourceImage, note: String?) async throws {
        try? FileManager.default.createDirectory(at: archivesDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: Date())
        let safeName = image.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let archiveURL = archivesDirectory.appendingPathComponent("\(safeName)_\(stamp).tar")

        let command = "image save --output \"\(archiveURL.path)\" \(image.name)"
        isLoading = true
        taskManager.startTask(module: "镜像归档", operation: "创建", command: command)
        taskManager.setIndeterminate(true)
        taskManager.appendOutput("正在归档镜像 \(image.name)...")

        do {
            // 只保存主机平台（轻量 VM），避免全平台膨胀
            let platform = Self.hostPlatform()
            var usedPlatform = true
            var saved = false
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let args = catalog.arguments(command: "image.save", options: [
                        "platform": usedPlatform ? [platform] : [], "output": [archiveURL.path]
                    ], positionals: [image.name])
                    _ = try await executor.execute(args, progressHandler: { line in
                        Task { @MainActor in
                            self.taskManager.appendOutput(line)
                            if let percent = line.percentageProgress {
                                self.taskManager.updateProgress(percent / 100.0)
                            } else if line.contains("Compressing") || line.contains("Saving") {
                                self.taskManager.setIndeterminate(true)
                            }
                        }
                    })
                    saved = true
                    break
                } catch {
                    lastError = error
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("digest") && attempt < 3 {
                        // 镜像内容不完整：只拉取主机平台补齐后重试
                        taskManager.appendOutput("镜像内容不完整，正在重新拉取补齐 \(image.name)（仅 \(platform)）...")
                        let pullArgs = catalog.arguments(command: "image.pull", options: [
                            "platform": usedPlatform ? [platform] : []
                        ], positionals: [image.name])
                        _ = try await executor.execute(pullArgs, progressHandler: { line in
                            Task { @MainActor in
                                self.taskManager.appendOutput(line)
                                if line.contains("Unpacking") { self.taskManager.setIndeterminate(true) }
                            }
                        })
                    } else if desc.contains("platform") && usedPlatform {
                        // 镜像无该平台变体 → 回退为全平台保存
                        usedPlatform = false
                    } else {
                        throw error
                    }
                }
            }
            if !saved, let lastError { throw lastError }

            let size = (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64) ?? 0
            let archive = ImageArchive(imageName: image.name, timestamp: Date(),
                                       archivePath: archiveURL.path, sizeBytes: size, note: note)
            archives.insert(archive, at: 0)
            persist()
            isLoading = false
            taskManager.finishTask(success: true, message: "镜像归档创建成功 ✅")
            logService.log(result: CLIResult(command: command, output: "OK", exitCode: 0, duration: 0, mode: .stream),
                           module: "镜像归档", operationType: "创建")
        } catch {
            isLoading = false
            errorMessage = "镜像归档创建失败: \(error.localizedDescription)"
            taskManager.finishTask(success: false, message: errorMessage ?? "镜像归档创建失败")
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream),
                           module: "镜像归档", operationType: "创建失败")
            throw error
        }
    }

    /// 主机容器平台（轻量 VM 运行平台）
    static func hostPlatform() -> String {
        var uts = utsname()
        uname(&uts)
        let mirror = Mirror(reflecting: uts.machine)
        let machine = mirror.children.reduce("") { partial, child in
            guard let c = child.value as? Int8, c != 0 else { return partial }
            return partial + String(UnicodeScalar(UInt8(bitPattern: c)))
        }
        return machine.contains("arm") ? "linux/arm64" : "linux/amd64"
    }

    // MARK: - 导入归档（image load ← tar）

    func importArchive(_ archive: ImageArchive, force: Bool = false) async throws {
        let command = "image load --input \"\(archive.archivePath)\"" + (force ? " --force" : "")
        isLoading = true
        taskManager.startTask(module: "镜像归档", operation: "导入", command: command)
        taskManager.setIndeterminate(true)
        taskManager.appendOutput("正在从归档导入 \(archive.imageName) ...")

        do {
            let args = catalog.arguments(command: "image.load", options: [
                "input": [archive.archivePath], "force": force ? ["true"] : []
            ])
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    self.taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        self.taskManager.updateProgress(percent / 100.0)
                    } else if line.contains("Loading") || line.contains("Unpacking") {
                        self.taskManager.setIndeterminate(true)
                    }
                }
            })
            isLoading = false
            taskManager.finishTask(success: true, message: "导入完成 ✅ \(archive.imageName)")
            logService.log(result: CLIResult(command: command, output: "OK", exitCode: 0, duration: 0, mode: .stream),
                           module: "镜像归档", operationType: "导入")
        } catch {
            isLoading = false
            errorMessage = "导入失败: \(error.localizedDescription)"
            taskManager.finishTask(success: false, message: errorMessage ?? "导入失败")
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream),
                           module: "镜像归档", operationType: "导入失败")
            throw error
        }
    }

    // MARK: - 删除归档

    func deleteArchive(_ archive: ImageArchive) {
        if FileManager.default.fileExists(atPath: archive.archivePath) {
            try? FileManager.default.removeItem(atPath: archive.archivePath)
        }
        archives.removeAll { $0.id == archive.id }
        persist()
        logService.log(result: CLIResult(command: "delete archive \(archive.archiveName)", output: "OK", exitCode: 0, duration: 0, mode: .async),
                       module: "镜像归档", operationType: "删除")
    }

    /// 显式删除某镜像的全部归档。镜像删除与 prune 不会调用此方法。
    @discardableResult
    func deleteAll(for imageName: String) -> Int {
        let targets = archives.filter { $0.imageName == imageName }
        for t in targets {
            if FileManager.default.fileExists(atPath: t.archivePath) {
                try? FileManager.default.removeItem(atPath: t.archivePath)
            }
        }
        archives.removeAll { $0.imageName == imageName }
        persist()
        return targets.count
    }
}
