//
//  ClusterTemplate.swift
//  AiguruContainerPanel
//
//  应用集群模板模型：定义一组由 Aiguru 统一编排的容器服务。
//  它是本机声明式编排，不伪装为 Kubernetes：不提供跨主机调度或 Service/VIP。
//

import Foundation

struct ClusterServicePreparation: Codable {
    let kind: String
    let context: String
    let output: String
    let image: String
    let command: [String]
    var title: String?
}

/// 服务就绪探针在目标容器内执行；只有连续成功达到阈值后，依赖服务才允许部署。
struct ClusterServiceReadiness: Codable, Hashable {
    var command: [String]
    var timeoutSeconds: Int = 3600
    var intervalSeconds: Int = 2
    var successThreshold: Int = 1
}

/// 模板级变量在部署解析时统一替换 `{{VAR:名称}}`。敏感标记供界面识别；
/// 变量值不会写入容器标签或运行日志。
struct ClusterTemplateVariable: Codable, Identifiable {
    var id: String { name }
    let name: String
    var value: String
    var sensitive: Bool = false
    var required: Bool = true
    var description: String?
}

/// 单个服务定义
struct ClusterService: Codable, Identifiable {
    var id = UUID()
    let name: String
    var image: String
    var ports: [String] = []
    var env: [String] = []
    var volumes: [String] = []
    var cpus: Int?
    var memory: String?
    var detach: Bool = true
    var interactive: Bool = false
    var tty: Bool = false
    var network: String?
    var workdir: String?
    var user: String?
    var entrypoint: String?
    /// 在镜像后执行的命令参数，例如 ["sh", "-c", "npm run dev"]。
    var command: [String] = []
    var initProcess: Bool = false
    var readOnly: Bool = false
    /// 业务角色仅作为应用集群元数据，不会改变 Apple Container 的运行时行为。
    var role: String?
    /// 需要由 Apple Container 在 default 网络的全局 DNS 域中注册此容器名。
    /// 该注册基于 `container run --name` 自动完成，而不是由面板伪造 DNS 记录。
    var dnsRegistration: Bool = true
    /// 是否将宿主机 SSH agent 转发到容器，对应 `container run --ssh`。
    var sshForward: Bool = false
    /// 服务依赖决定就绪门控顺序，而不仅是容器创建顺序。
    var dependsOn: [String] = []
    /// 可选显式就绪探针。未配置时至少要求容器连续保持 Running，防止 run -d 后立即退出。
    var readiness: ClusterServiceReadiness?
    /// 本机副本数。带宿主机发布端口的服务只能为 1，避免端口冲突。
    var replicas: Int = 1
    /// 可选的部署前产物准备阶段。界面与执行器均由此字段动态生成，不依赖服务名称或角色。
    var preDeploy: ClusterServicePreparation?

    enum CodingKeys: CodingKey { case name, image, ports, env, volumes, cpus, memory, detach, interactive, tty, network, workdir, user, entrypoint, command, initProcess, readOnly, role, dnsRegistration, sshForward, dependsOn, readiness, replicas, preDeploy }

    init(
        name: String, image: String, ports: [String] = [], env: [String] = [],
        volumes: [String] = [], cpus: Int? = nil, memory: String? = nil,
        detach: Bool = true, interactive: Bool = false, tty: Bool = false,
        network: String? = "default", workdir: String? = nil, user: String? = nil,
        entrypoint: String? = nil, command: [String] = [], initProcess: Bool = false,
        readOnly: Bool = false, role: String? = nil, dnsRegistration: Bool = true,
        sshForward: Bool = false, dependsOn: [String] = [], readiness: ClusterServiceReadiness? = nil, replicas: Int = 1,
        preDeploy: ClusterServicePreparation? = nil
    ) {
        self.name = name
        self.image = image
        self.ports = ports
        self.env = env
        self.volumes = volumes
        self.cpus = cpus
        self.memory = memory
        self.detach = detach
        self.interactive = interactive
        self.tty = tty
        self.network = network
        self.workdir = workdir
        self.user = user
        self.entrypoint = entrypoint
        self.command = command
        self.initProcess = initProcess
        self.readOnly = readOnly
        self.role = role
        self.dnsRegistration = dnsRegistration
        self.sshForward = sshForward
        self.dependsOn = dependsOn
        self.readiness = readiness
        self.replicas = replicas
        self.preDeploy = preDeploy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        image = try c.decode(String.self, forKey: .image)
        ports = try c.decodeIfPresent([String].self, forKey: .ports) ?? []
        env  = try c.decodeIfPresent([String].self, forKey: .env) ?? []
        volumes = try c.decodeIfPresent([String].self, forKey: .volumes) ?? []
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus)
        memory = try c.decodeIfPresent(String.self, forKey: .memory)
        detach = try c.decodeIfPresent(Bool.self, forKey: .detach) ?? true
        interactive = try c.decodeIfPresent(Bool.self, forKey: .interactive) ?? false
        tty = try c.decodeIfPresent(Bool.self, forKey: .tty) ?? false
        network = try c.decodeIfPresent(String.self, forKey: .network)
        workdir = try c.decodeIfPresent(String.self, forKey: .workdir)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        entrypoint = try c.decodeIfPresent(String.self, forKey: .entrypoint)
        command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
        initProcess = try c.decodeIfPresent(Bool.self, forKey: .initProcess) ?? false
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        role = try c.decodeIfPresent(String.self, forKey: .role)
        dnsRegistration = try c.decodeIfPresent(Bool.self, forKey: .dnsRegistration) ?? true
        sshForward = try c.decodeIfPresent(Bool.self, forKey: .sshForward) ?? false
        dependsOn = try c.decodeIfPresent([String].self, forKey: .dependsOn) ?? []
        readiness = try c.decodeIfPresent(ClusterServiceReadiness.self, forKey: .readiness)
        replicas = try c.decodeIfPresent(Int.self, forKey: .replicas) ?? 1
        preDeploy = try c.decodeIfPresent(ClusterServicePreparation.self, forKey: .preDeploy)
    }
}

/// 集群模板
struct ClusterTemplate: Identifiable, Codable {
    var id = UUID()
    /// 模板格式版本，便于未来演进。
    var apiVersion: String = "aiguru.container/v1"
    var kind: String = "ApplicationCluster"
    let name: String
    var description: String?
    var variables: [ClusterTemplateVariable]
    var services: [ClusterService]

    enum CodingKeys: CodingKey { case apiVersion, kind, name, description, variables, services }

    init(
        apiVersion: String = "aiguru.container/v1",
        kind: String = "ApplicationCluster",
        name: String,
        description: String? = nil,
        variables: [ClusterTemplateVariable] = [],
        services: [ClusterService] = []
    ) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.name = name
        self.description = description
        self.variables = variables
        self.services = services
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? "aiguru.container/v1"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "ApplicationCluster"
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        variables = try c.decodeIfPresent([ClusterTemplateVariable].self, forKey: .variables) ?? []
        services = try c.decodeIfPresent([ClusterService].self, forKey: .services) ?? []
    }

    var serviceCount: Int { services.count }
    var totalPorts: Int { services.reduce(0) { $0 + $1.ports.count } }
    var totalVolumes: Int { services.reduce(0) { $0 + $1.volumes.count } }
}

/// 模板管理服务
class ClusterTemplateManager {
    static let shared = ClusterTemplateManager()
    private init() {}

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    func parse(from data: Data) throws -> ClusterTemplate {
        try decoder.decode(ClusterTemplate.self, from: data)
    }

    func parse(from jsonString: String) throws -> ClusterTemplate {
        guard let data = jsonString.data(using: .utf8) else {
            throw ClusterTemplateError.invalidJSON
        }
        return try parse(from: data)
    }

    func export(_ template: ClusterTemplate) throws -> String {
        let data = try encoder.encode(template)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func validate(_ template: ClusterTemplate) -> Result<Void, ClusterTemplateError> {
        let ws = CharacterSet.whitespaces
        guard !template.name.trimmingCharacters(in: ws).isEmpty else { return .failure(.missingName) }
        guard !template.services.isEmpty else { return .failure(.noServices) }
        let variableNames = template.variables.map(\.name)
        guard Set(variableNames).count == variableNames.count else { return .failure(.duplicateVariableName) }
        for variable in template.variables {
            guard Self.validVariableName(variable.name) else { return .failure(.invalidVariableName(variable.name)) }
            if variable.required && variable.value.isEmpty { return .failure(.missingRequiredVariable(variable.name)) }
        }
        let definedVariables = Set(variableNames)
        let referencedVariables = Self.variableReferences(in: template.services.flatMap { $0.env + $0.command })
        if let missing = referencedVariables.first(where: { !definedVariables.contains($0) }) {
            return .failure(.undefinedVariable(missing))
        }
        let serviceNames = Set(template.services.map(\.name))
        guard serviceNames.count == template.services.count else { return .failure(.duplicateServiceName) }
        for svc in template.services {
            guard !svc.name.trimmingCharacters(in: ws).isEmpty else { return .failure(.missingServiceName) }
            guard !svc.image.trimmingCharacters(in: ws).isEmpty else { return .failure(.missingServiceImage(svc.name)) }
            // SERVICE_VOLUME 会解析成“集群--服务--逻辑卷”，每个服务实例独占，适合数据库等需 chown 的数据盘。
            // CLUSTER_VOLUME 可能造成多个 VM 同时附加同一块虚拟盘，当前运行时不支持。
            if let volume = svc.volumes.first(where: { $0.contains("{{CLUSTER_VOLUME:") }) {
                return .failure(.managedVolumeForbidden(service: svc.name, volume: volume))
            }
            if let role = svc.role, role.trimmingCharacters(in: ws).isEmpty {
                return .failure(.invalidServiceRole(svc.name))
            }
            guard svc.replicas > 0 else { return .failure(.invalidReplicaCount(svc.name)) }
            guard svc.replicas == 1 || svc.ports.isEmpty else { return .failure(.replicatedServiceHasPorts(svc.name)) }
            if let memory = svc.memory,
               let bytes = Self.memoryBytes(memory),
               bytes < Self.minimumRuntimeMemoryBytes {
                return .failure(.memoryBelowRuntimeMinimum(service: svc.name, configured: memory))
            }
            if let dependency = svc.dependsOn.first(where: { !serviceNames.contains($0) }) {
                return .failure(.unknownDependency(service: svc.name, dependency: dependency))
            }
            if let readiness = svc.readiness {
                guard !readiness.command.isEmpty,
                      (1...3600).contains(readiness.timeoutSeconds),
                      (1...60).contains(readiness.intervalSeconds),
                      (1...10).contains(readiness.successThreshold) else {
                    return .failure(.invalidReadiness(service: svc.name))
                }
            }
        }
        guard deploymentOrder(template) != nil else { return .failure(.dependencyCycle) }
        return .success(())
    }

    /// 稳定拓扑排序：同一层级保留模板声明顺序。
    func deploymentOrder(_ template: ClusterTemplate) -> [ClusterService]? {
        // 模板生成器会在用户编辑期间实时调用此方法，此时服务名可能暂时重复。
        // 不使用 Dictionary(uniqueKeysWithValues:)，避免重复键触发不可恢复的 Fatal Error。
        var unresolved: [String: ClusterService] = [:]
        for service in template.services {
            guard unresolved[service.name] == nil else { return nil }
            unresolved[service.name] = service
        }
        var resolved = Set<String>()
        var result: [ClusterService] = []
        while !unresolved.isEmpty {
            let ready = template.services.filter { service in
                unresolved[service.name] != nil && service.dependsOn.allSatisfy(resolved.contains)
            }
            guard !ready.isEmpty else { return nil }
            for service in ready {
                unresolved[service.name] = nil
                resolved.insert(service.name)
                result.append(service)
            }
        }
        return result
    }

    func deploymentContainerName(clusterName: String, serviceName: String, ordinal: Int) -> String {
        let normalizedCluster = normalizeName(clusterName)
        let normalizedService = normalizeName(serviceName)
        return "\(normalizedCluster)--\(normalizedService)--\(ordinal)"
    }

    /// 运行时自动注册的容器 FQDN。仅在 default 网络且配置 `[dns].domain` 后有效。
    func deploymentDNSName(clusterName: String, serviceName: String, ordinal: Int, domain: String) -> String {
        "\(deploymentContainerName(clusterName: clusterName, serviceName: serviceName, ordinal: ordinal)).\(domain)"
    }

    /// 解析模板环境变量中的 `{{CLUSTER_DNS:服务名}}`（默认第 1 个副本）或
    /// `{{CLUSTER_DNS:服务名:序号}}`。解析结果始终是 Apple Container 注册的实际 FQDN。
    func resolveEnvironment(
        _ environment: [String],
        clusterName: String,
        dnsDomain: String?,
        variables: [ClusterTemplateVariable] = []
    ) -> [String] {
        let values = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0.value) })
        return environment.map { source in
            var result = Self.replaceVariables(in: source, values: values)
            guard let dnsDomain, !dnsDomain.isEmpty else { return result }
            while let start = result.range(of: "{{CLUSTER_DNS:"),
                  let end = result[start.upperBound...].range(of: "}}") {
                let token = String(result[start.upperBound..<end.lowerBound])
                let parts = token.split(separator: ":", omittingEmptySubsequences: false)
                guard let servicePart = parts.first, !servicePart.isEmpty else { break }
                let ordinal = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let name = deploymentDNSName(
                    clusterName: clusterName,
                    serviceName: String(servicePart),
                    ordinal: ordinal,
                    domain: dnsDomain
                )
                result.replaceSubrange(start.lowerBound..<end.upperBound, with: name)
            }
            return result
        }
    }

    private static func validVariableName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func variableReferences(in values: [String]) -> Set<String> {
        var references = Set<String>()
        for value in values {
            var remainder = value[...]
            while let start = remainder.range(of: "{{VAR:") {
                let tail = remainder[start.upperBound...]
                guard let end = tail.range(of: "}}") else { break }
                let name = String(tail[..<end.lowerBound])
                if !name.isEmpty { references.insert(name) }
                remainder = tail[end.upperBound...]
            }
        }
        return references
    }

    private static func replaceVariables(in source: String, values: [String: String]) -> String {
        var result = source
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{{VAR:\(name)}}", with: value)
        }
        return result
    }

    /// 将模板中的项目根目录占位符转换为明确的宿主机绝对路径，避免桌面应用的
    /// 当前工作目录影响 bind mount。
    func resolveVolumes(
        _ volumes: [String],
        projectDirectory: String?,
        clusterName: String? = nil,
        serviceName: String? = nil,
        ordinal: Int? = nil
    ) -> [String] {
        volumes.map { volume in
            var resolved = volume
            if let projectDirectory, !projectDirectory.isEmpty {
                resolved = resolved.replacingOccurrences(of: "{{PROJECT_DIR}}", with: projectDirectory)
            }
            if let clusterName {
                resolved = replaceVolumeTokens(in: resolved, prefix: "{{CLUSTER_VOLUME:") { logicalName in
                    "\(normalizeName(clusterName))--\(normalizeName(logicalName))"
                }
                if let serviceName {
                    resolved = replaceVolumeTokens(in: resolved, prefix: "{{SERVICE_VOLUME:") { logicalName in
                        let instance = ordinal.map { "--\($0)" } ?? ""
                        return "\(normalizeName(clusterName))--\(normalizeName(serviceName))\(instance)--\(normalizeName(logicalName))"
                    }
                }
            }
            return resolved
        }
    }

    /// 应用集群统一使用项目目录 bind mount。旧模板中的实名卷占位符会转换为
    /// `.aiguru/data/<service>/<logical-name>`，状态型镜像以非 root 用户启动，避免
    /// MariaDB/Redis 入口脚本在 macOS 共享目录上执行 chown 而失败。
    func migratingLegacyStatefulBindMounts(_ template: ClusterTemplate) -> (template: ClusterTemplate, migrated: [String]) {
        var result = template
        var migrated: [String] = []
        for index in result.services.indices {
            let service = result.services[index]
            let role = service.role ?? ""
            result.services[index].volumes = service.volumes.map { specification in
                if specification.hasPrefix("{{SERVICE_VOLUME:"),
                   let separator = specification.range(of: "}}:") {
                    let logicalStart = specification.index(specification.startIndex, offsetBy: "{{SERVICE_VOLUME:".count)
                    let logicalName = String(specification[logicalStart..<separator.lowerBound])
                    let targetAndOptions = String(specification[separator.upperBound...])
                    migrated.append("\(service.name): {{SERVICE_VOLUME:\(logicalName)}} → 项目数据目录")
                    return "{{PROJECT_DIR}}/.aiguru/data/\(normalizeName(service.name))/\(normalizeName(logicalName)):\(targetAndOptions)"
                }
                let parts = specification.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let source = parts[0]
                    let isNamedVolume = !source.isEmpty && !source.hasPrefix("/") && !source.hasPrefix("./") && !source.hasPrefix("{{PROJECT_DIR}}")
                    if isNamedVolume {
                        var replacement = "{{PROJECT_DIR}}/.aiguru/data/\(normalizeName(service.name))/\(normalizeName(source)):\(parts[1])"
                        if parts.count > 2, !parts[2].isEmpty { replacement += ":\(parts[2])" }
                        migrated.append("\(service.name): \(source) → 项目数据目录")
                        return replacement
                    }
                }
                return specification
            }
            if role.hasPrefix("database-") && result.services[index].volumes.contains(where: { $0.contains(":/var/lib/mysql") }) {
                result.services[index].user = "mysql"
                if role == "database-primary" {
                    // MARIADB_USER/MARIADB_PASSWORD 只在空数据目录首次初始化时生效。
                    // 目录被保留或模板变量变化后，每次启动都幂等校准业务、复制和路由账号。
                    result.services[index].volumes = result.services[index].volumes.filter {
                        !$0.contains("01-ha-users.sql.template") && !$0.contains("01-ha-users-runtime-v2.sql")
                    }
                    result.services[index].entrypoint = "/bin/sh"
                    result.services[index].command = ["-c", "docker-entrypoint.sh mariadbd --server-id=1 --log-bin=mysql-bin --binlog-format=ROW --gtid-strict-mode=ON --log-slave-updates=ON & pid=$!; until mariadb-admin ping -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" --silent; do kill -0 $pid || exit 1; sleep 2; done; mariadb -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" --execute=\"CREATE DATABASE IF NOT EXISTS $MARIADB_DATABASE; CREATE USER IF NOT EXISTS '$MARIADB_USER'@'%' IDENTIFIED BY '$MARIADB_PASSWORD'; ALTER USER '$MARIADB_USER'@'%' IDENTIFIED BY '$MARIADB_PASSWORD'; GRANT ALL PRIVILEGES ON $MARIADB_DATABASE.* TO '$MARIADB_USER'@'%'; CREATE USER IF NOT EXISTS '$DB_REPLICATION_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; ALTER USER '$DB_REPLICATION_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; GRANT REPLICATION SLAVE ON *.* TO '$DB_REPLICATION_USER'@'%'; CREATE USER IF NOT EXISTS '$DB_ROUTER_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; ALTER USER '$DB_ROUTER_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON *.* TO '$DB_ROUTER_USER'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;\" || { kill $pid; wait $pid; exit 1; }; echo database-accounts-reconciled; wait $pid"]
                } else if role == "database-replica",
                          result.services[index].command.joined(separator: " ").contains("/docker-entrypoint-initdb.d/02-replica.sql") {
                    let serverID = result.services[index].name.hasSuffix("2") ? 3 : 2
                    result.services[index].entrypoint = "/bin/sh"
                    result.services[index].command = ["-c", "docker-entrypoint.sh mariadbd --server-id=\(serverID) --log-bin=mysql-bin --binlog-format=ROW --relay-log=relay-bin --read-only=ON --gtid-strict-mode=ON --log-slave-updates=ON & pid=$!; until mariadb-admin ping -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" --silent; do kill -0 $pid || exit 1; sleep 2; done; mariadb -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" -e \"CHANGE MASTER TO MASTER_HOST='${DB_PRIMARY_HOST}', MASTER_USER='${DB_REPLICATION_USER}', MASTER_PASSWORD='${DB_PASSWORD}', MASTER_USE_GTID=slave_pos; START SLAVE;\"; wait $pid"]
                }
            } else if role.hasPrefix("redis-") && result.services[index].volumes.contains(where: { $0.contains(":/data") }) {
                result.services[index].user = "redis"
            }
        }
        return (result, migrated)
    }

    private func replaceVolumeTokens(in value: String, prefix: String, name: (String) -> String) -> String {
        var result = value
        while let start = result.range(of: prefix), let end = result[start.upperBound...].range(of: "}}") {
            let logicalName = String(result[start.upperBound..<end.lowerBound])
            guard !logicalName.isEmpty else { break }
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: name(logicalName))
        }
        return result
    }

    func validateHostPaths(_ template: ClusterTemplate, projectDirectory: String?) -> Result<Void, ClusterTemplateError> {
        let usesProjectDirectory = template.services.contains { $0.volumes.contains { $0.contains("{{PROJECT_DIR}}") } }
        if usesProjectDirectory {
            guard let projectDirectory, !projectDirectory.isEmpty,
                  FileManager.default.fileExists(atPath: projectDirectory) else {
                return .failure(.projectDirectoryRequired)
            }
        }
        for service in template.services {
            for volume in resolveVolumes(service.volumes, projectDirectory: projectDirectory) {
                let source = String(volume.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                // 命名卷不需要预先存在；绝对路径/相对路径是宿主机 bind mount。
                if (source.hasPrefix("/") || source.hasPrefix("./")),
                   !FileManager.default.fileExists(atPath: source) {
                    return .failure(.missingHostPath(service: service.name, path: source))
                }
            }
        }
        return .success(())
    }

    /// Apple Container 的命名卷是虚拟磁盘，不可作为多容器共享存储使用。
    /// 多服务共享文件应使用宿主机 bind mount（例如 `{{PROJECT_DIR}}/shared/img`）。
    func validateNamedVolumeAttachments(
        _ template: ClusterTemplate,
        clusterName: String,
        projectDirectory: String?
    ) -> Result<Void, ClusterTemplateError> {
        var attachments: [String: Set<String>] = [:]
        for service in template.services {
            for volume in resolveVolumes(
                service.volumes,
                projectDirectory: projectDirectory,
                clusterName: clusterName,
                serviceName: service.name
            ) {
                let source = String(volume.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                guard !source.isEmpty, !source.hasPrefix("/") && !source.hasPrefix("./") else { continue }
                attachments[source, default: []].insert(service.name)
            }
        }
        if let shared = attachments.first(where: { $0.value.count > 1 }) {
            return .failure(.sharedNamedVolumeUnsupported(name: shared.key, services: shared.value.sorted()))
        }
        return .success(())
    }

    /// 对需要 DNS 的服务做部署前检查。Apple Container 目前仅保证 default 网络的
    /// 容器名注册；自定义网络应使用容器 IP 或在模板中关闭 dnsRegistration。
    func validateDNSRegistration(_ template: ClusterTemplate, configuredDomain: String?) -> Result<String?, ClusterTemplateError> {
        let dnsServices = template.services.filter(\.dnsRegistration)
        guard !dnsServices.isEmpty else { return .success(nil) }
        guard let domain = configuredDomain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
            return .failure(.dnsDomainMissing)
        }
        if let service = dnsServices.first(where: { service in
            let network = service.network?.trimmingCharacters(in: .whitespacesAndNewlines)
            return network != nil && network != "" && network != "default"
        }) {
            return .failure(.dnsRegistrationRequiresDefaultNetwork(service.name))
        }
        return .success(domain)
    }

    /// 按当前工作环境的版本指令库修正运行时内存下限。
    func runtimeSafeMemory(_ value: String?) -> String? {
        guard let value,
              let bytes = Self.memoryBytes(value),
              bytes < Self.minimumRuntimeMemoryBytes else { return value }
        return CLICommandCatalog.shared.recommendedValue(
            forConstraint: "container.run.minimumMemoryMiB",
            version: EnvironmentManager.shared.currentVersion
        ) ?? value
    }

    static var minimumRuntimeMemoryBytes: Int64 {
        let mib = CLICommandCatalog.shared.integerConstraint(
            "container.run.minimumMemoryMiB",
            version: EnvironmentManager.shared.currentVersion
        ) ?? 0
        return Int64(mib) * 1_024 * 1_024
    }

    static var minimumRuntimeMemoryDescription: String {
        let version = EnvironmentManager.shared.currentVersion
        let mib = CLICommandCatalog.shared.integerConstraint("container.run.minimumMemoryMiB", version: version) ?? 0
        return "当前指令档位 \(CLICommandCatalog.shared.profileLabel(for: version)) 的最低要求为 \(mib) MiB"
    }

    static func memoryBytes(_ value: String) -> Int64? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let units: [(suffix: String, multiplier: Int64)] = [
            ("GIB", 1_024 * 1_024 * 1_024), ("GB", 1_000 * 1_000 * 1_000), ("G", 1_024 * 1_024 * 1_024),
            ("MIB", 1_024 * 1_024), ("MB", 1_000 * 1_000), ("M", 1_024 * 1_024),
            ("KIB", 1_024), ("KB", 1_000), ("K", 1_024)
        ]
        for unit in units where normalized.hasSuffix(unit.suffix) {
            let amountText = normalized.dropLast(unit.suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let amount = Double(amountText), amount >= 0 else { return nil }
            return Int64(amount * Double(unit.multiplier))
        }
        return Int64(normalized)
    }

    private func normalizeName(_ value: String) -> String {
        let normalized = value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

enum ClusterTemplateError: LocalizedError {
    case invalidJSON, missingName, noServices, missingServiceName, missingServiceImage(String)
    case duplicateServiceName, invalidReplicaCount(String), replicatedServiceHasPorts(String), invalidServiceRole(String)
    case memoryBelowRuntimeMinimum(service: String, configured: String)
    case unknownDependency(service: String, dependency: String), dependencyCycle
    case invalidReadiness(service: String)
    case dnsDomainMissing, dnsRegistrationRequiresDefaultNetwork(String)
    case projectDirectoryRequired, missingHostPath(service: String, path: String)
    case sharedNamedVolumeUnsupported(name: String, services: [String])
    case managedVolumeForbidden(service: String, volume: String)
    case duplicateVariableName, invalidVariableName(String), missingRequiredVariable(String), undefinedVariable(String)
    var errorDescription: String? {
        switch self {
        case .invalidJSON: return "JSON 格式无效"
        case .missingName: return "模板名称不能为空"
        case .noServices: return "至少需要一个服务"
        case .missingServiceName: return "服务名称不能为空"
        case .missingServiceImage(let n): return "服务「\(n)」缺少镜像"
        case .duplicateServiceName: return "服务名称不能重复"
        case .invalidReplicaCount(let name): return "服务「\(name)」的副本数必须大于 0"
        case .replicatedServiceHasPorts(let name): return "服务「\(name)」发布了宿主机端口，副本数只能为 1"
        case .invalidServiceRole(let name): return "服务「\(name)」的角色不能为空字符串"
        case .memoryBelowRuntimeMinimum(let service, let configured):
            return "服务「\(service)」配置内存 \(configured)，低于\(ClusterTemplateManager.minimumRuntimeMemoryDescription)"
        case .unknownDependency(let service, let dependency): return "服务「\(service)」依赖不存在的服务「\(dependency)」"
        case .dependencyCycle: return "服务依赖存在循环，无法确定部署顺序"
        case .invalidReadiness(let service): return "服务「\(service)」的 readiness 配置无效：命令不能为空，超时 1...3600 秒，间隔 1...60 秒，连续成功 1...10 次"
        case .dnsDomainMissing: return "DNS 注册需要先在网络页设置全局 DNS 域，并重启 Container 系统"
        case .dnsRegistrationRequiresDefaultNetwork(let name): return "服务「\(name)」要求 DNS 注册，但使用了自定义网络；请改用 default 网络或关闭 dnsRegistration"
        case .projectDirectoryRequired: return "模板包含项目文件挂载；请先选择存在的项目根目录"
        case .missingHostPath(let service, let path): return "服务「\(service)」的宿主机挂载不存在：\(path)"
        case .sharedNamedVolumeUnsupported(let name, let services): return "命名卷「\(name)」不能同时附加给多个容器（\(services.joined(separator: ", "))）。请改用宿主机共享目录 bind mount。"
        case .managedVolumeForbidden(let service, let volume): return "服务「\(service)」仍使用运行时命名卷「\(volume)」，其 .img 会散落在用户支持目录。请改用 {{PROJECT_DIR}}/infra/<组件>/<服务>/... bind mount。"
        case .duplicateVariableName: return "模板变量名称不能重复"
        case .invalidVariableName(let name): return "模板变量名称无效：\(name)；仅允许 ASCII 字母、数字和下划线，且不能以数字开头"
        case .missingRequiredVariable(let name): return "必填模板变量「\(name)」没有值"
        case .undefinedVariable(let name): return "引用了未定义的模板变量「\(name)」"
        }
    }
}
