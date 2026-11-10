//
//  CommandProgressView.swift
//  AiguruContainerPanel
//
//  全局任务面板，显示当前执行的命令、进度和实时输出。
//  统一使用 TaskManager，不再依赖具体 ViewModel。
//

import SwiftUI

struct CommandProgressView: View {
    @EnvironmentObject var taskManager: TaskManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if taskManager.showTaskPanel {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("正在执行:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(taskManager.currentModule) - \(taskManager.currentOperation)")
                                .font(.caption)
                                .bold()
                            Spacer()
//                            Button(action: { taskManager.dismissPanel() }) {
//                                Image(systemName: "xmark.circle.fill")
//                                    .foregroundColor(.gray)
//                            }
//                            .buttonStyle(BorderlessButtonStyle())
                        }
                        Text(taskManager.currentCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    // 状态图标
                    switch taskManager.status {
                    case .running:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.7)
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    case .failure:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)

                // 进度条 / 倒计时
                if taskManager.hasTimeout {
                    HStack(spacing: 6) {
                        ProgressView(value: Double(taskManager.remainingSeconds), total: max(Double(taskManager.remainingSeconds), 1))
                            .progressViewStyle(LinearProgressViewStyle())
                        Text("\(taskManager.remainingSeconds)s")
                            .font(.caption2.monospaced())
                            .foregroundStyle(taskManager.remainingSeconds < 10 ? .red : .secondary)
                        Button("续期 +600s") { taskManager.extendTimeout() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("为当前计时任务增加 600 秒")
                    }
                } else if taskManager.isProgressIndeterminate {
                    ProgressView()
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 1)
                } else {
                    ProgressView(value: taskManager.progress, total: 1.0)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 1)
                        .animation(.easeInOut(duration: 0.3), value: taskManager.progress)
                }

                // 实时输出（可滚动）
                if !taskManager.liveOutput.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(taskManager.liveOutput.indices, id: \.self) { i in
                                    Text(taskManager.liveOutput[i])
                                        .font(.system(.caption, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .onChange(of: taskManager.liveOutput) { _, _ in
                                if let last = taskManager.liveOutput.indices.last {
                                    proxy.scrollTo(last, anchor: .trailing)
                                }
                            }
                        }
                        .frame(maxHeight: 40)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(4)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(4)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: -1)
    }
}
