//
//  PluginMarketView.swift
//  AiguruContainerPanel
//
//  插件市场管理弹出视图：完整工具栏 + 表单，风格统一。
//

import SwiftUI

// MARK: - 市场源管理面板（弹出 sheet）
struct MarketSourceManagerView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAddSheet = false
    @State private var editSource: PluginSourceConfig? = nil
    @State private var deleteTarget: PluginSourceConfig? = nil
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if pluginManager.sources.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("未配置任何市场源").font(.title2).foregroundStyle(.secondary)
                        Text("点击右上角「添加」按钮添加市场地址").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(pluginManager.sources) { source in
                                sourceRow(source)
                            }
                        } header: {
                            Text("已配置的市场源")
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("管理市场源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAddSheet = true }) {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                sourceForm(title: "添加市场源") { name, url in
                    pluginManager.addCustomSource(name: name, url: url)
                    showAddSheet = false
                }
            }
            .sheet(item: $editSource) { source in
                sourceForm(title: "编辑市场源", name: source.name, url: source.url) { name, url in
                    pluginManager.updateSource(source, name: name, url: url)
                    editSource = nil
                }
            }
            .alert("删除市场源", isPresented: $showDeleteAlert, presenting: deleteTarget) { src in
                Button("删除", role: .destructive) {
                    pluginManager.deleteSource(src)
                }
                Button("取消", role: .cancel) {}
            } message: { src in
                Text("确定要删除市场「\(src.name)」吗？")
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 440)
    }

    // MARK: - Source row
    private func sourceRow(_ source: PluginSourceConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: source.isCustom ? "network" : "building.2.fill")
                .foregroundStyle(source.isCustom ? .blue : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline)
                    if !source.isCustom {
                        Text("内置").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                Text(source.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if source.isCustom {
                Button(action: { editSource = source }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("编辑")
                Button(action: { deleteTarget = source; showDeleteAlert = true }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("删除")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Source add/edit form
private struct sourceForm: View {
    let title: String
    var name: String = ""
    var url: String = ""
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editName: String
    @State private var editURL: String

    init(title: String, name: String = "", url: String = "", onSave: @escaping (String, String) -> Void) {
        self.title = title
        self.name = name
        self.url = url
        self.onSave = onSave
        _editName = State(initialValue: name)
        _editURL = State(initialValue: url)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("市场名称").font(.callout).foregroundStyle(.secondary)
                    TextField("如 GitHub 官方、阿里云镜像", text: $editName)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("市场地址").font(.callout).foregroundStyle(.secondary)
                    TextField("https://example.com/plugins.json", text: $editURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                }
                Text("地址指向返回插件列表的 JSON 接口。")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button("保存") {
                        let n = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let u = editURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !n.isEmpty, !u.isEmpty else { return }
                        onSave(n, u)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              editURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .frame(width: 460, height: 280)
    }
}
