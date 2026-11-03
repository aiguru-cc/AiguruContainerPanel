import Foundation

enum ClusterPublishTarget: String, CaseIterable, Identifiable, Codable {
    case kubernetes = "OCI / Kubernetes"
    case docker = "Docker / 宝塔 Docker"
    case vmAppliance = "Apple Container VM Appliance"
    var id: String { rawValue }
}

struct ClusterPublishOptions {
    var targets: Set<ClusterPublishTarget>
    var registry: String
    var namespace: String
    var versionTag: String
    var platform: String
    var includeStoragePlan: Bool
    var includeHelm: Bool
    var kernelPath: String
}

struct ClusterPublishTask: Codable, Identifiable {
    let id: String
    let phase: String
    let title: String
    let command: [String]
    let requiresConfirmation: Bool
    let notes: String?
}

struct ClusterPublishPlan: Codable {
    let schemaVersion: Int
    let cluster: String
    let generatedAt: Date
    let targets: [ClusterPublishTarget]
    let tasks: [ClusterPublishTask]
}

enum ClusterPublishError: LocalizedError {
    case noTarget
    case noImage(String)
    case invalidRegistry

    var errorDescription: String? {
        switch self {
        case .noTarget: return "至少选择一种发布目标"
        case .noImage(let service): return "服务 \(service) 没有可发布的 OCI 镜像"
        case .invalidRegistry: return "OCI/Kubernetes 模式需要填写 Registry 地址"
        }
    }
}

/// 将 Apple Container 应用集群投影为可审阅的 OCI/Kubernetes 与 VM Appliance 任务包。
/// 这里只生成任务，不直接推送 Registry 或修改 Kubernetes 集群。
final class ApplicationClusterPublishManager {
    static let shared = ApplicationClusterPublishManager()
    private init() {}

    /// 为本机 K8s 直接部署生成清单。镜像引用保持为 Apple Container 本地 OCI 引用，
    /// 由调用方先通过 `k8s load-image` 导入节点 containerd。
    func liveKubernetesManifest(cluster: ApplicationCluster, namespace: String) throws -> String {
        let clusterName = slug(cluster.name)
        let safeNamespace = slug(namespace.isEmpty ? "default" : namespace)
        let namespaceAPI = kubernetesAPIVersion(for: "Namespace")
        let namespaceYAML = "apiVersion: \(namespaceAPI)\nkind: Namespace\nmetadata:\n  name: \(safeNamespace)"
        let workloads = try cluster.serviceGroups.map { service -> String in
            guard let image = service.containers.first?.image, image != "未知镜像" else {
                throw ClusterPublishError.noImage(service.name)
            }
            return kubernetesManifest(
                service: service,
                clusterName: clusterName,
                namespace: safeNamespace,
                image: image,
                includeStorage: true
            )
        }
        return ([namespaceYAML] + workloads).joined(separator: "\n---\n")
    }

    func generate(cluster: ApplicationCluster, options: ClusterPublishOptions, outputRoot: URL, progress: ((Double, String) -> Void)? = nil) throws -> URL {
        progress?(0.05, "准备发布目录")
        guard !options.targets.isEmpty else { throw ClusterPublishError.noTarget }
        if options.targets.contains(.kubernetes), options.registry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ClusterPublishError.invalidRegistry
        }

        let packageName = "\(slug(cluster.name))-publish"
        let packageURL = outputRoot.appendingPathComponent(packageName, isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        var tasks: [ClusterPublishTask] = []
        if options.targets.contains(.kubernetes) {
            progress?(0.20, "生成 Kubernetes / Helm / Compose 清单")
            tasks += try generateKubernetes(cluster: cluster, options: options, root: packageURL)
        }
        if options.targets.contains(.docker) {
            progress?(0.55, "生成 Docker / 宝塔 OCI 镜像归档任务")
            tasks += try generateDockerPortable(cluster: cluster, options: options, root: packageURL)
        }
        if options.targets.contains(.vmAppliance) {
            progress?(0.75, "生成 Apple Container Appliance")
            tasks += try generateVMAppliance(cluster: cluster, options: options, root: packageURL)
        }

        let plan = ClusterPublishPlan(
            schemaVersion: 1,
            cluster: cluster.name,
            generatedAt: Date(),
            targets: options.targets.sorted { $0.rawValue < $1.rawValue },
            tasks: tasks
        )
        try writeJSON(plan, to: packageURL.appendingPathComponent("task-plan.json"))
        try readme(cluster: cluster, options: options, tasks: tasks)
            .write(to: packageURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        progress?(1.0, "发布包生成完成")
        return packageURL
    }

    private func generateDockerPortable(
        cluster: ApplicationCluster,
        options: ClusterPublishOptions,
        root: URL
    ) throws -> [ClusterPublishTask] {
        let directory = root.appendingPathComponent("docker", isDirectory: true)
        let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let catalog = CLICommandCatalog.shared
        let savePath = catalog.path(command: "image.save") ?? []
        let outputFlag = catalog.flag(command: "image.save", option: "output")
        var tasks: [ClusterPublishTask] = []
        var composeServices: [String] = []
        var dockerLoad = ["#!/bin/sh", "set -eu"]
        var baotaLoad = ["#!/bin/sh", "set -eu", "# 在宝塔 Docker 环境执行；先将本目录复制到服务器"]
        var exported = Set<String>()

        for service in cluster.serviceGroups {
            guard let image = service.containers.first?.image, image != "未知镜像" else {
                throw ClusterPublishError.noImage(service.name)
            }
            let serviceName = slug(service.name)
            let archive = "images/(serviceName).oci.tar"
            if exported.insert(image).inserted {
                tasks.append(.init(
                    id: "docker-export-(serviceName)", phase: "package", title: "导出 (service.name) OCI 镜像归档",
                    command: ["container"] + savePath + [outputFlag, "docker/(archive)", image],
                    requiresConfirmation: false,
                    notes: "生成 Docker、Kubernetes 与宝塔 Docker 均可导入的 OCI tar 归档"
                ))
                dockerLoad.append("docker load -i \"$SCRIPT_DIR/\(archive)\"")
                baotaLoad.append("docker load -i \"$SCRIPT_DIR/\(archive)\"")
            }
            composeServices.append(composeService(service: service, image: image))
        }

        try ("services:\n" + composeServices.joined(separator: "\n"))
            .write(to: directory.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)
        let scriptDirLine = #"SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)""#
        let dockerScript = (["#!/bin/sh", "set -eu", scriptDirLine] + dockerLoad.dropFirst(2) + ["docker compose -f \"$SCRIPT_DIR/docker-compose.yml\" up -d"]).joined(separator: "\n") + "\n"
        let dockerScriptURL = directory.appendingPathComponent("import-docker.sh")
        try dockerScript.write(to: dockerScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dockerScriptURL.path)
        let baotaScript = (["#!/bin/sh", "set -eu", scriptDirLine] + baotaLoad.dropFirst(2) + ["echo \"镜像已导入宝塔 Docker；请在宝塔 Docker 模块中按 docker-compose.yml 创建应用.\""]).joined(separator: "\n") + "\n"
        let baotaScriptURL = directory.appendingPathComponent("import-baota-docker.sh")
        try baotaScript.write(to: baotaScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: baotaScriptURL.path)
        try dockerReadme(cluster: cluster, options: options).write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        return tasks
    }

    private func dockerReadme(cluster: ApplicationCluster, options: ClusterPublishOptions) -> String {
        """
        # (cluster.name) Docker / 宝塔 Docker 导入包

        目标 OS：(options.platform)

        1. 将整个目录复制到 Docker 主机或宝塔 Docker 主机。
        2. Docker 主机执行 `./import-docker.sh`；脚本会导入 `images/*.oci.tar` 并启动 Compose。
        3. 宝塔 Docker 主机执行 `./import-baota-docker.sh`，然后在宝塔 Docker 模块中导入 `docker-compose.yml`。

        OCI tar 是镜像归档，不包含运行中内存状态。宿主机挂载和数据库数据需要单独迁移。
        """
    }

    private func generateKubernetes(
        cluster: ApplicationCluster,
        options: ClusterPublishOptions,
        root: URL
    ) throws -> [ClusterPublishTask] {
        let directory = root.appendingPathComponent("kubernetes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = options.registry.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let clusterName = slug(cluster.name)
        let catalog = CLICommandCatalog.shared
        let tagPath = catalog.path(command: "image.tag") ?? []
        let pushPath = catalog.path(command: "image.push") ?? []
        var tasks: [ClusterPublishTask] = []
        var manifests: [String] = []
        var composeServices: [String] = []

        for service in cluster.serviceGroups {
            guard let sourceImage = service.containers.first?.image, sourceImage != "未知镜像" else {
                throw ClusterPublishError.noImage(service.name)
            }
            let serviceName = slug(service.name)
            let targetImage = "\(registry)/\(clusterName)/\(serviceName):\(slug(options.versionTag))"
            tasks.append(.init(
                id: "oci-tag-\(serviceName)", phase: "image", title: "标记 \(service.name) 镜像",
                command: ["container"] + tagPath + [sourceImage, targetImage],
                requiresConfirmation: false, notes: "OCI 镜像保持跨 Apple Container、Docker 与 Kubernetes 兼容"
            ))
            tasks.append(.init(
                id: "oci-push-\(serviceName)", phase: "publish", title: "推送 \(service.name) 镜像",
                command: ["container"] + pushPath + [targetImage],
                requiresConfirmation: true, notes: "需要 Registry 登录凭据"
            ))
            manifests.append(kubernetesManifest(service: service, clusterName: clusterName, namespace: options.namespace, image: targetImage, includeStorage: options.includeStoragePlan))
            composeServices.append(composeService(service: service, image: targetImage))
        }

        let namespace = slug(options.namespace)
        let namespaceAPI = kubernetesAPIVersion(for: "Namespace")
        let namespaceYAML = "apiVersion: \(namespaceAPI)\nkind: Namespace\nmetadata:\n  name: \(namespace)"
        try ([namespaceYAML] + manifests).joined(separator: "\n---\n")
            .write(to: directory.appendingPathComponent("kubernetes.yaml"), atomically: true, encoding: .utf8)
        try ("services:\n" + composeServices.joined(separator: "\n"))
            .write(to: directory.appendingPathComponent("docker-compose.yml"), atomically: true, encoding: .utf8)
        try executableScript(tasks: tasks.filter { $0.phase == "image" || $0.phase == "publish" })
            .write(to: directory.appendingPathComponent("publish-images.sh"), atomically: true, encoding: .utf8)
        try crictlDiagnostics(namespace: namespace)
            .write(to: directory.appendingPathComponent("crictl-diagnostics.sh"), atomically: true, encoding: .utf8)
        if options.includeStoragePlan {
            try storageMigrationPlan(cluster: cluster)
                .write(to: directory.appendingPathComponent("storage-migration.md"), atomically: true, encoding: .utf8)
        }

        tasks.append(.init(
            id: "k8s-apply", phase: "deploy", title: "部署 Kubernetes 工作负载",
            command: ["kubectl", "apply", "-f", "kubernetes/kubernetes.yaml"],
            requiresConfirmation: true, notes: "kubectl 是部署入口；crictl 仅用于 Linux 节点诊断"
        ))
        if options.includeHelm {
            let chart = directory.appendingPathComponent("helm", isDirectory: true)
            try FileManager.default.createDirectory(at: chart.appendingPathComponent("templates", isDirectory: true), withIntermediateDirectories: true)
            try "apiVersion: v2\nname: \(clusterName)\nversion: 0.1.0\nappVersion: \(yamlQuote(options.versionTag))\n"
                .write(to: chart.appendingPathComponent("Chart.yaml"), atomically: true, encoding: .utf8)
            try manifests.joined(separator: "\n---\n")
                .write(to: chart.appendingPathComponent("templates/workloads.yaml"), atomically: true, encoding: .utf8)
            tasks.append(.init(
                id: "helm-upgrade", phase: "deploy", title: "使用 Helm 部署",
                command: ["helm", "upgrade", "--install", clusterName, "kubernetes/helm", "--namespace", namespace, "--create-namespace"],
                requiresConfirmation: true, notes: nil
            ))
        }
        return tasks
    }

    private func generateVMAppliance(
        cluster: ApplicationCluster,
        options: ClusterPublishOptions,
        root: URL
    ) throws -> [ClusterPublishTask] {
        let directory = root.appendingPathComponent("vm-appliance", isDirectory: true)
        let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var tasks: [ClusterPublishTask] = []
        var restoreLines = ["#!/bin/sh", "set -eu", "CONTAINER_BIN=${CONTAINER_BIN:-/usr/local/bin/container}"]
        var exported = Set<String>()
        let catalog = CLICommandCatalog.shared
        let savePath = catalog.path(command: "image.save") ?? []
        let loadPath = catalog.path(command: "image.load") ?? []
        let outputFlag = catalog.flag(command: "image.save", option: "output")
        let inputFlag = catalog.flag(command: "image.load", option: "input")

        for service in cluster.serviceGroups {
            guard let image = service.containers.first?.image, image != "未知镜像" else {
                throw ClusterPublishError.noImage(service.name)
            }
            let serviceName = slug(service.name)
            let archive = "images/\(serviceName).oci.tar"
            if exported.insert(image).inserted {
                tasks.append(.init(
                    id: "vm-export-\(serviceName)", phase: "package", title: "导出 \(service.name) OCI 根文件系统",
                    command: ["container"] + savePath + [outputFlag, "vm-appliance/\(archive)", image],
                    requiresConfirmation: false, notes: "保存的是 OCI 镜像，不包含运行中内存状态"
                ))
                restoreLines.append((["\"$CONTAINER_BIN\""] + loadPath + [inputFlag, shellQuote(archive)]).joined(separator: " "))
            }
            for (index, container) in service.containers.enumerated() {
                var run = ["\"$CONTAINER_BIN\""] + (catalog.path(command: "container.run") ?? [])
                run += [catalog.flag(command: "container.run", option: "detach"), catalog.flag(command: "container.run", option: "name"), shellQuote(container.displayName)]
                if !options.kernelPath.isEmpty { run += [catalog.flag(command: "container.run", option: "kernel"), shellQuote(options.kernelPath)] }
                if container.configuration?.virtualization == true { run.append(catalog.flag(command: "container.run", option: "virtualization")) }
                for port in container.ports ?? [] {
                    if let host = port.hostPortString {
                        run += [catalog.flag(command: "container.run", option: "publish"), shellQuote("\(host):\(port.containerPortString)/\(port.protocolType)")]
                    }
                }
                for mount in container.mounts ?? [] {
                    run += [catalog.flag(command: "container.run", option: "volume"), shellQuote("\(mount.source):\(mount.destination)")]
                }
                run.append(shellQuote(image))
                restoreLines.append(run.joined(separator: " "))
                tasks.append(.init(
                    id: "vm-restore-\(serviceName)-\(index)", phase: "restore", title: "恢复 \(container.displayName) 原子 VM 容器",
                    command: run.map { $0.replacingOccurrences(of: "\"$CONTAINER_BIN\"", with: "container") },
                    requiresConfirmation: true, notes: "由 Apple Container 启动轻量 VM；不交给 crictl"
                ))
            }
        }

        let descriptor: [String: Any] = [
            "schemaVersion": 1,
            "kind": "AppleContainerVMAppliance",
            "cluster": cluster.name,
            "platform": options.platform,
            "kernel": options.kernelPath.isEmpty ? "recommended-or-current" : options.kernelPath,
            "stateIncluded": false,
            "services": cluster.serviceGroups.map { service in
                ["name": service.name, "image": service.containers.first?.image ?? "", "replicas": service.containers.count]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: descriptor, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("appliance.json"))
        try (restoreLines.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("restore-apple-container.sh"), atomically: true, encoding: .utf8)
        try executableScript(tasks: tasks.filter { $0.phase == "package" })
            .write(to: directory.appendingPathComponent("export-images.sh"), atomically: true, encoding: .utf8)
        return tasks
    }

    private func kubernetesManifest(service: ApplicationClusterService, clusterName: String, namespace: String, image: String, includeStorage: Bool) -> String {
        let name = slug(service.name)
        let ports = Array(Set(service.containers.flatMap { $0.ports ?? [] }.map(\.containerPortString))).sorted()
        let hasMounts = service.containers.contains { !($0.mounts ?? []).isEmpty }
        let kind = hasMounts && includeStorage ? "StatefulSet" : "Deployment"
        let mounts = includeStorage ? (service.containers.first?.mounts ?? []) : []
        let portYAML = ports.enumerated().map { "        - name: p\($0.offset)\n          containerPort: \($0.element)" }.joined(separator: "\n")
        let servicePorts = ports.enumerated().map { "  - name: p\($0.offset)\n    port: \($0.element)\n    targetPort: \($0.element)" }.joined(separator: "\n")
        let portsBlock = portYAML.isEmpty ? "" : "\n      ports:\n\(portYAML)"
        let volumeMounts = mounts.enumerated().map { "        - name: data-\($0.offset)\n          mountPath: \(yamlQuote($0.element.destination))" }.joined(separator: "\n")
        let volumeMountsBlock = volumeMounts.isEmpty ? "" : "\n      volumeMounts:\n\(volumeMounts)"
        let statefulServiceName = kind == "StatefulSet" ? "\n  serviceName: \(name)" : ""
        let claims = mounts.enumerated().map {
            "  - metadata:\n      name: data-\($0.offset)\n    spec:\n      accessModes: [\"ReadWriteOnce\"]\n      resources:\n        requests:\n          storage: 1Gi"
        }.joined(separator: "\n")
        let claimsBlock = claims.isEmpty ? "" : "\n  volumeClaimTemplates:\n\(claims)"
        let serviceBlock: String
        if ports.isEmpty, kind != "StatefulSet" {
            serviceBlock = ""
        } else {
            let headless = ports.isEmpty ? "\n  clusterIP: None" : ""
            let portSection = ports.isEmpty ? "" : "\n  ports:\n\(servicePorts)"
            serviceBlock = "\n---\napiVersion: \(kubernetesAPIVersion(for: "Service"))\nkind: Service\nmetadata:\n  name: \(name)\n  namespace: \(slug(namespace))\nspec:\(headless)\n  selector:\n    app.kubernetes.io/instance: \(clusterName)\n    app.kubernetes.io/name: \(name)\(portSection)"
        }
        return """
        apiVersion: \(kubernetesAPIVersion(for: kind))
        kind: \(kind)
        metadata:
          name: \(name)
          namespace: \(slug(namespace))
          labels:
            app.kubernetes.io/instance: \(clusterName)
            app.kubernetes.io/name: \(name)
        spec:
          replicas: \(service.containers.count)\(statefulServiceName)
          selector:
            matchLabels:
              app.kubernetes.io/instance: \(clusterName)
              app.kubernetes.io/name: \(name)
          template:
            metadata:
              labels:
                app.kubernetes.io/instance: \(clusterName)
                app.kubernetes.io/name: \(name)
            spec:
              containers:
              - name: \(name)
                image: \(yamlQuote(image))
                imagePullPolicy: IfNotPresent\(portsBlock)\(volumeMountsBlock)\(claimsBlock)
        \(serviceBlock)
        """
    }

    private func composeService(service: ApplicationClusterService, image: String) -> String {
        let name = slug(service.name)
        let ports = Array(Set(service.containers.flatMap { $0.ports ?? [] }.compactMap { port in
            port.hostPortString.map { "\($0):\(port.containerPortString)" }
        })).sorted()
        let portBlock = ports.isEmpty ? "" : "\n    ports:\n" + ports.map { "      - \(yamlQuote($0))" }.joined(separator: "\n")
        return "  \(name):\n    image: \(yamlQuote(image))\n    restart: unless-stopped\(portBlock)"
    }

    private func executableScript(tasks: [ClusterPublishTask]) -> String {
        (["#!/bin/sh", "set -eu"] + tasks.map { $0.command.map(shellQuote).joined(separator: " ") }).joined(separator: "\n") + "\n"
    }

    private func crictlDiagnostics(namespace: String) -> String {
        """
        #!/bin/sh
        set -eu
        # 在 Linux Kubernetes 节点执行。crictl 只用于 CRI 诊断，不负责部署。
        crictl images
        crictl pods --namespace \(shellQuote(namespace))
        crictl ps --all
        """
    }

    private func storageMigrationPlan(cluster: ApplicationCluster) -> String {
        let rows = cluster.mounts.map { mount in
            "| `\(mount.source)` | `\(mount.destination)` | \(mount.services.sorted().joined(separator: ", ")) | 待选择 PVC / CSI / 对象存储 |"
        }
        return """
        # 存储迁移计划

        宿主机 bind mount 不会写入 OCI 镜像。部署前为每项选择目标存储并执行应用一致性备份。

        | 当前来源 | 容器目标 | 服务 | Kubernetes 目标 |
        |---|---|---|---|
        \(rows.isEmpty ? "| 无挂载 | — | — | — |" : rows.joined(separator: "\n"))

        数据库应使用数据库原生备份/恢复；Redis、Memcached 等缓存默认不迁移。不要直接复制正在写入的数据目录。
        """
    }

    private func readme(cluster: ApplicationCluster, options: ClusterPublishOptions, tasks: [ClusterPublishTask]) -> String {
        """
        # \(cluster.name) 发布任务包

        本目录由 Aiguru Container Panel 生成，共 \(tasks.count) 个任务。`task-plan.json` 是向导任务的机器可读入口。

        - Kubernetes 链路：Apple Container OCI 镜像 → Registry → Docker/Kubernetes。使用 kubectl/Helm 部署，crictl 只做 Linux 节点诊断。
        - VM Appliance 链路：OCI 根文件系统 + Apple Container 恢复描述。每个容器仍由 Apple Container 启动独立轻量 VM，不伪装为 Kubernetes CRI 容器。
        - 包不包含运行中内存状态。宿主机 bind mount 数据不会被嵌入镜像，需按存储迁移计划处理。

        目标平台：\(options.platform)
        """
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url)
    }

    /// 生成清单时使用当前环境已验证的插件/API 档位；尚未探测过时使用库中最新标准档位。
    private func kubernetesAPIVersion(for kind: String) -> String {
        let environment = EnvironmentManager.shared
        let apiCatalog = KubernetesAPICatalog.shared
        let profile = apiCatalog.activeProfile(
            pluginVersion: KubernetesManager.shared.pluginVersion,
            environmentID: environment.currentEnvironment?.id
        ) ?? apiCatalog.latestProfile
        return profile?.resources[kind] ?? "v1"
    }

    private func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = allowed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "app" : collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func yamlQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }
    private func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }
}
