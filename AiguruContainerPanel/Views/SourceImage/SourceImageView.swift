//
//  SourceImageView.swift
//  AiguruContainerPanel
//
//  镜像管理主视图：列表、拉取、删除、推送，工具栏在标题栏。
//  支持多工作区环境切换。
//

import SwiftUI
import AppKit
internal import UniformTypeIdentifiers

struct SourceImageView: View {
    @StateObject private var viewModel = SourceImageListViewModel()
    @StateObject private var archiveManager = ImageArchiveManager.shared
    @State private var showPullSheet = false
    @State private var showBuildSheet = false
    @State private var showPushSheet = false
    @State private var searchText = ""
    @State private var showPruneConfirmation = false
    @State private var selectedImage: SourceImage?
    @State private var collapsedRepos: Set<String> = []   // 收起的仓库分组

    /// 按仓库域名分组的镜像（如 docker.1ms.run/alpine → docker.1ms.run；官方镜像 → Docker Hub）
    private var groupedImages: [(domain: String, images: [SourceImage])] {
        Dictionary(grouping: filteredImages) { image -> String in
            let parts = image.repository.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : "Docker Hub"
        }
        .map { (domain: $0.key, images: $0.value.sorted { $0.name < $1.name }) }
        .sorted { $0.domain < $1.domain }
    }

    var filteredImages: [SourceImage] {
        var result = viewModel.images
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        HSplitView {
            // 左侧：镜像列表
            VStack(spacing: 0) {
                if viewModel.isLoading && viewModel.images.isEmpty {
                    ProgressView("加载镜像列表...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredImages.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("没有镜像")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("点击工具栏「拉取镜像」开始")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedImages, id: \.domain) { group in
                            Section {
                                if !collapsedRepos.contains(group.domain) {
                                    ForEach(group.images) { image in
                                        SourceImageRow(image: image, viewModel: viewModel, isSelected: image.id == selectedImage?.id)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                selectedImage = image
                                            }
                                    }
                                }
                            } header: {
                                // 仓库分组头（点击展开/收起）
                                Button {
                                    if collapsedRepos.contains(group.domain) {
                                        collapsedRepos.remove(group.domain)
                                    } else {
                                        collapsedRepos.insert(group.domain)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: collapsedRepos.contains(group.domain) ? "chevron.right" : "chevron.down")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(group.domain)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text("\(group.images.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

            // 右侧：镜像详情 + 归档时间线
            if let image = selectedImage {
                ImageArchiveDetailView(
                    image: image,
                    archiveManager: archiveManager,
                    onRefresh: { viewModel.refreshImages(silent: true) }
                )
                .id(image.id)
                .frame(minWidth: 380, maxWidth: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("选择一个镜像查看归档")
                        .foregroundColor(.secondary)
                    Text("归档基于 image save / load，可独立于本地镜像保存和导入")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.refreshImages()
            }
        }
        .sheet(isPresented: $showPullSheet) {
            PullImageSheet(
                imageName: $pullImageName,
                imageTag: $pullImageTag,
                onPull: { fullImage, platform in
                    // 完整引用可能含私有库前缀（如 my-reg.com/nginx:latest）
                    viewModel.pullImage(name: fullImage, tag: "", platform: platform)
                    showPullSheet = false
                    pullImageName = ""
                    pullImageTag = "latest"
                },
                onCancel: {
                    showPullSheet = false
                    pullImageName = ""
                    pullImageTag = "latest"
                }
            )
        }
        .sheet(isPresented: $showBuildSheet) {
            BuildImageSheet(
                onBuild: { contextDir, dockerfile, tag, platform, target, noCache in
                    viewModel.buildImage(
                        contextDir: contextDir,
                        file: dockerfile,
                        tag: tag,
                        platform: platform,
                        target: target,
                        noCache: noCache
                    )
                    showBuildSheet = false
                },
                onCancel: {
                    showBuildSheet = false
                }
            )
        }
        .sheet(isPresented: $showRegistrySheet) {
            RegistryManageSheet()
        }
        .sheet(isPresented: $showPushSheet) {
            PushImageSheet(
                imageName: $pushImageName,
                imageTag: $pushImageTag,
                onPush: {
                    viewModel.pushImage(name: pushImageName, tag: pushImageTag)
                    showPushSheet = false
                    pushImageName = ""
                    pushImageTag = "latest"
                },
                onCancel: {
                    showPushSheet = false
                    pushImageName = ""
                    pushImageTag = "latest"
                }
            )
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                viewModel.refreshImages()
            }
        }
        .alert("错误", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("确定") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { viewModel.refreshImages() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新镜像列表")

                Button(action: { showPullSheet = true }) {
                    Label("拉取镜像", systemImage: "arrow.down.circle")
                }
                .help("拉取镜像")

                Button(action: { showBuildSheet = true }) {
                    Label("构建镜像", systemImage: "hammer")
                }
                .help("从 Dockerfile/Containerfile 构建镜像 (image build)")

                Button(action: { showPushSheet = true }) {
                    Label("推送镜像", systemImage: "arrow.up.circle")
                }
                .help("推送镜像")

                Button(action: { showRegistrySheet = true }) {
                    Label("私有库", systemImage: "shippingbox")
                }
                .help("管理私有镜像仓库（登录/登出）")

                Button(action: importImage) {
                    Label("导入镜像", systemImage: "square.and.arrow.down")
                }
                .help("从 tar 归档导入镜像 (image load)")

                Divider()
                Button(action: { showPruneConfirmation = true }) {
                    Label("清理悬空镜像", systemImage: "trash.slash")
                }
                .help("仅清理无标签的悬空镜像内容")
                .alert("确认清理", isPresented: $showPruneConfirmation) {
                    Button("取消", role: .cancel) { }
                    Button("清理悬空镜像", role: .destructive) {
                        viewModel.pruneDanglingImages()
                    }
                    Button("安全清理所有未使用镜像", role: .destructive) {
                        viewModel.deleteUnusedImagesSafely()
                    }
                } message: {
                    Text("“悬空镜像”仅执行 image prune。“安全清理”会保护全部运行/停止容器及所有 Kubernetes 节点 containerd 镜像；任一引用清单无法核实时不会删除。操作不可恢复。")
                }
                
                TextField("搜索镜像...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 180)
                    .help("按名称搜索镜像")

                // 进度条已由底部 CommandProgressView 统一展示，不再在工具条重复显示
                // if viewModel.isLoading {
                //     ProgressView()
                //         .progressViewStyle(CircularProgressViewStyle())
                //         .scaleEffect(0.6)
                // }
            }
        }
    }

    @State private var pullImageName = ""
    @State private var pullImageTag = "latest"
    @State private var showRegistrySheet = false
    @State private var pushImageName = ""
    @State private var pushImageTag = "latest"

    private func importImage() {
        let panel = NSOpenPanel()
        panel.title = "选择要导入的镜像归档"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.loadImage(from: url)
        }
    }
}

// MARK: - 镜像行
struct SourceImageRow: View {
    let image: SourceImage
    @ObservedObject var viewModel: SourceImageListViewModel
    var isSelected: Bool = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo")
                .foregroundColor(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(image.displayName)
                    .font(.headline)
                if let digest = image.digest {
                    Text(digest.prefix(12))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if let created = image.createdDate {
                Text(created, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(image.sizeString)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Button(action: saveImage) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.blue)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("保存镜像为 tar (image save)")

                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(BorderlessButtonStyle())
                .help("删除镜像")
                .alert("确认删除", isPresented: $showDeleteConfirmation) {
                    Button("取消", role: .cancel) { }
                    Button("删除", role: .destructive) {
                        viewModel.deleteImage(image)
                    }
                } message: {
                    Text("确定要删除镜像 \"\(image.displayName)\" 吗？此操作不可恢复。")
                }
            }
            .frame(height: 24)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    private func saveImage() {
        let panel = NSSavePanel()
        panel.title = "保存镜像"
        panel.nameFieldStringValue = image.name.replacingOccurrences(of: "/", with: "_") + ".tar"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.saveImage(image, to: url)
        }
    }
}

// MARK: - 拉取镜像 Sheet
// MARK: - 增强拉取镜像 Sheet（私有仓库 + 架构选择）
struct PullImageSheet: View {
    @Binding var imageName: String
    @Binding var imageTag: String
    let onPull: (String, String) -> Void   // 传入完整引用（含私有库前缀）+ 平台
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var imgSrcMgr = ImageSourceManager.shared
    @StateObject private var registryMgr = RegistryManager.shared
    @State private var registry = ""
    @State private var platform = "linux/arm64"

    private var fullImage: String {
        let base = imageTag.isEmpty ? imageName : "\(imageName):\(imageTag)"
        guard !registry.isEmpty else { return base }
        let clean = registry
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(clean)/\(base)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("拉取镜像").font(.title2.weight(.semibold))

            Picker("镜像源", selection: $imgSrcMgr.currentSource) {
                Text("Docker Hub").tag(nil as ImageSource?)
                ForEach(imgSrcMgr.sources) { src in
                    Text(src.name ?? "").tag(src as ImageSource?)
                }
            }
            .onChange(of: imgSrcMgr.currentSource) { _, src in
                registry = src?.url?
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            }

            TextField("私有仓库地址 (可选)", text: $registry)
                .textFieldStyle(.roundedBorder)

            // 已登录的私有库一键填充
            if !registryMgr.registries.isEmpty {
                HStack(spacing: 8) {
                    Text("已登录私有库").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding<String>(
                        get: { "" },
                        set: { server in
                            if !server.isEmpty { registry = server }
                        }
                    )) {
                        Text("选择...").tag("")
                        ForEach(registryMgr.registries) { reg in
                            Text(reg.hostname).tag(reg.hostname)
                        }
                    }
                    .frame(width: 200)
                }
            }

            HStack(spacing: 10) {
                TextField("镜像名称 (如 nginx)", text: $imageName)
                    .textFieldStyle(.roundedBorder)
                TextField("标签", text: $imageTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            HStack(spacing: 10) {
                TextField("平台 (如 linux/arm64)", text: $platform)
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: $platform) {
                    Text("linux/arm64").tag("linux/arm64")
                    Text("linux/amd64").tag("linux/amd64")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            Text("拉取: \(fullImage)").font(.caption.monospaced()).foregroundStyle(.secondary)

            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("拉取") { onPull(fullImage, platform); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(imageName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460, height: 300)
    }
}

// MARK: - 增强推送镜像 Sheet（选择本地镜像 + 目标仓库）
struct PushImageSheet: View {
    @Binding var imageName: String
    @Binding var imageTag: String
    let onPush: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sourceImageManager: SourceImageManager
    @State private var targetRegistry = ""
    @State private var selectedLocalImage: SourceImage?
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 16) {
            Text("推送镜像").font(.title2.weight(.semibold))

            // 从本地镜像选择
            if !sourceImageManager.images.isEmpty {
                Button("从本地镜像选择…") { showPicker = true }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showPicker) {
                        List(sourceImageManager.images) { img in
                            Button(img.displayName) {
                                imageName = img.repository
                                imageTag = img.tag
                                selectedLocalImage = img
                                showPicker = false
                            }
                        }
                        .frame(width: 300, height: 240)
                    }
            }

            if let sel = selectedLocalImage {
                Label("已选: \(sel.displayName)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                TextField("镜像名称 (如 myrepo/nginx)", text: $imageName)
                    .textFieldStyle(.roundedBorder)
                TextField("标签", text: $imageTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            TextField("目标仓库地址 (可选)", text: $targetRegistry)
                .textFieldStyle(.roundedBorder)

            if !targetRegistry.isEmpty {
                Text("推送至: \(targetRegistry)/\(imageName):\(imageTag)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Text("推送前请用 `container login` 登录仓库").font(.caption).foregroundStyle(.orange)

            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("推送") { onPush(); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(imageName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460, height: 340)
    }
}

// MARK: - 镜像详情 + 归档时间线

struct ImageArchiveDetailView: View {
    let image: SourceImage
    @ObservedObject var archiveManager: ImageArchiveManager
    var onRefresh: () -> Void = {}
    @State private var showCreateSheet = false
    @State private var restoreTarget: ImageArchive?
    @State private var deleteTarget: ImageArchive?
    @State private var showDeleteConfirm = false
    @State private var showRestoreConfirm = false

    private var archives: [ImageArchive] {
        archiveManager.archives(for: image.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                summaryCard
                timelineSection
            }
            .padding(20)
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateArchiveSheet(image: image, archiveManager: archiveManager)
        }
        .alert("确认导入", isPresented: $showRestoreConfirm, presenting: restoreTarget) { snap in
            Button("导入", role: .destructive) {
                Task { try? await archiveManager.importArchive(snap); onRefresh() }
            }
            Button("取消", role: .cancel) {}
        } message: { snap in
            Text("将从归档 \(snap.timestamp.formatted()) 导入镜像 \(image.displayName)，同名镜像可能被覆盖。")
        }
        .alert("确认删除归档", isPresented: $showDeleteConfirm, presenting: deleteTarget) { snap in
            Button("删除", role: .destructive) { archiveManager.deleteArchive(snap) }
            Button("取消", role: .cancel) {}
        } message: { snap in
            Text("确定删除归档 \(snap.timestamp.formatted())（\(snap.sizeString)）吗？此操作不可恢复。")
        }
    }

    // MARK: - 简介

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue.gradient, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(image.displayName).font(.title3.weight(.semibold))
                    Text("\(archives.count) 个归档 · 最近 \(archives.first.map { $0.timestamp.formatted() } ?? "无")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { showCreateSheet = true }) {
                    Label("创建归档", systemImage: "archivebox")
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { infoLabel("镜像"); infoValue(image.name) }
                GridRow { infoLabel("仓库"); infoValue(image.repository) }
                GridRow { infoLabel("标签"); infoValue(image.tag) }
                GridRow { infoLabel("大小"); infoValue(image.sizeString) }
                GridRow { infoLabel("创建"); infoValue(image.createdDate.map { $0.formatted() } ?? "未知") }
                if let digest = image.digest {
                    GridRow { infoLabel("摘要"); infoValue(digest.prefix(32).description) }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoLabel(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }
    private func infoValue(_ s: String) -> some View {
        Text(s).font(.caption.monospaced())
    }

    // MARK: - 归档时间线

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("镜像归档").font(.headline)
                Spacer()
                if !archives.isEmpty {
                    Button("删除全部") { for s in archives { archiveManager.deleteArchive(s) } }
                        .font(.caption).foregroundStyle(.red)
                }
            }

            if archives.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.badge.clock").font(.largeTitle).foregroundStyle(.secondary)
                    Text("暂无归档").foregroundStyle(.secondary)
                    Text("点击「创建归档」将镜像保存为 OCI tar；删除本地镜像不会删除归档")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                // 时间线
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(archives.enumerated()), id: \.element.id) { idx, snap in
                        HStack(alignment: .top, spacing: 10) {
                            // 时间线节点
                            VStack(spacing: 0) {
                                Circle()
                                    .fill(idx == 0 ? Color.green : Color.accentColor)
                                    .frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                if idx < archives.count - 1 {
                                    Rectangle().fill(.quaternary).frame(width: 2, height: 100)
                                }
                            }
                            .frame(width: 12)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Text(snap.timestamp.formatted(date: .abbreviated, time: .standard))
                                        .font(.headline)
                                    if idx == 0 {
                                        Text("最新").font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    Spacer()
                                    Text(snap.sizeString).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(snap.archiveName)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let note = snap.note, !note.isEmpty {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Button("导入此归档") {
                                        restoreTarget = snap; showRestoreConfirm = true
                                    }
                                    .buttonStyle(.bordered)
                                    .help("从此归档导入镜像（image load）")
                                    Button("删除") {
                                        deleteTarget = snap; showDeleteConfirm = true
                                    }
                                    .buttonStyle(.bordered).tint(.red)
                                }
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 创建归档 Sheet

struct CreateArchiveSheet: View {
    let image: SourceImage
    @ObservedObject var archiveManager: ImageArchiveManager
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("创建镜像归档").font(.title2.weight(.semibold))
            Text(image.displayName).font(.headline).foregroundStyle(.secondary)
            TextField("备注（可选，如：部署前基线、1.2.3 版本）", text: $note)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建") {
                    Task {
                        do {
                            try await archiveManager.createArchive(of: image, note: note.isEmpty ? nil : note)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420, height: 220)
    }
}

// MARK: - 构建镜像 Sheet（image build，支持 Dockerfile/Containerfile）
struct BuildImageSheet: View {
    let onBuild: (String, String?, String, String?, String?, Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var contextDir = ""
    @State private var dockerfile = ""
    @State private var tag = ""
    @State private var platform = ""
    @State private var target = ""
    @State private var noCache = false
    private let platformChoices = ["", "linux/arm64", "linux/amd64", "darwin/arm64", "windows/amd64"]

    var body: some View {
        VStack(spacing: 16) {
            Text("构建镜像").font(.title2.weight(.semibold))

            HStack(spacing: 10) {
                TextField("构建上下文目录 (含 Dockerfile/Containerfile)", text: $contextDir)
                    .textFieldStyle(.roundedBorder)
                Button("浏览…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.allowsMultipleSelection = false
                    p.begin { if $0 == .OK, let u = p.url { contextDir = u.path } }
                }
            }

            TextField("Dockerfile 路径 (可选，留空自动探测 Dockerfile → Containerfile)", text: $dockerfile)
                .textFieldStyle(.roundedBorder)

            TextField("镜像标签 (如 my-app:latest)", text: $tag)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Picker("平台", selection: $platform) {
                    ForEach(platformChoices, id: \.self) {
                        Text($0.isEmpty ? "默认 (os/arch)" : $0).tag($0)
                    }
                }
                .frame(width: 200)

                TextField("目标阶段 --target (可选)", text: $target)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("不使用缓存 (--no-cache)", isOn: $noCache)

            Text("将执行: container image build -t \(tag.isEmpty ? "<tag>" : tag) \(contextDir.isEmpty ? "<context>" : contextDir)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Button("取消") { onCancel(); dismiss() }
                Spacer()
                Button("构建") {
                    onBuild(
                        contextDir,
                        dockerfile.isEmpty ? nil : dockerfile,
                        tag,
                        platform.isEmpty ? nil : platform,
                        target.isEmpty ? nil : target,
                        noCache
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(contextDir.isEmpty || tag.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520, height: 320)
    }
}
