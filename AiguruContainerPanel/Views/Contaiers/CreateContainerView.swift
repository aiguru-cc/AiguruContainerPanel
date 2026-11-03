//
//  CreateContainerView.swift
//  AiguruContainerPanel
//
//  创建容器表单 — 对齐 container run 官方文档全部参数。
//  资源（CPU/内存/共享内存）用滑杆，常用项提供快录 chips，初始值从系统 config.toml 读取。
//

import SwiftUI

struct CreateContainerView: View {
    var applicationCluster: ApplicationCluster? = nil
    let onCreate: (_ name: String, _ image: String, _ ports: [String], _ env: [String], _ volumes: [String], _ options: ContainerRunOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceImageManager: SourceImageManager
    @StateObject private var imgMgr = ImageSourceManager.shared
    @StateObject private var volMgr = VolumeManager.shared
    @ObservedObject private var environmentManager = EnvironmentManager.shared
    @StateObject private var dynamicCLIState = DynamicCLIFormState()

    // 镜像
    @State private var imageName = "nginx"
    @State private var imageTag = "latest"
    @State private var imageDigest = ""

    // 基本
    @State private var containerName = ""
    @State private var clusterServiceName = ""
    @State private var clusterRole = ""
    @State private var detach = true
    @State private var interactive = false
    @State private var tty = false
    @State private var rm = false

    // 端口 / 环境 / 挂载 / 标签
    @State private var ports: [(h: String, c: String)] = []
    @State private var env: [String] = []
    @State private var mounts: [(src: String, dst: String)] = []
    @State private var mountPickerIndex: Int? = nil
    @State private var labels: [(key: String, value: String)] = []

    // 资源（滑杆）
    @State private var cpuValue: Double = 1
    @State private var memValue: Double = 2      // GB
    @State private var shmEnabled = false
    @State private var shmValue: Double = 256    // MB
    @State private var useSystemDefaults = false

    // 网络
    @State private var network = ""
    @State private var customNetwork = ""
    @State private var macAddress = ""
    @State private var mtu = ""
    private let networkMgr = NetworkManager.shared
    private var effectiveNetwork: String {
        var base = network == "__custom__" ? customNetwork : network
        guard !base.isEmpty else { return "" }
        if !macAddress.isEmpty { base += ",mac=\(macAddress)" }
        if !mtu.isEmpty { base += ",mtu=\(mtu)" }
        return base
    }

    // DNS
    @State private var dns: [String] = []
    @State private var dnsDomain = ""
    @State private var dnsSearch: [String] = []
    @State private var dnsOptions: [String] = []
    @State private var noDNS = false

    // 高级：进程
    @State private var workdir = ""
    @State private var user = ""
    @State private var uid = ""
    @State private var gid = ""
    @State private var entrypoint = ""
    @State private var envFile = ""
    /// 镜像后的容器进程命令，例如 `sleep infinity` 或 `npm start`。
    @State private var containerCommand = ""

    // 高级：运行时
    @State private var initProcess = false
    @State private var readOnly = false
    @State private var rosetta = false
    @State private var ssh = false
    @State private var virtualization = false
    @State private var runtime = ""

    // 高级：权限与平台
    @State private var capAdd: [String] = []
    @State private var capDrop: [String] = []
    @State private var osSelection = "linux"
    @State private var archSelection = "arm64"
    @State private var platformSelection = ""   // --platform，格式 os/arch[/variant]，优先于 --os/--arch
    @State private var progressSelection = ""        // --progress
    @State private var schemeSelection = "auto"
    @State private var maxDownloads: String = ""

    private let platformChoices = ["", "linux/arm64", "linux/amd64", "darwin/arm64", "windows/amd64"]
    private let progressChoices = ["", "auto", "none", "ansi", "plain", "color"]

    // 高级：其他
    @State private var kernel = ""
    @State private var initImage = ""
    @State private var cidfile = ""
    @State private var tmpfs: [String] = []
    @State private var publishSockets: [String] = []
    @State private var ulimits: [String] = []

    @State private var showAdvanced = true
    @State private var showLocalPicker = false
    @State private var localImages: [SourceImage] = []
    @State private var validationMessage: String?
    @State private var showValidationAlert = false

    private let osChoices = ["linux", "darwin", "windows"]
    private let archChoices = ["arm64", "amd64"]
    private let schemeChoices = ["auto", "http", "https"]
    private let quickPorts: [(spec: String, label: String)] = [
        ("80:80", "Web"), ("443:443", "HTTPS"), ("3306:3306", "MySQL"),
        ("6379:6379", "Redis"), ("8080:80", "Nginx"), ("5432:5432", "PG"),
    ]

    // MARK: - 系统级数据（config.toml 快录）

    private var systemCpus: Int? { CreateContainerView.systemDefaults.cpus }
    private var systemMemoryGB: Double? { CreateContainerView.systemDefaults.memoryGB }
    private var systemDnsDomain: String? { CreateContainerView.systemConfigDnsDomain }

    private static var systemDefaults: (cpus: Int?, memoryGB: Double?) {
        guard let content = systemConfigContent else { return (nil, nil) }
        var inContainer = false
        var cpus: Int? = nil
        var mem: Double? = nil
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                inContainer = (t == "[container]")
                continue
            }
            guard inContainer else { continue }
            if t.hasPrefix("cpus") {
                cpus = Int(t.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
            } else if t.hasPrefix("memory") {
                let raw = t.components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "").lowercased() ?? ""
                if raw.hasSuffix("g") { mem = Double(raw.dropLast()) }
                else if raw.hasSuffix("gb") { mem = Double(raw.dropLast(2)) }
                else if raw.hasSuffix("mb") { mem = (Double(raw.dropLast(2)) ?? 0) / 1024 }
                else if raw.hasSuffix("m") { mem = (Double(raw.dropLast()) ?? 0) / 1024 }
            }
        }
        return (cpus, mem)
    }

    private static var systemConfigDnsDomain: String? {
        guard let content = systemConfigContent else { return nil }
        var inDns = false
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                inDns = (t == "[dns]")
                continue
            }
            if inDns && t.hasPrefix("domain") {
                let cleaned = t
                    .replacingOccurrences(of: "domain", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "“", with: "")
                    .replacingOccurrences(of: "”", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    private static var systemConfigContent: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".config/container/config.toml").path
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Helpers

    private var quickImages: [(name: String, tag: String)] {
        imgMgr.allEntries.map { ($0.name ?? "", $0.tag ?? "latest") }
    }

    private func fullImageRef() -> String {
        let ref = imageTag.isEmpty ? imageName : "\(imageName):\(imageTag)"
        if ref.contains("/") { return ref }
        guard let src = imgMgr.currentSource, let url = src.url else { return ref }
        let reg = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return reg.isEmpty ? ref : "\(reg)/\(ref)"
    }

    private var memoryArg: String? {
        let mib = Int((memValue * 1024).rounded())
        guard mib > 0 else { return nil }
        return mib.isMultiple(of: 1024) ? "\(mib / 1024)G" : "\(mib)M"
    }

    private var cpuMax: Double { max(1, Double(ProcessInfo.processInfo.activeProcessorCount)) }
    private var memMaxGB: Double {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return max(2, Double(bytes) / 1_073_741_824)
    }

    private func applySystemDefaults() {
        if let cpus = systemCpus { cpuValue = Double(cpus) }
        if let mem = systemMemoryGB { memValue = mem }
        useSystemDefaults = true
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compatibilityBanner
                    if let applicationCluster { clusterIdentityGroup(applicationCluster) }
                    basicGroup
                    resourceGroup
                    networkDnsGroup
                    HStack(alignment: .top, spacing: 16) {
                        portGroup.frame(maxWidth: .infinity)
                        envGroup.frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        mountGroup.frame(maxWidth: .infinity)
                        labelsGroup.frame(maxWidth: .infinity)
                    }
                    advancedGroup
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CLI 预览:").font(.caption).foregroundStyle(.secondary)
                    Text(buildCommandPreview())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("创建容器") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imageName.isEmpty)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 640)
        .toolbar { ToolbarItem(placement: .principal) { Text("创建容器").font(.headline) } }
        .sheet(item: $mountPickerIndex) { i in MountPicker { mounts[i].src = $0; mountPickerIndex = nil } }
        .sheet(isPresented: $showLocalPicker) { LocalImagePicker(images: localImages) { r, t in imageName = r; imageTag = t; showLocalPicker = false } }
        .alert("无法创建容器", isPresented: $showValidationAlert) {
            Button("确定", role: .cancel) { showValidationAlert = false }
        } message: {
            Text(validationMessage ?? "")
        }
        .task {
            imgMgr.loadSources(); imgMgr.loadAllEntries()
            await volMgr.fetchVolumes(); await networkMgr.fetchNetworks()
            applySystemDefaults()
        }
    }

    private var compatibilityBanner: some View {
        let version = environmentManager.currentVersion
        return HStack(spacing: 8) {
            Image(systemName: version.isKnown ? (environmentManager.currentInstructionProfile != nil ? "checkmark.shield" : "exclamationmark.triangle.fill") : "hourglass")
            VStack(alignment: .leading, spacing: 2) {
                Text("工作环境：\(environmentManager.currentEnvironment?.name ?? "未选择") · Container \(version.isKnown ? version.description : "版本探测中")")
                    .font(.caption.weight(.semibold))
                if let profile = environmentManager.currentInstructionProfile {
                    Text("已自动加载：\(profile.label)")
                        .font(.caption2)
                } else if version.isKnown {
                    Text("没有匹配的版本指令档位，动态参数已关闭")
                        .font(.caption2)
                }
            }
            Spacer()
        }
        .foregroundStyle(version.isKnown && environmentManager.currentInstructionProfile == nil ? .orange : .secondary)
        .padding(10)
        .background((version.isKnown && environmentManager.currentInstructionProfile == nil ? Color.orange : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 基本信息

    private func clusterIdentityGroup(_ cluster: ApplicationCluster) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("应用集群") {
                    Text(cluster.name).font(.subheadline.weight(.semibold))
                }
                HStack(spacing: 12) {
                    TextField("服务名，例如 mailer", text: $clusterServiceName)
                        .textFieldStyle(.roundedBorder)
                    TextField("角色（可选）", text: $clusterRole)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("生成的容器名") {
                    Text(effectiveClusterContainerName(in: cluster))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("容器名称留空时使用建议名称；也可以在下方手工覆盖。集群关联由标签维护，不依赖容器名称。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("镜像、资源、网络、DNS、端口、环境变量、挂载、标签及高级参数均与普通容器使用同一套动态 CLI 表单。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("集群身份", "square.stack.3d.up") }
    }

    private var basicGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("容器名称", "tag")
                        TextField(applicationCluster == nil ? "留空自动生成…" : "留空使用集群建议名称…", text: $containerName)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("镜像源", "building.columns")
                        Picker("", selection: $imgMgr.currentSource) {
                            Text("Docker Hub").tag(nil as ImageSource?)
                            ForEach(imgMgr.sources) { Text($0.name ?? "").tag($0 as ImageSource?) }
                        }
                        .onChange(of: imgMgr.currentSource) { _, _ in rebuildImageName() }
                    }
                }

                if !quickImages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("本地镜像快录").font(.caption2).foregroundStyle(.tertiary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(quickImages.prefix(30).indices, id: \.self) { i in
                                    Button("\(quickImages[i].name):\(quickImages[i].tag)") {
                                        imageName = quickImages[i].name; imageTag = quickImages[i].tag
                                        rebuildImageName()
                                    }
                                    .buttonStyle(.bordered).controlSize(.small).font(.caption)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("镜像名，如 nginx、ubuntu:22.04", text: $imageName).textFieldStyle(.roundedBorder)
                    TextField("标签", text: $imageTag).textFieldStyle(.roundedBorder).frame(width: 100)
                    Button("本地…") { localImages = sourceImageManager.images; showLocalPicker = !localImages.isEmpty }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(sourceImageManager.images.isEmpty)
                }
                Text(fullImageRef())
                    .font(.caption2.monospaced())
                    .foregroundStyle(imageName.isEmpty ? .red : .secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("基本信息", "shippingbox") }
    }

    // MARK: - 资源（滑杆）

    private var resourceGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let cpus = systemCpus, let mem = systemMemoryGB {
                    HStack(spacing: 8) {
                        Label("系统默认", systemImage: "gearshape").font(.caption).foregroundStyle(.secondary)
                        Text("\(cpus) 核 / \(Int(mem)) GB（config.toml）").font(.caption.monospaced())
                        Button(useSystemDefaults ? "已应用" : "应用") { applySystemDefaults() }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(useSystemDefaults)
                    }
                }

                sliderRow(
                    title: "CPU", icon: "cpu",
                    value: $cpuValue, range: 1...cpuMax, step: 1,
                    display: "\(Int(cpuValue)) 核",
                    chips: quickChips([("1", 1.0), ("2", 2.0), ("4", 4.0)], bind: $cpuValue)
                )

                sliderRow(
                    title: "内存", icon: "memorychip",
                    value: $memValue, range: 0.5...memMaxGB, step: 0.5,
                    display: "\(String(format: "%.1f", memValue)) GB",
                    chips: quickChips([("1 GB", 1.0), ("2 GB", 2.0), ("4 GB", 4.0)], bind: $memValue)
                )

                Divider()
                HStack(spacing: 10) {
                    Toggle("共享内存 /dev/shm", isOn: $shmEnabled).toggleStyle(.switch).controlSize(.small)
                    if shmEnabled {
                        Slider(value: $shmValue, in: 64...2048, step: 64)
                        Text("\(Int(shmValue)) MB").font(.caption.monospaced()).frame(width: 60, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: { groupTitle("资源限制", "gauge.with.dots.needle.50percent") }
    }

    private func sliderRow(title: String, icon: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String, chips: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(display).font(.caption.monospaced())
            }
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                chips
            }
        }
    }

    private func quickChips(_ items: [(String, Double)], bind: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { item in
                Button(item.0) { bind.wrappedValue = item.1 }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - 网络与 DNS（对应系统级）

    private var networkDnsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("网络", "point.3.connected.trianglepath.dotted")
                    HStack(spacing: 10) {
                        Picker("", selection: $network) {
                            Text("默认 (default)").tag("")
                            ForEach(networkMgr.networks) { net in Text(net.displayName).tag(net.id) }
                            Text("自定义…").tag("__custom__")
                        }
                        if network == "__custom__" {
                            TextField("自定义网络名称", text: $customNetwork).textFieldStyle(.roundedBorder)
                        }
                        if !effectiveNetwork.isEmpty {
                            TextField("MAC (可选)", text: $macAddress).textFieldStyle(.roundedBorder).frame(width: 150)
                            TextField("MTU", text: $mtu).textFieldStyle(.roundedBorder).frame(width: 80)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("DNS（容器解析）", "network.badge.shield.half.filled")
                    if let dom = systemDnsDomain {
                        HStack(spacing: 6) {
                            Label("全局容器名域", systemImage: "globe").font(.caption2).foregroundStyle(.tertiary)
                            Text(dom).font(.caption.monospaced().weight(.medium))
                            Text("默认网络请使用 <名称>.\(dom)").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("未设置全局容器名域；请在“网络”页配置 [dns].domain 并重启服务。", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    if noDNS {
                        Label("已禁用 DNS：容器名和外部域名均无法通过 DNS 解析。", systemImage: "xmark.shield")
                            .font(.caption).foregroundStyle(.red)
                    } else if !dns.filter({ !$0.isEmpty }).isEmpty {
                        Label("已指定 --dns：这会覆盖内置 DNS，<名称>.<域> 的容器名解析可能失效。", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else if !effectiveNetwork.isEmpty {
                        Label("自定义网络与 default 隔离；官方当前不支持其 Compose 式名称发现，请使用容器 IP。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    } else if systemDnsDomain != nil {
                        Label("容器间名称解析已就绪：使用完整域名，不要只写裸容器名。", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if !dnsDomain.isEmpty {
                        Label("--dns-domain 仅覆盖当前容器的默认搜索域；不会注册或发布容器名称。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    ForEach(dns.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            TextField("DNS 服务器 IP", text: $dns[i]).textFieldStyle(.roundedBorder)
                            Button { dns.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)) }.buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 8) {
                        Button { dns.append("") } label: { Label("外部 DNS", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.orange)
                        TextField("DNS 域覆盖（高级）", text: $dnsDomain).textFieldStyle(.roundedBorder)
                        TextField("搜索域 (逗号分隔)", text: Binding(
                            get: { dnsSearch.joined(separator: ", ") },
                            set: { dnsSearch = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        )).textFieldStyle(.roundedBorder)
                        TextField("DNS 选项", text: Binding(
                            get: { dnsOptions.joined(separator: ", ") },
                            set: { dnsOptions = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                        )).textFieldStyle(.roundedBorder).frame(width: 120)
                        Toggle("禁用", isOn: $noDNS).controlSize(.small)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: { groupTitle("网络与 DNS", "network") }
    }

    // MARK: - 端口

    private var portGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickPorts, id: \.0) { p in
                            Button("\(p.spec) \(p.label)") { addQuickPort(p.spec) }
                                .buttonStyle(.bordered).controlSize(.mini).font(.caption2)
                        }
                    }
                }
                ForEach(ports.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        TextField("宿主机", text: $ports[i].h).textFieldStyle(.roundedBorder)
                        Text(":").foregroundStyle(.tertiary)
                        TextField("容器", text: $ports[i].c).textFieldStyle(.roundedBorder)
                        Button { ports.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)).font(.caption) }.buttonStyle(.plain)
                    }
                }
                Button { ports.append(("", "")) } label: { Label("添加端口", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.green)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("端口映射", "arrow.left.arrow.right") }
    }

    private func addQuickPort(_ spec: String) {
        let parts = spec.split(separator: ":")
        guard parts.count == 2 else { return }
        if let first = ports.firstIndex(where: { $0.h.isEmpty && $0.c.isEmpty }) {
            ports[first] = (String(parts[0]), String(parts[1]))
        } else {
            ports.append((String(parts[0]), String(parts[1])))
        }
    }

    // MARK: - 环境变量

    private var envGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(env.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        TextField("KEY=value", text: $env[i]).textFieldStyle(.roundedBorder)
                        Button { env.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)).font(.caption) }.buttonStyle(.plain)
                    }
                }
                Button { env.append("") } label: { Label("添加环境变量", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.green)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("环境变量", "list.bullet") }
    }

    // MARK: - 挂载

    private var mountGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if !volMgr.volumes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(volMgr.volumes.prefix(8)) { v in
                                Button(v.name) { mounts.append((v.name, "")) }
                                    .buttonStyle(.bordered).controlSize(.mini).font(.caption2)
                                    .help("点击添加命名卷")
                            }
                        }
                    }
                }
                ForEach(mounts.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Image(systemName: mounts[i].src.contains("/") ? "folder" : "cylinder").foregroundStyle(.blue).frame(width: 14)
                        Text(mounts[i].src.isEmpty ? "未选择" : mounts[i].src).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text("→").foregroundStyle(.tertiary)
                        TextField("容器路径", text: $mounts[i].dst).textFieldStyle(.roundedBorder).frame(width: 110)
                        Button { mountPickerIndex = i } label: { Image(systemName: "ellipsis.circle").font(.caption) }.buttonStyle(.borderless)
                        Button { mounts.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)).font(.caption) }.buttonStyle(.plain)
                    }
                }
                Button { mounts.append(("", "")) } label: { Label("添加挂载", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.green)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("挂载卷", "externaldrive") }
    }

    // MARK: - 标签

    private var labelsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(labels.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        TextField("键", text: $labels[i].key).textFieldStyle(.roundedBorder).frame(width: 90)
                        Text("=").foregroundStyle(.tertiary)
                        TextField("值", text: $labels[i].value).textFieldStyle(.roundedBorder)
                        Button { labels.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)).font(.caption) }.buttonStyle(.plain)
                    }
                }
                Button { labels.append(("", "")) } label: { Label("添加标签", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.green)
            }
            .padding(.vertical, 4)
        } label: { groupTitle("标签", "tag") }
    }

    // MARK: - 高级参数

    private var advancedGroup: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // 运行时
                GroupBox {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                        Toggle("后台运行 (-d)", isOn: $detach)
                        Toggle("自动删除 (--rm)", isOn: $rm)
                        Toggle("交互 (-i)", isOn: $interactive)
                        Toggle("TTY (-t)", isOn: $tty)
                        Toggle("init 进程", isOn: $initProcess)
                        Toggle("只读根文件系统", isOn: $readOnly)
                        Toggle("Rosetta", isOn: $rosetta)
                        Toggle("SSH 转发", isOn: $ssh)
                        Toggle("虚拟化", isOn: $virtualization)
                    }
                    .toggleStyle(.switch).controlSize(.small)
                    .padding(.vertical, 4)
                } label: { groupTitle("运行时", "play.circle") }

                // 进程
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("工作目录 (--workdir)", text: $workdir).textFieldStyle(.roundedBorder)
                            TextField("用户 (--user)", text: $user).textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            TextField("UID (--uid)", text: $uid).textFieldStyle(.roundedBorder)
                            TextField("GID (--gid)", text: $gid).textFieldStyle(.roundedBorder)
                            TextField("入口命令 (--entrypoint)", text: $entrypoint).textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            TextField("env 文件 (--env-file)", text: $envFile).textFieldStyle(.roundedBorder)
                            Button("浏览…") {
                                let p = NSOpenPanel(); p.canChooseFiles = true
                                p.begin { if $0 == .OK, let u = p.url { envFile = u.path } }
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("容器命令（IMAGE 后，例如 sleep infinity）", text: $containerCommand)
                                .textFieldStyle(.roundedBorder)
                            Text("这是容器内执行的进程命令；不要填写到 kernel-arg。支持引号，例如 sh -c \"npm install && npm start\"。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("⚠️ 用户必须存在于镜像中，否则容器无法启动").font(.caption2).foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                } label: { groupTitle("进程", "terminal") }

                // 权限
                GroupBox {
                    HStack(alignment: .top, spacing: 16) {
                        stringListGroup(title: "增加能力 (--cap-add)", icon: "plus.shield", items: $capAdd, placeholder: "如 NET_RAW")
                        stringListGroup(title: "丢弃能力 (--cap-drop)", icon: "minus.shield", items: $capDrop, placeholder: "如 ALL")
                    }
                    .padding(.vertical, 4)
                } label: { groupTitle("权限 (Capabilities)", "lock.shield") }

                // 平台与拉取
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Picker("平台", selection: $platformSelection) {
                                ForEach(platformChoices, id: \.self) { Text($0.isEmpty ? "默认 (os/arch)" : $0).tag($0) }
                            }.frame(width: 150)
                            Picker("OS", selection: $osSelection) { ForEach(osChoices, id: \.self) { Text($0).tag($0) } }.frame(width: 100)
                            Picker("架构", selection: $archSelection) { ForEach(archChoices, id: \.self) { Text($0).tag($0) } }.frame(width: 100)
                            Text("平台优先于 OS/架构").font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Picker("进度 (--progress)", selection: $progressSelection) {
                                ForEach(progressChoices, id: \.self) { Text($0.isEmpty ? "auto" : $0).tag($0) }
                            }.frame(width: 120)
                            Picker("Scheme", selection: $schemeSelection) { ForEach(schemeChoices, id: \.self) { Text($0).tag($0) } }.frame(width: 110)
                            TextField("并发下载数", text: $maxDownloads).textFieldStyle(.roundedBorder).frame(width: 90)
                        }
                        HStack(spacing: 12) {
                            TextField("运行时 (--runtime)", text: $runtime).textFieldStyle(.roundedBorder).frame(width: 220)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
                } label: { groupTitle("平台与拉取", "cpu") }

                DynamicCLIOptionsForm(
                    command: "container.run",
                    version: environmentManager.currentVersion,
                    state: dynamicCLIState
                )

                // 其他
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("内核 (--kernel)", text: $kernel).textFieldStyle(.roundedBorder)
                            TextField("init 镜像 (--init-image)", text: $initImage).textFieldStyle(.roundedBorder)
                            TextField("CID 文件 (--cidfile)", text: $cidfile).textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 8) {
                            stringListInline(title: "tmpfs", items: $tmpfs, placeholder: "如 /tmp:size=64M")
                            stringListInline(title: "publish-socket", items: $publishSockets, placeholder: "host:container")
                            stringListInline(title: "ulimit", items: $ulimits, placeholder: "如 nofile=1024:2048")
                        }
                    }
                    .padding(.vertical, 4)
                } label: { groupTitle("其他", "ellipsis.circle") }
            }
            .padding(.top, 4)
        } label: {
            Label("高级参数", systemImage: "gearshape.2").font(.subheadline.weight(.medium))
        }
    }

    private func stringListGroup(title: String, icon: String, items: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            ForEach(items.wrappedValue.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    TextField(placeholder, text: Binding(
                        get: { items.wrappedValue[i] },
                        set: { items.wrappedValue[i] = $0 }
                    )).textFieldStyle(.roundedBorder)
                    Button { items.wrappedValue.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.red.opacity(0.6)).font(.caption) }.buttonStyle(.plain)
                }
            }
            Button { items.wrappedValue.append("") } label: { Label("添加", systemImage: "plus.circle").font(.caption) }.buttonStyle(.borderless).foregroundStyle(.green)
        }
    }

    private func stringListInline(title: String, items: Binding<[String]>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.tertiary)
            TextField("逗号分隔", text: Binding(
                get: { items.wrappedValue.joined(separator: ", ") },
                set: { items.wrappedValue = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            )).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - 样式辅助

    private func groupTitle(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
    }

    private func sectionLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).font(.subheadline.weight(.medium))
    }

    // MARK: - Actions

    private func rebuildImageName() {
        let base = imageName.contains("/") ? String(imageName.split(separator: "/").last ?? Substring(imageName)) : imageName
        guard let src = imgMgr.currentSource, let url = src.url else { return }
        let reg = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !reg.isEmpty else { return }
        imageName = "\(reg)/\(base)"
    }

    private func buildCommandPreview() -> String {
        ContainerCommandBuilder.displayCommand(for: ContainerCommandBuilder.runArguments(
            image: fullImageRef(), name: containerName,
            ports: ports.filter { !$0.h.isEmpty && !$0.c.isEmpty }.map { "\($0.h):\($0.c)" },
            environment: env.filter { !$0.isEmpty },
            volumes: mounts.filter { !$0.dst.isEmpty }.map { $0.src.isEmpty ? $0.dst : "\($0.src):\($0.dst)" },
            options: makeRunOptions()
        ))
    }

    private func makeRunOptions() -> ContainerRunOptions {
        ContainerRunOptions(
            detach: detach, rm: rm, interactive: interactive, tty: tty,
            cpus: cpuValue > 0 ? String(format: "%g", cpuValue) : nil, memory: memoryArg,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint, workdir: workdir.isEmpty ? nil : workdir,
            user: user.isEmpty ? nil : user, uid: uid.isEmpty ? nil : uid, gid: gid.isEmpty ? nil : gid,
            initProcess: initProcess, readOnly: readOnly, shmSize: shmEnabled ? "\(Int(shmValue))M" : nil,
            ulimits: ulimits.filter { !$0.isEmpty }, envFile: envFile.isEmpty ? nil : envFile,
            runtime: runtime.isEmpty ? nil : runtime, network: effectiveNetwork.isEmpty ? nil : effectiveNetwork,
            dns: dns.filter { !$0.isEmpty }, dnsSearch: dnsSearch.filter { !$0.isEmpty },
            dnsDomain: dnsDomain.isEmpty ? nil : dnsDomain, dnsOptions: dnsOptions.filter { !$0.isEmpty },
            noDNS: noDNS, publishSockets: publishSockets.filter { !$0.isEmpty }, advancedMounts: [],
            tmpfsMounts: tmpfs.filter { !$0.isEmpty }, os: osSelection == "linux" ? nil : osSelection,
            arch: archSelection == "arm64" ? nil : archSelection,
            platform: platformSelection.isEmpty ? nil : platformSelection,
            capAdd: capAdd.filter { !$0.isEmpty }, capDrop: capDrop.filter { !$0.isEmpty },
            labels: { var result = [String: String](); for item in labels where !item.key.isEmpty { result[item.key] = item.value }; return result }(),
            kernel: kernel.isEmpty ? nil : kernel,
            initImage: initImage.isEmpty ? nil : initImage, rosetta: rosetta,
            progress: progressSelection.isEmpty ? nil : progressSelection,
            cidfile: cidfile.isEmpty ? nil : cidfile, sshForward: ssh, virtualization: virtualization,
            scheme: schemeSelection == "auto" ? nil : schemeSelection,
            maxConcurrentDownloads: Int(maxDownloads),
            command: parseContainerCommand(containerCommand) ?? [],
            catalogValues: dynamicCLIState.values
        )
    }

    /// 检查发布端口是否已被宿主机占用（lsof 检测 LISTEN）
    private func checkPortConflicts() async -> String? {
        let hostPorts = ports
            .filter { !$0.h.isEmpty && !$0.c.isEmpty }
            .map { $0.h }
        guard !hostPorts.isEmpty else { return nil }
        for port in hostPorts {
            let output = try? await CommandExecutor.shared.executeSystemCommand(
                arguments: ["/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
            )
            if let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let firstLine = output.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
                let proc = firstLine.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "未知进程"
                return "宿主机端口 \(port) 已被「\(proc)」占用，请更换端口后再创建"
            }
        }
        return nil
    }

    private func submit() {
        validationMessage = nil
        if !containerCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           parseContainerCommand(containerCommand) == nil {
            validationMessage = "容器命令中的引号或转义符不完整，请检查后重试"
            showValidationAlert = true
            return
        }
        if (dynamicCLIState.values["kernelArg"] ?? []).contains(where: { $0.contains("sleep ") || $0.contains("npm ") || $0.contains("node ") }) {
            validationMessage = "检测到 kernel-arg 中可能填写了容器进程命令。请清除该值，并填写到“进程 → 容器命令”。"
            showValidationAlert = true
            return
        }
        if applicationCluster != nil,
           clusterServiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationMessage = "追加到应用集群时必须填写服务名"
            showValidationAlert = true
            return
        }
        let p = ports.filter { !$0.h.isEmpty && !$0.c.isEmpty }.map { "\($0.h):\($0.c)" }
        let e = env.filter { !$0.isEmpty }
        let v = mounts.filter { !$0.dst.isEmpty }.map { $0.src.isEmpty ? $0.dst : "\($0.src):\($0.dst)" }
        var opts = makeRunOptions()
        var submittedName = containerName
        if let cluster = applicationCluster {
            let service = clusterServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let ordinal = nextClusterOrdinal(in: cluster, serviceName: service)
            submittedName = effectiveClusterContainerName(in: cluster)
            opts.labels["cc.aiguru.application-cluster"] = cluster.name
            opts.labels["cc.aiguru.application-service"] = service
            opts.labels["cc.aiguru.application-ordinal"] = String(ordinal)
            opts.labels["cc.aiguru.template-api-version"] = "aiguru.container/v1"
            let role = clusterRole.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty { opts.labels["cc.aiguru.application-role"] = role }
        }
        // 创建前检测发布端口冲突（如被其他容器/进程占用则提示，不提交）
        Task {
            if let conflict = await checkPortConflicts() {
                validationMessage = conflict
                showValidationAlert = true
                return
            }
            onCreate(submittedName, fullImageRef(), p, e, v, opts)
            dismiss()
        }
    }

    /// 将用户熟悉的命令行文本转换为 argv，不经过 shell 二次解析。
    /// `sh -c "npm install && npm start"` 会得到三个参数，并保留第三个参数中的空格。
    private func parseContainerCommand(_ source: String) -> [String]? {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasToken = false
        for character in source {
            if escaped {
                current.append(character)
                escaped = false
                hasToken = true
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                hasToken = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                else { current.append(character) }
                hasToken = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken {
                    arguments.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(character)
                hasToken = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if hasToken { arguments.append(current) }
        return arguments
    }

    private func nextClusterOrdinal(in cluster: ApplicationCluster, serviceName: String) -> Int {
        let ordinals = cluster.containers.compactMap { container -> Int? in
            guard container.labels?["cc.aiguru.application-service"] == serviceName else { return nil }
            return Int(container.labels?["cc.aiguru.application-ordinal"] ?? "")
        }
        return (ordinals.max() ?? 0) + 1
    }

    private func clusterContainerName(in cluster: ApplicationCluster) -> String {
        let service = clusterServiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClusterTemplateManager.shared.deploymentContainerName(
            clusterName: cluster.name,
            serviceName: service.isEmpty ? "service" : service,
            ordinal: nextClusterOrdinal(in: cluster, serviceName: service)
        )
    }

    private func effectiveClusterContainerName(in cluster: ApplicationCluster) -> String {
        let customName = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return customName.isEmpty ? clusterContainerName(in: cluster) : customName
    }
}

// MARK: - Mount Picker
extension Int: @retroactive Identifiable { public var id: Int { self } }

struct MountPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .volume
    @State private var volumes: [VolumeInfo] = []
    @State private var selVol = ""
    @State private var dirPath = ""

    enum Mode: String, CaseIterable { case volume = "命名卷", directory = "宿主机目录" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择挂载来源").font(.title2.weight(.semibold))
            Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if mode == .volume {
                if volumes.isEmpty {
                    Label("无可用卷", systemImage: "externaldrive").foregroundStyle(.secondary)
                } else {
                    List(volumes) { v in
                        HStack {
                            VStack(alignment: .leading) { Text(v.name).font(.headline); Text(v.source).font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary) }
                            Spacer(); if selVol == v.name { Image(systemName: "checkmark").foregroundStyle(.blue) }
                        }.contentShape(Rectangle()).onTapGesture { selVol = v.name }
                    }.frame(height: 180)
                }
            } else {
                HStack {
                    TextField("宿主机路径", text: $dirPath).textFieldStyle(.roundedBorder)
                    Button("浏览…") { let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.begin { if $0 == .OK, let u = p.url { dirPath = u.path } } }
                }
            }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("确定") {
                    let v = mode == .volume ? selVol : dirPath
                    if !v.isEmpty { onPick(v); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(mode == .volume ? selVol.isEmpty : dirPath.isEmpty)
            }
        }.padding(24).frame(width: 460, height: 380)
         .task { volumes = VolumeManager.shared.volumes; if volumes.isEmpty { await VolumeManager.shared.fetchVolumes() } }
    }
}

// MARK: - Local Image Picker
struct LocalImagePicker: View {
    let images: [SourceImage]
    let onPick: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(images) { img in
                HStack {
                    VStack(alignment: .leading) { Text(img.displayName).font(.headline); Text(img.digest?.prefix(12) ?? "").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Text(img.sizeString).font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).onTapGesture { onPick(img.repository, img.tag); dismiss() }
            }.navigationTitle("本地镜像").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.frame(minWidth: 480, minHeight: 300)
    }
}
