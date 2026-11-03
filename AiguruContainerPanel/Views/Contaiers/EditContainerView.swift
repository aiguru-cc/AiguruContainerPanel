//
//  EditContainerView.swift
//  AiguruContainerPanel
//
//  编辑容器配置（通过重建实现）；按当前环境版本查询 CLICommandCatalog 能力。
//

import SwiftUI

struct EditContainerView: View {
    let container: Container
    let config: ContainerConfig
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ContainerManager.shared

    // 可编辑字段
    @State private var envVars: [String]
    @State private var portMappings: [PortMappingInput]
    @State private var volumeMappings: [VolumeMappingInput]
    @State private var cpus: String
    @State private var memory: String
    @State private var entrypoint: String
    @State private var workdir: String
    @State private var user: String
    @State private var initProcess: Bool
    @State private var readOnly: Bool
    @State private var interactive: Bool
    @State private var tty: Bool
    @State private var network: String
    @State private var customNetwork = ""
    private let networkMgr = NetworkManager.shared
    private var effectiveNetwork: String {
        network == "__custom__" ? customNetwork : network
    }
    @State private var dnsServers: [String]
    @State private var dnsSearchDomains: [String]
    @State private var dnsDomain: String
    @State private var dnsOptions: [String]
    @State private var capAdd: [String]
    @State private var capDrop: [String]
    @State private var labels: [LabelInput]
    @State private var kernel: String
    @State private var initImage: String
    @State private var rm: Bool
    @State private var image: String  // 只读显示

    @State private var isSaving = false
    @State private var errorMessage: String?

    struct PortMappingInput: Identifiable {
        let id = UUID()
        var host: String
        var container: String
    }

    struct VolumeMappingInput: Identifiable {
        let id = UUID()
        var source: String
        var destination: String
    }

    struct LabelInput: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(container: Container, config: ContainerConfig) {
        self.container = container
        self.config = config

        // 初始化状态
        _image = State(initialValue: config.image)
        _envVars = State(initialValue: config.env)
        _portMappings = State(initialValue: config.ports.map { p in
            let parts = p.split(separator: ":")
            return PortMappingInput(host: parts.count > 0 ? String(parts[0]) : "", container: parts.count > 1 ? String(parts[1]) : "")
        })
        _volumeMappings = State(initialValue: config.volumes.map { VolumeMappingInput(source: $0.source, destination: $0.destination) })
        _cpus = State(initialValue: config.options.cpus ?? "")
        _memory = State(initialValue: config.options.memory ?? "")
        _entrypoint = State(initialValue: config.options.entrypoint ?? "")
        _workdir = State(initialValue: config.options.workdir ?? "")
        _user = State(initialValue: config.options.user ?? "")
        _initProcess = State(initialValue: config.options.initProcess)
        _readOnly = State(initialValue: config.options.readOnly)
        _interactive = State(initialValue: config.options.interactive)
        _tty = State(initialValue: config.options.tty)
        _network = State(initialValue: config.options.network ?? "")
        _dnsServers = State(initialValue: config.options.dns)
        _dnsSearchDomains = State(initialValue: config.options.dnsSearch)
        _dnsDomain = State(initialValue: config.options.dnsDomain ?? "")
        _dnsOptions = State(initialValue: config.options.dnsOptions)
        _capAdd = State(initialValue: config.options.capAdd)
        _capDrop = State(initialValue: config.options.capDrop)
        _labels = State(initialValue: config.options.labels.map { LabelInput(key: $0.key, value: $0.value) })
        _kernel = State(initialValue: config.options.kernel ?? "")
        _initImage = State(initialValue: config.options.initImage ?? "")
        _rm = State(initialValue: config.options.rm)
    }

    var body: some View {
        NavigationStack {
            Form {
                // 基本信息（只读）
                Section("基本信息") {
                    TextField("镜像", text: $image)
                        .disabled(true)
                    TextField("容器名称", text: .constant(container.displayName))
                        .disabled(true)
                }

                // 环境变量
                Section("环境变量") {
                    ForEach($envVars.indices, id: \.self) { idx in
                        HStack {
                            TextField("KEY=value", text: $envVars[idx])
                            Button(action: { envVars.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加环境变量") {
                        envVars.append("")
                    }
                    .buttonStyle(.borderless)
                }

                // 端口映射
                Section("端口映射") {
                    ForEach($portMappings.indices, id: \.self) { idx in
                        HStack {
                            TextField("主机端口", text: $portMappings[idx].host)
                            Text("→")
                            TextField("容器端口", text: $portMappings[idx].container)
                            Button(action: { portMappings.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加端口映射") {
                        portMappings.append(PortMappingInput(host: "", container: ""))
                    }
                    .buttonStyle(.borderless)
                }

                // 卷挂载
                Section("卷挂载") {
                    ForEach($volumeMappings.indices, id: \.self) { idx in
                        HStack {
                            TextField("宿主机路径", text: $volumeMappings[idx].source)
                            Text("→")
                            TextField("容器路径", text: $volumeMappings[idx].destination)
                            Button(action: { volumeMappings.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加卷挂载") {
                        volumeMappings.append(VolumeMappingInput(source: "", destination: ""))
                    }
                    .buttonStyle(.borderless)
                }

                // 资源限制
                Section("资源限制") {
                    TextField("CPU 配额 (如 2, 0.5)", text: $cpus)
                    TextField("内存限制 (如 2G, 512M)", text: $memory)
                }

                // 运行时选项
                Section("运行时选项") {
                    TextField("ENTRYPOINT", text: $entrypoint)
                    TextField("工作目录", text: $workdir)
                    TextField("用户 (如 root, 1000:1000)", text: $user)
                    Toggle("运行 init 进程", isOn: $initProcess)
                    Toggle("只读根文件系统", isOn: $readOnly)
                    Toggle("退出后自动删除 (--rm)", isOn: $rm)
                    Toggle("交互模式 (-i)", isOn: $interactive)
                    Toggle("分配 TTY (-t)", isOn: $tty)
                }

                // 网络与 DNS
                Section("网络与 DNS") {
                    Picker("网络", selection: $network) {
                        Text("默认 (bridge)").tag("")
                        ForEach(networkMgr.networks) { net in
                            Text(net.displayName).tag(net.id)
                        }
                        Text("自定义...").tag("__custom__")
                    }
                    .pickerStyle(.menu)
                    if network == "__custom__" {
                        TextField("输入网络名称", text: $customNetwork).textFieldStyle(.roundedBorder)
                            .onAppear { if customNetwork.isEmpty { network = "" } }
                    }
                    ForEach($dnsServers.indices, id: \.self) { idx in
                        HStack {
                            TextField("DNS 服务器", text: $dnsServers[idx])
                            Button(action: { dnsServers.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加 DNS 服务器") {
                        dnsServers.append("")
                    }
                    .buttonStyle(.borderless)

                    ForEach($dnsSearchDomains.indices, id: \.self) { idx in
                        HStack {
                            TextField("DNS 搜索域", text: $dnsSearchDomains[idx])
                            Button(action: { dnsSearchDomains.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加 DNS 搜索域") {
                        dnsSearchDomains.append("")
                    }
                    .buttonStyle(.borderless)

                    TextField("DNS 域", text: $dnsDomain)
                    ForEach($dnsOptions.indices, id: \.self) { idx in
                        HStack {
                            TextField("DNS 选项", text: $dnsOptions[idx])
                            Button(action: { dnsOptions.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加 DNS 选项") {
                        dnsOptions.append("")
                    }
                    .buttonStyle(.borderless)
                }

                // Capabilities
                Section("Linux Capabilities") {
                    TextField("添加 (逗号分隔)", text: Binding(
                        get: { capAdd.joined(separator: ",") },
                        set: { capAdd = $0.split(separator: ",").map(String.init).map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                    TextField("删除 (逗号分隔)", text: Binding(
                        get: { capDrop.joined(separator: ",") },
                        set: { capDrop = $0.split(separator: ",").map(String.init).map { $0.trimmingCharacters(in: .whitespaces) } }
                    ))
                }

                // 标签
                Section("标签") {
                    ForEach($labels.indices, id: \.self) { idx in
                        HStack {
                            TextField("键", text: $labels[idx].key)
                            Text("=")
                            TextField("值", text: $labels[idx].value)
                            Button(action: { labels.remove(at: idx) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                    Button("添加标签") {
                        labels.append(LabelInput(key: "", value: ""))
                    }
                    .buttonStyle(.borderless)
                }

                // 高级内核
                Section("高级内核") {
                    TextField("自定义内核路径", text: $kernel)
                    TextField("自定义 init 镜像", text: $initImage)
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑容器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveChanges()
                    }
                    .disabled(isSaving)
                }
            }
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView("正在重建容器...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: - 保存
    private func saveChanges() {
        isSaving = true
        errorMessage = nil

        let ports = portMappings
            .filter { !$0.host.isEmpty && !$0.container.isEmpty }
            .map { "\($0.host):\($0.container)" }
        let volumes = volumeMappings
            .filter { !$0.destination.isEmpty }
            .map { VolumeMapping(source: $0.source, destination: $0.destination) }
        let labelsDict = labels
            .filter { !$0.key.isEmpty }
            .reduce(into: [:]) { $0[$1.key] = $1.value }

        let options = ContainerRunOptions(
            detach: true,
            rm: rm,
            interactive: interactive,
            tty: tty,
            cpus: cpus.isEmpty ? nil : cpus,
            memory: memory.isEmpty ? nil : memory,
            entrypoint: entrypoint.isEmpty ? nil : entrypoint,
            workdir: workdir.isEmpty ? nil : workdir,
            user: user.isEmpty ? nil : user,
            initProcess: initProcess,
            readOnly: readOnly,
            network: effectiveNetwork.isEmpty ? nil : effectiveNetwork,
            dns: dnsServers.filter { !$0.isEmpty },
            dnsSearch: dnsSearchDomains.filter { !$0.isEmpty },
            dnsDomain: dnsDomain.isEmpty ? nil : dnsDomain,
            dnsOptions: dnsOptions.filter { !$0.isEmpty },
            noDNS: false,
            publishSockets: [],
            advancedMounts: [],
            tmpfsMounts: [],
            os: nil,
            arch: nil,
            capAdd: capAdd.filter { !$0.isEmpty },
            capDrop: capDrop.filter { !$0.isEmpty },
            labels: labelsDict,
            kernel: kernel.isEmpty ? nil : kernel,
            initImage: initImage.isEmpty ? nil : initImage,
            cidfile: nil,
            sshForward: false,
            virtualization: false,
            scheme: nil,
            maxConcurrentDownloads: nil
        )
        var rebuiltOptions = options
        rebuiltOptions.command = config.options.command

        let newConfig = ContainerConfig(
            image: image,
            env: envVars.filter { !$0.isEmpty },
            ports: ports,
            volumes: volumes,
            name: container.displayName,
            detach: true,
            options: rebuiltOptions
        )
        Task {
            do {
                try await manager.recreateContainer(with: newConfig, originalID: container.id)
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
