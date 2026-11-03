import SwiftUI
internal import UniformTypeIdentifiers

struct CreateMachineSheet: View {
    @ObservedObject var viewModel: MachineListViewModel
    @Environment(\.dismiss) private var dismiss
    // 该页面可从工具栏、快捷入口或预览独立展示；直接观察共享服务，
    // 避免遗漏 EnvironmentObject 注入时出现运行时 fatal error。
    @ObservedObject private var sourceImageManager = SourceImageManager.shared
    @ObservedObject private var machineImageManager = MachineImageManager.shared
    @ObservedObject private var machineManager = MachineManager.shared

    @State private var name = ""
    @State private var imageName = "alpine"
    @State private var imageTag = AppConstants.CLI.defaultImageTag
    @State private var imageRefOverride: String? = nil    // 完整 OCI 地址，优先于 name+tag
    @State private var isApplyingPreset = false             // 标记程序化设置，避免 onChange 清除 override
    @State private var selectedImage: MachineImageCollection? = nil  // 被选中的推荐镜像（用于镜像源列表）
    @State private var selectedMirror: String? = nil        // 用户选择的镜像源
    @State private var showMirrorEditor = false
    @State private var isTestingImage = false
    @State private var imageTestResult: Bool? = nil
    @State private var imageTestMessage: String? = nil
    @State private var useDefaultCpus = true
    @State private var cpuSlider: Double = 4
    @State private var useDefaultMemory = true
    @State private var memSlider: Double = 8
    @State private var homeMount: MachineCreateConfiguration.HomeMount = .readWrite
    @State private var virtualization = false
    @State private var noBoot = false
    @State private var setDefault = true
    @State private var architecture: MachineCreateConfiguration.Architecture?
    @State private var osSelection = "linux"
    @State private var scheme: MachineCreateConfiguration.RegistryScheme = .auto
    @State private var maxDownloads = ""
    @ObservedObject private var imgSourceMgr = ImageSourceManager.shared
    @State private var kernelPath = ""
    @State private var showLocalImagePicker = false
    @State private var showPullSheet = false
    @State private var showKernelPicker = false
    @State private var showAdvanced = false
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @State private var appliedDefaults = false

    private var imageReference: String {
        // 用户选的镜像源优先
        if let mirror = selectedMirror { return mirror }
        // 点击推荐按钮时 set 的完整 OCI 路径
        if let override = imageRefOverride { return override }
        // 手动输入：短名称补 Docker Hub 前缀；注册表端口号保留，不能当作 tag。
        let reference = imageTag.isEmpty ? imageName : imageName.imageReference(tag: imageTag)
        guard !reference.isEmpty else { return "" }
        return reference.contains("/")
            ? reference
            : "\(AppConstants.Image.defaultRegistry)/\(reference)"
    }
    private var canSubmit: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !imageName.isEmpty && !isSubmitting }
    private var quickImages: [(name: String, tag: String)] {
        imgSourceMgr.allEntries.map { ($0.name ?? "", $0.tag ?? "latest") }
    }

    // MARK: - 系统级默认（config.toml [machine] 段快录）

    private var machineDefaults: (cpus: Int?, memoryGB: Double?) { CreateMachineSheet.systemMachineDefaults }
    private var cpuMax: Double { max(1, Double(ProcessInfo.processInfo.activeProcessorCount)) }
    private var memMaxGB: Double {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return max(2, Double(bytes) / 1_073_741_824)
    }

    private static var systemMachineDefaults: (cpus: Int?, memoryGB: Double?) {
        guard let content = systemConfigContent else { return (nil, nil) }
        var inMachine = false
        var cpus: Int? = nil
        var mem: Double? = nil
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") && t.hasSuffix("]") {
                inMachine = (t == "[machine]")
                continue
            }
            guard inMachine else { continue }
            if t.hasPrefix("cpus") {
                cpus = Int(t.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
            } else if t.hasPrefix("memory") {
                let raw = t.components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\"", with: "").lowercased() ?? ""
                if raw.hasSuffix("gb") { mem = Double(raw.dropLast(2)) }
                else if raw.hasSuffix("g") { mem = Double(raw.dropLast()) }
                else if raw.hasSuffix("mb") { mem = (Double(raw.dropLast(2)) ?? 0) / 1024 }
                else if raw.hasSuffix("m") { mem = (Double(raw.dropLast()) ?? 0) / 1024 }
            }
        }
        return (cpus, mem)
    }

    private static var systemConfigContent: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent("Library/Application Support/com.apple.container/config/config.toml").path,
            home.appendingPathComponent(".config/container/config.toml").path,
        ]
        for p in paths {
            if let c = try? String(contentsOfFile: p, encoding: .utf8) { return c }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        identityCard
                        imageCard
                        resourcesCard
                        optionsCard
                        advancedCard
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

                if machineManager.isLoading {
                    CommandProgressView()
                        .environmentObject(TaskManager.shared)
                        .frame(height: 94)
                        .padding(.horizontal, 20)
                }

                Divider()
                HStack {
                    Text("创建后会\(noBoot ? "保留为停止状态" : "立即启动")。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(action: submit) {
                        if isSubmitting { ProgressView().controlSize(.small) }
                        Text("创建 Machine")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(minWidth: 640, idealWidth: 680, minHeight: 600, idealHeight: 680)
            .navigationTitle("新建 Machine")
            .fileImporter(isPresented: $showKernelPicker, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                kernelPath = url.path
            }
            .sheet(isPresented: $showLocalImagePicker) {
                ImagePickerSheet(images: sourceImageManager.images) { image in
                    imageName = image.repository
                    imageTag = image.tag
                    showLocalImagePicker = false
                }
            }
            .sheet(isPresented: $showPullSheet) {
                MachinePullImageSheet(imageName: $imageName, imageTag: $imageTag) {
                    showPullSheet = false
                }
            }
            .sheet(isPresented: $showMirrorEditor) {
                // SwiftUI may evaluate a sheet's content while presentation state is changing.
                // Never force-unwrap the selection here: an image refresh can clear the
                // managed-object reference in that interval.
                if let image = selectedImage {
                    MirrorEditorView(machineImageManager: machineImageManager, image: image)
                } else {
                    ContentUnavailableView("未选择镜像", systemImage: "shippingbox")
                }
            }
            .onChange(of: showMirrorEditor) { _, isShowing in
                if !isShowing, let sel = selectedImage, let id = sel.id {
                    selectedImage = machineImageManager.images.first { $0.id == id }
                    selectedMirror = selectedImage?.allMirrors.first
                }
            }
            .task {
                machineImageManager.loadImages()
                await sourceImageManager.fetchImages()
                imgSourceMgr.loadAllEntries()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Linux 开发环境")
                    .font(.title2.weight(.semibold))
                Text("从 OCI 镜像创建一个可长期使用的 Container Machine")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var identityCard: some View {
        sectionCard(title: "标识", icon: "tag") {
            TextField("Machine 名称，例如 dev", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("名称用于在命令行中定位此 Machine。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var imageCard: some View {
        sectionCard(title: "镜像", icon: "shippingbox") {
            Label("请选择 Linux OCI 镜像；Alpine、Ubuntu、Debian 适合开发环境。nginx、redis 等服务镜像更适合使用“创建容器”。", systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            // 推荐的 Machine 镜像（优先展示）
            if !machineImageManager.images.isEmpty {
                Text("推荐 Machine 镜像").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(machineImageManager.images) { image in
                            Button(image.displayName ?? AppConstants.Display.unknown) {
                                isApplyingPreset = true
                                imageName = image.name ?? ""
                                imageTag = image.tag ?? ""
                                selectedImage = image
                                selectedMirror = image.allMirrors.first
                                imageRefOverride = image.fullImageReference
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            // 镜像源选择器
            Picker("镜像源", selection: $imgSourceMgr.currentSource) {
                Text("Docker Hub").tag(nil as ImageSource?)
                ForEach(imgSourceMgr.sources) { src in Text(src.name ?? "").tag(src as ImageSource?) }
            }.onChange(of: imgSourceMgr.currentSource) { _, _ in
                let base = imageName.contains("/") ? String(imageName.split(separator: "/").last ?? Substring(imageName)) : imageName
                guard let src = imgSourceMgr.currentSource, let url = src.url else { return }
                let reg = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !reg.isEmpty else { return }
                imageName = "\(reg)/\(base)"
            }

            // 常用镜像快速录入
            if !quickImages.isEmpty {
                Text("快录镜像 (含容器镜像，可能不适用 Machine)").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(quickImages.indices, id: \.self) { i in
                            Button("\(quickImages[i].name):\(quickImages[i].tag)") {
                                imageName = quickImages[i].name; imageTag = quickImages[i].tag
                                isApplyingPreset = true
                                imageRefOverride = nil
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("镜像地址，例如 docker.io/library/alpine", text: $imageName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: imageName) {
                        if !isApplyingPreset {
                            imageRefOverride = nil
                            selectedImage = nil
                            selectedMirror = nil
                        }
                        isApplyingPreset = false
                        imageTestResult = nil
                    }
                TextField("标签", text: $imageTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onChange(of: imageTag) {
                        if !isApplyingPreset {
                            imageRefOverride = nil
                            selectedImage = nil
                            selectedMirror = nil
                        }
                        isApplyingPreset = false
                        imageTestResult = nil
                    }
                Button("本地镜像") { showLocalImagePicker = true }
                    .disabled(sourceImageManager.images.isEmpty)
                Button("拉取…") { showPullSheet = true }
            }
            Label(imageReference, systemImage: "terminal")
                .font(.caption.monospaced())
                .foregroundStyle(imageName.isEmpty ? .red : .secondary)

            // 镜像源选择器（仅当选中推荐镜像且有多个镜像源时显示）
            if let sel = selectedImage, !sel.allMirrors.isEmpty {
                HStack {
                    if sel.allMirrors.count > 1 {
                        Picker("镜像源", selection: $selectedMirror) {
                            ForEach(sel.allMirrors, id: \.self) { mirror in
                                Text(mirror).tag(Optional(mirror))
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text(sel.allMirrors.first ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("管理镜像源…") { showMirrorEditor = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }

            // 镜像可用性测试
            HStack(spacing: 8) {
                Button(action: testImage) {
                    if isTestingImage {
                        ProgressView().controlSize(.small)
                    }
                    Text("测试镜像")
                }
                .disabled(isTestingImage || imageName.isEmpty)
                .buttonStyle(.bordered)

                if let result = imageTestResult {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    if let msg = imageTestMessage {
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var resourcesCard: some View {
        sectionCard(title: "资源", icon: "gauge.with.dots.needle.50percent") {
            // 系统默认快录（config.toml [machine]）
            if machineDefaults.cpus != nil || machineDefaults.memoryGB != nil {
                let mc = machineDefaults
                HStack(spacing: 8) {
                    Label("系统默认", systemImage: "gearshape").font(.caption).foregroundStyle(.secondary)
                    Text("\(mc.cpus ?? 0) 核 / \(Int(mc.memoryGB ?? 0)) GB（config.toml）")
                        .font(.caption.monospaced())
                    Button(appliedDefaults ? "已应用" : "应用") { applyMachineDefaults() }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .disabled(appliedDefaults)
                }
            }

            // 虚拟 CPU（滑杆）
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("虚拟 CPU", systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("默认", isOn: $useDefaultCpus).toggleStyle(.switch).controlSize(.mini)
                    if useDefaultCpus {
                        Text("默认").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("\(Int(cpuSlider)) 核").font(.caption.monospaced()).frame(width: 56, alignment: .trailing)
                    }
                }
                if !useDefaultCpus {
                    HStack(spacing: 10) {
                        Slider(value: $cpuSlider, in: 1...cpuMax, step: 1)
                        quickChips([("1", 1.0), ("2", 2.0), ("4", 4.0)], bind: $cpuSlider)
                    }
                }
            }

            // 内存（滑杆）
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("内存", systemImage: "memorychip").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("默认", isOn: $useDefaultMemory).toggleStyle(.switch).controlSize(.mini)
                    if useDefaultMemory {
                        Text("默认").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("\(Int(memSlider)) GB").font(.caption.monospaced()).frame(width: 56, alignment: .trailing)
                    }
                }
                if !useDefaultMemory {
                    HStack(spacing: 10) {
                        Slider(value: $memSlider, in: 0.5...memMaxGB, step: 0.5)
                        quickChips([("2", 2.0), ("4", 4.0), ("8", 8.0)], bind: $memSlider)
                    }
                }
            }

            Text("默认 = Container 默认（内存为系统内存一半）；系统默认来自 config.toml [machine] 段。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func quickChips(_ items: [(String, Double)], bind: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.0) { item in
                Button(item.0) { bind.wrappedValue = item.1 }
                    .buttonStyle(.borderless).font(.caption2).foregroundStyle(.blue)
            }
        }
    }

    private func applyMachineDefaults() {
        if let c = machineDefaults.cpus { cpuSlider = Double(c) }
        if let m = machineDefaults.memoryGB { memSlider = m }
        useDefaultCpus = false
        useDefaultMemory = false
        appliedDefaults = true
    }

    private var optionsCard: some View {
        sectionCard(title: "启动选项", icon: "switch.2") {
            Picker("Home 目录", selection: $homeMount) {
                ForEach(MachineCreateConfiguration.HomeMount.allCases) { option in
                    Text("\(option.rawValue) · \(option.title)").tag(option)
                }
            }
            .pickerStyle(.segmented)
            Toggle("创建后不启动", isOn: $noBoot)
            Toggle("设为默认 Machine", isOn: $setDefault)
            Toggle("启用嵌套虚拟化", isOn: $virtualization)
                .help("需要 Apple Silicon M3+、macOS 15+ 及支持 KVM 的内核。")
        }
    }

    private var advancedCard: some View {
        DisclosureGroup("高级镜像与内核设置", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("架构", selection: $architecture) {
                    Text("使用主机架构").tag(MachineCreateConfiguration.Architecture?.none)
                    ForEach(MachineCreateConfiguration.Architecture.allCases) { arch in
                        Text(arch.rawValue).tag(Optional(arch))
                    }
                }
                Picker("系统 (OS)", selection: $osSelection) {
                    ForEach(["linux", "darwin", "windows"], id: \.self) { Text($0).tag($0) }
                }
                Picker("镜像仓库协议", selection: $scheme) {
                    ForEach(MachineCreateConfiguration.RegistryScheme.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                TextField("最大并发下载数（默认 3）", text: $maxDownloads)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("自定义内核路径（可选）", text: $kernelPath)
                        .textFieldStyle(.roundedBorder)
                    Button("选择文件…") { showKernelPicker = true }
                }
            }
            .padding(.top, 10)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func testImage() {
        let ref = imageReference
        guard !ref.isEmpty else { return }
        imageTestResult = nil
        imageTestMessage = nil
        isTestingImage = true

        guard let parsed = ref.ociManifestReference else {
            imageTestResult = false
            imageTestMessage = "格式无效"
            isTestingImage = false
            return
        }
        let urlString = "https://\(parsed.registry)/v2/\(parsed.repository)/manifests/\(parsed.tag)"
        guard let url = URL(string: urlString) else {
            imageTestResult = false
            imageTestMessage = "URL 无效"
            isTestingImage = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                isTestingImage = false
                if let error = error {
                    imageTestResult = false
                    imageTestMessage = "不可达: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse {
                    imageTestResult = (200...399).contains(http.statusCode)
                    imageTestMessage = imageTestResult! ? "镜像可用" : "状态码 \(http.statusCode)"
                } else {
                    imageTestResult = false
                    imageTestMessage = "无响应"
                }
            }
        }.resume()
    }

    private func submit() {
        validationMessage = nil
        let cpuText = useDefaultCpus ? "" : String(Int(cpuSlider))
        let memoryArg = useDefaultMemory ? "" : "\(Int(memSlider))G"
        let downloads = maxDownloads.trimmingCharacters(in: .whitespacesAndNewlines)
        guard downloads.isEmpty || Int(downloads) != nil else {
            validationMessage = "并发下载数必须是整数。"
            return
        }
        let configuration = MachineCreateConfiguration(
            name: name, image: imageReference, cpus: Int(cpuText), memory: memoryArg,
            homeMount: homeMount, virtualization: virtualization, kernelPath: kernelPath,
            noBoot: noBoot, setDefault: setDefault, architecture: architecture,
            os: osSelection == "linux" ? nil : osSelection,
            scheme: scheme, maxConcurrentDownloads: Int(downloads)
        )
        switch configuration.validated {
        case .failure(let error): validationMessage = error.localizedDescription
        case .success(let validated):
            isSubmitting = true
            Task {
                do {
                    try await viewModel.createMachine(validated)
                    dismiss()
                } catch {
                    validationMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

struct ImagePickerSheet: View {
    let images: [SourceImage]
    let onSelect: (SourceImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(images.filter { searchText.isEmpty || $0.displayName.localizedCaseInsensitiveContains(searchText) }) { image in
                Button {
                    onSelect(image)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(image.displayName).font(.headline)
                            Text(image.digest?.prefix(12) ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(image.sizeString).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "搜索镜像")
            .navigationTitle("本地镜像")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .frame(minWidth: 520, minHeight: 340)
    }
}

struct MachinePullImageSheet: View {
    @Binding var imageName: String
    @Binding var imageTag: String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sourceImageManager = SourceImageManager.shared
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("拉取镜像").font(.title2.weight(.semibold))
            TextField("镜像名称", text: $imageName).textFieldStyle(.roundedBorder)
            TextField("标签", text: $imageTag).textFieldStyle(.roundedBorder)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("拉取") {
                    Task {
                        do {
                            try await sourceImageManager.pullImage(name: imageName, tag: imageTag)
                            onDone()
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - 镜像源配置面板
struct MirrorEditorView: View {
    @ObservedObject var machineImageManager: MachineImageManager
    let image: MachineImageCollection
    @Environment(\.dismiss) private var dismiss

    @State private var mirrors: [String] = []
    @State private var newMirror = ""
    @State private var hasChanges = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理镜像源").font(.title2.weight(.semibold))

            if let disp = image.displayName {
                Text(disp).font(.headline).foregroundStyle(.secondary)
            }

            Divider()

            // Current mirrors list
            if mirrors.isEmpty {
                Label("暂无镜像源，请添加", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                List {
                    ForEach(Array(mirrors.enumerated()), id: \.offset) { idx, mirror in
                        HStack {
                            if idx == 0 {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .help("默认源（source 字段）")
                            }
                            Text(mirror)
                                .font(.caption.monospaced())
                            Spacer()
                            if idx > 0 {
                                Button(action: { removeMirror(at: idx) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            // Add mirror
            HStack {
                TextField("新镜像源，如 registry.example.com/name:tag", text: $newMirror)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    let trimmed = newMirror.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !mirrors.contains(trimmed) else { return }
                    mirrors.append(trimmed)
                    newMirror = ""
                    hasChanges = true
                }
                .disabled(newMirror.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { saveMirrors() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
            }
        }
        //.frame(width: 520, minHeight: 340)
        .padding(24)
        .onAppear {
            mirrors = image.allMirrors
        }
    }

    private func removeMirror(at index: Int) {
        guard index < mirrors.count else { return }
        mirrors.remove(at: index)
        hasChanges = true
    }

    private func saveMirrors() {
        let context = PersistenceController.shared.container.viewContext

        // 第一个镜像源作为 source，其余存入 JSON mirrors
        let primary = mirrors.first ?? ""
        let alternates = Array(mirrors.dropFirst())

        // 保留原有描述
        let oldCfg = image.mirrorConfig
        let cfg = ImageMirrorConfig(desc: oldCfg.desc, mirrors: alternates.isEmpty ? nil : alternates)
        let encoder = JSONEncoder()
        let json = (try? encoder.encode(cfg)).flatMap { String(data: $0, encoding: .utf8) }

        // 更新 Core Data
        let request: NSFetchRequest<MachineImageCollection> = MachineImageCollection.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", image.id! as CVarArg)
        if let result = try? context.fetch(request), let obj = result.first {
            obj.source = primary
            obj.attribute = json
            try? context.save()
        }

        machineImageManager.loadImages()
        dismiss()
    }
}
