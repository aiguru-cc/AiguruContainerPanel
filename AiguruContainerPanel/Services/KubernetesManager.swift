//
//  KubernetesManager.swift
//  AiguruContainerPanel
//
//  Kubernetes(k8s) 集群管理服务：list / create / stop / delete / load-image / write-config。
//  container k8s 插件命令由 CLICommandCatalog 的当前环境档位驱动。
//  节点控制面板：封装节点内 crictl 指令（images/ps/pods/rmi/stop/rm/pull/imagefsinfo）。
//

import Foundation
import Combine

/// 本地 Kubernetes 集群（来自 k8s list 输出，逐行解析）
struct KubernetesCluster: Identifiable, Hashable {
    let name: String
    /// Apple K8s 1.3 是单节点集群，节点容器由 `--name` 命名；不要从不稳定的表格列位置推断。
    let nodeName: String
    let detail: String
    let raw: String
    /// k8s list 第 4 列 STATE（running/stopped 等）
    var state: String = ""
    var id: String { name }

    var isRunning: Bool { state.localizedCaseInsensitiveCompare("running") == .orderedSame }
}

class KubernetesManager: ObservableObject {
    static let shared = KubernetesManager()
    private init() {}

    private let executor = CommandExecutor.shared
    private let logService = LogService.shared
    private let catalog = CLICommandCatalog.shared
    private let apiCatalog = KubernetesAPICatalog.shared

    @Published var clusters: [KubernetesCluster] = []
    @Published var rawList = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var pluginVersion: CLIVersion = .unknown
    @Published private(set) var compatibilityMessage: String?
    @Published private(set) var discoveredAPIResources: [String: [KubernetesAPIResource]] = [:]

    var apiProfile: KubernetesAPIProfile? {
        apiCatalog.activeProfile(
            pluginVersion: pluginVersion,
            environmentID: EnvironmentManager.shared.currentEnvironment?.id
        )
    }

    /// 只通过当前工作环境配置的 container CLI 探测 K8s 能力。
    /// 不扫描 /usr/local、Homebrew Cellar 或其他环境，避免把别处残留的插件误认为当前环境可用。
    func probeCurrentEnvironment() async -> Bool {
        let environment = EnvironmentManager.shared
        let cliVersion = environment.currentVersion
        let environmentName = environment.currentEnvironment?.name ?? "未选择环境"

        guard cliVersion.isKnown else {
            await MainActor.run {
                pluginVersion = .unknown
                compatibilityMessage = "当前工作环境“\(environmentName)”的 Container CLI 不可用或版本尚未探测完成。"
            }
            return false
        }

        guard let arguments = catalog.path(command: "k8s.version", version: cliVersion) else {
            let required = catalog.minimumVersion(command: "k8s.version")?.description ?? "未知版本"
            await MainActor.run {
                pluginVersion = .unknown
                compatibilityMessage = "当前工作环境“\(environmentName)”使用 Container \(cliVersion.description)，K8s 插件需要 \(required)+。请升级这一工作环境的完整 CLI 安装。"
            }
            return false
        }

        do {
            // CommandExecutor 已绑定 currentEnvironment，命令只能由该环境的绝对 CLI 路径执行。
            let output = try await executor.execute(arguments)
            let detected = CLIVersion(output)
            // 1.6+ `cluster --version` returns the CLI version banner rather than a
            // plugin-specific "k8s version" string; the parsed version is authoritative.
            guard detected.isKnown else {
                throw ContainerError.commandFailed("当前 CLI 未返回有效的 K8s 插件版本")
            }
            await MainActor.run {
                pluginVersion = detected
                compatibilityMessage = nil
            }
            apiCatalog.synchronize(pluginVersion: detected, environmentID: environment.currentEnvironment?.id)
            return true
        } catch {
            await MainActor.run {
                pluginVersion = .unknown
                compatibilityMessage = "当前工作环境“\(environmentName)”无法加载 K8s 插件：\(error.localizedDescription)"
            }
            return false
        }
    }

    private func catalogArguments(_ key: String) throws -> [String] {
        let version = EnvironmentManager.shared.currentVersion
        guard let path = catalog.path(command: key, version: version) else {
            let required = catalog.minimumVersion(command: key)?.description ?? "未知版本"
            throw ContainerError.commandFailed("当前工作环境 Container \(version.description) 不支持 \(key)（需要 \(required)+）")
        }
        return path
    }

    private func catalogFlag(_ command: String, _ option: String) -> String {
        catalog.flag(command: command, option: option)
    }

    // MARK: - 列表
    func fetchClusters() async {
        await MainActor.run { isLoading = true }
        guard await probeCurrentEnvironment() else {
            await MainActor.run {
                clusters = []
                rawList = ""
                errorMessage = compatibilityMessage
                isLoading = false
            }
            return
        }
        do {
            let output = try await executor.execute(catalogArguments("k8s.list"))
            let parsed = parseList(output)
            await MainActor.run {
                clusters = parsed
                rawList = output
                errorMessage = nil
                isLoading = false
            }
            logService.log(result: CLIResult(command: "k8s list", output: output, exitCode: 0, duration: 0, mode: .async), module: "Kubernetes", operationType: "列表刷新")
        } catch {
            await MainActor.run {
                clusters = []
                rawList = ""
                errorMessage = "获取集群列表失败: \(error.localizedDescription)"
                isLoading = false
            }
            logService.log(result: CLIResult(command: "k8s list", output: error.localizedDescription, exitCode: -1, duration: 0, mode: .async), module: "Kubernetes", operationType: "列表刷新失败")
        }
    }

    /// 解析实验性 `k8s list` 表格。1.3 未承诺固定列布局，因此按状态语义识别，禁止固定列号。
    private func parseList(_ output: String) -> [KubernetesCluster] {
        let knownStates: Set<String> = ["running", "stopped", "created", "starting", "stopping", "exited", "paused"]
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line -> KubernetesCluster? in
                let columns = line.split(separator: " ").map(String.init)
                guard let first = columns.first,
                      !["name", "cluster"].contains(first.lowercased()) else { return nil }
                let state = columns
                    .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                    .first(where: knownStates.contains) ?? "unknown"
                let cluster = KubernetesCluster(
                    name: first,
                    nodeName: first,
                    detail: columns.dropFirst().joined(separator: " "),
                    raw: line,
                    state: state
                )
                return cluster
            }
    }

    // MARK: - 通用流式执行（TaskManager 统一进度）
    private func stream(
        _ args: [String],
        operation: String,
        successMessage: String,
        indeterminateKeywords: [String] = []
    ) async throws {
        let taskManager = TaskManager.shared
        let command = "container \(args.joined(separator: " "))"

        await MainActor.run {
            taskManager.startTask(module: "Kubernetes", operation: operation, command: command, timeout: AppConstants.Time.streamingCommandTimeout)
            isLoading = true
        }

        do {
            _ = try await executor.execute(args, progressHandler: { line in
                Task { @MainActor in
                    taskManager.appendOutput(line)
                    if let percent = line.percentageProgress {
                        taskManager.updateProgress(percent / 100.0)
                    } else if indeterminateKeywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                        taskManager.setIndeterminate(true)
                    }
                }
            })
            await MainActor.run {
                isLoading = false
                taskManager.finishTask(success: true, message: successMessage)
            }
            await fetchClusters()
            logService.log(result: CLIResult(command: command, output: "", exitCode: 0, duration: 0, mode: .stream), module: "Kubernetes", operationType: operation)
        } catch {
            await MainActor.run {
                isLoading = false
                errorMessage = "\(operation)失败: \(error.localizedDescription)"
                taskManager.finishTask(success: false, message: "\(operation)失败: \(error.localizedDescription)")
            }
            logService.log(result: CLIResult(command: command, output: error.localizedDescription, exitCode: -1, duration: 0, mode: .stream), module: "Kubernetes", operationType: "\(operation)失败")
            throw error
        }
    }

    // MARK: - 创建（Container 1.5 新增 --cni，可从宿主机读取自定义网络清单）
    func createCluster(name: String, nodeImage: String?, cni: String?, cpus: String?, memory: String?, scheme: String?, maxConcurrentDownloads: String?, removeOnStop: Bool) async throws {
        var args = try catalogArguments("k8s.create") + [catalogFlag("k8s.create", "name"), name]
        if let nodeImage, !nodeImage.isEmpty { args += [catalogFlag("k8s.create", "nodeImage"), nodeImage] }
        if let cni, !cni.isEmpty {
            let expandedPath = (cni as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw ContainerError.commandFailed("自定义 CNI 清单不存在或不是文件：\(expandedPath)")
            }
            args += [catalogFlag("k8s.create", "cni"), expandedPath]
        }
        if let cpus, !cpus.isEmpty { args += [catalogFlag("k8s.create", "cpus"), cpus] }
        if let memory, !memory.isEmpty { args += [catalogFlag("k8s.create", "memory"), memory] }
        if let scheme, !scheme.isEmpty { args += [catalogFlag("k8s.create", "scheme"), scheme] }
        if let maxConcurrentDownloads, !maxConcurrentDownloads.isEmpty { args += [catalogFlag("k8s.create", "maxConcurrentDownloads"), maxConcurrentDownloads] }
        if removeOnStop { args.append(catalogFlag("k8s.create", "rm")) }
        try await stream(args, operation: "创建集群", successMessage: "集群创建成功 ✅ \(name)",
                         indeterminateKeywords: ["Creating cluster", "kubeadm", "Installing", "Pulling"])
    }

    // MARK: - 停止（官方 CLI 无 k8s stop，停止集群即停底层容器 container stop）
    func stopCluster(name: String) async throws {
        try await stream(catalog.arguments(command: "container.stop", positionals: [name]), operation: "停止集群", successMessage: "集群已停止 ✅ \(name)",
                         indeterminateKeywords: ["Stopping", "Shutting"])
    }

    // MARK: - 启动
    func startCluster(name: String) async throws {
        // 1.5.0 移除了 k8s start。不能用 container start 代替，否则不会完成插件的 kubeconfig/节点恢复流程。
        guard let startArguments = catalog.path(command: "k8s.start", version: EnvironmentManager.shared.currentVersion) else {
            throw ContainerError.commandFailed("Container 1.5 已移除 k8s start；请删除已停止的集群并重新创建")
        }
        try await stream(startArguments + [catalogFlag("k8s.start", "name"), name], operation: "启动集群", successMessage: "集群已启动 ✅ \(name)",
                         indeterminateKeywords: ["Starting", "Waiting", "booting"])
        // VM 启动需数秒，轮询 k8s list 直到 STATE=running（上限 60s），保证后续操作可用
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if await clusterState(name: name)?.isRunning == true { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let observed = await clusterState(name: name)?.state ?? "not-found"
        let message = "k8s start 已返回，但集群 \(name) 在 60 秒内未进入 Running（当前状态：\(observed)）"
        await MainActor.run { errorMessage = message }
        logService.log(result: CLIResult(command: "container k8s start --name \(name)", output: message, exitCode: -1, duration: 60, mode: .async), module: "Kubernetes", operationType: "启动就绪检查失败")
        throw ContainerError.commandFailed(message)
    }

    // MARK: - 删除
    func deleteCluster(name: String) async throws {
        try await stream(try catalogArguments("k8s.delete") + [catalogFlag("k8s.delete", "name"), name], operation: "删除集群", successMessage: "集群已删除 ✅ \(name)",
                         indeterminateKeywords: ["Deleting", "Stopping"])
    }

    // MARK: - 加载镜像
    func loadImage(name: String, image: String, platform: String?) async throws {
        // load-image 需要集群运行中（no runtime client: container is stopped），停止时先自动启动
        if await clusterState(name: name)?.isRunning == false {
            if catalog.supportsCapability("k8s.startRemoved", version: EnvironmentManager.shared.currentVersion) {
                throw ContainerError.commandFailed("集群 \(name) 已停止；Container 1.5 不支持重新启动，请删除并重建集群后再加载镜像")
            }
            try await startCluster(name: name)
        }
        var args = try catalogArguments("k8s.loadImage") + [catalogFlag("k8s.loadImage", "name"), name]
        if let platform, !platform.isEmpty { args += [catalogFlag("k8s.loadImage", "platform"), platform] }
        args.append(image)
        try await stream(args, operation: "加载镜像", successMessage: "镜像已加载到 \(name) ✅ \(image)",
                         indeterminateKeywords: ["Exporting", "Importing", "Loading"])
    }

    /// 查询指定集群的最新状态（独立于缓存的 clusters，避免用旧数据判断）
    private func clusterState(name: String) async -> KubernetesCluster? {
        guard let arguments = try? catalogArguments("k8s.list"),
              let output = try? await executor.execute(arguments) else { return nil }
        return parseList(output).first { $0.name == name }
    }

    // MARK: - 写入 kubeconfig
    func writeConfig(name: String, kubeconfig: String?) async throws {
        var args = try catalogArguments("k8s.writeConfig") + [catalogFlag("k8s.writeConfig", "name"), name]
        if let kubeconfig, !kubeconfig.isEmpty { args += [catalogFlag("k8s.writeConfig", "kubeconfig"), kubeconfig] }
        try await stream(args, operation: "写入 kubeconfig", successMessage: "kubeconfig 已写入 ✅ \(name)",
                         indeterminateKeywords: ["Fetching", "Merging"])
    }

    // MARK: - 节点容器 crictl 桥（PVE 风格右侧控制面板的数据源与操作）
    // 所有指令在集群节点容器内执行：container exec <集群> crictl <sub>，本机无需安装任何工具。
    // 查询类用 -o json 结构化解析；写操作走 TaskManager 任务流。

    private func execCrictl(_ subcommand: [String], cluster: String) async throws -> String {
        let nodeName = try await nodeContainerName(for: cluster)
        return try await executor.execute(catalog.arguments(command: "container.exec", positionals: [nodeName, "crictl"] + subcommand))
    }

    // MARK: Kubernetes API 节点桥

    /// kindest/node 内置 kubectl 和管理员 kubeconfig。通过节点内执行可避免宿主机必须安装 kubectl，
    /// 同时始终指向所选集群而不是用户当前的 kubectl context。
    private func nodeContainerName(for cluster: String) async throws -> String {
        if let cached = clusters.first(where: { $0.name == cluster }) {
            return cached.nodeName
        }
        let output = try await executor.execute(catalogArguments("k8s.list"))
        guard let nodeName = parseList(output).first(where: { $0.name == cluster })?.nodeName else {
            throw ContainerError.commandFailed("K8s 1.3 未返回集群 \(cluster) 对应的 NODE，无法连接控制平面")
        }
        return nodeName
    }

    private func execKubectl(_ arguments: [String], cluster: String) async throws -> String {
        let nodeName = try await nodeContainerName(for: cluster)
        return try await executor.execute(catalog.arguments(
            command: "container.exec",
            positionals: [nodeName, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"] + arguments
        ))
    }

    // MARK: Kubernetes API Discovery 与通用资源桥

    func discoverAPIResources(cluster: String, force: Bool = false) async throws -> [KubernetesAPIResource] {
        if !force, let cached = discoveredAPIResources[cluster], !cached.isEmpty { return cached }

        let coreData = try await rawKubernetesAPI("/api", cluster: cluster)
        let groupsData = try await rawKubernetesAPI("/apis", cluster: cluster)
        let core = try JSONDecoder().decode(KubernetesAPIVersions.self, from: coreData)
        let groups = try JSONDecoder().decode(KubernetesAPIGroupList.self, from: groupsData)
        var groupVersions = core.versions.map { (path: "/api/\($0)", groupVersion: $0) }
        groupVersions += groups.groups.compactMap { group in
            guard let preferred = group.preferredVersion else { return nil }
            return (path: "/apis/\(preferred.groupVersion)", groupVersion: preferred.groupVersion)
        }

        var resources: [KubernetesAPIResource] = []
        for endpoint in groupVersions {
            do {
                let data = try await rawKubernetesAPI(endpoint.path, cluster: cluster)
                let list = try JSONDecoder().decode(KubernetesAPIResourceList.self, from: data)
                resources += list.resources
                    .filter { !$0.name.contains("/") }
                    .map {
                        KubernetesAPIResource(
                            groupVersion: endpoint.groupVersion,
                            name: $0.name,
                            singularName: $0.singularName,
                            kind: $0.kind,
                            namespaced: $0.namespaced,
                            verbs: Set($0.verbs),
                            shortNames: $0.shortNames ?? []
                        )
                    }
            } catch {
                // 聚合 API（如 metrics.k8s.io）可能暂时不可用，不应阻断核心 discovery。
                continue
            }
        }
        let sorted = resources.sorted { ($0.category.sortOrder, $0.kind) < ($1.category.sortOrder, $1.kind) }
        await MainActor.run { discoveredAPIResources[cluster] = sorted }
        return sorted
    }

    private func rawKubernetesAPI(_ path: String, cluster: String) async throws -> Data {
        let output = try await execKubectl(["get", "--raw", path, "--request-timeout=10s"], cluster: cluster)
        guard let data = output.data(using: .utf8) else {
            throw ContainerError.commandFailed("Kubernetes API \(path) 返回非 UTF-8 数据")
        }
        return data
    }

    func fetchAPIObjects(cluster: String, resource: KubernetesAPIResource) async throws -> [KubernetesAPIObject] {
        var arguments = ["get", resource.qualifiedName]
        if resource.namespaced { arguments.append("--all-namespaces") }
        arguments += ["-o", "json", "--request-timeout=10s"]
        let output = try await execKubectl(arguments, cluster: cluster)
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw ContainerError.commandFailed("无法解析 \(resource.kind) API 列表")
        }
        return items.compactMap { item in
            guard let metadata = item["metadata"] as? [String: Any], let name = metadata["name"] as? String else { return nil }
            let status = item["status"] as? [String: Any]
            return KubernetesAPIObject(
                name: name,
                namespace: metadata["namespace"] as? String,
                createdAt: metadata["creationTimestamp"] as? String,
                phase: status?["phase"] as? String ?? status?["state"] as? String
            )
        }
    }

    func fetchAPIObjectYAML(cluster: String, resource: KubernetesAPIResource, object: KubernetesAPIObject) async throws -> String {
        var arguments = ["get", resource.qualifiedName, object.name]
        if let namespace = object.namespace { arguments += ["--namespace", namespace] }
        arguments += ["-o", "yaml", "--request-timeout=10s"]
        return try await execKubectl(arguments, cluster: cluster)
    }

    func deleteAPIObject(cluster: String, resource: KubernetesAPIResource, object: KubernetesAPIObject) async throws {
        let kubectlDeleteVerb = "delete"
        var arguments = [kubectlDeleteVerb, resource.qualifiedName, object.name]
        if let namespace = object.namespace { arguments += ["--namespace", namespace] }
        _ = try await execKubectl(arguments, cluster: cluster)
    }

    @MainActor
    func fetchKubernetesNodes(cluster: String) async throws -> [KubernetesNode] {
        let output = try await execKubectl(["get", "nodes", "-o", "json", "--request-timeout=10s"], cluster: cluster)
        guard let data = output.data(using: .utf8) else {
            throw ContainerError.commandFailed("Kubernetes Node API 返回了无效的 UTF-8 数据")
        }
        let response: KubernetesNodeListResponse
        do {
            response = try JSONDecoder().decode(KubernetesNodeListResponse.self, from: data)
        } catch {
            throw ContainerError.commandFailed("无法解析 Kubernetes Node API 响应：\(error.localizedDescription)\n\(output.prefix(500))")
        }
        return response.items.map(KubernetesNode.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func fetchNodeDescription(cluster: String, node: String) async -> String {
        (try? await execKubectl(["describe", "node", node], cluster: cluster)) ?? "无法获取节点描述。请确认集群正在运行。"
    }

    @MainActor
    func fetchKubernetesPods(cluster: String) async throws -> [KubernetesPod] {
        let output = try await execKubectl(["get", "pods", "--all-namespaces", "-o", "json", "--request-timeout=10s"], cluster: cluster)
        guard let data = output.data(using: .utf8) else {
            throw ContainerError.commandFailed("Kubernetes Pod API 返回了无效的 UTF-8 数据")
        }
        let response: KubernetesPodListResponse
        do {
            response = try JSONDecoder().decode(KubernetesPodListResponse.self, from: data)
        } catch {
            throw ContainerError.commandFailed("无法解析 Kubernetes Pod API 响应：\(error.localizedDescription)\n\(output.prefix(500))")
        }
        return response.items.map(KubernetesPod.init)
            .sorted { lhs, rhs in
                let namespaceOrder = lhs.namespace.localizedStandardCompare(rhs.namespace)
                return namespaceOrder == .orderedSame
                    ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    : namespaceOrder == .orderedAscending
            }
    }

    func fetchPodDescription(cluster: String, namespace: String, pod: String) async -> String {
        (try? await execKubectl(["describe", "pod", pod, "--namespace", namespace], cluster: cluster))
            ?? "无法获取 Pod describe。请确认集群正在运行。"
    }

    func fetchPodYAML(cluster: String, namespace: String, pod: String) async -> String {
        (try? await execKubectl(["get", "pod", pod, "--namespace", namespace, "-o", "yaml"], cluster: cluster))
            ?? "无法获取 Pod YAML。"
    }

    func fetchPodLogs(cluster: String, namespace: String, pod: String, container: String?, tail: Int = 200) async -> String {
        var kubectlArguments = ["logs", pod, "--namespace", namespace, "--tail", String(tail)]
        if let container, !container.isEmpty { kubectlArguments += ["--container", container] }
        return (try? await execKubectl(kubectlArguments, cluster: cluster)) ?? "无法获取 Pod 日志。"
    }

    func cordonNode(cluster: String, node: String) async throws {
        try await streamKubectl(["cordon", node], cluster: cluster, operation: "封锁节点",
                                successMessage: "节点已封锁，新的 Pod 不会再调度到 \(node) ✅")
    }

    func uncordonNode(cluster: String, node: String) async throws {
        try await streamKubectl(["uncordon", node], cluster: cluster, operation: "解除封锁",
                                successMessage: "节点已恢复可调度 ✅ \(node)")
    }

    func drainNode(
        cluster: String,
        node: String,
        ignoreDaemonSets: Bool,
        deleteEmptyDirData: Bool,
        force: Bool,
        gracePeriod: Int?
    ) async throws {
        var arguments = ["drain", node]
        if ignoreDaemonSets { arguments.append("--ignore-daemonsets") }
        if deleteEmptyDirData { arguments.append("--delete-emptydir-data") }
        if force { arguments.append("--force") }
        if let gracePeriod, gracePeriod >= 0 { arguments += ["--grace-period", String(gracePeriod)] }
        try await streamKubectl(arguments, cluster: cluster, operation: "驱逐节点 Pod",
                                successMessage: "节点已完成驱逐 ✅ \(node)",
                                indeterminateKeywords: ["evicting", "deleting", "waiting"])
    }

    func setNodeLabel(cluster: String, node: String, key: String, value: String?) async throws {
        let assignment = value.map { "\(key)=\($0)" } ?? "\(key)-"
        var arguments = ["label", "node", node, assignment]
        if value != nil { arguments.append("--overwrite") }
        try await streamKubectl(arguments, cluster: cluster, operation: value == nil ? "移除节点标签" : "更新节点标签",
                                successMessage: "节点标签已更新 ✅ \(node)")
    }

    func setNodeTaint(cluster: String, node: String, expression: String, removing: Bool) async throws {
        let taint = removing && !expression.hasSuffix("-") ? expression + "-" : expression
        var arguments = ["taint", "node", node, taint]
        if !removing { arguments.append("--overwrite") }
        try await streamKubectl(arguments, cluster: cluster, operation: removing ? "移除节点污点" : "更新节点污点",
                                successMessage: "节点污点已更新 ✅ \(node)")
    }

    private func streamKubectl(
        _ kubectlArguments: [String],
        cluster: String,
        operation: String,
        successMessage: String,
        indeterminateKeywords: [String] = []
    ) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(
            catalog.arguments(
                command: "container.exec",
                positionals: [nodeName, "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"] + kubectlArguments
            ),
            operation: operation,
            successMessage: successMessage,
            indeterminateKeywords: indeterminateKeywords
        )
    }

    // MARK: 查询：镜像列表（crictl images -o json）

    func fetchNodeImages(cluster: String) async -> [K8sNodeImage] {
        guard let out = try? await execCrictl(["images", "-o", "json"], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlImagesResponse.self, from: data) else { return [] }
        return decoded.images.map { img in
            K8sNodeImage(
                imageID: img.id,
                references: img.repoTags.isEmpty ? [img.id] : img.repoTags,
                sizeBytes: Int(img.size) ?? 0
            )
        }
    }

    /// 为宿主机“安全清理镜像”提供保守保护集。Kubernetes 的 containerd 镜像即使
    /// 当前没有运行容器，也可能被 Deployment、Job 或后续重启继续使用，因此全部保护。
    /// 任一集群停止或无法读取时抛错，让调用方在删除任何内容之前整体中止。
    func imageReferencesForSafeHostCleanup() async throws -> Set<String> {
        let output = try await executor.execute(catalogArguments("k8s.list"))
        let discovered = parseList(output)
        let clusterNames = Set(discovered.map(\.name))

        // 以当前环境 container list 的官方插件标签交叉核验，防止实验性 k8s list 漏报后得到空保护集。
        let containerOutput = try await executor.execute(catalog.arguments(
            command: "container.list", options: ["all": ["true"], "format": ["json"]]
        ))
        guard let containerData = containerOutput.data(using: .utf8),
              let allContainers = try? JSONDecoder().decode([Container].self, from: containerData) else {
            throw ContainerError.commandFailed("无法核对 Kubernetes 节点容器标签；已中止安全清理")
        }
        let labeledNodes = Set(allContainers.compactMap { container -> String? in
            let labels = container.labels ?? [:]
            let isKubernetes = labels["com.apple.container.plugin"] == "k8s"
                || labels["plugin"] == "k8s"
            return isKubernetes ? container.displayName : nil
        })
        guard labeledNodes.isSubset(of: clusterNames) else {
            let missing = labeledNodes.subtracting(clusterNames).sorted().joined(separator: ", ")
            throw ContainerError.commandFailed("k8s list 未报告已存在的节点容器（\(missing)）；为防止误删已中止安全清理")
        }

        var references = Set<String>()
        for clusterName in clusterNames.sorted() {
            guard discovered.contains(where: { $0.name == clusterName && $0.isRunning }) else {
                throw ContainerError.commandFailed("Kubernetes 集群「\(clusterName)」未运行，无法核对其镜像占用；已中止安全清理")
            }
            let json = try await execCrictl(["images", "-o", "json"], cluster: clusterName)
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(CrictlImagesResponse.self, from: data) else {
                throw ContainerError.commandFailed("无法解析 Kubernetes 集群「\(clusterName)」的镜像列表；已中止安全清理")
            }
            for image in response.images {
                references.insert(image.id)
                references.formUnion(image.repoTags)
                references.formUnion(image.repoDigests ?? [])
            }
            references.formUnion(try await declaredImageReferences(cluster: clusterName))
        }
        return references
    }

    /// 保护 Kubernetes 声明层的镜像，即使对应 Pod 尚未创建或节点尚未完成拉取。
    private func declaredImageReferences(cluster: String) async throws -> Set<String> {
        let output = try await execKubectl([
            "get", "deployment,statefulset,daemonset,job,cronjob,pod", "--all-namespaces", "-o", "json", "--request-timeout=10s"
        ], cluster: cluster)
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ContainerError.commandFailed("无法读取 Kubernetes 集群「\(cluster)」的工作负载镜像引用；已中止安全清理")
        }
        var references = Set<String>()
        func collect(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if key == "image", let reference = child as? String, !reference.isEmpty {
                        references.insert(reference)
                    } else {
                        collect(child)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(json)
        return references
    }

    // MARK: 查询：容器列表（crictl ps -a -o json，含已退出）

    func fetchNodeContainers(cluster: String) async -> [K8sNodeContainer] {
        guard let out = try? await execCrictl(["ps", "-a", "-o", "json"], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlContainersResponse.self, from: data) else { return [] }
        return decoded.containers.map { c in
            K8sNodeContainer(
                id: c.id,
                name: c.metadata?.name ?? c.id.prefix(12).description,
                image: c.image?.userSpecifiedImage.flatMap { $0.isEmpty ? nil : $0 }
                    ?? String((c.image?.image ?? "").suffix(19)), // 无可读引用时用 sha256 尾段
                state: c.state,
                podName: c.labels?["io.kubernetes.pod.name"] ?? "",
                namespace: c.labels?["io.kubernetes.pod.namespace"] ?? "",
                restarts: c.annotations?["io.kubernetes.container.restartCount"] ?? "0"
            )
        }
    }

    // MARK: 查询：Pod 沙箱列表（crictl pods -o json）

    func fetchNodePods(cluster: String) async -> [K8sNodePod] {
        guard let out = try? await execCrictl(["pods", "-o", "json"], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlPodsResponse.self, from: data) else { return [] }
        return decoded.items.map { p in
            K8sNodePod(
                id: p.id,
                name: p.metadata?.name ?? p.id.prefix(12).description,
                namespace: p.metadata?.namespace ?? "",
                state: p.state
            )
        }
    }

    // MARK: 查询：镜像文件系统占用（crictl imagefsinfo）

    func fetchNodeImageFsInfo(cluster: String) async -> Int {
        guard let out = try? await execCrictl(["imagefsinfo"], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlImageFsResponse.self, from: data),
              let fs = decoded.status?.imageFilesystems?.first,
              let bytes = fs.usedBytes?.bytes else { return 0 }
        return bytes
    }

    // MARK: 写操作：封装 crictl 指令（stop / rm / rmi / pull）

    func stopNodeContainer(cluster: String, id: String, name: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "crictl", "stop", id]),
                         operation: "停止节点容器",
                         successMessage: "节点容器已停止 ✅ \(name)",
                         indeterminateKeywords: ["Stopping"])
    }

    func removeNodeContainer(cluster: String, id: String, name: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "crictl", "rm", id]),
                         operation: "删除节点容器",
                         successMessage: "节点容器已删除 ✅ \(name)",
                         indeterminateKeywords: ["Removing", "Deleting"])
    }

    func deleteNodeImage(cluster: String, imageID: String, reference: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "crictl", "rmi", imageID]),
                         operation: "删除节点镜像",
                         successMessage: "节点镜像已删除 ✅ \(reference)",
                         indeterminateKeywords: ["Removing", "Deleting"])
    }

    func pullNodeImage(cluster: String, reference: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "crictl", "pull", reference]),
                         operation: "拉取镜像到节点",
                         successMessage: "镜像已拉取到节点 ✅ \(reference)",
                         indeterminateKeywords: ["Pulling", "Downloading", "Resolving"])
    }

    // MARK: 全量 crictl 指令封装：inspecti / inspect / stats / logs / exec / prune + ctr tag/push

    /// 镜像详情（crictl inspecti -o json）
    func fetchImageDetail(cluster: String, imageID: String) async -> K8sImageDetail? {
        guard let out = try? await execCrictl(["inspecti", "-o", "json", imageID], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlInspectImage.self, from: data) else { return nil }
        let s = decoded.status
        let spec = decoded.info?.imageSpec
        let cfg = spec?.config
        return K8sImageDetail(
            imageID: s.id,
            repoTags: s.repoTags,
            repoDigests: s.repoDigests,
            sizeBytes: Int(s.size) ?? 0,
            pinned: s.pinned,
            architecture: spec?.architecture ?? "-",
            os: spec?.os ?? "-",
            created: spec?.created ?? "-",
            entrypoint: (cfg?.entrypoint ?? []) + (cfg?.args ?? []),
            env: cfg?.env ?? [],
            labels: cfg?.labels ?? [:],
            user: cfg?.user ?? "",
            workingDir: cfg?.workingDir ?? ""
        )
    }

    /// 容器详情（crictl inspect -o json：pid/创建时间/日志路径）
    func fetchContainerDetail(cluster: String, containerID: String) async -> K8sContainerDetail? {
        guard let out = try? await execCrictl(["inspect", "-o", "json", containerID], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlInspectContainer.self, from: data) else { return nil }
        let s = decoded.status
        return K8sContainerDetail(
            containerID: s.id,
            pid: s.pid?.value ?? 0,
            createdAt: s.createdAt ?? "0",
            logPath: s.logPath ?? "-",
            restartCount: decoded.info?.config?.annotations?["io.kubernetes.container.restartCount"] ?? "0"
        )
    }

    /// 容器实时资源（crictl stats -o json，cpu.usageNanoCores + memory.workingSetBytes）
    func fetchContainerStats(cluster: String, containerID: String) async -> K8sContainerStats? {
        guard let out = try? await execCrictl(["stats", "-o", "json"], cluster: cluster),
              let data = out.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CrictlStatsResponse.self, from: data) else { return nil }
        guard let s = decoded.stats.first(where: { $0.attributes?.id?.hasPrefix(String(containerID.prefix(12))) == true }) else { return nil }
        return K8sContainerStats(
            cpuNanoCores: s.cpu?.usageNanoCores ?? "0",
            workingSetBytes: s.memory?.workingSetBytes ?? "0"
        )
    }

    /// 容器日志（crictl logs --tail N；不走流式，一次性返回）
    func fetchContainerLogs(cluster: String, containerID: String, tail: Int) async -> String {
        (try? await execCrictl(["logs", "--tail", String(tail), containerID], cluster: cluster)) ?? "(无日志或获取失败)"
    }

    /// 容器内执行一次性命令（crictl exec <id> <cmd...>；非交互，返回输出）
    func execInNodeContainer(cluster: String, containerID: String, command: [String]) async -> String {
        (try? await execCrictl(["exec", containerID] + command, cluster: cluster)) ?? "(执行失败)"
    }

    /// 安全清理节点镜像：禁止 `crictl rmi --prune`，逐项核对声明层引用并永久保护系统镜像。
    func pruneNodeImages(cluster: String) async throws {
        let json = try await execCrictl(["images", "-o", "json"], cluster: cluster)
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(CrictlImagesResponse.self, from: data) else {
            throw ContainerError.commandFailed("无法读取节点镜像列表；已拒绝清理")
        }
        let images = response.images.map { image in
            K8sNodeImage(imageID: image.id,
                         references: image.repoTags.isEmpty ? (image.repoDigests ?? [image.id]) : image.repoTags,
                         sizeBytes: Int(image.size) ?? 0)
        }
        var deleted = 0
        for image in images where !image.isSystemComponent {
            let usages = try await strictImageUsages(cluster: cluster, references: image.references + [image.imageID])
            guard usages.isEmpty else { continue }
            _ = try await execCrictl(["rmi", image.imageID], cluster: cluster)
            deleted += 1
        }
        logService.log(result: CLIResult(command: "verified crictl rmi", output: "deleted=\(deleted), protected-system=\(images.filter(\.isSystemComponent).count)", exitCode: 0, duration: 0, mode: .async), module: "Kubernetes", operationType: "安全清理节点镜像")
    }

    /// 镜像打标签（crictl 无 tag 指令，用节点内 ctr；命名空间 k8s.io 与 containerd 一致）
    func tagNodeImage(cluster: String, from sourceRef: String, to targetRef: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "ctr", "-n", "k8s.io", "images", "tag", sourceRef, targetRef]),
                         operation: "镜像打标签",
                         successMessage: "已打标签 ✅ \(sourceRef) → \(targetRef)",
                         indeterminateKeywords: [])
    }

    /// 推送镜像到 registry（crictl 无 push 指令，用节点内 ctr；需先 tag 成目标仓库引用）
    func pushNodeImage(cluster: String, reference: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        try await stream(catalog.arguments(command: "container.exec", positionals: [nodeName, "ctr", "-n", "k8s.io", "images", "push", reference]),
                         operation: "推送镜像",
                         successMessage: "镜像已推送 ✅ \(reference)",
                         indeterminateKeywords: ["Pushing", "mounting", "Uploading"])
    }

    /// 查询 Kubernetes 声明层对镜像的引用，而不是只看当前正在运行的 CRI 容器。
    func fetchImageUsages(cluster: String, references: [String]) async -> [K8sImageUsage] {
        (try? await strictImageUsages(cluster: cluster, references: references)) ?? []
    }

    private func strictImageUsages(cluster: String, references: [String]) async throws -> [K8sImageUsage] {
        let output = try await execKubectl([
            "get", "deployment,statefulset,daemonset,job,cronjob,pod", "--all-namespaces", "-o", "json"
        ], cluster: cluster)
        guard let data = output.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw ContainerError.commandFailed("无法核对 Kubernetes 工作负载镜像引用；已拒绝删除")
        }
        let normalizedTargets = Set(references.map(Self.normalizedImageReference))
        return items.compactMap { item in
            let kind = item["kind"] as? String ?? "Unknown"
            let metadata = item["metadata"] as? [String: Any] ?? [:]
            let namespace = metadata["namespace"] as? String ?? "default"
            let name = metadata["name"] as? String ?? "-"
            guard let podSpec = Self.podSpec(in: item, kind: kind) else { return nil }
            let containers = (podSpec["containers"] as? [[String: Any]] ?? [])
                + (podSpec["initContainers"] as? [[String: Any]] ?? [])
            let matched = containers.compactMap { $0["image"] as? String }.filter {
                normalizedTargets.contains(Self.normalizedImageReference($0))
            }
            guard !matched.isEmpty else { return nil }
            return K8sImageUsage(kind: kind, namespace: namespace, name: name, images: matched)
        }.sorted { $0.displayName < $1.displayName }
    }

    func createDeploymentFromImage(
        cluster: String,
        reference: String,
        name: String,
        namespace: String,
        replicas: Int,
        containerPort: Int?,
        exposeService: Bool
    ) async throws {
        let safeNamespace = namespace.isEmpty ? "default" : namespace
        _ = try await execKubectl([
            "create", "deployment", name,
            "--namespace", safeNamespace,
            "--image", reference,
            "--replicas", String(max(1, replicas))
        ], cluster: cluster)
        if let containerPort {
            _ = try await execKubectl([
                "patch", "deployment", name, "--namespace", safeNamespace, "--type", "strategic",
                "-p", "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"\(name)\",\"ports\":[{\"containerPort\":\(containerPort)}]}]}}}}"
            ], cluster: cluster)
            if exposeService {
                _ = try await execKubectl([
                    "expose", "deployment", name, "--namespace", safeNamespace,
                    "--name", name, "--port", String(containerPort), "--target-port", String(containerPort),
                    "--type", "ClusterIP"
                ], cluster: cluster)
            }
        }
    }

    func applyManifest(cluster: String, yaml: String) async throws {
        let nodeName = try await nodeContainerName(for: cluster)
        let remotePath = "/tmp/cc.aiguru-\(UUID().uuidString).yaml"
        let payload = Data(yaml.utf8).base64EncodedString()
        _ = try await executor.execute(catalog.arguments(
            command: "container.exec",
            positionals: [nodeName, "sh", "-c", "printf '%s' '\(payload)' | base64 -d > '\(remotePath)'"]
        ))
        do {
            _ = try await execKubectl(["apply", "-f", remotePath], cluster: cluster)
            _ = try? await executor.execute(catalog.arguments(command: "container.exec", positionals: [nodeName, "rm", "-f", remotePath]))
        } catch {
            _ = try? await executor.execute(catalog.arguments(command: "container.exec", positionals: [nodeName, "rm", "-f", remotePath]))
            throw error
        }
    }

    func deleteNodeImageSafely(cluster: String, image: K8sNodeImage) async throws {
        guard !image.isSystemComponent else {
            throw ContainerError.commandFailed("控制平面/CNI 系统镜像受永久保护，不能从安全删除入口移除")
        }
        let usages = try await strictImageUsages(cluster: cluster, references: image.references + [image.imageID])
        guard usages.isEmpty else {
            throw ContainerError.commandFailed("镜像仍被 Kubernetes 资源引用：\(usages.map(\.displayName).joined(separator: ", "))")
        }
        try await deleteNodeImage(cluster: cluster, imageID: image.imageID, reference: image.displayReference)
    }

    private static func normalizedImageReference(_ value: String) -> String {
        var result = value.lowercased()
        if result.hasPrefix("docker.io/library/") { result.removeFirst("docker.io/library/".count) }
        else if result.hasPrefix("docker.io/") { result.removeFirst("docker.io/".count) }
        return result
    }

    private static func podSpec(in item: [String: Any], kind: String) -> [String: Any]? {
        guard let spec = item["spec"] as? [String: Any] else { return nil }
        switch kind {
        case "Pod": return spec
        case "CronJob":
            return (((spec["jobTemplate"] as? [String: Any])?["spec"] as? [String: Any])?["template"] as? [String: Any])?["spec"] as? [String: Any]
        default:
            return (spec["template"] as? [String: Any])?["spec"] as? [String: Any]
        }
    }
}

// MARK: - 节点控制面板数据模型

/// Kubernetes API 的 Node 资源，而非底层 containerd 容器。
/// Apple Container 的 k8s 当前是单节点集群，但仍使用标准 Node API，因而标签、污点、
/// 可调度状态和条件都与常规 Kubernetes 集群保持一致。
struct KubernetesNode: Identifiable, Hashable {
    let name: String
    let labels: [String: String]
    let annotations: [String: String]
    let unschedulable: Bool
    let taints: [KubernetesNodeTaint]
    let conditions: [KubernetesNodeCondition]
    let addresses: [KubernetesNodeAddress]
    let capacity: [String: String]
    let allocatable: [String: String]
    let nodeInfo: KubernetesNodeInfo
    let podCIDR: String?
    let createdAt: String?

    @MainActor init(_ dto: KubernetesNodeListResponse.Item) {
        name = dto.metadata.name
        labels = dto.metadata.labels ?? [:]
        annotations = dto.metadata.annotations ?? [:]
        unschedulable = dto.spec?.unschedulable ?? false
        taints = dto.spec?.taints?.map(KubernetesNodeTaint.init) ?? []
        conditions = dto.status?.conditions?.map(KubernetesNodeCondition.init) ?? []
        addresses = dto.status?.addresses?.map(KubernetesNodeAddress.init) ?? []
        capacity = dto.status?.capacity ?? [:]
        allocatable = dto.status?.allocatable ?? [:]
        nodeInfo = KubernetesNodeInfo(dto.status?.nodeInfo)
        podCIDR = dto.spec?.podCIDR
        createdAt = dto.metadata.creationTimestamp
    }

    var id: String { name }
    var readyCondition: KubernetesNodeCondition? { conditions.first { $0.type == "Ready" } }
    var isReady: Bool { readyCondition?.status == "True" }
    var internalIP: String { addresses.first(where: { $0.type == "InternalIP" })?.address ?? "-" }
    var roles: [String] {
        labels.keys.compactMap { key in
            guard key.hasPrefix("node-role.kubernetes.io/") else { return nil }
            return String(key.dropFirst("node-role.kubernetes.io/".count))
        }.sorted()
    }
    var roleText: String { roles.isEmpty ? "<none>" : roles.joined(separator: ", ") }
    var schedulabilityText: String { unschedulable ? "SchedulingDisabled" : "Schedulable" }
    var cpuText: String { "\(allocatable["cpu"] ?? "-") / \(capacity["cpu"] ?? "-")" }
    var memoryText: String { "\(allocatable["memory"] ?? "-") / \(capacity["memory"] ?? "-")" }
    var podsText: String { "\(allocatable["pods"] ?? "-") / \(capacity["pods"] ?? "-")" }
}

struct KubernetesNodeTaint: Identifiable, Hashable {
    let key: String
    let value: String?
    let effect: String
    var id: String { "\(key)=\(value ?? ""):\(effect)" }
    var expression: String { value.map { "\(key)=\($0):\(effect)" } ?? "\(key):\(effect)" }
    @MainActor init(_ dto: KubernetesNodeListResponse.Taint) { key = dto.key; value = dto.value; effect = dto.effect }
}

struct KubernetesNodeCondition: Identifiable, Hashable {
    let type: String
    let status: String
    let reason: String?
    let message: String?
    let lastTransitionTime: String?
    var id: String { type }
    @MainActor init(_ dto: KubernetesNodeListResponse.Condition) {
        type = dto.type; status = dto.status; reason = dto.reason; message = dto.message; lastTransitionTime = dto.lastTransitionTime
    }
}

struct KubernetesNodeAddress: Identifiable, Hashable {
    let type: String
    let address: String
    var id: String { "\(type):\(address)" }
    @MainActor init(_ dto: KubernetesNodeListResponse.Address) { type = dto.type; address = dto.address }
}

struct KubernetesNodeInfo: Hashable {
    let kubeletVersion: String
    let containerRuntimeVersion: String
    let osImage: String
    let kernelVersion: String
    let architecture: String
    @MainActor init(_ dto: KubernetesNodeListResponse.NodeInfo?) {
        kubeletVersion = dto?.kubeletVersion ?? "-"
        containerRuntimeVersion = dto?.containerRuntimeVersion ?? "-"
        osImage = dto?.osImage ?? "-"
        kernelVersion = dto?.kernelVersion ?? "-"
        architecture = dto?.architecture ?? "-"
    }
}

/// Kubernetes API 的 Pod 资源。此模型不同于 crictl 的 Pod sandbox，包含控制器、就绪数、
/// 重启次数与调度节点等用户在 kubectl 中实际关注的信息。
struct KubernetesPod: Identifiable, Hashable {
    let name: String
    let namespace: String
    let phase: String
    let nodeName: String
    let podIP: String
    let createdAt: String?
    let containers: [KubernetesPodContainer]
    let owner: String
    let reason: String?
    let message: String?

    @MainActor init(_ dto: KubernetesPodListResponse.Item) {
        name = dto.metadata.name
        namespace = dto.metadata.namespace ?? "default"
        phase = dto.status?.phase ?? "Unknown"
        nodeName = dto.spec?.nodeName ?? "<pending>"
        podIP = dto.status?.podIP ?? "-"
        createdAt = dto.metadata.creationTimestamp
        containers = dto.status?.containerStatuses?.map(KubernetesPodContainer.init) ?? []
        if let ownerReference = dto.metadata.ownerReferences?.first {
            owner = "\(ownerReference.kind)/\(ownerReference.name)"
        } else {
            owner = "-"
        }
        reason = dto.status?.reason
        message = dto.status?.message
    }

    var id: String { "\(namespace)/\(name)" }
    var readyCount: Int { containers.filter(\.ready).count }
    var readyText: String { "\(readyCount)/\(containers.count)" }
    var isHealthy: Bool { phase == "Running" && readyCount == containers.count && !containers.isEmpty }
}

struct KubernetesPodContainer: Identifiable, Hashable {
    let name: String
    let ready: Bool
    let restartCount: Int
    let image: String
    let state: String
    let reason: String?

    @MainActor init(_ dto: KubernetesPodListResponse.ContainerStatus) {
        name = dto.name
        ready = dto.ready
        restartCount = dto.restartCount
        image = dto.image
        if dto.state.running != nil { state = "Running"; reason = nil }
        else if let waiting = dto.state.waiting { state = "Waiting"; reason = waiting.reason }
        else if let terminated = dto.state.terminated { state = "Terminated"; reason = terminated.reason }
        else { state = "Unknown"; reason = nil }
    }

    var id: String { name }
}

enum KubernetesResourceCategory: String, CaseIterable, Identifiable {
    case workloads = "工作负载"
    case networking = "服务与网络"
    case configuration = "配置与存储"
    case access = "访问控制"
    case extensions = "扩展与事件"

    var id: String { rawValue }
    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

struct KubernetesAPIResource: Identifiable, Hashable {
    let groupVersion: String
    let name: String
    let singularName: String
    let kind: String
    let namespaced: Bool
    let verbs: Set<String>
    let shortNames: [String]

    var id: String { "\(groupVersion)/\(name)" }
    var group: String { groupVersion.contains("/") ? String(groupVersion.split(separator: "/")[0]) : "core" }
    var qualifiedName: String { group == "core" ? name : "\(name).\(group)" }
    var canList: Bool { verbs.contains("list") }
    var canCreate: Bool { verbs.contains("create") }
    var canUpdate: Bool { verbs.contains("update") || verbs.contains("patch") }
    var canDelete: Bool { verbs.contains("delete") }
    var category: KubernetesResourceCategory {
        switch kind {
        case "Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "ReplicationController": return .workloads
        case "Service", "Endpoints", "EndpointSlice", "Ingress", "IngressClass", "NetworkPolicy": return .networking
        case "ConfigMap", "Secret", "PersistentVolume", "PersistentVolumeClaim", "StorageClass", "VolumeAttachment", "CSIDriver", "CSINode": return .configuration
        case "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding": return .access
        default: return .extensions
        }
    }
}

struct KubernetesAPIObject: Identifiable, Hashable {
    let name: String
    let namespace: String?
    let createdAt: String?
    let phase: String?
    var id: String { "\(namespace ?? "_")/\(name)" }
}

private struct KubernetesAPIVersions: Decodable { let versions: [String] }
private struct KubernetesAPIGroupList: Decodable {
    let groups: [Group]
    struct Group: Decodable {
        let preferredVersion: Version?
        struct Version: Decodable { let groupVersion: String }
    }
}
private struct KubernetesAPIResourceList: Decodable {
    let resources: [Resource]
    struct Resource: Decodable {
        let name: String
        let singularName: String
        let namespaced: Bool
        let kind: String
        let verbs: [String]
        let shortNames: [String]?
    }
}

/// 节点 containerd 内的单个镜像（crictl images -o json）
struct K8sNodeImage: Identifiable, Hashable {
    let imageID: String          // sha256:...
    let references: [String]     // repoTags（可能多个，digest 镜像则为 [id]）
    let sizeBytes: Int
    var id: String { imageID }
    var displayReference: String { references.first ?? imageID }
    var sizeText: String { sizeBytes.byteCountText }
    /// 集群系统组件镜像（控制平面/网络/存储等）。实测 crictl rmi 即使镜像在用也可能删成功，
    /// 删除后组件重启将无法拉回（registry.k8s.io 不可达），集群需重建，必须强警告。
    var isSystemComponent: Bool {
        references.contains { ref in
            ref.hasPrefix("registry.k8s.io")
                || ref.hasPrefix("docker.io/kindest")
                || ref.hasPrefix("registry.aliyuncs.com/google_containers")
        }
    }
}

struct K8sImageUsage: Identifiable, Hashable {
    let kind: String
    let namespace: String
    let name: String
    let images: [String]
    var id: String { "\(kind)/\(namespace)/\(name)" }
    var displayName: String { "\(kind) \(namespace)/\(name)" }
}

/// 节点 containerd 内的单个容器（crictl ps -o json）
struct K8sNodeContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String            // CONTAINER_RUNNING / CONTAINER_EXITED / ...
    let podName: String
    let namespace: String
    let restarts: String
    var id12: String { String(id.prefix(12)) }
    var isRunning: Bool { state == "CONTAINER_RUNNING" }
    var stateText: String {
        switch state {
        case "CONTAINER_RUNNING": return "Running"
        case "CONTAINER_EXITED": return "Exited"
        case "CONTAINER_CREATED": return "Created"
        default: return state.replacingOccurrences(of: "CONTAINER_", with: "")
        }
    }
}

/// 节点内的 Pod 沙箱（crictl pods -o json）
struct K8sNodePod: Identifiable, Hashable {
    let id: String
    let name: String
    let namespace: String
    let state: String            // SANDBOX_READY / SANDBOX_NOTREADY
    var id12: String { String(id.prefix(12)) }
    var isReady: Bool { state == "SANDBOX_READY" }
    var stateText: String {
        switch state {
        case "SANDBOX_READY": return "Ready"
        case "SANDBOX_NOTREADY": return "NotReady"
        default: return state.replacingOccurrences(of: "SANDBOX_", with: "")
        }
    }
}

/// 镜像详情（crictl inspecti）
struct K8sImageDetail {
    let imageID: String
    let repoTags: [String]
    let repoDigests: [String]
    let sizeBytes: Int
    let pinned: Bool
    let architecture: String
    let os: String
    let created: String
    let entrypoint: [String]
    let env: [String]
    let labels: [String: String]
    let user: String
    let workingDir: String
}

/// 容器详情（crictl inspect）
struct K8sContainerDetail {
    let containerID: String
    let pid: Int
    let createdAt: String         // Unix 纳秒
    let logPath: String
    let restartCount: String
    var createdDateText: String {
        guard let nanos = Double(createdAt), nanos > 0 else { return "-" }
        let date = Date(timeIntervalSince1970: nanos / 1_000_000_000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 容器实时资源（crictl stats）
struct K8sContainerStats {
    let cpuNanoCores: String
    let workingSetBytes: String
    var cpuText: String {
        guard let cores = Double(cpuNanoCores), cores > 0 else { return "0" }
        return String(format: "%.1f mCPU", cores / 1_000_000)
    }
    var memText: String {
        guard let bytes = Double(workingSetBytes), bytes > 0 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

extension Int {
    /// 字节数转可读文本（MB/GB）
    var byteCountText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(self))
    }
}

// MARK: - crictl JSON DTO（字段名与 crictl -o json 输出一致）

private struct CrictlImagesResponse: Decodable {
    let images: [CrictlImage]
    struct CrictlImage: Decodable {
        let id: String
        let repoTags: [String]
        let repoDigests: [String]?
        let size: String
    }
}

private struct CrictlContainersResponse: Decodable {
    let containers: [CrictlContainer]
    struct CrictlContainer: Decodable {
        let id: String
        let metadata: Metadata?
        let image: Image?
        let state: String
        let labels: [String: String]?
        let annotations: [String: String]?
        struct Metadata: Decodable { let name: String? }
        struct Image: Decodable { let image: String?; let userSpecifiedImage: String? }
    }
}

private struct CrictlPodsResponse: Decodable {
    let items: [CrictlPod]
    struct CrictlPod: Decodable {
        let id: String
        let metadata: Metadata?
        let state: String
        struct Metadata: Decodable { let name: String?; let namespace: String? }
    }
}

private struct CrictlImageFsResponse: Decodable {
    let status: Status?
    struct Status: Decodable {
        let imageFilesystems: [Fs]?
        struct Fs: Decodable {
            let usedBytes: UsedBytes?
            struct UsedBytes: Decodable { let bytes: Int }
        }
    }
}

// inspecti：status + info.imageSpec.config
private struct CrictlInspectImage: Decodable {
    let status: Status
    let info: Info?
    struct Status: Decodable {
        let id: String
        let repoTags: [String]
        let repoDigests: [String]
        let size: String
        let pinned: Bool
    }
    struct Info: Decodable { let imageSpec: ImageSpec? }
    struct ImageSpec: Decodable {
        let architecture: String?
        let os: String?
        let created: String?
        let config: ImageConfig?
    }
    struct ImageConfig: Decodable {
        let entrypoint: [String]?
        let args: [String]?
        let env: [String]?
        let labels: [String: String]?
        let user: String?
        let workingDir: String?
    }
}

// inspect：status(pid/createdAt/logPath) + info.config.annotations
private struct CrictlInspectContainer: Decodable {
    let status: Status
    let info: Info?
    struct Status: Decodable {
        let id: String
        let pid: Pid?
        let createdAt: String?
        let logPath: String?
        struct Pid: Decodable { let value: Int }
    }
    struct Info: Decodable { let config: Config? }
    struct Config: Decodable { let annotations: [String: String]? }
}

// stats：cpu.usageNanoCores / memory.workingSetBytes
private struct CrictlStatsResponse: Decodable {
    let stats: [Stat]
    struct Stat: Decodable {
        let attributes: Attributes?
        let cpu: Cpu?
        let memory: Memory?
        struct Attributes: Decodable { let id: String? }
        struct Cpu: Decodable { let usageNanoCores: String? }
        struct Memory: Decodable { let workingSetBytes: String? }
    }
}

// MARK: - Kubernetes Node API DTO（kubectl get nodes -o json）

struct KubernetesNodeListResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let metadata: Metadata
        let spec: Spec?
        let status: Status?
    }

    struct Metadata: Decodable {
        let name: String
        let labels: [String: String]?
        let annotations: [String: String]?
        let creationTimestamp: String?
    }

    struct Spec: Decodable {
        let unschedulable: Bool?
        let taints: [Taint]?
        let podCIDR: String?
    }

    struct Taint: Decodable {
        let key: String
        let value: String?
        let effect: String
    }

    struct Status: Decodable {
        let addresses: [Address]?
        let capacity: [String: String]?
        let allocatable: [String: String]?
        let conditions: [Condition]?
        let nodeInfo: NodeInfo?
    }

    struct Address: Decodable { let type: String; let address: String }
    struct Condition: Decodable {
        let type: String
        let status: String
        let reason: String?
        let message: String?
        let lastTransitionTime: String?
    }
    struct NodeInfo: Decodable {
        let kubeletVersion: String?
        let containerRuntimeVersion: String?
        let osImage: String?
        let kernelVersion: String?
        let architecture: String?
    }
}

// MARK: - Kubernetes Pod API DTO（kubectl get pods -A -o json）

struct KubernetesPodListResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let metadata: Metadata
        let spec: Spec?
        let status: Status?
    }
    struct Metadata: Decodable {
        let name: String
        let namespace: String?
        let creationTimestamp: String?
        let ownerReferences: [OwnerReference]?
    }
    struct OwnerReference: Decodable { let kind: String; let name: String }
    struct Spec: Decodable { let nodeName: String? }
    struct Status: Decodable {
        let phase: String?
        let podIP: String?
        let reason: String?
        let message: String?
        let containerStatuses: [ContainerStatus]?
    }
    struct ContainerStatus: Decodable {
        let name: String
        let ready: Bool
        let restartCount: Int
        let image: String
        let state: ContainerState
    }
    struct ContainerState: Decodable {
        let running: Running?
        let waiting: Waiting?
        let terminated: Terminated?
        struct Running: Decodable {}
        struct Waiting: Decodable { let reason: String? }
        struct Terminated: Decodable { let reason: String? }
    }
}
