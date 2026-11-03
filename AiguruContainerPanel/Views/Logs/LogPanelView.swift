//
//  LogPanelView.swift
//  AiguruContainerPanel
//
//  底部日志面板，显示最近日志，增加复制全部功能。
//

import SwiftUI

struct LogPanelView: View {
    @StateObject private var viewModel = LogViewModel()
    @State private var autoScroll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("操作日志")
                    .font(.headline)
                Spacer()
                // ✅ 新增：复制全部
                Button(action: copyAllLogs) {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制全部日志")
                .disabled(viewModel.logs.isEmpty)
                .padding(8)
                Button(action: { viewModel.loadLogs() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .padding(8)
                .help("刷新日志")
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(0.7)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                List(viewModel.logs.prefix(20), id: \.objectID) { entry in
                    HStack {
                        Text(entry.timestamp?.formatted(date: .numeric, time: .standard) ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(entry.module ?? "")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(entry.operationType ?? "")
                            .font(.caption)
                            .foregroundColor(.purple)
                        Text(entry.command?.prefix(50) ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: entry.result == "成功" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(entry.result == "成功" ? .green : .red)
                    }
                    .id(entry.objectID)
                }
                .listStyle(PlainListStyle())
                .onChange(of: viewModel.logs) {
                    if autoScroll, let last = viewModel.logs.first {
                        proxy.scrollTo(last.objectID, anchor: .bottom)
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadLogs()
        }
        .overlay(alignment: .top) {
            Rectangle().fill(.gray).frame(height: 0.5)
        }
    }

    private func copyAllLogs() {
        let logs = viewModel.logs.prefix(20)
        let text = logs.map { entry in
            let time = entry.timestamp?.formatted(date: .numeric, time: .standard) ?? ""
            let module = entry.module ?? ""
            let op = entry.operationType ?? ""
            let cmd = entry.command ?? ""
            let result = entry.result ?? ""
            return "[\(time)] [\(module)] [\(op)] \(cmd) -> \(result)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
