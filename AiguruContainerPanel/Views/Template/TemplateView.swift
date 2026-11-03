//
//  TemplateView.swift
//  AiguruContainerPanel
//
//  应用集群：导入/导出声明式 JSON 模板，并一键部署本机容器服务。
//

import SwiftUI
internal import UniformTypeIdentifiers

struct TemplateView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var template: ClusterTemplate?
    @State private var sourceTemplate: ClusterTemplate?
    @State private var jsonText = ""
    @State private var remoteURL = ""
    @State private var errorMessage: String?
    @State private var showFileImporter = false
    @State private var isApplying = false
    @State private var isFetchingRemote = false
    @State private var applyProgress = ""
    @State private var createdCount = 0
    @State private var deploymentResult: String?
    @State private var deploymentName = ""
    @State private var projectDirectory = ""
    @State private var deploymentStates: [String: DeploymentInstanceState] = [:]
    @State private var deploymentTask: Task<Void, Never>?
    @State private var retryingContainerNames: Set<String> = []
    @State private var isCancellationRequested = false
    @State private var showFileExporter = false
    @State private var showTemplateGenerator = false
    @State private var exportDocument = ApplicationClusterTemplateDocument(text: "")
    @AppStorage("applicationCluster.mavenRepositoryMirror") private var mavenRepositoryMirror = MavenRepositoryMirror.aliyun.rawValue
    @StateObject private var imgSrcMgr = ImageSourceManager.shared
    @ObservedObject private var taskManager = TaskManager.shared

    private let templateSvc = ClusterTemplateManager.shared

    private var configuredDNSDomain: String? {
        ContainerRuntimeConfiguration.configuredDNSDomain
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部操作栏
            HStack(spacing: 8) {
                Label("应用集群模板", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()

                // 远程 URL
                TextField("远程模板 URL…", text: $remoteURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button(action: fetchRemote) {
                    if isFetchingRemote {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("拉取", systemImage: "icloud.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(remoteURL.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty)

                Button("导入模板…") { showFileImporter = true }
                    .buttonStyle(.bordered)
                Button("模板生成器…") { showTemplateGenerator = true }
                    .buttonStyle(.borderedProminent)
                Button("加载 Web 开发示例") { loadSample() }
                    .buttonStyle(.bordered)
                Button("加载高可用示例") { loadHighAvailabilitySample() }
                    .buttonStyle(.bordered)
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(isApplying)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let template {
                templatePreview(template)
            } else {
                editorView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Sheet 位于主窗口 Toast 之上；在此层挂载同一单例，确保创建过程提示可见。
        .toast()
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json, .plainText]) { result in
            guard case .success(let url) = result else { return }
            loadTemplate(from: url)
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "\(template?.name ?? "application-cluster").aigurucluster"
        ) { _ in }
        .sheet(isPresented: $showTemplateGenerator) {
            TemplateGeneratorView(template: sourceTemplate ?? template) { generated in
                sourceTemplate = generated
                template = applyingSelectedRegistry(to: generated)
                deploymentName = generated.name
                jsonText = (try? templateSvc.export(generated)) ?? ""
                errorMessage = nil
            }
        }
    }

    private func presentError(_ message: String) {
        errorMessage = message
        ToastManager.shared.showError(message)
    }

    // MARK: - 编辑器
    private var editorView: some View {
        VStack(spacing: 10) {
            // 镜像源选择
            HStack {
                Text("镜像源:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $imgSrcMgr.currentSource) {
                    Text("Docker Hub").tag(nil as ImageSource?)
                    ForEach(imgSrcMgr.sources) { src in Text(src.name ?? "").tag(src as ImageSource?) }
                }
                .pickerStyle(.menu)
                if imgSrcMgr.currentSource != nil {
                    Text("将自动为短名镜像添加注册表前缀")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
            }

            Text("粘贴应用集群 JSON，或通过上方按钮导入。模板描述期望服务、副本、依赖、卷与端口。")
                .font(.caption)
                .foregroundStyle(.secondary)

            PlainCodeEditor(text: $jsonText)
                .frame(minHeight: 220)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("解析模板") { parseAndApplyMirror() }
                    .buttonStyle(.borderedProminent)
                    .disabled(jsonText.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty)
            }
        }
        .controlSize(.small)
        .padding(20)
    }

    // MARK: - 模板预览
    private func templatePreview(_ t: ClusterTemplate) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 模板头部
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.name).font(.headline)
                    if let desc = t.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(t.serviceCount) 个服务 · \(t.services.reduce(0) { $0 + $1.replicas }) 个期望实例 · \(t.totalPorts) 个端口映射 · \(t.totalVolumes) 个卷")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Button {
                        exportTemplate(t)
                    } label: {
                        Label("导出模板", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { self.template = nil; self.sourceTemplate = nil } label: {
                        Label("清除", systemImage: "xmark").labelStyle(.iconOnly)
                    }.buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 服务列表
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(t.services) { service in
                        serviceCard(service, template: t)
                    }
                }
                .padding(10)
            }

            Divider()

            dnsRegistrationStatus(for: t)

            if isApplying || !retryingContainerNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isApplying ? "正在部署应用集群" : "正在重试失败实例")
                                .font(.caption.weight(.semibold))
                            Text(applyProgress).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isApplying {
                            Text("\(createdCount) / \(t.services.reduce(0) { $0 + $1.replicas })")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Button("取消部署") { cancelDeployment() }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                    }
                    deploymentLogOutput
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.tint.opacity(0.08))
            }

            HStack(spacing: 8) {
                Text("部署名称").font(.caption).foregroundStyle(.secondary)
                TextField("用于容器名称与标签", text: $deploymentName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Text("容器命名：<集群>--<服务>--<序号>")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 10)

            HStack(spacing: 8) {
                Text("项目目录").font(.caption).foregroundStyle(.secondary)
                TextField("模板中的 {{PROJECT_DIR}}", text: $projectDirectory)
                    .textFieldStyle(.roundedBorder)
                Button(action: chooseProjectDirectory) {
                    Image(systemName: "folder")
                }
                .help("选择包含 apps 与 infra 目录的项目根目录")
                Button("按模板生成挂载") { generateTemplateMounts() }
                    .disabled(projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("补齐 apps 与 infra 的 bind mount 目录和文件；已有内容不会被覆盖，空 app.jar 需替换为实际构建产物")
                Text("源码与共享文件用 bind mount；命名卷仅限单容器")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.vertical, 8)

            HStack(spacing: 8) {
                Text("Maven 源").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $mavenRepositoryMirror) {
                    ForEach(MavenRepositoryMirror.allCases) { mirror in
                        Text(mirror.title).tag(mirror.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                Text(MavenRepositoryMirror(rawValue: mavenRepositoryMirror)?.detail ?? MavenRepositoryMirror.official.detail)
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 16).padding(.bottom, 8)

            Text("卷规则：持久化资源统一使用 {{PROJECT_DIR}}/infra/<组件>/<服务>/... bind mount；不再推荐会把 .img 放入用户支持目录的命名卷。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)

            // 底部操作
            HStack {
                if let deploymentResult {
                    Text(deploymentResult).font(.caption).foregroundStyle(deploymentResult.hasPrefix("✅") ? .green : .orange)
                }
                Spacer()
                Button("返回编辑") { self.template = nil }
                Button("一键部署") { applyTemplate(t, deploymentName: deploymentName) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || deploymentName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var deploymentLogOutput: some View {
        if taskManager.liveOutput.isEmpty {
            Text("等待 container 输出…")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(taskManager.liveOutput.indices, id: \.self) { index in
                            Text(taskManager.liveOutput[index])
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: taskManager.liveOutput) { _, output in
                    if let last = output.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
                .frame(height: 76)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    // MARK: - 服务卡片
    private func serviceCard(_ svc: ClusterService, template: ClusterTemplate) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                    Text(svc.name).font(.subheadline.weight(.semibold))
                    if let role = svc.role, !role.isEmpty {
                        Text(role)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(svc.image).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                if !svc.ports.isEmpty {
                    Label("端口: \(svc.ports.joined(separator: ", "))", systemImage: "arrow.left.arrow.right")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !svc.env.isEmpty {
                    Label("环境变量: \(svc.env.joined(separator: ", "))", systemImage: "gearshape")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !svc.volumes.isEmpty {
                    Label("挂载: \(svc.volumes.joined(separator: ", "))", systemImage: "externaldrive")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !svc.dependsOn.isEmpty {
                    Label("依赖: \(svc.dependsOn.joined(separator: ", "))", systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let preparation = svc.preDeploy {
                    Label("部署前阶段: \(preparation.title ?? preparation.kind)", systemImage: "hammer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !svc.command.isEmpty {
                    Label("命令: \(svc.command.joined(separator: " "))", systemImage: "terminal")
                        .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                if svc.dnsRegistration {
                    Label("DNS: 自动注册容器名（default 网络）", systemImage: "network")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("DNS: 此服务不注册", systemImage: "network.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if svc.sshForward {
                    Label("SSH Agent 转发已启用", systemImage: "key.horizontal")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if svc.replicas > 1 {
                    Label("副本: \(svc.replicas)（不发布宿主机端口）", systemImage: "square.3.layers.3d")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let cpus = svc.cpus, let mem = svc.memory {
                    Label("资源: \(cpus) CPU · \(mem)", systemImage: "cpu")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let cpus = svc.cpus {
                    Label("CPU: \(cpus)", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                } else if let mem = svc.memory {
                    Label("内存: \(mem)", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                }
                if !deploymentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(1...svc.replicas, id: \.self) { ordinal in
                        deploymentInstanceRow(service: svc, template: template, ordinal: ordinal)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .background(serviceDeploymentBackground(for: svc), in: RoundedRectangle(cornerRadius: 6))
    }

    private func serviceDeploymentBackground(for service: ClusterService) -> Color {
        let states = (1...service.replicas).compactMap { ordinal in
            deploymentStates[templateSvc.deploymentContainerName(
                clusterName: deploymentName,
                serviceName: service.name,
                ordinal: ordinal
            )]
        }
        if states.contains(where: {
            if case .failure = $0 { return true }
            if case .artifactFailure = $0 { return true }
            return false
        }) {
            return .red.opacity(0.09)
        }
        if states.count == service.replicas, states.allSatisfy({ state in
            if case .success = state { return true }
            if case .skipped = state { return true }
            return false
        }) {
            return .green.opacity(0.09)
        }
        if states.contains(where: {
            if case .deploying = $0 { return true }
            if case .preparingArtifact = $0 { return true }
            return false
        }) {
            return .blue.opacity(0.07)
        }
        return .clear
    }

    private func deploymentInstanceRow(service: ClusterService, template: ClusterTemplate, ordinal: Int) -> some View {
        let name = templateSvc.deploymentContainerName(
            clusterName: deploymentName,
            serviceName: service.name,
            ordinal: ordinal
        )
        let state = deploymentStates[name] ?? .idle
        return HStack(spacing: 6) {
            Image(systemName: state.icon).foregroundStyle(state.foregroundColor)
            Text(name).font(.caption2.monospaced()).lineLimit(1)
            Spacer()
            Text(state.title).font(.caption2).foregroundStyle(state.foregroundColor).lineLimit(1)
            if retryingContainerNames.contains(name) {
                ProgressView().controlSize(.mini)
            } else if case .failure = state {
                Button("重试") { retryFailedContainer(service, template: template, ordinal: ordinal) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func dnsRegistrationStatus(for template: ClusterTemplate) -> some View {
        let dnsServices = template.services.filter(\.dnsRegistration)
        if dnsServices.isEmpty {
            Label("模板未要求容器 DNS 注册。", systemImage: "network.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
        } else {
            switch templateSvc.validateDNSRegistration(template, configuredDomain: configuredDNSDomain) {
            case .success(let domain):
                if let domain {
                    Label("DNS 已就绪：default 网络中的容器将自动注册为 <容器名>.\(domain)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    // MARK: - Web 开发 JSON 示例
    private func chooseProjectDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Web 项目根目录"
        panel.message = "目录中应包含 apps 与 infra"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                projectDirectory = url.path
            }
        }
    }

    private func generateTemplateMounts() {
        guard let template else {
            presentError("请先加载或生成模板")
            return
        }
        let path = projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: path) else {
            presentError("项目目录不存在，请先选择有效目录")
            return
        }
        do {
            let result = try TemplateMountScaffold.generate(for: template, in: path)
            deploymentResult = result.created.isEmpty ? "✅ 当前模板的项目挂载资源已齐全" : "✅ 已按当前模板生成 \(result.created.count) 项挂载资源"
            errorMessage = nil
            let createdJAR = result.created.contains { $0.hasSuffix("/app.jar") }
            let message = createdJAR
                ? "已补齐挂载；三个空 app.jar 占位文件需替换为实际构建产物"
                : (deploymentResult ?? "项目挂载资源已生成")
            if result.created.isEmpty, !result.skippedExternal.isEmpty {
                ToastManager.shared.showInfo("模板仅使用外部绝对路径挂载；不会在项目目录生成额外内容")
            } else {
                ToastManager.shared.showSuccess(message)
            }
        } catch {
            presentError("生成挂载目录失败: \(error.localizedDescription)")
        }
    }

    private func loadSample() {
        jsonText = """
        {
          "apiVersion": "aiguru.container/v1",
          "kind": "ApplicationCluster",
          "name": "web-dev",
          "description": "本地高可用 Web 开发栈：CoreDNS 缓存转发、SSH Bastion、双 Nginx 冗余反向代理/穿透、PHP-FPM、MariaDB 主从、Redis 主从与三节点 Sentinel、TypeScript 前端、Node.js API、Worker 及 Spring Boot 服务。",

          "services": [
            {
              "name": "dns",
              "role": "dns-cache-forwarder",
              "image": "coredns/coredns:1.11.3",
              "network": "default",
              "ports": ["127.0.0.1:5354:53/udp", "127.0.0.1:5354:53/tcp"],
              "volumes": ["{{PROJECT_DIR}}/infra/dns/Corefile:/etc/coredns/Corefile"],
              "command": ["-conf", "/etc/coredns/Corefile"],
              "cpus": 1,
              "memory": "256M",
              "detach": true,
              "dnsRegistration": true
            },
            {
              "name": "ssh-bastion",
              "role": "ssh-bastion",
              "image": "lscr.io/linuxserver/openssh-server:latest",
              "network": "default",
              "ports": ["127.0.0.1:2222:2222"],
              "volumes": ["{{PROJECT_DIR}}/infra/ssh/ssh-bastion/config:/config", "{{PROJECT_DIR}}/infra/ssh/authorized_keys:/run/secrets/authorized_keys", "{{PROJECT_DIR}}/shared/img:/workspace/shared/img"],
              "env": ["PUID=1000", "PGID=1000", "TZ=Asia/Shanghai", "USER_NAME=aiguru", "PUBLIC_KEY_FILE=/run/secrets/authorized_keys", "PASSWORD_ACCESS=false", "SUDO_ACCESS=false", "LOG_STDOUT=true"],
              "cpus": 1,
              "memory": "256M",
              "detach": true,
              "dnsRegistration": true,
              "dependsOn": ["dns"]
            },
            {
              "name": "nginx-primary",
              "role": "edge-primary-reverse-tunnel",
              "image": "nginx:alpine",
              "network": "default",
              "ports": ["8081:80", "19000:9000"],
              "volumes": ["{{PROJECT_DIR}}/apps/frontend/dist:/usr/share/nginx/html", "{{PROJECT_DIR}}/apps/php:/var/www/html", "{{PROJECT_DIR}}/shared/img:/data/img", "{{PROJECT_DIR}}/infra/nginx/nginx-primary-runtime-v4.conf:/etc/nginx/templates/nginx.conf.template"],
              "env": ["NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx", "NGINX_ENVSUBST_FILTER=^(API_HOST|PHP_FPM_HOST)$", "API_HOST={{CLUSTER_DNS:api}}", "PHP_FPM_HOST={{CLUSTER_DNS:php}}"],
              "cpus": 1,
              "memory": "256M",
              "detach": true,
              "dnsRegistration": true,
              "dependsOn": ["dns", "php", "api", "spring-gateway"]
            },
            {
              "name": "nginx-secondary",
              "role": "edge-secondary-reverse-tunnel",
              "image": "nginx:alpine",
              "network": "default",
              "ports": ["8082:80", "19001:9000"],
              "volumes": ["{{PROJECT_DIR}}/apps/frontend/dist:/usr/share/nginx/html", "{{PROJECT_DIR}}/apps/php:/var/www/html", "{{PROJECT_DIR}}/shared/img:/data/img", "{{PROJECT_DIR}}/infra/nginx/nginx-secondary-runtime-v4.conf:/etc/nginx/templates/nginx.conf.template"],
              "env": ["NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx", "NGINX_ENVSUBST_FILTER=^(API_HOST|PHP_FPM_HOST)$", "API_HOST={{CLUSTER_DNS:api}}", "PHP_FPM_HOST={{CLUSTER_DNS:php}}"],
              "cpus": 1,
              "memory": "256M",
              "detach": true,
              "dnsRegistration": true,
              "dependsOn": ["dns", "php", "api", "spring-gateway"]
            },
            {
              "name": "php",
              "role": "php-fpm",
              "image": "php:8.3-fpm-alpine",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/apps/php:/var/www/html", "{{PROJECT_DIR}}/shared/img:/data/img"],
              "env": ["APP_ENV=development", "UPLOAD_DIR=/data/img", "DATABASE_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-primary}}:3306/webapp", "DATABASE_REPLICA_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-replica}}:3306/webapp", "REDIS_URL=redis://{{CLUSTER_DNS:redis-master}}:6379", "REDIS_SENTINEL_MASTER=mymaster", "REDIS_SENTINELS={{CLUSTER_DNS:redis-sentinel:1}}:26379,{{CLUSTER_DNS:redis-sentinel:2}}:26379,{{CLUSTER_DNS:redis-sentinel:3}}:26379"],
              "cpus": 1,
              "memory": "512M",
              "workdir": "/var/www/html",
              "dnsRegistration": true,
              "dependsOn": ["db-primary", "db-replica", "redis-sentinel"]
            },
            {
              "name": "db-primary",
              "role": "database-primary",
              "image": "mariadb:11",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/infra/mariadb/db-primary/data:/var/lib/mysql", "{{PROJECT_DIR}}/infra/mariadb/01-primary-replication.sql:/docker-entrypoint-initdb.d/01-primary-replication.sql"],
              "env": ["MARIADB_ROOT_PASSWORD=change-root-password", "MARIADB_DATABASE=webapp", "MARIADB_USER=webapp", "MARIADB_PASSWORD=change-me"],
              "command": ["--server-id=1", "--log-bin=mysql-bin", "--binlog-format=ROW"],
              "cpus": 1,
              "memory": "1G",
              "dnsRegistration": true
            },
            {
              "name": "db-replica",
              "role": "database-replica",
              "image": "mariadb:11",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/infra/mariadb/db-replica/data:/var/lib/mysql"],
              "env": ["MARIADB_ROOT_PASSWORD=change-root-password", "MARIADB_DATABASE=webapp", "MARIADB_USER=webapp", "MARIADB_PASSWORD=change-me", "DB_PRIMARY_HOST={{CLUSTER_DNS:db-primary}}"],
              "command": ["sh", "-c", "printf \\\"CHANGE MASTER TO MASTER_HOST='%s', MASTER_USER='replicator', MASTER_PASSWORD='change-replication-password', MASTER_USE_GTID=slave_pos; START SLAVE;\\n\\\" \\\"$DB_PRIMARY_HOST\\\" > /docker-entrypoint-initdb.d/02-replica.sql && exec docker-entrypoint.sh mariadbd --server-id=2 --relay-log=relay-bin --read-only=ON"],
              "cpus": 1,
              "memory": "1G",
              "dnsRegistration": true,
              "dependsOn": ["db-primary"]
            },
            {
              "name": "redis-master",
              "role": "redis-master",
              "image": "redis:7-alpine",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/infra/redis/redis-master/data:/data"],
              "command": ["redis-server", "--appendonly", "yes"],
              "memory": "256M",
              "dnsRegistration": true
            },
            {
              "name": "redis-replica",
              "role": "redis-replica",
              "image": "redis:7-alpine",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/infra/redis/redis-replica/data:/data"],
              "command": ["redis-server", "--appendonly", "yes", "--replicaof", "{{CLUSTER_DNS:redis-master}}", "6379"],
              "memory": "256M",
              "dnsRegistration": true,
              "dependsOn": ["redis-master"]
            },
            {
              "name": "redis-sentinel",
              "role": "redis-sentinel",
              "image": "redis:7-alpine",
              "network": "default",
              "command": ["sh", "-c", "printf 'port 26379\\nsentinel resolve-hostnames yes\\nsentinel announce-hostnames yes\\nsentinel monitor mymaster {{CLUSTER_DNS:redis-master}} 6379 2\\nsentinel down-after-milliseconds mymaster 5000\\nsentinel failover-timeout mymaster 10000\\nsentinel parallel-syncs mymaster 1\\n' > /tmp/sentinel.conf && exec redis-sentinel /tmp/sentinel.conf"],
              "memory": "256M",
              "dnsRegistration": true,
              "replicas": 3,
              "dependsOn": ["redis-master", "redis-replica"]
            },
            {
              "name": "api",
              "role": "api",
              "image": "node:20-alpine",
              "network": "default",
              "ports": ["13000:3000"],
              "volumes": ["{{PROJECT_DIR}}/apps/api:/app", "{{PROJECT_DIR}}/shared/img:/data/img"],
              "workdir": "/app",
              "command": ["sh", "-c", "npm install --no-audit --no-fund && npm run dev"],
              "env": ["NODE_ENV=development", "PORT=3000", "UPLOAD_DIR=/data/img", "DATABASE_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-primary}}:3306/webapp", "DATABASE_REPLICA_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-replica}}:3306/webapp", "REDIS_URL=redis://{{CLUSTER_DNS:redis-master}}:6379", "REDIS_SENTINEL_MASTER=mymaster", "REDIS_SENTINELS={{CLUSTER_DNS:redis-sentinel:1}}:26379,{{CLUSTER_DNS:redis-sentinel:2}}:26379,{{CLUSTER_DNS:redis-sentinel:3}}:26379", "PHP_FPM_HOST={{CLUSTER_DNS:php}}"],
              "cpus": 1,
              "memory": "512M",
              "dnsRegistration": true,
              "dependsOn": ["db-primary", "db-replica", "redis-sentinel"]
            },
            {
              "name": "frontend",
              "role": "typescript-frontend",
              "image": "node:20-alpine",
              "network": "default",
              "ports": ["5173:5173"],
              "volumes": ["{{PROJECT_DIR}}/apps/frontend:/app"],
              "workdir": "/app",
              "command": ["sh", "-c", "npm install --no-audit --no-fund && npm run dev -- --host 0.0.0.0"],
              "env": ["NODE_ENV=development", "VITE_API_BASE_URL=http://localhost:13000"],
              "cpus": 1,
              "memory": "512M",
              "dnsRegistration": true,
              "dependsOn": ["api"]
            },
            {
              "name": "worker",
              "role": "queue-worker",
              "image": "node:20-alpine",
              "network": "default",
              "volumes": ["{{PROJECT_DIR}}/apps/worker:/app"],
              "workdir": "/app",
              "command": ["sh", "-c", "npm install --no-audit --no-fund && npm run worker"],
              "env": ["NODE_ENV=development", "DATABASE_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-primary}}:3306/webapp", "DATABASE_REPLICA_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-replica}}:3306/webapp", "REDIS_URL=redis://{{CLUSTER_DNS:redis-master}}:6379", "REDIS_SENTINEL_MASTER=mymaster", "REDIS_SENTINELS={{CLUSTER_DNS:redis-sentinel:1}}:26379,{{CLUSTER_DNS:redis-sentinel:2}}:26379,{{CLUSTER_DNS:redis-sentinel:3}}:26379"],
              "cpus": 1,
              "memory": "256M",
              "dnsRegistration": true,
              "dependsOn": ["api", "redis-sentinel"]
            },
            {
              "name": "node22",
              "role": "nodejs-22-runtime",
              "image": "node:22-alpine",
              "network": "default",
              "ports": ["13022:3000"],
              "volumes": ["{{PROJECT_DIR}}/apps/node22:/app"],
              "workdir": "/app",
              "command": ["sh", "-c", "npm install --no-audit --no-fund && npm start"],
              "env": ["NODE_ENV=development", "PORT=3000", "NODE_RUNTIME=22"],
              "cpus": 1,
              "memory": "512M",
              "dnsRegistration": true
            },
            {
              "name": "node24",
              "role": "nodejs-24-runtime",
              "image": "node:24-alpine",
              "network": "default",
              "ports": ["13024:3000"],
              "volumes": ["{{PROJECT_DIR}}/apps/node24:/app"],
              "workdir": "/app",
              "command": ["sh", "-c", "npm install --no-audit --no-fund && npm start"],
              "env": ["NODE_ENV=development", "PORT=3000", "NODE_RUNTIME=24"],
              "cpus": 1,
              "memory": "512M",
              "dnsRegistration": true
            },
            {
              "name": "spring-auth",
              "role": "springboot-auth",
              "preDeploy": {"kind": "maven-spring-boot", "title": "构建认证服务", "context": "apps/spring-auth", "output": "app.jar", "image": "maven:3.9-eclipse-temurin-21", "command": ["mvn", "--batch-mode", "-DskipTests", "package"]},
              "image": "eclipse-temurin:21-jre",
              "network": "default",
              "ports": ["18081:8080"],
              "volumes": ["{{PROJECT_DIR}}/apps/spring-auth/app.jar:/app/app.jar"],
              "command": ["sh", "-c", "if [ ! -s /app/app.jar ]; then echo 'spring-auth: app.jar 尚未构建，等待替换'; fi; while [ ! -s /app/app.jar ]; do sleep 10; done; while true; do java -jar /app/app.jar; code=$?; echo spring-auth: JVM-exit-code=${code}, retrying-in-5s; sleep 5; done"],
              "env": ["SPRING_PROFILES_ACTIVE=dev", "SPRING_DATASOURCE_URL=jdbc:mysql://{{CLUSTER_DNS:db-primary}}:3306/webapp", "SPRING_REPLICA_URL=jdbc:mysql://{{CLUSTER_DNS:db-replica}}:3306/webapp", "REDIS_SENTINELS={{CLUSTER_DNS:redis-sentinel:1}}:26379,{{CLUSTER_DNS:redis-sentinel:2}}:26379,{{CLUSTER_DNS:redis-sentinel:3}}:26379"],
              "memory": "768M", "dnsRegistration": true, "dependsOn": ["db-primary", "db-replica", "redis-sentinel"]
            },
            {
              "name": "spring-order",
              "role": "springboot-order",
              "preDeploy": {"kind": "maven-spring-boot", "title": "构建订单服务", "context": "apps/spring-order", "output": "app.jar", "image": "maven:3.9-eclipse-temurin-21", "command": ["mvn", "--batch-mode", "-DskipTests", "package"]},
              "image": "eclipse-temurin:21-jre",
              "network": "default",
              "ports": ["18082:8080"],
              "volumes": ["{{PROJECT_DIR}}/apps/spring-order/app.jar:/app/app.jar"],
              "command": ["sh", "-c", "if [ ! -s /app/app.jar ]; then echo 'spring-order: app.jar 尚未构建，等待替换'; fi; while [ ! -s /app/app.jar ]; do sleep 10; done; while true; do java -jar /app/app.jar; code=$?; echo spring-order: JVM-exit-code=${code}, retrying-in-5s; sleep 5; done"],
              "env": ["SPRING_PROFILES_ACTIVE=dev", "SPRING_DATASOURCE_URL=jdbc:mysql://{{CLUSTER_DNS:db-primary}}:3306/webapp", "SPRING_REPLICA_URL=jdbc:mysql://{{CLUSTER_DNS:db-replica}}:3306/webapp", "REDIS_SENTINELS={{CLUSTER_DNS:redis-sentinel:1}}:26379,{{CLUSTER_DNS:redis-sentinel:2}}:26379,{{CLUSTER_DNS:redis-sentinel:3}}:26379"],
              "memory": "768M", "dnsRegistration": true, "dependsOn": ["db-primary", "db-replica", "redis-sentinel"]
            },
            {
              "name": "spring-gateway",
              "role": "springboot-gateway",
              "preDeploy": {"kind": "maven-spring-boot", "title": "构建网关服务", "context": "apps/spring-gateway", "output": "app.jar", "image": "maven:3.9-eclipse-temurin-21", "command": ["mvn", "--batch-mode", "-DskipTests", "package"]},
              "image": "eclipse-temurin:21-jre",
              "network": "default",
              "ports": ["18080:8080"],
              "volumes": ["{{PROJECT_DIR}}/apps/spring-gateway/app.jar:/app/app.jar"],
              "command": ["sh", "-c", "if [ ! -s /app/app.jar ]; then echo 'spring-gateway: app.jar 尚未构建，等待替换'; fi; while [ ! -s /app/app.jar ]; do sleep 10; done; while true; do java -jar /app/app.jar; code=$?; echo spring-gateway: JVM-exit-code=${code}, retrying-in-5s; sleep 5; done"],
              "env": ["SPRING_PROFILES_ACTIVE=dev"],
              "memory": "768M", "dnsRegistration": true, "dependsOn": ["spring-auth", "spring-order"]
            }
          ]
        }
        """
        parseAndApplyMirror()
    }

    /// 在标准 Web 示例之上生成一份独立的高可用模板：三节点 GTID 主从集群由
    /// MaxScale 监控并自动切换，业务侧只持有 db-router 的稳定地址。
    private func loadHighAvailabilitySample() {
        loadSample()
        guard let base = try? templateSvc.parse(from: jsonText) else {
            presentError("无法读取 Web 示例的原始短镜像模板")
            return
        }

        let databaseNames: Set<String> = ["db-primary", "db-replica"]
        var services = base.services.filter { !databaseNames.contains($0.name) }
        let databaseEnvironment = [
            "MARIADB_ROOT_PASSWORD=change-root-password",
            "MARIADB_DATABASE=webapp",
            "MARIADB_USER=webapp",
            "MARIADB_PASSWORD=change-me",
            "DB_REPLICATION_USER=replicator",
            "DB_ROUTER_USER=maxscale",
            "DB_PASSWORD=change-root-password"
        ]
        let primary = ClusterService(
            name: "db-primary", image: "mariadb:11.4",
            env: databaseEnvironment,
            volumes: ["{{PROJECT_DIR}}/.aiguru/data/db-primary/mysql:/var/lib/mysql"],
            cpus: 1, memory: "1G", user: "mysql", role: "database-primary"
        )
        let replica1 = highAvailabilityReplica(name: "db-replica-1", serverID: 2)
        let replica2 = highAvailabilityReplica(name: "db-replica-2", serverID: 3)
        let router = ClusterService(
            name: "db-router", image: "mariadb/maxscale:24.02",
            ports: ["127.0.0.1:13306:3306", "127.0.0.1:13307:3307", "127.0.0.1:18989:8989"],
            env: [
                "DB_PRIMARY_HOST={{CLUSTER_DNS:db-primary}}",
                "DB_REPLICA_1_HOST={{CLUSTER_DNS:db-replica-1}}",
                "DB_REPLICA_2_HOST={{CLUSTER_DNS:db-replica-2}}",
                "DB_PASSWORD=change-root-password"
            ],
            volumes: ["{{PROJECT_DIR}}/infra/mariadb/maxscale-ha.cnf.template:/config/maxscale-ha.cnf.template:ro"],
            cpus: 1, memory: "512M", entrypoint: "/bin/bash",
            command: ["-c", "sed -e \"s|__DB_PRIMARY__|${DB_PRIMARY_HOST}|g\" -e \"s|__DB_REPLICA_1__|${DB_REPLICA_1_HOST}|g\" -e \"s|__DB_REPLICA_2__|${DB_REPLICA_2_HOST}|g\" -e \"s|__DB_PASSWORD__|${DB_PASSWORD}|g\" /config/maxscale-ha.cnf.template > /tmp/maxscale.cnf && exec maxscale -d -U maxscale --config=/tmp/maxscale.cnf"],
            role: "database-router", dependsOn: ["db-primary", "db-replica-1", "db-replica-2"]
        )
        let backup = ClusterService(
            name: "db-backup", image: "mariadb:11.4",
            env: ["DB_ROUTER_HOST={{CLUSTER_DNS:db-router}}", "MARIADB_PWD=change-me"],
            volumes: ["{{PROJECT_DIR}}/backups/mariadb:/backups"], cpus: 1, memory: "256M",
            command: ["sh", "-c", "while true; do until mariadb-admin ping -h \"$DB_ROUTER_HOST\" -uwebapp --silent; do echo waiting-for-db-router; sleep 5; done; stamp=$(date +%Y%m%d-%H%M%S); mariadb-dump -h \"$DB_ROUTER_HOST\" -uwebapp --single-transaction --routines --events webapp | gzip > \"/backups/webapp-${stamp}.sql.gz\"; find /backups -name 'webapp-*.sql.gz' -mtime +7 -delete; sleep 86400; done"],
            role: "database-logical-backup", dependsOn: ["db-router"]
        )
        if let insertion = services.firstIndex(where: { $0.name == "redis-master" }) {
            services.insert(contentsOf: [primary, replica1, replica2, router, backup], at: insertion)
        } else {
            services.append(contentsOf: [primary, replica1, replica2, router, backup])
        }

        let generatedDatabaseServices: Set<String> = [
            "db-primary", "db-replica-1", "db-replica-2", "db-router", "db-backup"
        ]
        for index in services.indices where !generatedDatabaseServices.contains(services[index].name) {
            services[index].env = services[index].env.compactMap(highAvailabilityEnvironment)
            let oldDependencies = services[index].dependsOn
            if oldDependencies.contains(where: databaseNames.contains) {
                services[index].dependsOn = Array(Set(oldDependencies.filter { !databaseNames.contains($0) } + ["db-router"])).sorted()
            }
        }
        let generated = ClusterTemplate(
            name: "web-ha",
            description: "高可用 Web 栈：MariaDB 一主两从、GTID 复制、MaxScale 稳定读写入口与自动故障切换，并保留 7 天逻辑备份；Redis 通过三节点 Sentinel 发现当前主节点。",
            services: services
        )
        sourceTemplate = generated
        template = applyingSelectedRegistry(to: generated)
        deploymentName = generated.name
        jsonText = (try? templateSvc.export(generated)) ?? ""
        errorMessage = nil
    }

    private func highAvailabilityReplica(name: String, serverID: Int) -> ClusterService {
        ClusterService(
            name: name, image: "mariadb:11.4",
            env: [
                "MARIADB_ROOT_PASSWORD=change-root-password", "MARIADB_DATABASE=webapp",
                "MARIADB_USER=webapp", "MARIADB_PASSWORD=change-me",
                "DB_REPLICATION_USER=replicator", "DB_PASSWORD=change-root-password",
                "DB_PRIMARY_HOST={{CLUSTER_DNS:db-primary}}"
            ],
            volumes: ["{{PROJECT_DIR}}/.aiguru/data/\(name)/mysql:/var/lib/mysql"], cpus: 1, memory: "1G", user: "mysql",
            entrypoint: "/bin/sh",
            command: ["-c", "docker-entrypoint.sh mariadbd --server-id=\(serverID) --log-bin=mysql-bin --binlog-format=ROW --relay-log=relay-bin --read-only=ON --gtid-strict-mode=ON --log-slave-updates=ON & pid=$!; until mariadb-admin ping -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" --silent; do kill -0 $pid || exit 1; sleep 2; done; mariadb -h 127.0.0.1 -uroot --password=\"$MARIADB_ROOT_PASSWORD\" -e \"CHANGE MASTER TO MASTER_HOST='${DB_PRIMARY_HOST}', MASTER_USER='${DB_REPLICATION_USER}', MASTER_PASSWORD='${DB_PASSWORD}', MASTER_USE_GTID=slave_pos; START SLAVE;\"; wait $pid"],
            role: "database-replica", dependsOn: ["db-primary"]
        )
    }

    private func highAvailabilityEnvironment(_ value: String) -> String? {
        if value.hasPrefix("DATABASE_URL=") {
            return "DATABASE_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-router}}:3306/webapp"
        }
        if value.hasPrefix("DATABASE_REPLICA_URL=") {
            return "DATABASE_REPLICA_URL=mysql://webapp:change-me@{{CLUSTER_DNS:db-router}}:3307/webapp"
        }
        if value.hasPrefix("SPRING_DATASOURCE_URL=") {
            return "SPRING_DATASOURCE_URL=jdbc:mysql://{{CLUSTER_DNS:db-router}}:3306/webapp"
        }
        if value.hasPrefix("SPRING_REPLICA_URL=") {
            return "SPRING_REPLICA_URL=jdbc:mysql://{{CLUSTER_DNS:db-router}}:3307/webapp"
        }
        if value.hasPrefix("REDIS_URL=") {
            return "REDIS_MODE=sentinel"
        }
        return value
    }

    // MARK: - 镜像注册表前缀
    private func registryPrefix(for image: String) -> String {
        guard let src = imgSrcMgr.currentSource,
              let url = src.url else { return image }
        let reg = url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !reg.isEmpty, !image.hasPrefix(reg + "/") else { return image }
        // `mariadb/maxscale`、`library/node` 是 Docker Hub 命名空间，不是注册表。
        // 只有首段带域名/端口或 localhost 时才视为已经指定了仓库地址。
        if image.contains("/"), let first = image.split(separator: "/").first {
            let component = String(first).lowercased()
            if component == "localhost" || component.contains(".") || component.contains(":") {
                return image
            }
        }
        return "\(reg)/\(image)"
    }

    private func applyingSelectedRegistry(to source: ClusterTemplate) -> ClusterTemplate {
        var result = source
        for index in result.services.indices {
            result.services[index].image = registryPrefix(for: result.services[index].image)
        }
        return result
    }

    private func parseAndApplyMirror() {
        do {
            let source = try templateSvc.parse(from: jsonText)
            let t = applyingSelectedRegistry(to: source)
            sourceTemplate = source
            template = t
            deploymentName = t.name
            errorMessage = nil
        } catch {
            presentError("解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 远程拉取
    private func fetchRemote() {
        let urlString = remoteURL.trimmingCharacters(in: CharacterSet.whitespaces)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            presentError("无效的 URL")
            return
        }
        isFetchingRemote = true
        errorMessage = nil
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                isFetchingRemote = false
                if let error {
                    presentError("拉取失败: \(error.localizedDescription)")
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    presentError("无数据或编码错误")
                    return
                }
                jsonText = text
                do {
                    let source = try templateSvc.parse(from: data)
                    let t = applyingSelectedRegistry(to: source)
                    sourceTemplate = source
                    template = t
                    deploymentName = t.name
                    errorMessage = nil
                } catch {
                    presentError("解析失败: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    // MARK: - 本地文件加载
    private func loadTemplate(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            jsonText = String(data: data, encoding: .utf8) ?? ""
            let source = try templateSvc.parse(from: data)
            let t = applyingSelectedRegistry(to: source)
            sourceTemplate = source
            template = t
            deploymentName = t.name
            errorMessage = nil
        } catch {
            presentError("解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 批量创建
    private func exportTemplate(_ template: ClusterTemplate) {
        do {
            exportDocument = ApplicationClusterTemplateDocument(text: try templateSvc.export(sourceTemplate ?? template))
            showFileExporter = true
        } catch {
            presentError("导出失败: \(error.localizedDescription)")
        }
    }

    private func createDeploymentInstance(
        service: ClusterService,
        template: ClusterTemplate,
        deploymentName: String,
        ordinal: Int,
        dnsDomain: String?,
        projectDirectory: String
    ) async throws {
        let containerName = templateSvc.deploymentContainerName(
            clusterName: deploymentName,
            serviceName: service.name,
            ordinal: ordinal
        )
        var labels = [
            "cc.aiguru.application-cluster": deploymentName,
            "cc.aiguru.application-service": service.name,
            "cc.aiguru.application-ordinal": String(ordinal),
            "cc.aiguru.template-api-version": template.apiVersion,
            "cc.aiguru.application-project-directory": canonicalProjectDirectory(projectDirectory),
            "cc.aiguru.application-service-config": serviceConfigurationFingerprint(service)
        ]
        if let role = service.role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            labels["cc.aiguru.application-role"] = role
        }
        if !service.dependsOn.isEmpty {
            labels[AppConstants.ContainerLabel.applicationDependsOn] = service.dependsOn.joined(separator: ",")
        }
        let resolvedEnvironment = templateSvc.resolveEnvironment(
            service.env, clusterName: deploymentName, dnsDomain: dnsDomain, variables: template.variables
        )
        let upstreams = template.services.map(\.name).filter { candidate in
            candidate != service.name && resolvedEnvironment.contains(where: {
                $0.localizedCaseInsensitiveContains(candidate)
            })
        }
        if !upstreams.isEmpty {
            labels[AppConstants.ContainerLabel.applicationUpstreams] = upstreams.joined(separator: ",")
        }
        if let preparation = service.preDeploy {
            let artifactURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
                .appendingPathComponent(preparation.context, isDirectory: true)
                .appendingPathComponent(preparation.output)
            labels["cc.aiguru.application-artifact-state"] = isRunnableJar(artifactURL) ? "ready" : "waiting"
        }
        if let dnsDomain {
            labels["cc.aiguru.application-dns-name"] = templateSvc.deploymentDNSName(
                clusterName: deploymentName, serviceName: service.name, ordinal: ordinal, domain: dnsDomain
            )
        }
        let options = ContainerRunOptions(
            detach: service.detach,
            interactive: service.interactive,
            tty: service.tty,
            cpus: service.cpus.map { "\($0)" },
            memory: templateSvc.runtimeSafeMemory(service.memory),
            entrypoint: service.entrypoint,
            workdir: service.workdir,
            user: service.user,
            initProcess: service.initProcess,
            readOnly: service.readOnly,
            network: service.network,
            labels: labels,
            sshForward: service.sshForward,
            command: templateSvc.resolveEnvironment(
                service.command, clusterName: deploymentName, dnsDomain: dnsDomain, variables: template.variables
            )
        )
        let resolvedVolumes = templateSvc.resolveVolumes(
            service.volumes,
            projectDirectory: projectDirectory,
            clusterName: deploymentName,
            serviceName: service.name,
            ordinal: ordinal
        )
        try await VolumeManager.shared.ensureNamedVolumes(
            for: resolvedVolumes,
            clusterName: deploymentName,
            serviceName: service.name
        )
        _ = try await ContainerManager.shared.createContainer(
            name: containerName,
            image: service.image,
            detach: service.detach,
            ports: service.ports,
            env: resolvedEnvironment,
            volumes: resolvedVolumes,
            options: options
        )
        try await waitForServiceReadiness(
            service: service,
            containerName: containerName,
            template: template,
            deploymentName: deploymentName,
            dnsDomain: dnsDomain
        )
    }

    /// `run -d` 成功只表示容器已创建。依赖门控必须等到显式探针成功；旧模板至少要求稳定 Running。
    private func waitForServiceReadiness(
        service: ClusterService,
        containerName: String,
        template: ClusterTemplate,
        deploymentName: String,
        dnsDomain: String?
    ) async throws {
        let probe = service.readiness
        let timeout = TimeInterval(probe?.timeoutSeconds ?? 3600)
        let interval = UInt64(probe?.intervalSeconds ?? 1) * 1_000_000_000
        let requiredSuccesses = probe?.successThreshold ?? 3
        let deadline = Date().addingTimeInterval(timeout)
        let resolvedCommand = templateSvc.resolveEnvironment(
            probe?.command ?? [], clusterName: deploymentName, dnsDomain: dnsDomain, variables: template.variables
        )
        var consecutiveSuccesses = 0
        var consecutiveTerminalStates = 0

        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let listOutput = try await ContainerManager.shared.executor.execute(
                    CLICommandCatalog.shared.arguments(command: "container.list", options: ["all": ["true"], "format": ["json"]])
                )
                guard let data = listOutput.data(using: .utf8),
                      let containers = try? JSONDecoder().decode([Container].self, from: data),
                      let container = containers.first(where: { $0.displayName == containerName }) else {
                    consecutiveSuccesses = 0
                    consecutiveTerminalStates = 0
                    try await Task.sleep(nanoseconds: interval)
                    continue
                }
                if [.stopped, .exited, .dead].contains(container.state) {
                    consecutiveSuccesses = 0
                    consecutiveTerminalStates += 1
                    if consecutiveTerminalStates >= 3 {
                        let logs = (try? await ContainerManager.shared.executor.execute(
                            CLICommandCatalog.shared.arguments(
                                command: "container.logs", options: ["tail": ["80"]], positionals: [containerName]
                            )
                        )) ?? "无法读取容器日志"
                        throw ServiceReadinessFailure.terminal(
                            "服务 \(service.name) 已退出（\(container.state.rawValue)），不会继续等待：\n\(logs)"
                        )
                    }
                    try await Task.sleep(nanoseconds: interval)
                    continue
                }
                guard container.state == .running else {
                    consecutiveSuccesses = 0
                    consecutiveTerminalStates = 0
                    try await Task.sleep(nanoseconds: interval)
                    continue
                }
                consecutiveTerminalStates = 0
                if !resolvedCommand.isEmpty {
                    _ = try await ContainerManager.shared.executor.execute(
                        CLICommandCatalog.shared.arguments(command: "container.exec", positionals: [containerName] + resolvedCommand),
                        timeout: TimeInterval(min(15, probe?.intervalSeconds ?? 2) + 5)
                    )
                }
                consecutiveSuccesses += 1
                if consecutiveSuccesses >= requiredSuccesses { return }
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as ServiceReadinessFailure {
                // 容器已连续处于终止状态时，立即结束部署。这类确定性失败
                // 不能落入下方的探针重试逻辑，否则 UI 会假性“卡死”直到一小时超时。
                throw failure
            } catch {
                consecutiveSuccesses = 0
            }
            try await Task.sleep(nanoseconds: interval)
        }
        let detail = probe == nil ? "未能连续保持 Running" : "readiness probe 未达到连续成功阈值"
        throw ContainerError.commandFailed("服务 \(service.name)（\(containerName)）在 \(Int(timeout)) 秒内未就绪：\(detail)")
    }

    private func retryFailedContainer(_ service: ClusterService, template: ClusterTemplate, ordinal: Int) {
        let name = templateSvc.deploymentContainerName(clusterName: deploymentName, serviceName: service.name, ordinal: ordinal)
        guard case .success(let dnsDomain) = templateSvc.validateDNSRegistration(template, configuredDomain: configuredDNSDomain) else {
            presentError("当前 DNS 配置不满足重试条件")
            return
        }
        guard let fullOrder = templateSvc.deploymentOrder(template) else {
            presentError("模板依赖存在循环，无法生成重试顺序")
            return
        }
        let requiredNames = transitiveDependencies(of: service.name, template: template).union([service.name])
        let recoveryOrder = fullOrder.filter { requiredNames.contains($0.name) }
        let recoveryInstances = recoveryOrder.flatMap { candidate -> [(ClusterService, Int)] in
            let ordinals = candidate.name == service.name ? [ordinal] : Array(1...candidate.replicas)
            return ordinals.map { (candidate, $0) }
        }
        let recoveryContainerNames = Set(recoveryInstances.map {
            templateSvc.deploymentContainerName(clusterName: deploymentName, serviceName: $0.0.name, ordinal: $0.1)
        })
        guard retryingContainerNames.isDisjoint(with: recoveryContainerNames) else { return }
        retryingContainerNames.formUnion(recoveryContainerNames)
        applyProgress = "按依赖顺序恢复 \(name)…"
        for recoveryName in recoveryContainerNames { deploymentStates[recoveryName] = .deploying }
        Task {
            defer {
                Task { @MainActor in
                    retryingContainerNames.subtract(recoveryContainerNames)
                    if retryingContainerNames.isEmpty { applyProgress = "" }
                }
            }
            do {
                await ContainerManager.shared.fetchContainers()
                let initialContainers = await MainActor.run { ContainerManager.shared.containers }
                let allDeploymentContainers = initialContainers.filter {
                    $0.labels?["cc.aiguru.application-cluster"] == deploymentName
                }
                let projectMatches = isSameDeploymentProject(
                    allDeploymentContainers,
                    template: template,
                    deploymentName: deploymentName,
                    projectDirectory: canonicalProjectDirectory(projectDirectory)
                )

                for (candidate, candidateOrdinal) in recoveryInstances {
                    try Task.checkCancellation()
                    let candidateName = templateSvc.deploymentContainerName(
                        clusterName: deploymentName, serviceName: candidate.name, ordinal: candidateOrdinal
                    )
                    await MainActor.run { applyProgress = "依赖恢复：检查 \(candidateName)" }
                    await ContainerManager.shared.fetchContainers()
                    let existing = await MainActor.run {
                        ContainerManager.shared.containers.first { $0.displayName == candidateName }
                    }
                    if let existing {
                        guard isSameDeploymentInstance(
                            existing,
                            service: candidate,
                            deploymentName: deploymentName,
                            ordinal: candidateOrdinal,
                            projectDirectory: canonicalProjectDirectory(projectDirectory),
                            deploymentProjectMatches: projectMatches
                        ) else {
                            throw ContainerError.commandFailed("现有容器 \(candidateName) 不属于当前应用目录")
                        }
                        if existing.state == .running {
                            do {
                                try await waitForServiceReadiness(
                                    service: candidate, containerName: candidateName, template: template,
                                    deploymentName: deploymentName, dnsDomain: dnsDomain
                                )
                                await MainActor.run { deploymentStates[candidateName] = .success }
                                continue
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // 单个节点总等待上限为一小时；不能等待一小时后重建并再次等待一小时。
                                throw error
                            }
                        }
                        _ = try await ContainerManager.shared.executor.execute(
                            CLICommandCatalog.shared.arguments(command: "container.delete", options: ["force": ["true"]], positionals: [existing.id])
                        )
                    }
                    await MainActor.run { applyProgress = "依赖恢复：部署 \(candidateName)" }
                    try await createDeploymentInstance(
                        service: candidate, template: template, deploymentName: deploymentName,
                        ordinal: candidateOrdinal, dnsDomain: dnsDomain, projectDirectory: projectDirectory
                    )
                    await MainActor.run { deploymentStates[candidateName] = .success }
                }
                await MainActor.run {
                    applyProgress = "依赖链已按顺序恢复，容器 \(name) 就绪"
                    ToastManager.shared.showSuccess("容器「\(name)」及其依赖已恢复")
                }
            } catch {
                await MainActor.run {
                    applyProgress = "容器 \(name) 重试失败"
                    deploymentStates[name] = .failure(error.localizedDescription)
                    presentError("容器「\(name)」重试失败: \(error.localizedDescription)")
                }
            }
        }
    }

    private func transitiveDependencies(of serviceName: String, template: ClusterTemplate) -> Set<String> {
        let services = Dictionary(uniqueKeysWithValues: template.services.map { ($0.name, $0) })
        var result = Set<String>()
        func visit(_ name: String) {
            guard let service = services[name] else { return }
            for dependency in service.dependsOn where result.insert(dependency).inserted {
                visit(dependency)
            }
        }
        visit(serviceName)
        return result
    }

    private func cancelDeployment() {
        guard isApplying else { return }
        isCancellationRequested = true
        deploymentTask?.cancel()
        applyProgress = "已请求取消：当前容器操作结束后将停止后续部署"
        ToastManager.shared.showInfo("已请求取消部署")
    }

    private func applyTemplate(_ sourceTemplate: ClusterTemplate, deploymentName: String) {
        let migration = templateSvc.migratingLegacyStatefulBindMounts(sourceTemplate)
        let t = migration.template
        if !migration.migrated.isEmpty {
            TaskManager.shared.appendOutput("[模板兼容迁移] 实名卷已转换为项目目录挂载：")
            for item in migration.migrated { TaskManager.shared.appendOutput("  \(item)") }
            ToastManager.shared.showInfo("已将 \(migration.migrated.count) 个实名卷转换为项目数据目录")
        }
        switch templateSvc.validate(t) {
        case .failure(let err):
            presentError(err.localizedDescription)
            return
        case .success: break
        }

        let needsProjectResources = t.services.contains { service in
            service.preDeploy != nil || service.volumes.contains(where: { $0.contains("{{PROJECT_DIR}}") })
        }
        if needsProjectResources {
            do {
                _ = try TemplateMountScaffold.generate(for: t, in: projectDirectory)
            } catch {
                presentError("按模板生成挂载资源失败: \(error.localizedDescription)")
                return
            }
        }

        switch templateSvc.validateHostPaths(t, projectDirectory: projectDirectory) {
        case .success: break
        case .failure(let err):
            presentError(err.localizedDescription)
            return
        }

        switch templateSvc.validateNamedVolumeAttachments(
            t,
            clusterName: deploymentName,
            projectDirectory: projectDirectory
        ) {
        case .success: break
        case .failure(let err):
            presentError(err.localizedDescription)
            return
        }

        let dnsDomain: String?
        switch templateSvc.validateDNSRegistration(t, configuredDomain: configuredDNSDomain) {
        case .success(let domain):
            dnsDomain = domain
        case .failure(let err):
            presentError(err.localizedDescription)
            return
        }

        guard let orderedServices = templateSvc.deploymentOrder(t) else {
            presentError("服务依赖存在循环，无法部署")
            return
        }
        let manager = ContainerManager.shared
        let selectedProjectDirectory = canonicalProjectDirectory(projectDirectory)
        let plannedNames = Set(orderedServices.flatMap { service in
            (1...service.replicas).map {
                templateSvc.deploymentContainerName(clusterName: deploymentName, serviceName: service.name, ordinal: $0)
            }
        })
        isApplying = true; createdCount = 0; errorMessage = nil; deploymentResult = nil; isCancellationRequested = false
        let totalInstances = orderedServices.reduce(0) { $0 + $1.replicas }
        deploymentStates = Dictionary(uniqueKeysWithValues: plannedNames.map { ($0, .idle) })

        deploymentTask = Task {
            var errors: [String] = []
            var wasCancelled = false
            do {
                try await prepareDeclaredArtifacts(template: t, projectDirectory: selectedProjectDirectory)
            } catch {
                await MainActor.run {
                    isApplying = false
                    applyProgress = ""
                    deploymentTask = nil
                    presentError("部署前准备失败: \(error.localizedDescription)")
                }
                return
            }
            await manager.fetchContainers()
            let existingContainers = await MainActor.run { manager.containers }
            let existingByName = Dictionary(uniqueKeysWithValues: existingContainers.map { ($0.displayName, $0) })
            let existingPlannedContainers = existingContainers.filter { plannedNames.contains($0.displayName) }
            let projectMatches = isSameDeploymentProject(
                existingPlannedContainers,
                template: t,
                deploymentName: deploymentName,
                projectDirectory: selectedProjectDirectory
            )
            var skippedNames = Set<String>()
            var rebuildByName: [String: Container] = [:]

            if !existingPlannedContainers.isEmpty, !projectMatches {
                await MainActor.run {
                    isApplying = false
                    applyProgress = ""
                    deploymentTask = nil
                    presentError("检测到同名部署，但现有容器的项目挂载与当前应用目录不一致，已停止续建。")
                }
                return
            }

            for service in orderedServices {
                for ordinal in 1...service.replicas {
                    let name = templateSvc.deploymentContainerName(
                        clusterName: deploymentName, serviceName: service.name, ordinal: ordinal
                    )
                    guard let existing = existingByName[name] else { continue }
                    guard isSameDeploymentInstance(
                        existing,
                        service: service,
                        deploymentName: deploymentName,
                        ordinal: ordinal,
                        projectDirectory: selectedProjectDirectory,
                        deploymentProjectMatches: projectMatches
                    ) else {
                        await MainActor.run {
                            isApplying = false
                            applyProgress = ""
                            deploymentTask = nil
                            presentError("容器「\(name)」与当前部署名称或应用目录不匹配，已停止续建以避免覆盖。")
                        }
                        return
                    }
                    let artifactReady = service.preDeploy == nil
                        || existing.labels?["cc.aiguru.application-artifact-state"] == "ready"
                    let configurationMatches = existing.labels?["cc.aiguru.application-service-config"]
                        == serviceConfigurationFingerprint(service)
                    if existing.state == .running, artifactReady, configurationMatches {
                        skippedNames.insert(name)
                    } else {
                        rebuildByName[name] = existing
                    }
                }
            }
            await MainActor.run {
                for name in skippedNames { deploymentStates[name] = .skipped }
                createdCount = skippedNames.count
            }

            deploymentLoop: for service in orderedServices {
                // 依赖只决定尝试顺序。某个容器创建后若应用启动失败，
                // 仍继续部署后续服务，使用户可以一次完成其余安装并分别重试失败项。
                for ordinal in 1...service.replicas {
                    if Task.isCancelled {
                        wasCancelled = true
                        break deploymentLoop
                    }
                    let containerName = templateSvc.deploymentContainerName(
                        clusterName: deploymentName,
                        serviceName: service.name,
                        ordinal: ordinal
                    )
                    if skippedNames.contains(containerName) {
                        do {
                            try await waitForServiceReadiness(
                                service: service, containerName: containerName, template: t,
                                deploymentName: deploymentName, dnsDomain: dnsDomain
                            )
                            await MainActor.run {
                                applyProgress = "复检并跳过已就绪实例 \(containerName)（\(createdCount)/\(totalInstances)）"
                            }
                        } catch {
                            errors.append("\(containerName): 已有实例未就绪 — \(error.localizedDescription)")
                            await MainActor.run { deploymentStates[containerName] = .failure(error.localizedDescription) }
                        }
                        continue
                    }
                    await MainActor.run {
                        applyProgress = "部署 \(service.name) #\(ordinal)... (\(createdCount + 1)/\(totalInstances))"
                        deploymentStates[containerName] = .deploying
                    }
                    do {
                        if let existing = rebuildByName[containerName] {
                            _ = try await manager.executor.execute(CLICommandCatalog.shared.arguments(command: "container.delete", options: ["force": ["true"]], positionals: [existing.id]))
                        }
                        try await createDeploymentInstance(
                            service: service,
                            template: t,
                            deploymentName: deploymentName,
                            ordinal: ordinal,
                            dnsDomain: dnsDomain,
                            projectDirectory: selectedProjectDirectory
                        )
                        await MainActor.run {
                            createdCount += 1
                            deploymentStates[containerName] = .success
                        }
                    } catch {
                        errors.append("\(containerName): \(error.localizedDescription)")
                        await MainActor.run {
                            deploymentStates[containerName] = .failure(error.localizedDescription)
                        }
                    }
                }
            }
            await MainActor.run {
                isApplying = false; applyProgress = ""; deploymentTask = nil
                if wasCancelled || isCancellationRequested {
                    for (name, state) in deploymentStates {
                        if case .idle = state { deploymentStates[name] = .cancelled }
                    }
                    deploymentResult = "⚠️ 已取消，已完成或跳过 \(createdCount)/\(totalInstances)"
                    ToastManager.shared.showInfo("应用集群部署已取消")
                } else if !errors.isEmpty {
                    presentError("\(createdCount)/\(totalInstances) 成功或跳过。失败: \(errors.joined(separator: "; "))")
                    deploymentResult = "⚠️ 部分服务部署失败"
                } else {
                    deploymentResult = "✅ 已完成 \(totalInstances) 个实例（跳过 \(skippedNames.count) 个）"
                    ToastManager.shared.showSuccess("应用集群「\(deploymentName)」续建完成")
                }
            }
        }
    }

    private func canonicalProjectDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func prepareDeclaredArtifacts(
        template: ClusterTemplate,
        projectDirectory: String
    ) async throws {
        let mavenConfiguration = try prepareMavenBuildConfiguration(projectDirectory: projectDirectory)
        for service in template.services {
            guard let preparation = service.preDeploy else { continue }
            guard preparation.kind == "maven-spring-boot" else {
                setArtifactState(.artifactFailure("不支持准备类型 \(preparation.kind)"), for: service)
                throw ContainerError.commandFailed("\(service.name) 使用了不支持的 preDeploy 类型：\(preparation.kind)")
            }
            let serviceDirectory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
                .appendingPathComponent(preparation.context, isDirectory: true)
            let artifactURL = serviceDirectory.appendingPathComponent(preparation.output)
            if isRunnableJar(artifactURL) {
                setArtifactState(.artifactReady, for: service)
                continue
            }
            let pomURL = serviceDirectory.appendingPathComponent("pom.xml")
            guard FileManager.default.fileExists(atPath: pomURL.path) else {
                setArtifactState(.artifactFailure("缺少 pom.xml"), for: service)
                throw ContainerError.commandFailed("\(service.name) 缺少 pom.xml，请先生成项目挂载资源")
            }
            await MainActor.run {
                applyProgress = preparation.title ?? "准备 \(service.name) 部署产物…"
                TaskManager.shared.appendOutput("[部署前准备] \(preparation.title ?? service.name)")
            }
            setArtifactState(.preparingArtifact(preparation.title ?? "准备部署产物…"), for: service)
            let arguments = CLICommandCatalog.shared.arguments(
                command: "container.run",
                options: [
                    "rm": ["true"],
                    "volume": [
                        "\(serviceDirectory.path):/workspace",
                        "\(mavenConfiguration.repositoryDirectory):/root/.m2/repository",
                        "\(mavenConfiguration.settingsFile):/root/.m2/settings.xml:ro"
                    ],
                    "workdir": ["/workspace"]
                ],
                positionals: [preparation.image] + preparation.command
            )
            do {
                _ = try await CommandExecutor.shared.execute(
                    arguments,
                    timeout: AppConstants.Time.streamingCommandTimeout,
                    progressHandler: { line in
                        Task { @MainActor in TaskManager.shared.appendOutput("[\(service.name)] \(line)") }
                    }
                )
            } catch {
                // Apple Container 的临时 --rm 构建容器偶尔在产物已经完整落盘后
                // 仍返回 XPC/清理阶段错误。最终产物有效时继续，避免误报构建失败。
                guard await waitForRunnableJar(artifactURL) else {
                    setArtifactState(.artifactFailure(error.localizedDescription), for: service)
                    throw error
                }
                await MainActor.run {
                    TaskManager.shared.appendOutput("[\(service.name)] 准备容器返回异常，但最终产物已验证，继续部署")
                }
            }
            guard isRunnableJar(artifactURL) else {
                setArtifactState(.artifactFailure("未生成有效产物 \(preparation.output)"), for: service)
                throw ContainerError.commandFailed("\(service.name) 准备命令完成，但未生成有效 \(preparation.output)")
            }
            setArtifactState(.artifactReady, for: service)
        }
    }

    @MainActor
    private func setArtifactState(_ state: DeploymentInstanceState, for service: ClusterService) {
        for ordinal in 1...service.replicas {
            let name = templateSvc.deploymentContainerName(
                clusterName: deploymentName,
                serviceName: service.name,
                ordinal: ordinal
            )
            deploymentStates[name] = state
        }
    }

    private func prepareMavenBuildConfiguration(projectDirectory: String) throws -> (settingsFile: String, repositoryDirectory: String) {
        let configurationDirectory = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".aiguru/maven", isDirectory: true)
        let repositoryDirectory = configurationDirectory.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryDirectory, withIntermediateDirectories: true)

        let selectedMirror = MavenRepositoryMirror(rawValue: mavenRepositoryMirror) ?? .official
        let mirrorXML: String
        if let url = selectedMirror.url {
            mirrorXML = """
              <mirrors>
                <mirror>
                  <id>\(selectedMirror.id)</id>
                  <name>\(selectedMirror.title)</name>
                  <url>\(url)</url>
                  <mirrorOf>*</mirrorOf>
                </mirror>
              </mirrors>
            """
        } else {
            mirrorXML = "  <mirrors />"
        }
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
                  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                  xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 https://maven.apache.org/xsd/settings-1.0.0.xsd">
        \(mirrorXML)
        </settings>
        """
        let settingsFile = configurationDirectory.appendingPathComponent("settings.xml")
        try Data(settings.utf8).write(to: settingsFile, options: .atomic)
        return (settingsFile.path, repositoryDirectory.path)
    }

    private func waitForRunnableJar(_ url: URL) async -> Bool {
        for _ in 0..<10 {
            if isRunnableJar(url) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func isRunnableJar(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 4,
              size.int64Value > 1_024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) else { return false }
        // ZIP/JAR 中的中央目录文件名未压缩，可据此区分普通 JAR 与
        // spring-boot-maven-plugin 重打包后的可执行 Boot JAR。
        let bootClasses = Data("BOOT-INF/classes/".utf8)
        let bootLoader = Data("org/springframework/boot/loader/launch/JarLauncher.class".utf8)
        return data.range(of: bootClasses) != nil && data.range(of: bootLoader) != nil
    }

    private func isSameDeploymentInstance(
        _ container: Container,
        service: ClusterService,
        deploymentName: String,
        ordinal: Int,
        projectDirectory: String,
        deploymentProjectMatches: Bool = true
    ) -> Bool {
        let labels = container.labels ?? [:]
        guard labels["cc.aiguru.application-cluster"] == deploymentName,
              labels["cc.aiguru.application-service"] == service.name,
              labels["cc.aiguru.application-ordinal"] == String(ordinal),
              container.image == service.image else { return false }

        if let recorded = labels["cc.aiguru.application-project-directory"] {
            return canonicalProjectDirectory(recorded) == projectDirectory
        }
        return deploymentProjectMatches
    }

    /// 用稳定摘要判断模板服务定义是否变化。已有容器没有该标签时会在续建时重建一次，
    /// 后续仅重建配置发生变化的服务，仍保留成功容器跳过部署的能力。
    private func serviceConfigurationFingerprint(_ service: ClusterService) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(service)) ?? Data(service.name.utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func isSameDeploymentProject(
        _ containers: [Container],
        template: ClusterTemplate,
        deploymentName: String,
        projectDirectory: String
    ) -> Bool {
        guard !containers.isEmpty else { return true }
        let recordedDirectories = Set(containers.compactMap {
            $0.labels?["cc.aiguru.application-project-directory"].map(canonicalProjectDirectory)
        })
        guard recordedDirectories.isEmpty || recordedDirectories == [projectDirectory] else { return false }
        let hasRecordedDirectory = !recordedDirectories.isEmpty

        var servicesByName: [String: ClusterService] = [:]
        for service in template.services {
            guard servicesByName[service.name] == nil else { return false }
            servicesByName[service.name] = service
        }
        var verifiedProjectMount = false
        for container in containers {
            guard container.labels?["cc.aiguru.application-cluster"] == deploymentName,
                  let serviceName = container.labels?["cc.aiguru.application-service"],
                  let service = servicesByName[serviceName] else { return false }
            let expected = expectedProjectMounts(
                service: service,
                deploymentName: deploymentName,
                projectDirectory: projectDirectory
            )
            guard !expected.isEmpty else { continue }
            let actualProjectSources = (container.mounts ?? [])
                .map { canonicalProjectDirectory($0.source) }
                .filter { $0 == projectDirectory || $0.hasPrefix(projectDirectory + "/") }
            // 模板升级可能调整某一个配置文件名；项目身份只由真实 bind mount 的
            // 根目录决定，具体挂载差异交给实例配置/续建流程处理。
            guard !actualProjectSources.isEmpty else { return false }
            verifiedProjectMount = true
        }
        return hasRecordedDirectory || verifiedProjectMount
    }

    private func expectedProjectMounts(
        service: ClusterService,
        deploymentName: String,
        projectDirectory: String
    ) -> Set<String> {
        Set(templateSvc.resolveVolumes(
            service.volumes,
            projectDirectory: projectDirectory,
            clusterName: deploymentName,
            serviceName: service.name
        ).compactMap { specification -> String? in
            let parts = specification.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2,
                  parts[0].hasPrefix(projectDirectory + "/") || String(parts[0]) == projectDirectory else { return nil }
            return "\(canonicalProjectDirectory(String(parts[0])))\u{0}\(parts[1])"
        })
    }
}

private enum MavenRepositoryMirror: String, CaseIterable, Identifiable {
    case official
    case aliyun
    case tencent
    case huawei

    var id: String { rawValue }

    var title: String {
        switch self {
        case .official: return "Maven Central（官方）"
        case .aliyun: return "阿里云 Maven"
        case .tencent: return "腾讯云 Maven"
        case .huawei: return "华为云 Maven"
        }
    }

    var url: String? {
        switch self {
        case .official: return nil
        case .aliyun: return "https://maven.aliyun.com/repository/public"
        case .tencent: return "https://mirrors.cloud.tencent.com/nexus/repository/maven-public/"
        case .huawei: return "https://repo.huaweicloud.com/repository/maven/"
        }
    }

    var detail: String { url ?? "https://repo.maven.apache.org/maven2/" }
}

private enum ServiceReadinessFailure: LocalizedError {
    case terminal(String)

    var errorDescription: String? {
        switch self {
        case .terminal(let message): return message
        }
    }
}

private enum DeploymentInstanceState {
    case idle
    case preparingArtifact(String)
    case artifactReady
    case artifactFailure(String)
    case deploying
    case success
    case skipped
    case failure(String)
    case cancelled

    var title: String {
        switch self {
        case .idle: return "等待部署"
        case .preparingArtifact(let progress): return progress
        case .artifactReady: return "部署产物已就绪"
        case .artifactFailure(let message): return "部署前准备失败：\(message)"
        case .deploying: return "部署中"
        case .success: return "成功"
        case .skipped: return "已存在，跳过"
        case .failure(let message): return message
        case .cancelled: return "已取消"
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .preparingArtifact: return "arrow.down.circle"
        case .artifactReady: return "checkmark.seal.fill"
        case .artifactFailure: return "exclamationmark.triangle.fill"
        case .deploying: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .skipped: return "forward.end.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .success, .skipped, .artifactReady: return .green
        case .failure, .artifactFailure: return .red
        case .deploying, .preparingArtifact: return .blue
        case .cancelled: return .orange
        case .idle: return .secondary
        }
    }

    var backgroundColor: Color {
        switch self {
        case .success, .skipped, .artifactReady: return .green.opacity(0.09)
        case .failure, .artifactFailure: return .red.opacity(0.09)
        case .deploying, .preparingArtifact: return .blue.opacity(0.07)
        case .cancelled: return .orange.opacity(0.08)
        case .idle: return .clear
        }
    }
}

/// `.aigurucluster.json` 本质为 UTF-8 JSON，便于在 Git 中版本管理与团队共享。
struct ApplicationClusterTemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
