import SwiftUI

/// 根据 Apple Container 返回的真实网络、端口与服务标签绘制应用集群拓扑。
struct ClusterNetworkTopologyView: View {
    let cluster: ApplicationCluster
    @State private var runtimeConnections: Set<ServiceConnection> = []
    @State private var zoomMode: TopologyZoomMode = .normal
    @State private var viewportWidth: CGFloat = 920
    /// 默认只显示基础网络层，其它关系由用户按需逐层叠加。
    @State private var visibleLayers: Set<TopologyLayer> = [.network]
    private let fitViewportHeight: CGFloat = 420

    /// 右侧为多条服务关系预留独立弯曲轨道，避免依赖线挤在节点边缘。
    private let canvasWidth: CGFloat = 1160
    private let rowHeight: CGFloat = 82

    private var canvasHeight: CGFloat {
        max(300, CGFloat(cluster.serviceGroups.count) * rowHeight + 70)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("关系图层")
                    .font(.caption.weight(.semibold))
                ForEach(TopologyLayer.allCases) { layer in
                    layerToggle(layer)
                }
                Button("全选") { visibleLayers = Set(TopologyLayer.allCases) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                Button("清除") { visibleLayers.removeAll() }
                    .buttonStyle(.plain)
                    .font(.caption2)
            }
            HStack(spacing: 14) {
                Spacer()
                Text("\(cluster.networkNames.count) 网络 · \(cluster.serviceGroups.count) 服务 · \(cluster.desiredCount) 容器")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Picker("缩放", selection: $zoomMode) {
                    ForEach(TopologyZoomMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 230)
            }
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    topologyEdges
                    hostNode
                    networkNodes
                    highAvailabilityGroupOverlays
                    serviceNodes
                }
                .frame(width: canvasWidth, height: canvasHeight)
                .scaleEffect(effectiveScale, anchor: .topLeading)
                .frame(width: canvasWidth * effectiveScale, height: canvasHeight * effectiveScale, alignment: .topLeading)
                .padding(8)
            }
            .scrollIndicators(.visible)
            .frame(height: topologyViewportHeight)
            .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { viewportWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
                }
            }
        }
        .task(id: runtimeMonitorID) {
            while !Task.isCancelled {
                runtimeConnections = await readRuntimeConnections()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var topologyEdges: some View {
        Canvas { context, _ in
            for (serviceIndex, service) in cluster.serviceGroups.enumerated() {
                let destination = servicePosition(serviceIndex)
                if visibleLayers.contains(.network) {
                    for (networkIndex, network) in cluster.networkNames.enumerated()
                        where serviceUsesNetwork(service, network: network) {
                        drawCurve(
                            from: CGPoint(x: networkPosition(networkIndex).x + 75, y: networkPosition(networkIndex).y),
                            to: CGPoint(x: destination.x - 125, y: destination.y),
                            color: .teal.opacity(0.55),
                            in: &context
                        )
                    }
                }
                if visibleLayers.contains(.hostPorts),
                   service.containers.contains(where: { !($0.ports ?? []).isEmpty }) {
                    drawCurve(
                        from: CGPoint(x: hostPosition.x + 65, y: hostPosition.y),
                        to: CGPoint(x: destination.x - 125, y: destination.y + 12),
                        color: .orange.opacity(0.65),
                        in: &context
                    )
                }
            }
            drawServiceRelationships(in: &context)
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .allowsHitTesting(false)
    }

    private var hostNode: some View {
        topologyNode(icon: "desktopcomputer", title: "macOS 宿主机", subtitle: hostPortSummary, tint: .orange)
            .frame(width: 130, height: 58)
            .position(hostPosition)
    }

    private var networkNodes: some View {
        ForEach(Array(cluster.networkNames.enumerated()), id: \.element) { index, network in
            topologyNode(
                icon: "point.3.connected.trianglepath.dotted",
                title: network,
                subtitle: "\(networkContainerCount(network)) 个容器",
                tint: .teal
            )
            .frame(width: 150, height: 58)
            .position(networkPosition(index))
        }
    }

    private var serviceNodes: some View {
        ForEach(Array(cluster.serviceGroups.enumerated()), id: \.element.id) { index, service in
            HStack(spacing: 8) {
                Circle()
                    .fill(service.runningCount == service.containers.count ? Color.green : (service.runningCount == 0 ? .red : .orange))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(service.name).font(.caption.weight(.semibold)).lineLimit(1)
                        if let role = service.role {
                            Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(serviceSubtitle(service))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Text("\(service.runningCount)/\(service.containers.count)")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(width: 250, height: 64)
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
            .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
            .position(servicePosition(index))
            .help(service.containers.map { "\($0.displayName)  \($0.ipAddress ?? "无 IP")  \($0.formattedPorts)" }.joined(separator: "\n"))
        }
    }

    /// 服务组来自角色语义，而不是容器名称或当前是否恰好存在活跃连接。
    /// 内置、导入和修改后的模板只要保留角色，就能得到一致的分组结果。
    private var highAvailabilityGroupOverlays: some View {
        ForEach(topologyServiceGroups) { group in
            highAvailabilityGroupOverlay(
                title: group.title,
                range: group.range,
                tint: group.tint
            )
        }
    }

    private var topologyServiceGroups: [TopologyServiceGroup] {
        var indicesByFamily: [ServiceRoleFamily: [Int]] = [:]
        for index in cluster.serviceGroups.indices {
            guard let role = cluster.serviceGroups[index].role,
                  let family = serviceRoleFamily(for: role) else { continue }
            indicesByFamily[family, default: []].append(index)
        }
        return indicesByFamily.compactMap { family, indices in
            guard indices.count > 1, let first = indices.min(), let last = indices.max() else { return nil }
            let title: String
            if family == .database {
                let replicas = indices.count { cluster.serviceGroups[$0].role == "database-replica" }
                title = "MariaDB HA · 1 主 \(replicas) 从"
            } else {
                title = "\(family.title) · \(indices.count) 节点"
            }
            return TopologyServiceGroup(family: family, title: title, range: first...last)
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func serviceRoleFamily(for role: String) -> ServiceRoleFamily? {
        if role == "database-primary" || role == "database-replica" { return .database }
        if role == "database-router" || role == "database-logical-backup" { return nil }
        if role.hasPrefix("redis-") { return .redis }
        if role.hasPrefix("springboot-") { return .springBoot }
        if role.hasPrefix("nodejs-") { return .nodeJS }
        if role.hasPrefix("edge-") { return .edge }
        if role.hasPrefix("php-") { return .php }
        if role.hasPrefix("ssh-") { return .ssh }
        if role.hasPrefix("dns-") || role == "dns" { return .dns }
        // 未知模板也采用同一规则：相同角色族出现两个以上节点时自动成组。
        return .custom(role.split(separator: "-", maxSplits: 1).first.map(String.init) ?? role)
    }

    private func highAvailabilityGroupOverlay(
        title: String,
        range: ClosedRange<Int>,
        tint: Color
    ) -> some View {
        let top = servicePosition(range.lowerBound).y - 38
        let bottom = servicePosition(range.upperBound).y + 38
        return RoundedRectangle(cornerRadius: 13)
            .fill(tint.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(tint.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .background(.background)
                    .offset(x: 10, y: -7)
            }
            .frame(width: 274, height: bottom - top)
            .position(x: 690, y: (top + bottom) / 2)
            .allowsHitTesting(false)
    }

    private var hostPosition: CGPoint { CGPoint(x: 78, y: canvasHeight / 2) }

    private var effectiveScale: CGFloat {
        switch zoomMode {
        case .normal: return 1
        case .seventyFive: return 0.75
        case .fifty: return 0.5
        case .fit:
            let widthScale = max(0.01, (viewportWidth - 16) / canvasWidth)
            let heightScale = max(0.01, (fitViewportHeight - 16) / canvasHeight)
            return min(1, widthScale, heightScale)
        }
    }

    private var topologyViewportHeight: CGFloat {
        zoomMode == .fit ? fitViewportHeight : canvasHeight * effectiveScale + 16
    }

    private func networkPosition(_ index: Int) -> CGPoint {
        let count = max(cluster.networkNames.count, 1)
        let spacing = canvasHeight / CGFloat(count + 1)
        return CGPoint(x: 315, y: spacing * CGFloat(index + 1))
    }

    private func servicePosition(_ index: Int) -> CGPoint {
        CGPoint(x: 690, y: 52 + CGFloat(index) * rowHeight)
    }

    private func serviceUsesNetwork(_ service: ApplicationClusterService, network: String) -> Bool {
        service.containers.contains { container in
            container.configuration?.networks?.contains(where: { $0.network == network }) == true
        }
    }

    private func drawServiceRelationships(in context: inout GraphicsContext) {
        let services = cluster.serviceGroups
        // 外部导入或旧标签可能产生重复服务名；拓扑图保留首个节点，避免渲染阶段崩溃。
        var indices: [String: Int] = [:]
        for (index, service) in services.enumerated() where indices[service.name] == nil {
            indices[service.name] = index
        }
        var dependencyLane = 0
        for (sourceIndex, service) in services.enumerated() {
            for target in declaredDependencies(for: service).sorted() {
                guard let targetIndex = indices[target], targetIndex != sourceIndex else { continue }
                // 数据库路由的完整后端集合单独作为服务连接绘制，避免空闲从库
                // 因暂时没有 socket 连接而在拓扑中成为“孤儿”。
                if isDatabaseRouterBackend(source: service, targetName: target) { continue }
                let isHighAvailability = isHighAvailabilityRelationship(source: service, targetName: target)
                let relationshipColor: Color = isHighAvailability ? .blue.opacity(0.8) : .gray.opacity(0.55)
                // HA 使用内侧轨道；普通依赖循环使用八条外扩轨道。
                // 相邻依赖也会获得不同曲率，不再全部覆盖为同一条线。
                let lane: CGFloat
                if isHighAvailability {
                    lane = 0
                } else {
                    lane = CGFloat(1 + dependencyLane % 8)
                    dependencyLane += 1
                }
                let layer: TopologyLayer = isHighAvailability ? .highAvailability : .dependencies
                guard visibleLayers.contains(layer) else { continue }
                drawRelationship(from: servicePosition(sourceIndex), to: servicePosition(targetIndex),
                                 color: relationshipColor, dashed: true, lane: lane, in: &context)
            }
        }
        if visibleLayers.contains(.serviceConnections) {
            for connection in declaredDatabaseRouterConnections(indices: indices) {
                drawRelationship(from: servicePosition(connection.source), to: servicePosition(connection.target),
                                 color: .purple.opacity(0.5), dashed: false, lane: 9, in: &context)
            }
            for connection in runtimeConnections {
                guard let sourceIndex = indices[connection.sourceService],
                      let targetIndex = indices[connection.targetService], sourceIndex != targetIndex else { continue }
                drawRelationship(from: servicePosition(sourceIndex), to: servicePosition(targetIndex),
                                 color: .purple.opacity(0.9), dashed: false, lane: 9, in: &context)
            }
        }
    }

    private func declaredDependencies(for service: ApplicationClusterService) -> Set<String> {
        var result = Set<String>()
        for container in service.containers {
            for key in [AppConstants.ContainerLabel.applicationDependsOn, AppConstants.ContainerLabel.applicationUpstreams] {
                result.formUnion(container.labels?[key]?.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? [])
            }
            // 升级前的容器没有拓扑标签；从真实环境和启动参数恢复上游服务。
            let runtimeConfiguration = (container.configuration?.initProcess?.environment ?? [])
                + (container.configuration?.initProcess?.arguments ?? [])
            for candidate in cluster.serviceGroups where candidate.name != service.name {
                if runtimeConfiguration.contains(where: {
                    $0.localizedCaseInsensitiveContains(candidate.name)
                }) {
                    result.insert(candidate.name)
                }
            }
        }
        // 标准高可用角色的语义关系不依赖容器名称，确保旧部署也能恢复主从/哨兵拓扑。
        let servicesByRole = Dictionary(grouping: cluster.serviceGroups) { $0.role ?? "" }
        switch service.role {
        case "database-replica":
            result.formUnion(servicesByRole["database-primary", default: []].map(\.name))
        case "database-router":
            result.formUnion(servicesByRole["database-primary", default: []].map(\.name))
            result.formUnion(servicesByRole["database-replica", default: []].map(\.name))
        case "redis-replica":
            result.formUnion(servicesByRole["redis-master", default: []].map(\.name))
        case "redis-sentinel":
            result.formUnion(servicesByRole["redis-master", default: []].map(\.name))
            result.formUnion(servicesByRole["redis-replica", default: []].map(\.name))
        default:
            break
        }
        let knownServices = Set(cluster.serviceGroups.map(\.name))
        result = result.intersection(knownServices)
        result.remove(service.name)
        return result
    }

    private func isHighAvailabilityRelationship(source: ApplicationClusterService, targetName: String) -> Bool {
        guard let target = cluster.serviceGroups.first(where: { $0.name == targetName }) else { return false }
        switch (source.role, target.role) {
        case ("database-replica", "database-primary"),
             ("redis-replica", "redis-master"),
             ("redis-sentinel", "redis-master"),
             ("redis-sentinel", "redis-replica"):
            return true
        default:
            return false
        }
    }

    private func isDatabaseRouterBackend(source: ApplicationClusterService, targetName: String) -> Bool {
        guard source.role == "database-router",
              let target = cluster.serviceGroups.first(where: { $0.name == targetName }) else { return false }
        return target.role == "database-primary" || target.role == "database-replica"
    }

    private func declaredDatabaseRouterConnections(indices: [String: Int]) -> [(source: Int, target: Int)] {
        let backends = cluster.serviceGroups.enumerated().filter {
            $0.element.role == "database-primary" || $0.element.role == "database-replica"
        }
        return cluster.serviceGroups.enumerated().flatMap { sourceIndex, service in
            guard service.role == "database-router" else { return [(source: Int, target: Int)]() }
            return backends.compactMap { _, backend in
                guard let targetIndex = indices[backend.name], targetIndex != sourceIndex else { return nil }
                return (source: sourceIndex, target: targetIndex)
            }
        }
    }

    private func networkContainerCount(_ network: String) -> Int {
        cluster.containers.filter { container in
            container.configuration?.networks?.contains(where: { $0.network == network }) == true
        }.count
    }

    private var hostPortSummary: String {
        let count = cluster.containers.reduce(0) { $0 + ($1.ports?.count ?? 0) }
        return count == 0 ? "无发布端口" : "\(count) 个发布端口"
    }

    private func serviceSubtitle(_ service: ApplicationClusterService) -> String {
        let ips = service.containers.compactMap(\.ipAddress)
        let ports = service.containers.flatMap { $0.ports ?? [] }.compactMap(\.hostPortString)
        if !ports.isEmpty { return "host: \(ports.joined(separator: ", "))" }
        if !ips.isEmpty { return ips.prefix(2).joined(separator: ", ") }
        return "尚未获得网络地址"
    }

    private func topologyNode(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.35)))
    }

    private func layerToggle(_ layer: TopologyLayer) -> some View {
        Toggle(isOn: layerBinding(layer)) {
            HStack(spacing: 4) {
                if layer.dashed {
                    HStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Rectangle().fill(layer.color).frame(width: 4, height: 2)
                        }
                    }
                    .frame(width: 18)
                } else {
                    Capsule().fill(layer.color).frame(width: 18, height: 2)
                }
                Text(layer.title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private func layerBinding(_ layer: TopologyLayer) -> Binding<Bool> {
        Binding(
            get: { visibleLayers.contains(layer) },
            set: { isVisible in
                if isVisible {
                    visibleLayers.insert(layer)
                } else {
                    visibleLayers.remove(layer)
                }
            }
        )
    }

    private func drawCurve(from: CGPoint, to: CGPoint, color: Color, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: from)
        let midpoint = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: midpoint, y: from.y), control2: CGPoint(x: midpoint, y: to.y))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func drawRelationship(from: CGPoint, to: CGPoint, color: Color, dashed: Bool, lane: CGFloat,
                                  in context: inout GraphicsContext) {
        let start = CGPoint(x: from.x + 125, y: from.y)
        let end = CGPoint(x: to.x + 125, y: to.y)
        let outerX = 850 + lane * 28
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: outerX, y: start.y), control2: CGPoint(x: outerX, y: end.y))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: dashed ? 1.2 : 2.4, lineCap: .round,
                                          dash: dashed ? [5, 4] : []))
    }

    private var runtimeMonitorID: String {
        cluster.containers.map { "\($0.id):\($0.state.rawValue):\($0.ipAddress ?? "")" }.joined(separator: "|")
    }

    private func readRuntimeConnections() async -> Set<ServiceConnection> {
        let pairs = cluster.containers.compactMap { container -> (String, String)? in
            guard let ip = container.ipAddress?.split(separator: "/").first.map(String.init),
                  let service = container.labels?["cc.aiguru.application-service"] else { return nil }
            return (ip, service)
        }
        let ipToService = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        var result = Set<ServiceConnection>()
        for container in cluster.containers where container.state == .running {
            guard let source = container.labels?["cc.aiguru.application-service"] else { continue }
            let output = try? await ContainerManager.shared.executor.execute(
                CLICommandCatalog.shared.arguments(
                    command: "container.exec",
                    positionals: [container.id, "sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"]
                ), timeout: 5
            )
            for line in output?.split(separator: "\n") ?? [] {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count > 3, fields[3] == "01" else { continue }
                let remote = fields[2].split(separator: ":", maxSplits: 1)
                guard remote.count == 2, let ip = decodeProcIPv4(String(remote[0])),
                      let target = ipToService[ip], target != source,
                      let port = Int(remote[1], radix: 16) else { continue }
                result.insert(ServiceConnection(sourceService: source, targetService: target, port: port))
            }
        }
        return result
    }

    private func decodeProcIPv4(_ value: String) -> String? {
        guard value.count == 8, let raw = UInt32(value, radix: 16) else { return nil }
        return [raw & 0xff, (raw >> 8) & 0xff, (raw >> 16) & 0xff, (raw >> 24) & 0xff]
            .map(String.init).joined(separator: ".")
    }
}

private struct ServiceConnection: Hashable {
    let sourceService: String
    let targetService: String
    let port: Int
}

private struct TopologyServiceGroup: Identifiable {
    let family: ServiceRoleFamily
    let title: String
    let range: ClosedRange<Int>

    var id: ServiceRoleFamily { family }
    var tint: Color { family.tint }
}

private enum ServiceRoleFamily: Hashable {
    case database, redis, springBoot, nodeJS, edge, php, ssh, dns
    case custom(String)

    var title: String {
        switch self {
        case .database: return "MariaDB HA"
        case .redis: return "Redis HA"
        case .springBoot: return "Spring Boot"
        case .nodeJS: return "Node.js"
        case .edge: return "Nginx Edge"
        case .php: return "PHP-FPM"
        case .ssh: return "SSH Bastion"
        case .dns: return "DNS"
        case .custom(let name): return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var tint: Color {
        switch self {
        case .database: return .blue
        case .redis: return .red
        case .springBoot: return .green
        case .nodeJS: return .mint
        case .edge: return .orange
        case .php: return .indigo
        case .ssh: return .brown
        case .dns: return .cyan
        case .custom: return .purple
        }
    }
}

private enum TopologyLayer: String, CaseIterable, Identifiable {
    case network
    case hostPorts
    case dependencies
    case highAvailability
    case serviceConnections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: return "网络连接"
        case .hostPorts: return "宿主端口"
        case .dependencies: return "声明依赖"
        case .highAvailability: return "主从 / 哨兵"
        case .serviceConnections: return "服务连接"
        }
    }

    var color: Color {
        switch self {
        case .network: return .teal
        case .hostPorts: return .orange
        case .dependencies: return .gray
        case .highAvailability: return .blue
        case .serviceConnections: return .purple
        }
    }

    var dashed: Bool {
        self == .dependencies || self == .highAvailability
    }
}

private enum TopologyZoomMode: String, CaseIterable, Identifiable {
    case normal, seventyFive, fifty, fit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "正常"
        case .seventyFive: return "75%"
        case .fifty: return "50%"
        case .fit: return "全貌"
        }
    }
}
