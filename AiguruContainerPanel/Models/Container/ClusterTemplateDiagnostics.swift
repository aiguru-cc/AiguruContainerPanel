import Foundation

enum ClusterTemplateDiagnosticSeverity: Int, Comparable {
    case error = 0
    case warning = 1
    case suggestion = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ClusterTemplateDiagnostic: Identifiable {
    let id = UUID()
    let severity: ClusterTemplateDiagnosticSeverity
    let service: String?
    let title: String
    let guidance: String
}

extension ClusterTemplateManager {
    /// 面向模板生成器的全量静态审查。运行时端口占用仍由部署前预检负责；这里检查模板内部冲突。
    func diagnostics(for template: ClusterTemplate) -> [ClusterTemplateDiagnostic] {
        var result: [ClusterTemplateDiagnostic] = []
        let trimmedName = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            result.append(.init(severity: .error, service: nil, title: "模板名称为空", guidance: "填写用于导出和部署识别的模板名称。"))
        }
        if template.services.isEmpty {
            result.append(.init(severity: .error, service: nil, title: "尚未添加服务", guidance: "从常用服务或自定义服务中至少加入一项。"))
            return result
        }

        let variableNames = template.variables.map(\.name)
        for name in Set(variableNames) where variableNames.filter({ $0 == name }).count > 1 {
            result.append(.init(severity: .error, service: nil, title: "模板变量重复：\(name)", guidance: "每个变量只能定义一次。"))
        }
        let definedVariables = Set(variableNames)
        let referencedVariables = ClusterTemplateManager.variableReferences(in: template.services.flatMap { $0.env + $0.command })
        for name in referencedVariables where !definedVariables.contains(name) {
            result.append(.init(severity: .error, service: nil, title: "模板变量未定义：\(name)", guidance: "在顶层 variables 中定义该变量。"))
        }
        for variable in template.variables where variable.required && variable.value.isEmpty {
            result.append(.init(severity: .error, service: nil, title: "必填变量为空：\(variable.name)", guidance: "部署前填写变量值。"))
        }

        let groupedNames = Dictionary(grouping: template.services, by: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        for (name, services) in groupedNames where name.isEmpty || services.count > 1 {
            result.append(.init(
                severity: .error, service: name.isEmpty ? nil : name,
                title: name.isEmpty ? "存在空服务名" : "服务名重复：\(name)",
                guidance: "服务名必须唯一，建议使用小写字母、数字和连字符。"
            ))
        }
        let names = Set(groupedNames.keys.filter { !$0.isEmpty })
        let normalizedGroups = Dictionary(grouping: names, by: normalizeDiagnosticName)
        for (_, collisions) in normalizedGroups where collisions.count > 1 {
            result.append(.init(
                severity: .error, service: nil,
                title: "规范化后的容器名冲突：\(collisions.sorted().joined(separator: "、"))",
                guidance: "这些名称会被转换成同一个容器名，请修改服务名。"
            ))
        }

        var publishedPorts: [(host: String, port: Int, proto: String, owner: String)] = []
        var sharedWritableSources: [String: Set<String>] = [:]
        for service in template.services {
            let serviceName = service.name.isEmpty ? "未命名服务" : service.name
            if service.image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(severity: .error, service: serviceName, title: "缺少镜像", guidance: "填写 image:tag；生产用途避免使用 latest。"))
            } else if !service.image.contains(":"), !service.image.contains("@sha256:") {
                result.append(.init(severity: .suggestion, service: serviceName, title: "镜像未锁定版本", guidance: "建议显式指定版本标签或 digest，避免上游升级导致不可复现。"))
            }
            if service.replicas < 1 {
                result.append(.init(severity: .error, service: serviceName, title: "副本数无效", guidance: "副本数必须至少为 1。"))
            }
            if service.replicas > 1, !service.ports.isEmpty {
                result.append(.init(severity: .error, service: serviceName, title: "多副本共享宿主机端口", guidance: "移除宿主机端口并由网关访问，或将副本数改为 1。"))
            }
            if let memory = service.memory, let bytes = Self.memoryBytes(memory), bytes < Self.minimumRuntimeMemoryBytes {
                let recommended = CLICommandCatalog.shared.recommendedValue(
                    forConstraint: "container.run.minimumMemoryMiB",
                    version: EnvironmentManager.shared.currentVersion
                ) ?? "更高值"
                result.append(.init(severity: .error, service: serviceName, title: "内存低于运行时下限", guidance: "\(Self.minimumRuntimeMemoryDescription)；建议设置 \(recommended) 或更高。"))
            }

            for dependency in service.dependsOn {
                if dependency == service.name {
                    result.append(.init(severity: .error, service: serviceName, title: "服务依赖自身", guidance: "删除自身依赖。"))
                } else if !names.contains(dependency) {
                    result.append(.init(severity: .error, service: serviceName, title: "依赖不存在：\(dependency)", guidance: "先加入该服务，或从依赖列表中移除。"))
                }
            }

            let referencedServices = dnsReferences(in: service.env + service.command)
            for reference in referencedServices where !names.contains(reference) {
                result.append(.init(severity: .error, service: serviceName, title: "DNS 引用不存在：\(reference)", guidance: "加入对应服务或修正 {{CLUSTER_DNS:服务名}}。"))
            }
            for reference in referencedServices where names.contains(reference) && !service.dependsOn.contains(reference) && reference != service.name {
                result.append(.init(severity: .warning, service: serviceName, title: "引用了 \(reference) 但未声明依赖", guidance: "建议加入 dependsOn，使创建顺序与连接关系一致。"))
            }

            for specification in service.ports {
                guard let endpoint = publishedPortEndpoint(specification) else {
                    result.append(.init(severity: .error, service: serviceName, title: "端口格式无法识别：\(specification)", guidance: "使用 [宿主IP:]宿主端口:容器端口[/tcp|udp]。"))
                    continue
                }
                if let collision = publishedPorts.first(where: {
                    $0.port == endpoint.port && $0.proto == endpoint.proto
                        && ($0.host == "*" || endpoint.host == "*" || $0.host == endpoint.host)
                }) {
                    let key = "\(endpoint.host):\(endpoint.port)/\(endpoint.proto)"
                    result.append(.init(severity: .error, service: serviceName, title: "宿主机端口冲突：\(key)", guidance: "已由 \(collision.owner) 使用；修改其中一项宿主机端口。"))
                }
                publishedPorts.append((endpoint.host, endpoint.port, endpoint.proto, serviceName))
            }

            var targets: [String: String] = [:]
            for specification in service.volumes {
                if specification.contains("{{SERVICE_VOLUME:") || specification.contains("{{CLUSTER_VOLUME:") {
                    result.append(.init(severity: .error, service: serviceName, title: "禁止运行时命名卷", guidance: "命名卷的 .img 会进入用户支持目录；改用 {{PROJECT_DIR}}/infra/<组件>/<服务>/... bind mount。"))
                }
                guard let mount = parsedMount(specification) else {
                    result.append(.init(severity: .error, service: serviceName, title: "挂载格式无法识别：\(specification)", guidance: "使用 source:/container/path[:ro]。"))
                    continue
                }
                if let previous = targets[mount.target], previous != mount.source {
                    result.append(.init(severity: .error, service: serviceName, title: "容器挂载目标冲突：\(mount.target)", guidance: "同一服务不能将多个来源挂载到同一目标；保留一个来源或调整目标路径。"))
                } else {
                    targets[mount.target] = mount.source
                }
                if !mount.readOnly {
                    sharedWritableSources[mount.source, default: []].insert(serviceName)
                }
            }
            if service.network != nil, service.network != "default", service.dnsRegistration {
                result.append(.init(severity: .warning, service: serviceName, title: "自定义网络启用了 DNS 注册", guidance: "Apple Container 的自动容器名 DNS 面向 default 网络；请确认该环境支持解析，或关闭 DNS 注册。"))
            }
        }

        if deploymentOrder(template) == nil {
            result.append(.init(severity: .error, service: nil, title: "依赖关系存在循环", guidance: "删除环中的一个 dependsOn；数据库/缓存通常位于依赖链底部，网关位于顶部。"))
        }
        for (source, owners) in sharedWritableSources where owners.count > 1 && !source.hasPrefix("{{SERVICE_VOLUME:") {
            result.append(.init(severity: .warning, service: nil, title: "多个服务共享可写挂载：\(source)", guidance: "涉及 \(owners.sorted().joined(separator: "、"))。如只需读取请加 :ro；并发写入时确认文件锁和权限策略。"))
        }
        if result.isEmpty {
            result.append(.init(severity: .suggestion, service: nil, title: "未发现静态冲突", guidance: "部署时还会检查本机实时端口占用和宿主机路径是否存在。"))
        }
        return result.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            return (lhs.service ?? "") < (rhs.service ?? "")
        }
    }

    private func normalizeDiagnosticName(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func dnsReferences(in values: [String]) -> Set<String> {
        var references = Set<String>()
        for value in values {
            var remainder = value[...]
            while let start = remainder.range(of: "{{CLUSTER_DNS:") {
                let tail = remainder[start.upperBound...]
                guard let end = tail.range(of: "}}") else { break }
                let token = tail[..<end.lowerBound].split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                if !token.isEmpty { references.insert(token) }
                remainder = tail[end.upperBound...]
            }
        }
        return references
    }

    private func publishedPortEndpoint(_ specification: String) -> (host: String, port: Int, proto: String)? {
        let baseAndProtocol = specification.split(separator: "/", maxSplits: 1).map(String.init)
        let proto = (baseAndProtocol.count == 2 ? baseAndProtocol[1] : "tcp").lowercased()
        guard proto == "tcp" || proto == "udp" else { return nil }
        let components = baseAndProtocol[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2 || components.count == 3,
              let hostPort = Int(components[components.count - 2]), (1...65535).contains(hostPort),
              let containerPort = Int(components.last ?? ""), (1...65535).contains(containerPort) else { return nil }
        let host = components.count == 3 ? components[0] : "*"
        return (host, hostPort, proto)
    }

    private func parsedMount(_ specification: String) -> (source: String, target: String, readOnly: Bool)? {
        let parts = specification.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, parts[1].hasPrefix("/") else { return nil }
        return (parts[0], parts[1], parts.count == 3 && parts[2].split(separator: ",").contains("ro"))
    }
}
