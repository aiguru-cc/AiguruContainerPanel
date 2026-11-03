//
//  VolumeListView.swift
//  AiguruContainerPanel
//
//  卷管理视图：列表 + 详情（对齐容器/Machine 布局），支持搜索、创建（大小/标签/选项）、删除、清理。
//

import SwiftUI

struct VolumeListView: View {
    @StateObject private var manager = VolumeManager.shared
    @State private var showCreateSheet = false
    @State private var search = ""
    @State private var selID: String? = nil
    @State private var showDeleteAlert = false
    @State private var deleteTarget: VolumeInfo?
    @State private var showPruneAlert = false

    var filtered: [VolumeInfo] {
        var r = manager.volumes
        if !search.isEmpty { r = r.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        return r
    }
    var sel: VolumeInfo? { filtered.first { $0.id == selID } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if manager.isLoading && manager.volumes.isEmpty {
                    Spacer()
                    ProgressView("加载卷列表…")
                    Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                        Text("没有卷").font(.title2).foregroundStyle(.secondary)
                        Text("点击工具栏「创建卷」开始").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(selection: $selID) {
                        ForEach(filtered) { vol in
                            VolumeRow(volume: vol, onDelete: {
                                deleteTarget = vol; showDeleteAlert = true
                            })
                            .tag(vol.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            .layoutPriority(0)

            if let v = sel {
                VolumeDetailView(volume: v, manager: manager, onDelete: {
                    deleteTarget = v; showDeleteAlert = true
                })
                .frame(minWidth: 300)
                .layoutPriority(1)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("选择卷查看详情").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.2))
                .layoutPriority(1)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { Task { await manager.fetchVolumes() } }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }.help("刷新卷列表")

                Button(action: { showCreateSheet = true }) {
                    Label("创建卷", systemImage: "plus")
                }.help("创建新卷")

                if !manager.volumes.isEmpty {
                    Button(action: { showPruneAlert = true }) {
                        Label("清理未使用", systemImage: "trash")
                    }.help("清理未使用的卷")
                }

                TextField("搜索卷...", text: $search)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 160)
                    .help("按名称搜索卷")

                // 进度条已由底部 CommandProgressView 统一展示，不再在工具条重复显示
                // if manager.isLoading {
                //     ProgressView().scaleEffect(0.6)
                // }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateVolumeSheet(manager: manager, isPresented: $showCreateSheet)
        }
        .alert("确认删除", isPresented: $showDeleteAlert, presenting: deleteTarget) { vol in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { try? await manager.deleteVolume(name: vol.name) } }
        } message: { vol in Text("删除卷「\(vol.name)」后数据将不可恢复。") }
        .alert("清理未使用的卷", isPresented: $showPruneAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { Task { try? await manager.pruneVolumes() } }
        } message: { Text("将删除所有未被容器引用的卷。") }
        .onAppear { Task { await manager.fetchVolumes() } }
    }
}

// MARK: - 创建卷表单

struct CreateVolumeSheet: View {
    @ObservedObject var manager: VolumeManager
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var size = ""
    @State private var labels = ""
    @State private var options = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("创建卷").font(.title2.weight(.semibold))
            TextField("卷名称", text: $name).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("大小（如 10G，可选）", text: $size).textFieldStyle(.roundedBorder)
                Text("支持 K/M/G/T/P 后缀").font(.caption2).foregroundStyle(.secondary)
            }
            TextField("标签（key=value，逗号分隔，可选）", text: $labels).textFieldStyle(.roundedBorder)
            TextField("选项（key=value，逗号分隔，可选）", text: $options).textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { isPresented = false }
                Spacer()
                Button("创建") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    isCreating = true
                    errorMessage = nil
                    Task {
                        do {
                            try await manager.createVolume(name: n,
                                                           size: size.trimmingCharacters(in: .whitespaces).isEmpty ? nil : size.trimmingCharacters(in: .whitespaces),
                                                           labels: parseKV(labels),
                                                           options: parseKV(options))
                            isPresented = false
                        } catch {
                            errorMessage = "创建失败: \(error.localizedDescription)"
                            isCreating = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func parseKV(_ s: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in s.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let v = String(kv[1]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { dict[k] = v }
        }
        return dict
    }
}

// MARK: - 行

struct VolumeRow: View {
    let volume: VolumeInfo
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive").foregroundStyle(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).font(.headline)
                HStack(spacing: 8) {
                    Text("驱动: \(volume.driver)").font(.caption).foregroundStyle(.secondary)
                    if let fmt = volume.format { Text("格式: \(fmt)").font(.caption).foregroundStyle(.secondary) }
                    if !volume.sizeDescription.isEmpty { Text(volume.sizeDescription).font(.caption).foregroundStyle(.secondary) }
                }
                Text(volume.source).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(action: onDelete) { Image(systemName: "trash").foregroundStyle(.red) }
                .buttonStyle(.borderless).help("删除")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - 详情（对齐容器详情布局）

struct VolumeDetailView: View {
    let volume: VolumeInfo
    @ObservedObject var manager: VolumeManager
    let onDelete: () -> Void
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题头
                HStack {
                    VStack(alignment: .leading) {
                        Text(volume.name).font(.largeTitle).bold()
                        if !volume.source.isEmpty {
                            Text("来源: \(volume.source)")
                                .font(.subheadline).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Text(volume.driver).font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(12)
                }
                Divider()

                // 基本信息卡片
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    InfoCard(title: "名称", value: volume.name, icon: "externaldrive", color: .blue)
                    InfoCard(title: "驱动", value: volume.driver, icon: "gearshape", color: .indigo)
                    if let fmt = volume.format {
                        InfoCard(title: "格式", value: fmt, icon: "doc", color: .orange)
                    }
                    if let bytes = volume.sizeInBytes {
                        InfoCard(title: "大小", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), icon: "internaldrive", color: .green)
                    }
                    if let created = volume.createdAt {
                        InfoCard(title: "创建时间", value: formatDate(created), icon: "calendar", color: .indigo)
                    }
                }

                // 标签
                if let labels = volume.labels, !labels.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("标签", systemImage: "tag").font(.caption).foregroundStyle(.secondary)
                        ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            Text("\(k) = \(v)")
                                .font(.caption.monospaced()).padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // 选项
                if let options = volume.options, !options.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("选项", systemImage: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
                        ForEach(options.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            Text("\(k) = \(v)")
                                .font(.caption.monospaced()).padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                // 操作按钮
                HStack(spacing: 12) {
                    Button("刷新") { Task { await manager.fetchVolumes() } }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("删除", role: .destructive) { showDelete = true }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .alert("确认删除", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { onDelete() }
        } message: { Text("删除卷「\(volume.name)」后数据将不可恢复。") }
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            dateFormatter.timeStyle = .medium
            return dateFormatter.string(from: date)
        }
        return isoString
    }
}
