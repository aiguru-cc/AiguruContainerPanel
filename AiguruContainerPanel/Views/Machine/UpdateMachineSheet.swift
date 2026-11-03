//
//  UpdateMachineSheet.swift
//  AiguruContainerPanel
//
//  更新 Machine 配置：CPU、内存、Home 挂载、虚拟化、内核
//

import SwiftUI

struct UpdateMachineSheet: View {
    let machine: ContainerMachine
    @ObservedObject var viewModel: MachineListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var cpus: String
    @State private var memory: String
    @State private var homeMount: String
    @State private var virtualization: Bool
    @State private var kernel: String

    private let homeMountOptions = ["rw", "ro", "none"]

    init(machine: ContainerMachine, viewModel: MachineListViewModel) {
        self.machine = machine
        self.viewModel = viewModel
        _cpus = State(initialValue: machine.cpus.map { "\($0)" } ?? "")
        _memory = State(initialValue: machine.memory)
        _homeMount = State(initialValue: "rw")
        _virtualization = State(initialValue: false)
        _kernel = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    LabeledContent("名称", value: machine.displayName)
                    if let ip = machine.ipAddress {
                        LabeledContent("IP", value: ip)
                    }
                    LabeledContent("状态", value: machine.state.displayName)
                }

                Section("资源") {
                    TextField("CPU 核数", text: $cpus)
                        .textFieldStyle(.roundedBorder)
                    TextField("内存 (如 8G, 4096M)", text: $memory)
                        .textFieldStyle(.roundedBorder)
                    Text("更改将在下次停止/启动后生效")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Home 目录挂载") {
                    Picker("挂载模式", selection: $homeMount) {
                        Text("读写 (rw)").tag("rw")
                        Text("只读 (ro)").tag("ro")
                        Text("不挂载 (none)").tag("none")
                    }
                    .pickerStyle(.radioGroup)
                }

                Section("高级") {
                    Toggle("启用嵌套虚拟化", isOn: $virtualization)
                        .help("需要 Apple Silicon M3+、macOS 15+ 及支持 KVM 的内核")
                    TextField("自定义内核路径 (留空使用系统默认)", text: $kernel)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("更新 \(machine.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let config = MachineConfig(
                            cpus: Int(cpus),
                            memory: memory.trimmingCharacters(in: .whitespaces).isEmpty ? nil : memory,
                            homeMount: homeMount,
                            virtualization: virtualization,
                            kernel: kernel.trimmingCharacters(in: .whitespaces).isEmpty ? nil : kernel
                        )
                        viewModel.updateMachine(machine, config: config)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}
