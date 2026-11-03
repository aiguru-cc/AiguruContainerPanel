//
//  SourceImageManager.swift
//  AiguruContainerPanel
//
//  镜像管理服务：列表、拉取、删除、推送、清理未使用。
//  与 EnvironmentManager 集成，支持多工作区，集成 TaskManager 统一进度。
//

import Foundation
import Combine

class SourceImageManager: ObservableObject {
    static let shared = SourceImageManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared

    @Published var images: [SourceImage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - 获取镜像列表
    // 在 SourceImageManager.swift 中
    func fetchImages() async {
        await MainActor.run { self.isLoading = true }

        let command = "image list --format json"
        do {
            let output = try await executor.execute(catalog.arguments(command: "image.list", options: ["format": ["json"]]))
            guard !output.isEmpty else {
                await MainActor.run {
                    self.images = []
                    self.isLoading = false
                }
                return
            }
            let data = output.data(using: .utf8) ?? Data()
            let decoded = try JSONDecoder().decode([SourceImage].self, from: data)
            await MainActor.run {
                self.images = decoded
                self.errorMessage = nil
                self.isLoading = false
            }
            let result = CLIResult(command: command, output: output, exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "列表刷新")
        } catch {
            await MainActor.run {
                self.images = []
                self.errorMessage = "获取镜像列表失败: \(error.localizedDescription)"
                self.isLoading = false
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "列表刷新失败")
        }
    }
    
    // MARK: - 拉取镜像（集成 TaskManager）

    /// 直接查询当前镜像名集合（不触碰 isLoading/errorMessage，供清理对比使用）
    private func currentImageNames() async -> Set<String> {
        guard let output = try? await executor.execute(catalog.arguments(command: "image.list", options: ["format": ["json"]])),
              let data = output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SourceImage].self, from: data) else {
            return []
        }
        return Set(decoded.map { $0.name })
    }
    func pullImage(name: String, tag: String = "latest", platform: String? = nil) async throws {
        let taskManager = TaskManager.shared
        let fullImage = name.imageReference(tag: tag)
        let args = catalog.arguments(command: "image.pull", options: [
            "platform": platform.map { [$0] } ?? []
        ], positionals: [fullImage])
        let command = "container \(args.joined(separator: " "))"

        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "拉取", command: command, timeout: AppConstants.Time.streamingCommandTimeout)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    } else if line.contains("Downloading") || line.contains("Pulling") {
                        taskManager.setIndeterminate(true)
                    }
                }
            })
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "镜像拉取成功 ✅")
            }
            await fetchImages()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "拉取")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "拉取镜像失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "拉取失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "拉取失败")
            throw error
        }
    }

    // MARK: - 构建镜像（image build，支持 Dockerfile/Containerfile）
    func buildImage(
        contextDir: String,
        file: String? = nil,
        tag: String,
        platform: String? = nil,
        target: String? = nil,
        noCache: Bool = false
    ) async throws {
        let taskManager = TaskManager.shared
        // `build` is a top-level Container command, not an `image` subcommand.
        let args = catalog.arguments(command: "image.build", options: [
            "file": file.map { [$0] } ?? [], "tag": [tag],
            "platform": platform.map { [$0] } ?? [], "target": target.map { [$0] } ?? [],
            "noCache": noCache ? ["true"] : []
        ], positionals: [contextDir])
        let command = "container \(args.joined(separator: " "))"

        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "构建", command: command, timeout: AppConstants.Time.streamingCommandTimeout)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    } else if line.contains("writing image") || line.contains("naming to") || line.contains("DONE") {
                        taskManager.setIndeterminate(true)
                    }
                }
            })
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "镜像构建成功 ✅ \(tag)")
            }
            await fetchImages()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "构建")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "构建失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "构建失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "构建失败")
            throw error
        }
    }

    // MARK: - 删除镜像
    func deleteImage(id: String) async throws {
        let taskManager = TaskManager.shared
        let command = "image delete \(id)"
        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "删除", command: command)
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "image.delete", positionals: [id]))
            await MainActor.run {
                taskManager.finishTask(success: true, message: "删除成功；已有镜像归档已保留")
            }
            await fetchImages()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "删除")
        } catch {
            await MainActor.run {
                self.errorMessage = "删除失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "删除失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "删除失败")
            throw error
        }
    }

    // MARK: - 推送镜像
    func pushImage(name: String, tag: String = "latest") async throws {
        let taskManager = TaskManager.shared
        let fullImage = name.imageReference(tag: tag)
        let command = "image push \(fullImage)"

        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "推送", command: command, timeout: AppConstants.Time.streamingCommandTimeout)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "image.push", positionals: [fullImage]), progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    }
                }
            })
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "推送成功 ✅")
            }
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "推送")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "推送失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "推送失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "推送失败")
            throw error
        }
    }

    // MARK: - 清理未使用镜像
    func pruneDanglingImages() async throws {
        let taskManager = TaskManager.shared
        let command = "image prune"
        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "清理悬空镜像", command: command)
            self.isLoading = true
        }

        do {
            _ = try await executor.execute(catalog.arguments(command: "image.prune"))
            await fetchImages()

            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "清理完成 ✅；镜像归档已保留")
            }
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "清理悬空镜像")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "清理失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "清理失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async)
            logService.log(result: result, module: "镜像", operationType: "清理失败")
            throw error
        }
    }

    /// 安全删除所有未被运行或停止容器引用的带标签镜像。
    /// 不使用 `image prune --all`，因为该运行时指令曾发生基础设施别名误删。
    func deleteUnusedImagesSafely() async throws {
        let taskManager = TaskManager.shared
        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "安全清理未使用镜像", command: "image delete <verified-unused-images>")
            taskManager.setIndeterminate(true)
            self.isLoading = true
        }

        do {
            let containerOutput = try await executor.execute(catalog.arguments(command: "container.list", options: ["all": ["true"], "format": ["json"]]))
            guard let containerData = containerOutput.data(using: .utf8),
                  let containers = try? JSONDecoder().decode([Container].self, from: containerData) else {
                throw ContainerError.commandFailed("无法解析全部容器列表，已中止镜像删除")
            }
            var protectedReferences = Set(containers.map(\.image).filter { !$0.isEmpty })
            // K8s 节点 containerd 是独立镜像库，Apple Container 的容器列表不会包含
            // 工作负载镜像。必须在计算候选项之前完整读取，否则安全清理直接失败关闭。
            let kubernetesReferences = try await KubernetesManager.shared.imageReferencesForSafeHostCleanup()
            protectedReferences.formUnion(kubernetesReferences)
            let protectedAliases = protectedReferences.reduce(into: Set<String>()) {
                $0.formUnion(imageReferenceAliases($1))
            }

            let imageOutput = try await executor.execute(catalog.arguments(command: "image.list", options: ["format": ["json"]]))
            guard let imageData = imageOutput.data(using: .utf8),
                  let installedImages = try? JSONDecoder().decode([SourceImage].self, from: imageData) else {
                throw ContainerError.commandFailed("无法解析镜像列表，已中止镜像删除")
            }
            let candidates = installedImages.filter { image in
                let aliases = imageReferenceAliases(image.name)
                    .union(imageReferenceAliases(image.id))
                    .union(image.digest.map(imageReferenceAliases) ?? [])
                return aliases.isDisjoint(with: protectedAliases)
            }
            var failures: [String] = []
            for image in candidates {
                do {
                    _ = try await executor.execute(catalog.arguments(command: "image.delete", positionals: [image.name]))
                    await MainActor.run { taskManager.appendOutput("已删除：\(image.name)") }
                } catch {
                    failures.append("\(image.name)：\(error.localizedDescription)")
                    await MainActor.run { taskManager.appendOutput("删除失败：\(image.name) — \(error.localizedDescription)") }
                }
            }
            await fetchImages()
            if !failures.isEmpty {
                throw ContainerError.commandFailed(failures.joined(separator: "\n"))
            }
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "已安全删除 \(candidates.count) 个未使用镜像")
            }
            logService.log(
                result: CLIResult(command: "image delete <verified-unused-images>", output: "deleted=\(candidates.count), protected=\(protectedReferences.count)", exitCode: 0, duration: 0, mode: .async),
                module: "镜像", operationType: "安全清理未使用镜像"
            )
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "清理失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "清理失败: \(error.localizedDescription)")
            }
            logService.log(
                result: CLIResult(command: "image delete <verified-unused-images>", output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async),
                module: "镜像", operationType: "安全清理未使用镜像失败"
            )
            throw error
        }
    }

    /// 将 registry/repository:tag、digest 和运行时 ID 归一成一组保守别名。
    /// 镜像清理宁可多保留，也不能因为 docker.io、镜像加速源或 digest 表达不同而误删。
    private func imageReferenceAliases(_ source: String) -> Set<String> {
        var result = Set<String>()
        var reference = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !reference.isEmpty else { return result }
        reference = reference.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        result.insert(reference)

        // Apple Container/CRI 的同一内容可能分别表示为 sha256:<hex>、sha256-<hex> 或裸 hex。
        if reference.hasPrefix("sha256-") {
            let hex = String(reference.dropFirst("sha256-".count))
            result.insert("sha256:\(hex)")
            result.insert(hex)
        } else if reference.hasPrefix("sha256:") {
            result.insert(String(reference.dropFirst("sha256:".count)))
        } else if reference.count == 64, reference.allSatisfy({ $0.isHexDigit }) {
            result.insert("sha256:\(reference)")
        }

        if let at = reference.firstIndex(of: "@") {
            let digest = String(reference[reference.index(after: at)...])
            if !digest.isEmpty { result.insert(digest) }
            reference = String(reference[..<at])
            result.insert(reference)
        }
        if reference.hasPrefix("sha256:") || reference.hasPrefix("sha256-") { return result }

        func withDefaultTag(_ value: String) -> String {
            let lastSlash = value.lastIndex(of: "/")
            let lastColon = value.lastIndex(of: ":")
            let hasTag = lastColon.map { colon in lastSlash.map { colon > $0 } ?? true } ?? false
            return hasTag ? value : value + ":latest"
        }

        var pathVariants = Set([reference, withDefaultTag(reference)])
        let components = reference.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count > 1 {
            let first = components[0]
            if first == "localhost" || first.contains(".") || first.contains(":" ) {
                let withoutRegistry = components.dropFirst().joined(separator: "/")
                pathVariants.insert(withoutRegistry)
                pathVariants.insert(withDefaultTag(withoutRegistry))
            }
        }
        for value in Array(pathVariants) where value.hasPrefix("library/") {
            let short = String(value.dropFirst("library/".count))
            pathVariants.insert(short)
            pathVariants.insert(withDefaultTag(short))
        }
        result.formUnion(pathVariants)
        return result
    }

    // MARK: - 保存镜像（image save → tar 归档）
    func saveImage(reference: String, to url: URL) async throws {
        let taskManager = TaskManager.shared
        let command = "image save --output \"\(url.path)\" \(reference)"

        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "保存", command: command)
            taskManager.setIndeterminate(true)
            taskManager.appendOutput("正在保存镜像 \(reference)...")
            self.isLoading = true
        }

        do {
            // 只保存主机平台（轻量 VM），避免全平台膨胀
            let platform = ImageArchiveManager.hostPlatform()
            var usedPlatform = true
            var saved = false
            for attempt in 1...3 {
                do {
                    let args = catalog.arguments(command: "image.save", options: [
                        "platform": usedPlatform ? [platform] : [], "output": [url.path]
                    ], positionals: [reference])
                    _ = try await executor.execute(args, progressHandler: { line in
                        Task { @MainActor in
                            taskManager.appendOutput(line)
                            if let percent = line.percentageProgress {
                                taskManager.updateProgress(percent / 100.0)
                            } else if line.contains("Compressing") || line.contains("Saving") {
                                taskManager.setIndeterminate(true)
                            }
                        }
                    })
                    saved = true
                    break
                } catch {
                    let desc = error.localizedDescription.lowercased()
                    if desc.contains("digest") && attempt < 3 {
                        taskManager.appendOutput("镜像内容不完整，正在重新拉取补齐 \(reference)（仅 \(platform)）...")
                        let pullArgs = catalog.arguments(command: "image.pull", options: [
                            "platform": usedPlatform ? [platform] : []
                        ], positionals: [reference])
                        _ = try await executor.execute(pullArgs, progressHandler: { line in
                            Task { @MainActor in
                                taskManager.appendOutput(line)
                                if line.contains("Unpacking") { taskManager.setIndeterminate(true) }
                            }
                        })
                    } else if desc.contains("platform") && usedPlatform {
                        usedPlatform = false   // 无该平台变体 → 回退全平台
                    } else {
                        throw error
                    }
                }
            }
            if !saved { throw ContainerError.commandFailed("保存失败") }
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "镜像已保存 ✅ \(url.lastPathComponent)")
            }
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "保存")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "保存失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "保存失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "保存失败")
            throw error
        }
    }

    // MARK: - 导入镜像（image load ← tar 归档）
    func loadImage(from url: URL, force: Bool = false) async throws {
        let taskManager = TaskManager.shared
        let command = "image load --input \"\(url.path)\"" + (force ? " --force" : "")

        await MainActor.run {
            taskManager.startTask(module: "镜像", operation: "导入", command: command)
            taskManager.setIndeterminate(true)
            taskManager.appendOutput("正在导入 \(url.lastPathComponent)...")
            self.isLoading = true
        }

        do {
            let args = catalog.arguments(command: "image.load", options: [
                "input": [url.path], "force": force ? ["true"] : []
            ])
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    } else if line.contains("Loading") || line.contains("Unpacking") {
                        taskManager.setIndeterminate(true)
                    }
                }
            })
            await MainActor.run {
                self.isLoading = false
                taskManager.finishTask(success: true, message: "镜像导入成功 ✅")
            }
            await fetchImages()
            let result = CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "导入")
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = "导入失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "导入失败: \(error.localizedDescription)")
            }
            let result = CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream)
            logService.log(result: result, module: "镜像", operationType: "导入失败")
            throw error
        }
    }

}
