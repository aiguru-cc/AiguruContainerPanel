//
//  ApplicationCluster.swift
//  AiguruContainerPanel
//
//  由应用集群标签从 Apple Container 的真实容器列表投影出的管理模型。
//

import Foundation

struct ApplicationCluster: Identifiable {
    let name: String
    let containers: [Container]

    var id: String { name }
    var runningCount: Int { containers.filter { $0.state == .running }.count }
    var desiredCount: Int { containers.count }
    var networkNames: [String] {
        Array(Set(containers.flatMap { container in
            container.configuration?.networks?.map(\.network) ?? []
        })).sorted()
    }
    var mounts: [ApplicationClusterMount] {
        var values: [String: ApplicationClusterMount] = [:]
        for container in containers {
            let service = container.labels?["cc.aiguru.application-service"] ?? container.displayName
            for mount in container.mounts ?? [] {
                let key = "\(mount.source)\u{0}\(mount.destination)"
                var value = values[key] ?? ApplicationClusterMount(
                    source: mount.source,
                    destination: mount.destination,
                    services: []
                )
                value.services.insert(service)
                values[key] = value
            }
        }
        return values.values.sorted {
            $0.source.localizedStandardCompare($1.source) == .orderedAscending
        }
    }
    var serviceGroups: [ApplicationClusterService] {
        Dictionary(grouping: containers) { container in
            container.labels?["cc.aiguru.application-service"] ?? "未分类服务"
        }
        .map { ApplicationClusterService(name: $0.key, containers: $0.value) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func discover(in containers: [Container]) -> [ApplicationCluster] {
        Dictionary(grouping: containers) { container in
            container.labels?["cc.aiguru.application-cluster"]
        }
        .compactMap { name, members in
            guard let name, !name.isEmpty else { return nil }
            return ApplicationCluster(name: name, containers: members.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ApplicationClusterMount: Identifiable {
    let source: String
    let destination: String
    var services: Set<String>
    var id: String { "\(source)\u{0}\(destination)" }
}

struct ApplicationClusterService: Identifiable {
    let name: String
    let containers: [Container]

    var id: String { name }
    var role: String? { containers.compactMap { $0.labels?["cc.aiguru.application-role"] }.first }
    var runningCount: Int { containers.filter { $0.state == .running }.count }
}
