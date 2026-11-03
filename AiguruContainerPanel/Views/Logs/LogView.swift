//
//  LogView.swift
//  AiguruContainerPanel
//
//  完整日志管理视图，支持筛选、搜索、复制。
//  点选日志行展开详情，手动管理选中状态，确保稳定。
//

import SwiftUI

struct LogView: View {
    @StateObject private var viewModel = LogViewModel()
    @State private var selectedModule = "全部"
    @State private var selectedResult = "全部"

    let modules = ["全部", "容器", "镜像", "网络", "卷", "Machine", "系统"]
    let results = ["全部", "成功", "失败"]

    var body: some View {
        VStack {
            // 工具栏
            HStack {
                Picker("模块", selection: $selectedModule) {
                    ForEach(modules, id: \.self) { Text($0) }
                }
                .frame(width: 120)
                .onChange(of: selectedModule) { _, newValue in
                    viewModel.filterModule = newValue == "全部" ? nil : newValue
                    viewModel.applyFilters()
                }

                Picker("结果", selection: $selectedResult) {
                    ForEach(results, id: \.self) { Text($0) }
                }
                .frame(width: 100)
                .onChange(of: selectedResult) { _, newValue in
                    viewModel.filterResult = newValue == "全部" ? nil : newValue
                    viewModel.applyFilters()
                }

                TextField("搜索命令或输出...", text: $viewModel.searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 200)
                    .onChange(of: viewModel.searchText) { _, _ in
                        viewModel.applyFilters()
                    }

                Spacer()

                Button(action: { viewModel.copyAllLogs() }) {
                    Label("复制全部", systemImage: "doc.on.doc")
                }
                .help("复制所有日志到剪贴板")

                Button("导出...") { /* 导出功能 */ }
                Button("清空所有") { viewModel.clearAllLogs() }
                    .foregroundColor(.red)
                Button("刷新") { viewModel.loadLogs() }
            }
            .padding()

            // 日志列表（手动管理选中）
            List(viewModel.logs, id: \.objectID) { entry in
                LogEntryRow(entry: entry)
                    .onTapGesture {
                        // 点击切换选中状态：再次点击同一行取消选中
                        if viewModel.selectedLog?.objectID == entry.objectID {
                            viewModel.selectedLog = nil
                        } else {
                            viewModel.selectedLog = entry
                        }
                    }
                    .background(
                        // 高亮选中的行
                        viewModel.selectedLog?.objectID == entry.objectID
                            ? Color.blue.opacity(0.1)
                            : Color.clear
                    )
                    .contextMenu {
                        Button("复制本条日志") {
                            viewModel.copyLogEntry(entry)
                        }
                        Button("删除") {
                            viewModel.deleteLog(entry)
                        }
                    }
            }
            .listStyle(PlainListStyle())
            .onAppear {
                viewModel.loadLogs()
            }

            // ✅ 详情面板（根据选中状态展开）
            if let selected = viewModel.selectedLog {
                Divider()
                LogDetailView(entry: selected, viewModel: viewModel)
                    .padding()
                    .frame(maxHeight: 200)
            }
        }
    }
}

// MARK: - 日志条目行
struct LogEntryRow: View {
    let entry: AiguruContainerPanel.LogEntry

    var body: some View {
        HStack {
            Text(entry.timestamp?.formatted(date: .numeric, time: .standard) ?? "")
                .font(.caption)
                .frame(width: 120, alignment: .leading)
            Text(entry.user ?? "")
                .font(.caption)
                .frame(width: 80)
            Text(entry.module ?? "")
                .font(.caption)
                .foregroundColor(.blue)
                .frame(width: 80)
            Text(entry.operationType ?? "")
                .font(.caption)
                .foregroundColor(.purple)
                .frame(width: 80)
            Text(entry.command?.prefix(80) ?? "")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Image(systemName: entry.result == "成功" ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(entry.result == "成功" ? .green : .red)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 日志详情视图（含复制按钮）
struct LogDetailView: View {
    let entry: AiguruContainerPanel.LogEntry
    @ObservedObject var viewModel: LogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("完整命令:")
                    .font(.headline)
                Spacer()
                Button(action: { viewModel.copyLogEntry(entry) }) {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .help("复制此条日志到剪贴板")
            }

            Text(entry.command ?? "")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            HStack {
                Text("执行模式: \(entry.executionMode ?? "")")
                Text("耗时: \(entry.duration, specifier: "%.3f")秒")
                Text("退出码: \(entry.exitCode)")
            }
            .font(.caption)

            Text("输出摘要:")
                .font(.headline)
            Text(entry.outputSummary ?? "")
                .font(.caption)
                .textSelection(.enabled)

            if let full = entry.fullOutput, full != entry.outputSummary {
                DisclosureGroup("查看完整输出") {
                    ScrollView {
                        Text(full)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}
