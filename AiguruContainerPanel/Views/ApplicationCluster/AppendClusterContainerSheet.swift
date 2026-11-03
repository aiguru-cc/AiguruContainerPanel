//
//  AppendClusterContainerSheet.swift
//  AiguruContainerPanel
//
//  向既有应用集群追加一个带统一元数据的容器。
//

import SwiftUI

struct AppendClusterContainerSheet: View {
    let cluster: ApplicationCluster
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var serviceName = ""
    @State private var role = ""
    @State private var imageName = ""
    @State private var imageTag = "latest"
    @State private var showLocalImagePicker = false
    @State private var ports = ""
    @State private var environment = ""
    @State private var volumes = ""
    @State private var command = ""
    @State private var dnsRegistration = true
    @State private var sshForward = false
    @State private var isCreating = false
    @State private var errorMessage: String?
    @StateObject private var imageSourceManager = ImageSourceManager.shared
    @ObservedObject private var sourceImageManager = SourceImageManager.shared

    private let templateManager = ClusterTemplateManager.shared

    private var nextOrdinal: Int {
        let existingOrdinals = cluster.containers.compactMap { container -> Int? in
            guard container.labels?["cc.aiguru.application-service"] == serviceName else { return nil }
            return Int(container.labels?["cc.aiguru.application-ordinal"] ?? "")
        }
        return (existingOrdinals.max() ?? 0) + 1
    }

    private var proposedName: String {
        templateManager.deploymentContainerName(
            clusterName: cluster.name,
            serviceName: serviceName.isEmpty ? "service" : serviceName,
            ordinal: nextOrdinal
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("追加容器").font(.headline)
                    Text("应用集群：\(cluster.name)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.disabled(isCreating)
            }

            Form {
                Section("容器身份") {
                    TextField("服务名，例如 mailer", text: $serviceName)
                    TextField("角色（可选），例如 worker", text: $role)
                    Picker("镜像源", selection: $imageSourceManager.currentSource) {
                        Text("Docker Hub").tag(nil as ImageSource?)
                        ForEach(imageSourceManager.sources) { source in
                            Text(source.name ?? "").tag(source as ImageSource?)
                        }
                    }
                    .pickerStyle(.menu)
                    if !quickImages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(quickImages.prefix(30).enumerated()), id: \.offset) { _, item in
                                    Button("\(item.name):\(item.tag)") {
                                        imageName = item.name
                                        imageTag = item.tag
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("镜像名，例如 nginx", text: $imageName)
                        TextField("标签", text: $imageTag).frame(width: 100)
                        Button("本地…") { showLocalImagePicker = true }
                            .disabled(sourceImageManager.images.isEmpty)
                    }
                    LabeledContent("完整引用") {
                        Text(fullImageReference).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    LabeledContent("容器名") {
                        Text(proposedName).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Section("运行配置") {
                    TextField("端口映射（可选，逗号分隔），例如 1025:1025,8025:8025", text: $ports)
                    TextField("命令参数（可选，空格分隔）", text: $command)
                    Toggle("注册到应用集群 DNS", isOn: $dnsRegistration)
                    Toggle("转发宿主机 SSH Agent", isOn: $sshForward)
                    if dnsRegistration {
                        Text(dnsHint).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Section("环境变量与卷") {
                    TextEditor(text: $environment)
                        .font(.caption.monospaced())
                        .frame(height: 58)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.quaternary) }
                    TextEditor(text: $volumes)
                        .font(.caption.monospaced())
                        .frame(height: 58)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.quaternary) }
                    Text("每行一个：环境变量 KEY=VALUE；卷 SOURCE:TARGET。命名卷可直接填写，集群共享卷可使用 {{CLUSTER_VOLUME:name}}。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }.disabled(isCreating)
                Button {
                    createContainer()
                } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Label("追加到集群", systemImage: "plus") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || serviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 680)
        .toast()
        .sheet(isPresented: $showLocalImagePicker) {
            LocalImagePicker(images: sourceImageManager.images) { repository, tag in
                imageName = repository
                imageTag = tag
                showLocalImagePicker = false
            }
        }
        .task {
            imageSourceManager.loadSources()
            imageSourceManager.loadAllEntries()
            await sourceImageManager.fetchImages()
        }
    }

    private var dnsHint: String {
        if let domain = ContainerRuntimeConfiguration.configuredDNSDomain {
            return "将注册为 \(proposedName).\(domain)（default 网络）"
        }
        return "未配置全局 DNS 域；请在网络页设置后再创建。"
    }

    private var quickImages: [(name: String, tag: String)] {
        imageSourceManager.allEntries.compactMap { entry in
            guard let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let tag = entry.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name, tag.isEmpty ? "latest" : tag)
        }
    }

    private var fullImageReference: String {
        let trimmedName = imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "尚未选择镜像" }
        let reference = imageTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? trimmedName
            : trimmedName.imageReference(tag: imageTag.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !reference.contains("/"),
              let url = imageSourceManager.currentSource?.url else { return reference }
        let registry = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return registry.isEmpty ? reference : "\(registry)/\(reference)"
    }

    private func splitLines(_ text: String, allowComma: Bool = false) -> [String] {
        let separators = allowComma ? CharacterSet.newlines.union(CharacterSet(charactersIn: ",")) : .newlines
        return text.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func createContainer() {
        let service = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageReference = fullImageReference
        guard !service.isEmpty, !imageReference.isEmpty else { return }
        let name = proposedName
        guard !ContainerManager.shared.containers.contains(where: { $0.displayName == name }) else {
            fail("容器「\(name)」已存在")
            return
        }
        let domain: String?
        if dnsRegistration {
            guard let configured = ContainerRuntimeConfiguration.configuredDNSDomain, !configured.isEmpty else {
                fail("DNS 注册需要先在网络页配置全局 DNS 域")
                return
            }
            domain = configured
        } else {
            domain = nil
        }

        var labels = [
            "cc.aiguru.application-cluster": cluster.name,
            "cc.aiguru.application-service": service,
            "cc.aiguru.application-ordinal": String(nextOrdinal),
            "cc.aiguru.template-api-version": "aiguru.container/v1"
        ]
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRole.isEmpty { labels["cc.aiguru.application-role"] = trimmedRole }
        if let domain {
            labels["cc.aiguru.application-dns-name"] = "\(name).\(domain)"
        }

        isCreating = true
        errorMessage = nil
        Task {
            do {
                let options = ContainerRunOptions(
                    detach: true,
                    network: "default",
                    labels: labels,
                    sshForward: sshForward,
                    command: splitLines(command, allowComma: false).flatMap { $0.split(separator: " ").map(String.init) }
                )
                let resolvedVolumes = templateManager.resolveVolumes(
                    splitLines(volumes),
                    projectDirectory: nil,
                    clusterName: cluster.name,
                    serviceName: service,
                    ordinal: nextOrdinal
                )
                try await VolumeManager.shared.ensureNamedVolumes(
                    for: resolvedVolumes,
                    clusterName: cluster.name,
                    serviceName: service
                )
                _ = try await ContainerManager.shared.createContainer(
                    name: name,
                    image: imageReference,
                    ports: splitLines(ports, allowComma: true),
                    env: splitLines(environment),
                    volumes: resolvedVolumes,
                    options: options
                )
                await MainActor.run {
                    isCreating = false
                    ToastManager.shared.showSuccess("容器「\(name)」已追加到集群")
                    onCreated()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    fail("追加失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        ToastManager.shared.showError(message)
    }
}
