//
//  MachineListView.swift
//  AiguruContainerPanel
//
//  Machine 管理 — HSplitView 列表 + 详情，对齐容器管理布局。
//

import SwiftUI

struct MachineListView: View {
    @StateObject private var vm = MachineListViewModel()
    @State private var showCreate = false
    @State private var showUpdate: ContainerMachine? = nil
    @State private var search = ""
    @State private var selID: String? = nil

    var filtered: [ContainerMachine] {
        var r = vm.machines
        if !search.isEmpty { r = r.filter { $0.displayName.localizedCaseInsensitiveContains(search) } }
        return r
    }
    var sel: ContainerMachine? { filtered.first { $0.id == selID } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                if vm.isLoading && vm.machines.isEmpty {
                    Spacer(); ProgressView("加载中..."); Spacer()
                } else if filtered.isEmpty {
                    Spacer()
                    VStack(spacing: 12) { Image(systemName: "macpro.gen1").font(.largeTitle).foregroundStyle(.secondary); Text("没有 Machine").font(.title2).foregroundStyle(.secondary) }
                    Spacer()
                } else {
                    List(selection: $selID) {
                        ForEach(filtered) { m in MachineRow(m: m).tag(m.id) }
                    }.listStyle(.plain)
                }
            }.frame(minWidth: 280, idealWidth: 320, maxWidth: 400).layoutPriority(0)

            if let m = sel {
                MachineDetailView(machine: m, vm: vm, onSettings: { showUpdate = m }).frame(minWidth: 300).layoutPriority(1)
            } else {
                VStack(spacing: 12) { Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(.secondary); Text("选择 Machine 查看详情").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.2)).layoutPriority(1)
            }
        }
        .sheet(isPresented: $showCreate) { CreateMachineSheet(viewModel: vm).environmentObject(MachineManager.shared).environmentObject(SourceImageManager.shared).environmentObject(MachineImageManager.shared) }
        .sheet(item: $showUpdate) { m in UpdateMachineSheet(machine: m, viewModel: vm) }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { vm.refreshMachines() } }
        .alert("错误", isPresented: .constant(vm.errorMessage != nil)) { Button("确定") { vm.errorMessage = nil } } message: { Text(vm.errorMessage ?? "") }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.refreshMachines() }) { Label("刷新", systemImage: "arrow.clockwise") }.help("刷新")
                Button(action: { showCreate = true }) { Label("创建", systemImage: "plus") }.help("创建 Machine")
                TextField("搜索...", text: $search).textFieldStyle(.roundedBorder).frame(width: 140)
                // 进度条已由底部 CommandProgressView 统一展示，不再在工具条重复显示
                // if vm.isLoading { ProgressView().scaleEffect(0.6) }
            }
        }
    }
}

struct MachineRow: View {
    let m: ContainerMachine
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: m.state == .running ? "play.circle.fill" : "stop.circle.fill")
                .foregroundStyle(m.state.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayName).font(.headline)
                if let ip = m.ipAddress { Text(ip).font(.caption).foregroundStyle(.secondary) }
                if let c = m.cpus { Text("\(c) 核 · \(m.memory) · \(m.disk)").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(m.state.displayName).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(m.state.color.opacity(0.15)).cornerRadius(4).foregroundStyle(m.state.color)
        }.padding(.vertical, 3).contentShape(Rectangle())
    }
}

struct MachineDetailView: View {
    let machine: ContainerMachine
    @ObservedObject var vm: MachineListViewModel
    var onSettings: (() -> Void)? = nil
    @State private var showDelete = false
    @State private var showCmd = false
    @State private var cmdText = ""
    @State private var showLogs = false
    @State private var logLines: [String] = []
    @State private var isLogLoading = false
    @State private var logShowBoot = false
    @State private var logTail: Int = 0
    private let logTailChoices = [0, 50, 100, 200, 500]
    private let mgr = MachineManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 标题头
                HStack {
                    VStack(alignment: .leading) {
                        Text(machine.displayName).font(.largeTitle).bold()
                        if let img = machine.image {
                            Text("镜像: \(img)").font(.subheadline).foregroundColor(.secondary)
                        } else if let ip = machine.ipAddress {
                            Text("IP: \(ip)").font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    statusBadge
                }
                Divider()

                // 基本信息卡片（对齐容器详情）
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    InfoCard(title: "ID", value: machine.id, icon: "number", color: .blue)
                    InfoCard(title: "状态", value: machine.state.displayName, icon: "circle.fill", color: machine.state.color)
                    if let created = machine.createdAt {
                        InfoCard(title: "创建时间", value: formatDate(created), icon: "calendar", color: .indigo)
                    }
                    if let cpus = machine.cpus {
                        InfoCard(title: "CPU", value: "\(cpus) 核", icon: "cpu", color: .blue)
                    }
                    if !machine.memory.isEmpty {
                        InfoCard(title: "内存", value: machine.memory, icon: "memorychip", color: .green)
                    }
                    if !machine.disk.isEmpty {
                        InfoCard(title: "磁盘", value: machine.disk, icon: "internaldrive", color: .orange)
                    }
                    if let ip = machine.ipAddress {
                        InfoCard(title: "IP", value: ip, icon: "globe", color: .teal)
                    }
                    if machine.isDefault {
                        InfoCard(title: "默认", value: "是", icon: "checkmark.seal.fill", color: .purple)
                    }
                }

                // 操作按钮
                HStack(spacing: 12) {
                    if machine.state == .running {
                        Button("停止") { vm.stopMachine(machine) }
                            .buttonStyle(.bordered)
                            .foregroundColor(.orange)
                        Button("运行命令") { showCmd = true }
                            .buttonStyle(.bordered)
                    } else {
                        Button("启动") { vm.startMachine(machine) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("终端") { openTerminal(for: machine) }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                    Button("日志") { showLogs = true; loadLogs() }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                    if let onSettings {
                        Button("设置") { onSettings() }
                            .buttonStyle(.bordered)
                    }
                    Button("设为默认") { vm.setDefaultMachine(machine) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("删除", role: .destructive) { showDelete = true }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                }
                .padding(.top, 8)

                if showCmd {
                    HStack {
                        TextField("输入命令...", text: $cmdText).textFieldStyle(.roundedBorder)
                        Button("执行") { vm.runCommand(in: machine, command: cmdText); showCmd = false; cmdText = "" }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
        }
        .id(machine.id + machine.state.rawValue)
        .task { await mgr.fetchImage(for: machine) }
        .sheet(isPresented: $showLogs) {
            MachineLogView(
                lines: logLines,
                title: "\(machine.displayName) 日志",
                isLoading: isLogLoading,
                showBoot: $logShowBoot,
                tail: $logTail,
                tailChoices: logTailChoices,
                onReload: loadLogs
            )
        }
        .alert("确认删除", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}; Button("删除", role: .destructive) { vm.deleteMachine(machine) }
        } message: { Text("删除 Machine「\(machine.displayName)」及其持久化存储？") }
    }

    private var statusBadge: some View {
        Text(machine.state.displayName)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(machine.state.color.opacity(0.2))
            .foregroundColor(machine.state.color)
            .cornerRadius(12)
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

    private func loadLogs() {
        isLogLoading = true
        Task {
            do {
                let output = try await mgr.fetchMachineLogs(
                    machine,
                    boot: logShowBoot,
                    tail: logTail > 0 ? logTail : nil
                )
                logLines = output.split(separator: "\n").map(String.init)
            } catch {
                logLines = ["获取日志失败: \(error.localizedDescription)"]
            }
            isLogLoading = false
        }
    }

    private func openTerminal(for machine: ContainerMachine) {
        let command = ContainerCommandBuilder.displayCommand(for: CLICommandCatalog.shared.arguments(
            command: "machine.run", options: ["name": [machine.name]]
        ))
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to do script \"\(escaped)\""
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        do { try process.run() } catch { vm.errorMessage = "无法打开终端: \(error.localizedDescription)" }
    }
}

// MARK: - Machine 日志视图
struct MachineLogView: View {
    let lines: [String]
    let title: String
    let isLoading: Bool
    @Binding var showBoot: Bool
    @Binding var tail: Int
    let tailChoices: [Int]
    let onReload: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                HStack(spacing: 12) {
                    Toggle("启动日志 (--boot)", isOn: $showBoot)
                        .toggleStyle(.switch).controlSize(.small)
                    Picker("行数", selection: $tail) {
                        ForEach(tailChoices, id: \.self) { n in
                            Text(n == 0 ? "全部" : "\(n) 行").tag(n)
                        }
                    }
                    .frame(width: 110)
                    Button {
                        onReload()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(isLoading)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if isLoading {
                    ProgressView("加载日志...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    Text("暂无日志")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top) {
                                    Text("\(index+1)")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                        .frame(width: 40, alignment: .trailing)
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
}
