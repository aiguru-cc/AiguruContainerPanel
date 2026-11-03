import SwiftUI

struct TemplateGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templateName: String
    @State private var templateDescription: String
    @State private var services: [ClusterService]
    @State private var selectedServiceID: UUID?
    @State private var draft = ServiceDraft()
    @State private var preset: ServicePreset = .nginx
    @State private var showBlockingAlert = false

    let onUse: (ClusterTemplate) -> Void
    private let manager = ClusterTemplateManager.shared

    init(template: ClusterTemplate?, onUse: @escaping (ClusterTemplate) -> Void) {
        _templateName = State(initialValue: template?.name ?? "my-application")
        _templateDescription = State(initialValue: template?.description ?? "")
        _services = State(initialValue: template?.services ?? [])
        _selectedServiceID = State(initialValue: template?.services.first?.id)
        if let service = template?.services.first {
            _draft = State(initialValue: ServiceDraft(service))
        }
        self.onUse = onUse
    }

    private var generatedTemplate: ClusterTemplate {
        ClusterTemplate(
            name: templateName.trimmingCharacters(in: .whitespacesAndNewlines),
            description: templateDescription.nilIfBlank,
            services: effectiveServices
        )
    }

    /// 右侧审查直接使用尚未点击“保存服务”的当前表单，做到输入时即时反馈。
    private var effectiveServices: [ClusterService] {
        guard let selectedServiceID else { return services }
        return services.map { stored in
            guard stored.id == selectedServiceID else { return stored }
            var current = draft.service()
            current.id = stored.id
            return current
        }
    }

    private var diagnostics: [ClusterTemplateDiagnostic] { manager.diagnostics(for: generatedTemplate) }
    private var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                serviceLibrary.frame(minWidth: 210, idealWidth: 235, maxWidth: 280)
                serviceEditor.frame(minWidth: 440, idealWidth: 560)
                diagnosticsPanel.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            }
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 680)
        .alert("模板仍有阻断问题", isPresented: $showBlockingAlert) {
            Button("返回修改", role: .cancel) {}
        } message: {
            Text("请先处理右侧标记为“错误”的项目，再将模板载入部署页。")
        }
        .onChange(of: selectedServiceID) { _, id in
            guard let service = services.first(where: { $0.id == id }) else { return }
            draft = ServiceDraft(service)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("模板生成器", systemImage: "wand.and.stars")
                .font(.headline)
            TextField("模板名称", text: $templateName).frame(width: 190)
            TextField("用途说明（可选）", text: $templateDescription)
            Spacer()
            Text("\(services.count) 个服务")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
    }

    private var serviceLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务与预设").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Picker("", selection: $preset) {
                    ForEach(ServicePreset.allCases) { item in Text(item.title).tag(item) }
                }
                .labelsHidden()
                Button { addPreset() } label: { Image(systemName: "plus") }
                    .help("将所选预设加入模板")
            }
            List(selection: $selectedServiceID) {
                ForEach(services) { service in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name).font(.callout.weight(.medium))
                        Text(service.image).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(service.id)
                    .contextMenu {
                        Button("复制") { duplicate(service) }
                        Button("删除", role: .destructive) { remove(service.id) }
                    }
                }
                .onDelete { offsets in remove(offsets) }
                .onMove { source, destination in services.move(fromOffsets: source, toOffset: destination) }
            }
            HStack {
                Button { moveSelected(-1) } label: { Image(systemName: "arrow.up") }.disabled(!canMoveSelected(-1))
                Button { moveSelected(1) } label: { Image(systemName: "arrow.down") }.disabled(!canMoveSelected(1))
                Spacer()
                Button(role: .destructive) {
                    if let selectedServiceID { remove(selectedServiceID) }
                } label: { Image(systemName: "trash") }
                .disabled(selectedServiceID == nil)
            }
            Text("拖动或使用箭头调整声明顺序；实际创建顺序由依赖关系自动计算。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder private var serviceEditor: some View {
        if selectedServiceID == nil {
            ContentUnavailableView("选择或添加服务", systemImage: "shippingbox", description: Text("常用预设可继续修改；“自定义”提供完整字段。"))
        } else {
            Form {
                Section("基本信息") {
                    LabeledContent("服务名") { TextField("api", text: $draft.name) }
                    LabeledContent("业务角色") { TextField("api / database / gateway", text: $draft.role) }
                    LabeledContent("镜像") { TextField("registry/image:tag", text: $draft.image) }
                    LabeledContent("网络") { TextField("default", text: $draft.network) }
                    LabeledContent("副本") { Stepper("\(draft.replicas)", value: $draft.replicas, in: 1...20) }
                    HStack {
                        Toggle("后台运行", isOn: $draft.detach)
                        Toggle("注册 DNS", isOn: $draft.dnsRegistration)
                        Toggle("init", isOn: $draft.initProcess)
                        Toggle("只读根文件系统", isOn: $draft.readOnly)
                        Toggle("SSH Agent", isOn: $draft.sshForward)
                    }
                }
                Section("资源与进程") {
                    LabeledContent("CPU") { TextField("1", text: $draft.cpus).frame(width: 100) }
                    LabeledContent("内存") { TextField("256M", text: $draft.memory).frame(width: 140) }
                    LabeledContent("工作目录") { TextField("/app", text: $draft.workdir) }
                    LabeledContent("用户") { TextField("可选", text: $draft.user) }
                    LabeledContent("入口点") { TextField("可选", text: $draft.entrypoint) }
                    multiLineField("命令参数", hint: "每行一个参数；需要 shell 时：sh、-c、实际命令", text: $draft.command)
                }
                Section("连接与存储") {
                    multiLineField("端口", hint: "每行一项，例如 127.0.0.1:8080:80/tcp", text: $draft.ports)
                    multiLineField("环境变量", hint: "KEY=value；可使用 {{CLUSTER_DNS:服务名}}", text: $draft.environment)
                    multiLineField("挂载", hint: "统一使用 {{PROJECT_DIR}}/infra/<组件>/<服务>/data:/container/path[:ro]", text: $draft.volumes)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("依赖服务").font(.caption).foregroundStyle(.secondary)
                        if dependencyCandidates.isEmpty {
                            Text("模板中暂无其它服务").font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(dependencyCandidates, id: \.self) { name in
                                    Toggle(name, isOn: dependencyBinding(name)).toggleStyle(.button).controlSize(.mini)
                                }
                            }
                        }
                    }
                }
                Section("部署前准备（可选）") {
                    Toggle("生成运行产物", isOn: $draft.hasPreparation)
                    if draft.hasPreparation {
                        LabeledContent("类型") { TextField("maven-spring-boot", text: $draft.preparationKind) }
                        LabeledContent("构建目录") { TextField("apps/service", text: $draft.preparationContext) }
                        LabeledContent("输出文件") { TextField("target/app.jar", text: $draft.preparationOutput) }
                        LabeledContent("构建镜像") { TextField("maven:3-eclipse-temurin-21", text: $draft.preparationImage) }
                        multiLineField("构建命令", hint: "每行一个参数", text: $draft.preparationCommand)
                    }
                }
                HStack {
                    Spacer()
                    Button("还原") { reloadDraft() }
                    Button("保存服务") { saveDraft() }.buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("自动审查").font(.subheadline.weight(.semibold))
                Spacer()
                if hasErrors { Text("不可生成").foregroundStyle(.red) }
                else { Text("可生成").foregroundStyle(.green) }
            }
            .font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(diagnostics) { item in diagnosticCard(item) }
                }
            }
            Text("静态检查：依赖、DNS 引用、模板端口、挂载目标、共享写入、资源下限、网络与镜像版本。部署前还会检查本机实时占用和路径。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("取消") { dismiss() }
            Spacer()
            Button("保存当前服务") { saveDraft() }.disabled(selectedServiceID == nil)
            Button("载入模板") {
                saveDraft()
                if hasErrors { showBlockingAlert = true; return }
                onUse(generatedTemplate)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private func multiLineField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title).font(.caption); Spacer(); Text(hint).font(.caption2).foregroundStyle(.secondary) }
            TextEditor(text: text).font(.caption.monospaced()).frame(minHeight: 58).border(.quaternary)
        }
    }

    private func diagnosticCard(_ item: ClusterTemplateDiagnostic) -> some View {
        let color: Color = item.severity == .error ? .red : item.severity == .warning ? .orange : .blue
        return VStack(alignment: .leading, spacing: 3) {
            Label(item.title, systemImage: item.severity == .error ? "xmark.octagon.fill" : item.severity == .warning ? "exclamationmark.triangle.fill" : "lightbulb.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(color)
            if let service = item.service { Text(service).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            Text(item.guidance).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var dependencyCandidates: [String] {
        services.map(\.name).filter { !$0.isEmpty && $0 != draft.name }
    }

    private func dependencyBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { draft.dependencies.contains(name) }, set: { enabled in
            if enabled { draft.dependencies.insert(name) } else { draft.dependencies.remove(name) }
        })
    }

    private func addPreset() {
        let service = preset.service(existingNames: Set(services.map(\.name)))
        services.append(service)
        selectedServiceID = service.id
        draft = ServiceDraft(service)
    }

    private func saveDraft() {
        guard let id = selectedServiceID, let index = services.firstIndex(where: { $0.id == id }) else { return }
        var service = draft.service()
        service.id = id
        services[index] = service
    }

    private func reloadDraft() {
        guard let id = selectedServiceID, let service = services.first(where: { $0.id == id }) else { return }
        draft = ServiceDraft(service)
    }

    private func duplicate(_ service: ClusterService) {
        var copy = service
        copy.id = UUID()
        copy = ServiceDraft(copy, name: uniqueName(service.name)).service()
        services.append(copy)
        selectedServiceID = copy.id
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(services.map(\.name))
        if !names.contains(base) { return base }
        var suffix = 2
        while names.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    private func remove(_ id: UUID) {
        services.removeAll { $0.id == id }
        selectedServiceID = services.first?.id
    }

    private func remove(_ offsets: IndexSet) {
        services.remove(atOffsets: offsets)
        if let selectedServiceID, !services.contains(where: { $0.id == selectedServiceID }) { self.selectedServiceID = services.first?.id }
    }

    private func canMoveSelected(_ delta: Int) -> Bool {
        guard let id = selectedServiceID, let index = services.firstIndex(where: { $0.id == id }) else { return false }
        return services.indices.contains(index + delta)
    }

    private func moveSelected(_ delta: Int) {
        guard let id = selectedServiceID, let index = services.firstIndex(where: { $0.id == id }), services.indices.contains(index + delta) else { return }
        services.swapAt(index, index + delta)
    }
}

private struct ServiceDraft {
    var name = "service"
    var role = ""
    var image = ""
    var ports = ""
    var environment = ""
    var volumes = ""
    var cpus = "1"
    var memory = "256M"
    var detach = true
    var network = "default"
    var workdir = ""
    var user = ""
    var entrypoint = ""
    var command = ""
    var initProcess = false
    var readOnly = false
    var dnsRegistration = true
    var sshForward = false
    var replicas = 1
    var dependencies = Set<String>()
    var hasPreparation = false
    var preparationKind = ""
    var preparationContext = ""
    var preparationOutput = ""
    var preparationImage = ""
    var preparationCommand = ""

    init() {}
    init(_ service: ClusterService, name: String? = nil) {
        self.name = name ?? service.name; role = service.role ?? ""; image = service.image
        ports = service.ports.joined(separator: "\n"); environment = service.env.joined(separator: "\n")
        volumes = service.volumes.joined(separator: "\n"); cpus = service.cpus.map(String.init) ?? ""
        memory = service.memory ?? ""; detach = service.detach; network = service.network ?? ""
        workdir = service.workdir ?? ""; user = service.user ?? ""; entrypoint = service.entrypoint ?? ""
        command = service.command.joined(separator: "\n"); initProcess = service.initProcess; readOnly = service.readOnly
        dnsRegistration = service.dnsRegistration; sshForward = service.sshForward; replicas = service.replicas
        dependencies = Set(service.dependsOn)
        if let preparation = service.preDeploy {
            hasPreparation = true; preparationKind = preparation.kind; preparationContext = preparation.context
            preparationOutput = preparation.output; preparationImage = preparation.image
            preparationCommand = preparation.command.joined(separator: "\n")
        }
    }

    func service() -> ClusterService {
        ClusterService(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), image: image.trimmingCharacters(in: .whitespacesAndNewlines),
            ports: ports.lines, env: environment.lines, volumes: volumes.lines,
            cpus: Int(cpus), memory: memory.nilIfBlank, detach: detach, network: network.nilIfBlank,
            workdir: workdir.nilIfBlank, user: user.nilIfBlank, entrypoint: entrypoint.nilIfBlank,
            command: command.lines, initProcess: initProcess, readOnly: readOnly, role: role.nilIfBlank,
            dnsRegistration: dnsRegistration, sshForward: sshForward,
            dependsOn: dependencies.sorted(), replicas: replicas,
            preDeploy: hasPreparation ? ClusterServicePreparation(
                kind: preparationKind, context: preparationContext, output: preparationOutput,
                image: preparationImage, command: preparationCommand.lines, title: nil
            ) : nil
        )
    }
}

private enum ServicePreset: String, CaseIterable, Identifiable {
    case nginx, php, node, redis, mysql, postgres, mongo, coredns, ssh, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nginx: "Nginx"; case .php: "PHP-FPM"; case .node: "Node.js"
        case .redis: "Redis"; case .mysql: "MySQL"; case .postgres: "PostgreSQL"
        case .mongo: "MongoDB"; case .coredns: "CoreDNS"; case .ssh: "SSH"
        case .custom: "自定义"
        }
    }

    func service(existingNames: Set<String>) -> ClusterService {
        func name(_ base: String) -> String {
            if !existingNames.contains(base) { return base }
            var i = 2; while existingNames.contains("\(base)-\(i)") { i += 1 }; return "\(base)-\(i)"
        }
        switch self {
        case .nginx: return .init(name: name("nginx"), image: "nginx:1.27-alpine", ports: ["8080:80"], volumes: ["{{PROJECT_DIR}}/www:/usr/share/nginx/html:ro"], memory: "256M", role: "gateway")
        case .php: return .init(name: name("php"), image: "php:8.3-fpm-alpine", volumes: ["{{PROJECT_DIR}}/www:/var/www/html"], memory: "512M", role: "php-fpm")
        case .node: return .init(name: name("api"), image: "node:22-alpine", ports: ["3000:3000"], volumes: ["{{PROJECT_DIR}}/apps/api:/app"], memory: "512M", workdir: "/app", command: ["npm", "start"], role: "api")
        case .redis:
            let serviceName = name("redis")
            return .init(name: serviceName, image: "redis:7-alpine", volumes: ["{{PROJECT_DIR}}/infra/redis/\(serviceName)/data:/data"], memory: "256M", command: ["redis-server", "--appendonly", "yes"], role: "cache")
        case .mysql:
            let serviceName = name("mysql")
            return .init(name: serviceName, image: "mysql:8.4", env: ["MYSQL_ROOT_PASSWORD=change-me"], volumes: ["{{PROJECT_DIR}}/infra/mysql/\(serviceName)/data:/var/lib/mysql"], memory: "1G", role: "database")
        case .postgres:
            let serviceName = name("postgres")
            return .init(name: serviceName, image: "postgres:17-alpine", env: ["POSTGRES_PASSWORD=change-me"], volumes: ["{{PROJECT_DIR}}/infra/postgresql/\(serviceName)/data:/var/lib/postgresql/data"], memory: "512M", role: "database")
        case .mongo:
            let serviceName = name("mongo")
            return .init(name: serviceName, image: "mongo:8", volumes: ["{{PROJECT_DIR}}/infra/mongodb/\(serviceName)/data:/data/db"], memory: "512M", role: "database")
        case .coredns: return .init(name: name("dns"), image: "coredns/coredns:1.11.3", ports: ["127.0.0.1:5354:53/udp"], memory: "256M", role: "dns")
        case .ssh:
            let serviceName = name("ssh")
            return .init(name: serviceName, image: "lscr.io/linuxserver/openssh-server:latest", ports: ["127.0.0.1:2222:2222"], volumes: ["{{PROJECT_DIR}}/infra/ssh/\(serviceName)/config:/config"], memory: "256M", role: "ssh-bastion")
        case .custom: return .init(name: name("service"), image: "", memory: "256M", role: "custom")
        }
    }
}

private extension String {
    var lines: [String] { split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : trimmingCharacters(in: .whitespacesAndNewlines) }
}
