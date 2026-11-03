//
//  ContainerLogView.swift
//  AiguruContainerPanel
//
//  容器日志查看视图，显示容器日志并支持实时刷新。
//

import SwiftUI

struct ContainerLogView: View {
    @ObservedObject var viewModel: ContainerListViewModel
    @Environment(\.dismiss) var dismiss
    @State private var autoScroll = true
    @State private var tailLines = 100

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("容器日志")
                    .font(.headline)
                if let container = viewModel.logContainer {
                    Text("· \(container.displayName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("行数", selection: $tailLines) {
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
                .frame(width: 100)
                .onChange(of: tailLines) {_, newValue in
                    if let container = viewModel.logContainer {
                        viewModel.fetchLogs(for: container, tail: newValue)
                    }
                }
                Button(action: {
                    if let container = viewModel.logContainer {
                        viewModel.fetchLogs(for: container, tail: tailLines)
                    }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新日志")
                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(SwitchToggleStyle())
                    .frame(width: 100)
                    .scaleEffect(0.7)
                Button("关闭") {
                    viewModel.closeLogView()
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            // 日志内容
            if viewModel.isLogLoading {
                ProgressView("加载日志...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.logLines.isEmpty {
                Text("暂无日志")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(viewModel.logLines.indices, id: \.self) { index in
                                Text(viewModel.logLines[index])
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index % 2 == 0 ? Color.clear : Color(NSColor.controlBackgroundColor).opacity(0.3))
                            }
                        }
                    }
                    .onChange(of: viewModel.logLines) {
                        if autoScroll, let last = viewModel.logLines.indices.last {
                            withAnimation {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // 底部工具栏
            HStack {
                Button(action: {
                    if let container = viewModel.logContainer {
                        viewModel.fetchLogs(for: container, tail: tailLines)
                    }
                }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text("共 \(viewModel.logLines.count) 行")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("复制全部") {
                    let text = viewModel.logLines.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .font(.caption)
                Button("清空") {
                    viewModel.logLines = []
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .frame(width: 800, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            if let container = viewModel.logContainer {
                viewModel.fetchLogs(for: container, tail: tailLines)
            }
        }
    }
}
