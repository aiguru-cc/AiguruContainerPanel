//
//  NetworkView.swift
//  AiguruContainerPanel
//
//  网络管理 — HSplitView 列表 + 详情，含创建/删除/检查/清理。
//

import SwiftUI
import Combine

struct HostsEntry: Identifiable, Hashable {
    let address: String
    let hostnames: [String]
    var id: String { "\(address)|\(hostnames.joined(separator: ","))" }
}
struct HostsGroup: Identifiable {
    let name: String
    let entries: [HostsEntry]
    var id: String { name }
}

struct NetworkView: View {
    @StateObject private var vm = NetworkViewModel()
    @State private var selID: String?
    @State private var showCreate = false
    @State private var showPruneConfirm = false
    @State private var showInspect = false
    @State private var inspectOutput = ""
    @State private var showError = false
    // 宿主机 DNS 域管理（container system dns，需要管理员权限）
    @State private var showDnsCreate = false
    @State private var dnsToDelete: String?
    @State private var dnsPendingDelete = ""
    @State private var dnsPendingDomain = ""
    @State private var dnsPendingLocalhost = ""
    @State private var sudoMode: DnsSudoMode = .create
    @State private var showSudoPrompt = false
    @State private var sudoPassword = ""
    @State private var sudoBusy = false
    @State private var sudoError: String?
    @State private var showDnsProperty = false
    // 写入官方 config.toml [dns] domain 并重启
    @State private var showDnsConfigWrite = false
    @State private var dnsConfigDomain = ""
    @State private var dnsConfigBusy = false
    @State private var dnsConfigResult: String?
    @State private var showHostsTool = false

    var sel: NetworkInfo? { vm.networks.first { $0.id == selID } }

    var body: some View {
        TabView {
            networkPage
                .tabItem { Label("网络", systemImage: "network") }
            hostsPage
                .tabItem { Label("Hosts", systemImage: "list.bullet.rectangle") }
        }
        .tabViewStyle(.automatic)
        .sheet(isPresented: $showDnsCreate) {
            DnsCreateSheet { domain, localhost in
                dnsPendingDomain = domain
                dnsPendingLocalhost = localhost
                sudoMode = .create
                sudoError = nil
                sudoPassword = ""
                showSudoPrompt = true
            }
        }
        .sheet(isPresented: $showSudoPrompt) {
            SudoPasswordSheet(
                title: sudoMode == .create ? "配置 macOS DNS 解析" : "删除 macOS DNS 解析",
                message: sudoMode == .create
                    ? "将以管理员权限执行：container system dns create \(dnsPendingDomain)\(dnsPendingLocalhost.isEmpty ? "" : " --localhost \(dnsPendingLocalhost)")"
                    : "将以管理员权限执行：container system dns delete \(dnsPendingDelete)",
                password: $sudoPassword,
                busy: sudoBusy,
                error: sudoError
            ) {
                guard !sudoBusy else { return }
                sudoBusy = true
                sudoError = nil
                Task {
                    let err: String?
                    if sudoMode == .create {
                        err = await vm.createDnsDomain(domain: dnsPendingDomain, localhost: dnsPendingLocalhost.nilIfEmpty, password: sudoPassword)
                    } else {
                        err = await vm.deleteDnsDomain(domain: dnsPendingDelete, password: sudoPassword)
                    }
                    await MainActor.run {
                        sudoBusy = false
                        if let err { sudoError = err }
                        else { sudoPassword = ""; showSudoPrompt = false; dnsToDelete = nil; dnsPendingDelete = "" }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) { CreateNetworkSheet(vm: vm) }
        .alert("确认清理", isPresented: $showPruneConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { vm.prune() }
        } message: { Text("删除所有未连接容器的网络？") }
        .onAppear { vm.refresh(); vm.refreshDnsDomains(); vm.refreshSystemDnsProperty(); vm.refreshHosts() }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.refresh() }) { Label("刷新", systemImage: "arrow.clockwise") }
                Button(action: { showCreate = true }) { Label("创建", systemImage: "plus") }
                Button(action: { showPruneConfirm = true }) { Label("清理", systemImage: "trash") }
            }
        }
        .alert("错误", isPresented: $showError) { Button("确定") { showError = false; vm.errorMessage = nil } } message: { Text(vm.errorMessage ?? "") }
        .onChange(of: vm.errorMessage) { _, msg in if msg != nil { showError = true } }
    }

    private var networkPage: some View {
        VStack(spacing: 0) {
            dnsBar
            Divider()
            HStack(spacing: 0) {
            // 左侧列表
            VStack(spacing: 0) {
                if vm.isLoading && vm.networks.isEmpty {
                    Spacer(); ProgressView("加载中..."); Spacer()
                } else if vm.networks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "network.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("没有网络").font(.title2).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(selection: $selID) {
                        ForEach(vm.networks) { net in
                            NetworkRow(net: net, onDelete: { vm.delete(net.id) }).tag(net.id)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .layoutPriority(0)

            Divider()

            // 右侧详情
            if let net = sel {
                NetworkDetailView(network: net, vm: vm, showInspect: $showInspect, inspectOutput: $inspectOutput)
                    .frame(minWidth: 300)
                    .layoutPriority(1)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("选择一个网络查看详情").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.2))
                .layoutPriority(1)
            }
            }
        }
    }

    private var hostsPage: some View {
        HostsToolView(vm: vm)
    }

    private struct HostsToolView: View {
        @ObservedObject var vm: NetworkViewModel
        @State private var selectedID: String?
        @State private var pendingDelete: HostsEntry?
        @State private var deleteTarget: HostsEntry?
        @State private var showDeletePassword = false
        @State private var deletePassword = ""
        @State private var address = ""
        @State private var hostnames = ""
        @State private var busy = false
        @State private var error: String?
        var body: some View {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Text("/etc/hosts").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("IP 地址", text: $address).textFieldStyle(.roundedBorder)
                        TextField("域名（逗号分隔）", text: $hostnames).textFieldStyle(.roundedBorder)
                        Button("提交") { addHost() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing).disabled(busy)
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(12)
                    Spacer()
                }.frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                Divider()
                Group {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Label("Aiguru Hosts", systemImage: "checkmark.seal")
                                .font(.headline)
                            Spacer()
                            Text("\(vm.allHostsEntries.count) 条记录").foregroundStyle(.secondary)
                        }.padding(14)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(vm.managedHostGroups) { group in
                                    hostSection(group.name, entries: group.entries, managed: group.name == "AiguruContainerPanel")
                                }
                                hostSection("其它应用设置", entries: vm.otherHostsEntries, managed: false)
                            }
                            .padding(14)
                        }
                    }
                }.frame(maxWidth: .infinity).padding(24)
            }
            .alert("删除 Hosts 条目？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    deleteTarget = pendingDelete
                    deletePassword = ""
                    showDeletePassword = true
                }
            } message: { Text("删除选中的 Hosts 条目？确认后将打开 macOS 原生管理员授权窗口。") }
            .sheet(isPresented: $showDeletePassword) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("删除 Hosts 条目").font(.title2.bold())
                    if let entry = deleteTarget {
                        Text("将删除 \(entry.hostnames.joined(separator: ", ")) → \(entry.address)").foregroundStyle(.secondary)
                    }
                    Text("确认后将打开 macOS 原生管理员授权窗口。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { showDeletePassword = false }
                        Spacer()
                        Button("确认删除") {
                            showDeletePassword = false
                            deleteHost()
                        }.buttonStyle(.borderedProminent).disabled(busy)
                    }
                }
                .padding(20)
                .frame(width: 380)
            }
            .onAppear { vm.refreshHosts() }
        }

        @ViewBuilder private func hostSection(_ title: String, entries: [HostsEntry], managed: Bool) -> some View {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Label(title, systemImage: managed ? "checkmark.seal" : "externaldrive"); Spacer(); Text("\(entries.count) 条记录").foregroundStyle(.secondary) }
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .top) {
                                    Image(systemName: managed ? "checkmark.seal" : "externaldrive").foregroundStyle(managed ? .green : .secondary)
                                    Text(entry.hostnames.joined(separator: " ")).font(.headline).lineLimit(1); Spacer()
                                    if managed { Button(role: .destructive) { pendingDelete = entry } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                                }
                                Text(entry.address).font(.body.monospaced())
                            }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                        }
                    }
                }
            }
        }

        private func addHost() {
            busy = true; error = nil
            Task {
                let result = await vm.addHostsEntry(address: address, hostnames: hostnames, password: "")
                await MainActor.run { busy = false; error = result; if result == nil { address = ""; hostnames = "" } }
            }
        }

        private func deleteHost() {
            guard let entry = deleteTarget else { return }
            busy = true; error = nil
            Task {
                let result = await vm.deleteHostsEntry(entry, password: "")
                await MainActor.run {
                    busy = false
                    error = result
                    if result == nil {
                        selectedID = nil
                        pendingDelete = nil
                        deleteTarget = nil
                    }
                }
            }
        }
    }
    /* legacy body modifiers moved to the outer TabView */
        /* .sheet(isPresented: $showDnsCreate) {
            DnsCreateSheet { domain, localhost in
                dnsPendingDomain = domain
                dnsPendingLocalhost = localhost
                sudoMode = .create
                sudoError = nil
                sudoPassword = ""
                showSudoPrompt = true
            }
        }
        .sheet(isPresented: $showSudoPrompt) {
            SudoPasswordSheet(
                title: sudoMode == .create ? "配置 macOS DNS 解析" : "删除 macOS DNS 解析",
                message: sudoMode == .create
                    ? "将以管理员权限执行：container system dns create \(dnsPendingDomain)\(dnsPendingLocalhost.isEmpty ? "" : " --localhost \(dnsPendingLocalhost)")"
                    : "将以管理员权限执行：container system dns delete \(dnsPendingDelete)",
                password: $sudoPassword,
                busy: sudoBusy,
                error: sudoError
            ) {
                guard !sudoBusy else { return }
                sudoBusy = true
                sudoError = nil
                Task {
                    let err: String?
                    if sudoMode == .create {
                        err = await vm.createDnsDomain(domain: dnsPendingDomain, localhost: dnsPendingLocalhost.nilIfEmpty, password: sudoPassword)
                    } else {
                        err = await vm.deleteDnsDomain(domain: dnsPendingDelete, password: sudoPassword)
                    }
                    await MainActor.run {
                        sudoBusy = false
                        if let err {
                            sudoError = err
                        } else {
                            sudoPassword = ""
                            showSudoPrompt = false
                            dnsToDelete = nil
                            dnsPendingDelete = ""
                        }
                    }
                }
            }
        }
        .alert("删除 macOS DNS 域", isPresented: Binding(
            get: { dnsToDelete != nil },
            set: { if !$0 { dnsToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { dnsToDelete = nil }
            Button("删除", role: .destructive) {
                // alert 关闭时会触发 Binding set(false) 清空 dnsToDelete，先捕获到独立变量
                dnsPendingDelete = dnsToDelete ?? ""
                sudoMode = .delete
                sudoError = nil
                sudoPassword = ""
                showSudoPrompt = true
            }
        } message: {
            Text("删除 macOS DNS 解析域「\(dnsToDelete ?? "")」？此操作需要管理员权限。")
        }
        .sheet(isPresented: $showDnsConfigWrite) {
            DnsConfigWriteSheet(
                domain: $dnsConfigDomain,
                busy: dnsConfigBusy,
                result: dnsConfigResult
            ) {
                guard !dnsConfigBusy else { return }
                dnsConfigBusy = true
                dnsConfigResult = nil
                Task {
                    let err = await vm.writeDnsDomainToConfig(domain: dnsConfigDomain)
                    await MainActor.run {
                        dnsConfigBusy = false
                        dnsConfigResult = err ?? "✅ 已写入容器配置 config.toml 并重启服务，DNS 域生效"
                        if err == nil {
                            vm.refreshDnsDomains()
                            vm.refreshSystemDnsProperty()
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateNetworkSheet(vm: vm)
        }
        .sheet(isPresented: $showHostsTool) {
            HostsToolSheet(vm: vm)
        }
        .alert("确认清理", isPresented: $showPruneConfirm) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { vm.prune() }
        } message: {
            Text("删除所有未连接容器的网络？")
        }
        .onAppear {
            vm.refresh()
            vm.refreshDnsDomains()
            vm.refreshSystemDnsProperty()
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { vm.refresh() }) {
                    Label("刷新", systemImage: "arrow.clockwise")
                }.help("刷新")
                Button(action: { showCreate = true }) {
                    Label("创建", systemImage: "plus")
                }.help("创建网络")
                Button(action: { showPruneConfirm = true }) {
                    Label("清理", systemImage: "trash")
                }.help("清理未使用网络")
                Button(action: { vm.refreshHosts(); showHostsTool = true }) {
                    Label("Hosts", systemImage: "list.bullet.rectangle")
                }.help("管理宿主机 /etc/hosts 中的本地域名")
                // 进度条已由底部 CommandProgressView 统一展示，不再在工具条重复显示
                // if vm.isLoading { ProgressView().scaleEffect(0.6) }
            }
        }
        .alert("错误", isPresented: $showError) {
            Button("确定") { showError = false; vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onChange(of: vm.errorMessage) { _, msg in
            if msg != nil { showError = true }
        } */

    // MARK: - 宿主机 DNS 解析条（container system dns）

    private var dnsBar: some View {
        HStack(spacing: 10) {
            Label("macOS DNS 解析", systemImage: "network.badge.shield.half.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("container system dns — 让 macOS 将指定域名交给 container DNS 服务解析（需要管理员权限）")

            if let configuredDomain = vm.readConfiguredDnsDomain() {
                Label("容器名注册：\(configuredDomain)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("第 1 步已完成：default 网络的容器以 <名称>.\(configuredDomain) 注册")
            } else {
                Label("先配置容器名域", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("先使用“写入配置”设置 [dns].domain 并重启服务")
            }

            if vm.isDnsLoading {
                ProgressView().controlSize(.small)
            } else if vm.dnsDomains.isEmpty {
                Text("无").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(vm.dnsDomains, id: \.self) { domain in
                    HStack(spacing: 6) {
                        Text(domain)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        Button {
                            dnsToDelete = domain
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("删除 \(domain)")
                    }
                }
            }

            Spacer()

            Button {
                showDnsCreate = true
            } label: {
                Label("新建域", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .help("配置 macOS 解析域（container system dns create）；需先设置全局 [dns].domain")

            Button(action: { vm.refreshDnsDomains(); vm.refreshSystemDnsProperty() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新 DNS 域列表")

            Button {
                vm.refreshSystemDnsProperty()
            vm.refreshHosts()
                showDnsProperty = true
            } label: {
                Label("DNS 状态", systemImage: "checkmark.seal")
            }
            .buttonStyle(.borderless)
            .help("用 container system property list 检查 DNS 设置是否生效")

            Button {
                dnsConfigDomain = vm.readConfiguredDnsDomain() ?? vm.dnsDomains.first ?? "local"
                dnsConfigResult = nil
                showDnsConfigWrite = true
            } label: {
                Label("写入配置", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("把 DNS 域写入容器配置 config.toml 并重启服务使其生效")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
        .popover(isPresented: $showDnsProperty) {
            VStack(alignment: .leading, spacing: 8) {
                Text("DNS 设置状态").font(.headline)
                Divider()
                HStack(alignment: .top) {
                    Text("property list dns:")
                        .font(.caption).foregroundStyle(.secondary)
                    if vm.isPropertyLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(vm.systemDnsProperty ?? "—")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Text("容器名注册由 config.toml 的 [dns].domain 决定；system dns 只向 macOS 的 /etc/resolver/ 写入转发规则。两步都完成后，Mac 才能解析 <容器名>.<域>。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 360)
        }
    }
}

// MARK: - 配置 macOS DNS 解析 Sheet

struct DnsCreateSheet: View {
    let onDone: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var domain = ""
    @State private var localhost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("配置 macOS DNS 解析").font(.title2.weight(.semibold))
            Text("这是第 2 步：先在“写入配置”设置相同的 [dns].domain 并重启服务。此命令仅让 macOS 将 *.<域> 查询转发给 container DNS；容器间解析不依赖此步骤。需要管理员权限。")
                .font(.caption).foregroundStyle(.secondary)

            TextField("域名（必须与 [dns].domain 相同，如 test）", text: $domain)
                .textFieldStyle(.roundedBorder)
            TextField("--localhost 重定向 IP（可选）", text: $localhost)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("创建") {
                    onDone(
                        domain.trimmingCharacters(in: .whitespaces),
                        localhost.trimmingCharacters(in: .whitespaces)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - 管理员密码 Sheet

struct HostsToolSheet: View {
    @ObservedObject var vm: NetworkViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = "127.0.0.1"
    @State private var hostnames = "app.local"
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("本地域名 Hosts").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() } }
            Text("管理宿主机 /etc/hosts 的 Aiguru 专属区域；不会改动其他系统条目。写入需要管理员密码。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("IP 地址", text: $address).textFieldStyle(.roundedBorder)
                TextField("域名（逗号分隔）", text: $hostnames).textFieldStyle(.roundedBorder)
                SecureField("管理员密码", text: $password).textFieldStyle(.roundedBorder)
                Button("添加") { add() }.buttonStyle(.borderedProminent).disabled(busy)
            }
            Divider()
            if vm.isHostsLoading { ProgressView("读取中…") }
            else if vm.hostsEntries.isEmpty { Text("暂无托管条目").foregroundStyle(.secondary) }
            else { List(vm.hostsEntries) { entry in
                HStack { Text(entry.address).font(.body.monospaced()); Text(entry.hostnames.joined(separator: " ")); Spacer(); Button(role: .destructive) { delete(entry) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
            }.frame(minHeight: 160) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(20).frame(width: 700, height: 420).onAppear { vm.refreshHosts() }
    }
    private func add() { busy = true; error = nil; Task { let result = await vm.addHostsEntry(address: address.trimmingCharacters(in: .whitespacesAndNewlines), hostnames: hostnames, password: password); await MainActor.run { busy = false; error = result; if result == nil { password = "" } } } }
    private func delete(_ entry: HostsEntry) { busy = true; error = nil; Task { let result = await vm.deleteHostsEntry(entry, password: password); await MainActor.run { busy = false; error = result; if result == nil { password = "" } } } }
}

enum DnsSudoMode {
    case create
    case delete
}

struct SudoPasswordSheet: View {
    let title: String
    let message: String
    @Binding var password: String
    let busy: Bool
    let error: String?
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
            SecureField("管理员密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !busy { onConfirm() } }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { dismiss() }
                    .disabled(busy)
                Spacer()
                Button("执行") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - 写入 DNS 配置 Sheet

struct DnsConfigWriteSheet: View {
    @Binding var domain: String
    let busy: Bool
    let result: String?
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/container/config.toml").path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("写入 DNS 配置").font(.title3.weight(.semibold))
            Text("这是第 1 步：把 [dns] domain 写入官方配置 \(configPath)，随后重启服务。容器将在 default 网络注册为 <名称>.<域>。如需让 Mac 也解析，再配置上方的 macOS DNS 解析。")
                .font(.caption).foregroundStyle(.secondary)

            TextField("DNS 域（如 test）", text: $domain)
                .textFieldStyle(.roundedBorder)

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("写入并重启服务中...").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✅") ? .green : .red)
            }

            HStack {
                Button("取消") { dismiss() }
                    .disabled(busy)
                Spacer()
                Button("写入并重启服务") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - ViewModel
class NetworkViewModel: ObservableObject {
    @Published var networks: [NetworkInfo] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var dnsDomains: [String] = []
    @Published var isDnsLoading = false
    /// container system property list 中的 dns 配置（验证 DNS 是否设置成功）
    @Published var systemDnsProperty: String?
    @Published var isPropertyLoading = false
    @Published var hostsEntries: [HostsEntry] = []
    @Published var allHostsEntries: [HostsEntry] = []
    @Published var serverHostsEntries: [HostsEntry] = []
    @Published var otherHostsEntries: [HostsEntry] = []
    @Published var managedHostGroups: [HostsGroup] = []
    @Published var isHostsLoading = false
    private let mgr = NetworkManager.shared

    private let hostsPath = "/etc/hosts"
    private let hostsBegin = "# >>> AiguruContainerPanel managed block (do not edit manually)"
    private let hostsEnd = "# <<< AiguruContainerPanel managed block"

    func refreshHosts() {
        isHostsLoading = true
        Task { @MainActor in
            defer { isHostsLoading = false }
            do {
                let text = try String(contentsOfFile: hostsPath, encoding: .utf8)
                hostsEntries = parseHosts(text)
                allHostsEntries = parseAllHosts(text)
                managedHostGroups = parseManagedGroups(text)
                serverHostsEntries = managedHostGroups.first(where: { $0.name != "AiguruContainerPanel" })?.entries ?? []
                let managed = managedHostGroups.flatMap(\.entries)
                otherHostsEntries = allHostsEntries.filter { !managed.contains($0) }
            } catch { errorMessage = "读取 /etc/hosts 失败：\(error.localizedDescription)" }
        }
    }

    func addHostsEntry(address: String, hostnames: String, password: String) async -> String? {
        let names = hostnames.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard isValidHostsAddress(address), !names.isEmpty, names.allSatisfy(isValidHostname) else { return "请输入有效 IP 地址和域名（支持逗号分隔多个域名）" }
        return await addHostsEntryAtomically(address: address, names: names)
        /*
        let names = hostnames.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard isValidHostsAddress(address), !names.isEmpty, names.allSatisfy(isValidHostname) else { return "请输入有效 IP 地址和域名（支持逗号分隔多个域名）" }
        return await updateManagedHosts({ entries in
            let filtered = entries.filter { $0.address != address }
            return filtered + [HostsEntry(address: address, hostnames: names)]
        }, password: password)
        */
    }

    private func addHostsEntryAtomically(address: String, names: [String]) async -> String? {
        do {
            let original = try String(contentsOfFile: hostsPath, encoding: .utf8)
            let existingNames = parseAllHosts(original).flatMap(\.hostnames)
            guard names.allSatisfy({ !existingNames.contains($0) }) else { return "域名已存在于 /etc/hosts，已取消添加" }
            let line = "\(address)\t\(names.joined(separator: " "))"
            let updated: String
            if let end = original.range(of: hostsEnd) {
                updated = String(original[..<end.lowerBound]) + line + "\n" + String(original[end.lowerBound...])
            } else {
                updated = original.trimmingCharacters(in: .newlines) + "\n\n" + hostsBegin + "\n" + line + "\n" + hostsEnd + "\n"
            }
            let temp = "/tmp/aiguru-hosts-\(UUID().uuidString)"
            try updated.write(toFile: temp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: temp) }
            _ = try await CommandExecutor.shared.executeAdministratorShellCommand("/usr/bin/cmp -s /etc/hosts '\(hostsPath)' && /usr/bin/install -m 644 '\(temp)' /etc/hosts")
            let verified = try String(contentsOfFile: hostsPath, encoding: .utf8)
            guard names.allSatisfy({ parseAllHosts(verified).flatMap(\.hostnames).contains($0) }) else { return "原子写入后校验失败，新增条目不存在" }
            await MainActor.run { refreshHosts() }
            return nil
        } catch { return error.localizedDescription }
    }

    func deleteHostsEntry(_ entry: HostsEntry, password: String = "") async -> String? {
        return await deleteHostsEntryAtomically(entry)
        /*
        do {
            let original = try String(contentsOfFile: hostsPath, encoding: .utf8)
            let updated = original.components(separatedBy: .newlines).filter { line in
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 2, String(parts[0]) == entry.address else { return true }
                return !parts.dropFirst().contains { entry.hostnames.contains(String($0)) }
            }.joined(separator: "\n")
            let encoded = Data(updated.utf8).base64EncodedString()
            let command = "/bin/printf '%s' '\(encoded)' | base64 -d | /usr/bin/tee /etc/hosts"
            let writeOutput = try await CommandExecutor.shared.executeAdministratorShellCommand(command)
            let verified = try String(contentsOfFile: hostsPath, encoding: .utf8)
            if parseAllHosts(verified).contains(where: { $0.id == entry.id }) {
                return "删除命令已执行，但 /etc/hosts 中仍存在该条目。授权输出：\(writeOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            await MainActor.run { refreshHosts() }
            return nil
        } catch { return error.localizedDescription }
        */
    }

    private func deleteHostsEntryAtomically(_ entry: HostsEntry) async -> String? {
        do {
            let original = try String(contentsOfFile: hostsPath, encoding: .utf8)
            let lines = original.components(separatedBy: .newlines)
            let matching = lines.filter { line in
                let body = line.split(separator: "#", maxSplits: 1).first ?? ""
                let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
                return parts.count >= 2 && String(parts[0]) == entry.address && parts.dropFirst().contains { entry.hostnames.contains(String($0)) }
            }
            guard matching.count == 1 else { return "未找到唯一匹配的 Hosts 条目，已取消删除" }
            let updated = lines.enumerated().filter { index, line in
                !matching.contains(line) || !line.contains(entry.hostnames.first ?? "\u{0}") || index != lines.firstIndex(of: line)
            }.map(\.element).joined(separator: "\n")
            let temp = "/tmp/aiguru-hosts-\(UUID().uuidString)"
            try updated.write(toFile: temp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: temp) }
            _ = try await CommandExecutor.shared.executeAdministratorShellCommand("/usr/bin/cmp -s /etc/hosts '\(hostsPath)' && /usr/bin/install -m 644 '\(temp)' /etc/hosts")
            let verified = try String(contentsOfFile: hostsPath, encoding: .utf8)
            guard !parseAllHosts(verified).contains(where: { $0.id == entry.id }) else { return "原子写入后校验失败，条目仍存在" }
            await MainActor.run { refreshHosts() }
            return nil
        } catch { return error.localizedDescription }
    }

    private func parseHosts(_ text: String) -> [HostsEntry] {
        guard let start = text.range(of: hostsBegin), let end = text.range(of: hostsEnd, range: start.upperBound..<text.endIndex) else { return [] }
        return text[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "#", maxSplits: 1).first?.split(whereSeparator: { $0 == " " || $0 == "\t" }) ?? []
            guard parts.count >= 2 else { return nil }
            return HostsEntry(address: String(parts[0]), hostnames: parts.dropFirst().map(String.init))
        }
    }

    private func parseAllHosts(_ text: String) -> [HostsEntry] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let content = trimmed.split(separator: "#", maxSplits: 1).first ?? ""
            let parts = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { return nil }
            return HostsEntry(address: String(parts[0]), hostnames: parts.dropFirst().map(String.init))
        }
    }

    private func parseBlock(_ text: String, begin: String, end: String) -> [HostsEntry] {
        guard let start = text.range(of: begin), let finish = text.range(of: end, range: start.upperBound..<text.endIndex) else { return [] }
        return parseAllHosts(String(text[start.upperBound..<finish.lowerBound]))
    }

    private func parseManagedGroups(_ text: String) -> [HostsGroup] {
        let lines = text.components(separatedBy: .newlines)
        var groups: [HostsGroup] = []
        var activeName: String?
        var activeLines = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# >>> ") && trimmed.contains(" managed block") {
                activeName = trimmed.replacingOccurrences(of: "# >>> ", with: "").replacingOccurrences(of: " (do not edit manually)", with: "").replacingOccurrences(of: " managed block", with: "").trimmingCharacters(in: .whitespaces)
                activeLines = ""
            } else if let name = activeName, trimmed.hasPrefix("# <<< ") {
                groups.append(HostsGroup(name: name, entries: parseAllHosts(activeLines)))
                activeName = nil
            } else if activeName != nil { activeLines += line + "\n" }
        }
        return groups
    }

    private func updateManagedHosts(_ transform: ([HostsEntry]) -> [HostsEntry], password: String) async -> String? {
        do {
            let original = try String(contentsOfFile: hostsPath, encoding: .utf8)
            let updatedEntries = transform(parseHosts(original))
            let block = ([hostsBegin] + updatedEntries.map { "\($0.address)\t\($0.hostnames.joined(separator: " "))" } + [hostsEnd]).joined(separator: "\n")
            let output: String
            if let start = original.range(of: hostsBegin), let end = original.range(of: hostsEnd, range: start.upperBound..<original.endIndex) {
                var replaced = original
                replaced.replaceSubrange(start.lowerBound..<end.upperBound, with: block)
                output = replaced
            } else {
                output = original.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n"
            }
            _ = try await CommandExecutor.shared.executeSystemCommandWithSudo(["/usr/bin/tee", hostsPath], password: password, stdinData: Data(output.utf8))
            await MainActor.run { self.refreshHosts() }
            return nil
        } catch { return error.localizedDescription }
    }

    private func isValidHostname(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 253 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    private func isValidHostsAddress(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 45 && value.allSatisfy { $0.isLetter || $0.isNumber || ".:".contains($0) }
    }

    // MARK: - macOS DNS 解析（container system dns）

    /// 读取 container system property list 的 dns 键，作为 DNS 设置是否写入系统配置的验证
    func refreshSystemDnsProperty() {
        isPropertyLoading = true
        Task {
            do {
                let output = try await CommandExecutor.shared.execute(CLICommandCatalog.shared.arguments(command: "system.property.list", options: ["format": ["json"]]))
                var text = "解析失败"
                if let data = output.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let dns = obj["dns"] {
                    text = String(describing: dns)
                }
                await MainActor.run {
                    systemDnsProperty = text
                    isPropertyLoading = false
                }
            } catch {
                await MainActor.run {
                    systemDnsProperty = "读取失败: \(error.localizedDescription)"
                    isPropertyLoading = false
                }
            }
        }
    }

    func refreshDnsDomains() {
        isDnsLoading = true
        Task {
            do {
                let output = try await CommandExecutor.shared.execute(CLICommandCatalog.shared.arguments(command: "system.dns.list", options: ["format": ["json"]]))
                let domains = (try? JSONDecoder().decode([String].self, from: Data(output.utf8))) ?? []
                await MainActor.run {
                    dnsDomains = domains
                    isDnsLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isDnsLoading = false
                }
            }
        }
    }

    /// 执行 container system dns create（sudo），成功返回 nil，失败返回错误信息
    func createDnsDomain(domain: String, localhost: String?, password: String) async -> String? {
        let configuredDomain = readConfiguredDnsDomain()?.lowercased()
        guard configuredDomain == domain.trimmingCharacters(in: .whitespaces).lowercased() else {
            return "请先把 [dns].domain 配置为 \(domain)，重启 container 服务后再配置 macOS DNS 解析"
        }
        let cliArgs = CLICommandCatalog.shared.arguments(command: "system.dns.create", options: [
            "localhost": localhost.map { [$0] } ?? []
        ], positionals: [domain])
        let args = [CommandExecutor.shared.currentCliPath] + cliArgs
        do {
            _ = try await CommandExecutor.shared.executeSystemCommandWithSudo(args, password: password)
            refreshDnsDomains()
            refreshSystemDnsProperty()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 执行 container system dns delete（sudo），成功返回 nil，失败返回错误信息
    func deleteDnsDomain(domain: String, password: String) async -> String? {
        do {
            _ = try await CommandExecutor.shared.executeSystemCommandWithSudo(
                [CommandExecutor.shared.currentCliPath] + CLICommandCatalog.shared.arguments(command: "system.dns.delete", positionals: [domain]),
                password: password
            )
            refreshDnsDomains()
            refreshSystemDnsProperty()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 写入 config.toml（[dns] domain）并重启服务

    /// 官方文档指定的运行时配置文件。
    private var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/container/config.toml").path
    }

    private func readConfig(from path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func writeConfig(_ content: String, to path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 读取 config.toml 中 [dns] domain 当前值（无则返回 nil）
    func readConfiguredDnsDomain() -> String? {
        let content = readConfig(from: configPath)
        guard let content else { return nil }
        var inDns = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inDns = (trimmed == "[dns]")
                continue
            }
            if inDns && trimmed.hasPrefix("domain") {
                // 兼容标准引号与全角引号
                let cleaned = trimmed
                    .replacingOccurrences(of: "domain", with: "")
                    .replacingOccurrences(of: "=", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "“", with: "")
                    .replacingOccurrences(of: "”", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    /// 把 domain 写入官方 config.toml 的 [dns] domain（保留其他配置），随后重启容器服务。
    /// 成功返回 nil，失败返回错误信息。
    func writeDnsDomainToConfig(domain: String) async -> String? {
        let domain = domain.trimmingCharacters(in: .whitespaces)
        guard !domain.isEmpty else { return "域名不能为空" }
        guard domain.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#,
            options: .regularExpression
        ) != nil else {
            return "域名格式无效：仅支持字母、数字、连字符和点，且不能含空格或引号"
        }

        let content = readConfig(from: configPath)

        let lines = content?.components(separatedBy: .newlines) ?? []

        var inDns = false
        var dnsSectionIndex: Int? = nil
        var domainReplaced = false
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inDns = (trimmed == "[dns]")
                if inDns { dnsSectionIndex = output.count }
                output.append(line)
                continue
            }
            if inDns && trimmed.hasPrefix("domain") {
                output.append("domain = \"\(domain)\"")
                domainReplaced = true
                continue
            }
            output.append(line)
        }
        if let idx = dnsSectionIndex, !domainReplaced {
            output.insert("domain = \"\(domain)\"", at: idx + 1)
            domainReplaced = true
        }
        if !domainReplaced {
            if let last = output.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                output.append("")
            }
            output.append("[dns]")
            output.append("domain = \"\(domain)\"")
        }

        let newContent = output.joined(separator: "\n")
        do {
            try writeConfig(newContent, to: configPath)
        } catch {
            return "写入配置失败: \(error.localizedDescription)"
        }

        // 重启容器服务使配置生效
        do {
            _ = try await CommandExecutor.shared.execute(CLICommandCatalog.shared.arguments(command: "system.stop"))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = try await CommandExecutor.shared.execute(CLICommandCatalog.shared.arguments(command: "system.start"))
        } catch {
            return "配置已写入，但重启服务失败: \(error.localizedDescription)"
        }

        refreshSystemDnsProperty()
        return nil
    }

    func refresh() {
        isLoading = true
        Task {
            await mgr.fetchNetworks()
            await MainActor.run {
                networks = mgr.networks
                errorMessage = mgr.errorMessage
                isLoading = false
            }
        }
    }

    func create(name: String, subnet: String?, subnetV6: String?, internalOnly: Bool, plugin: String? = nil, options: [String: String] = [:]) {
        Task {
            do {
                try await mgr.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, internalOnly: internalOnly, options: options, plugin: plugin)
                await syncFromManager()
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    func delete(_ id: String) {
        Task {
            do {
                try await mgr.deleteNetwork(id)
                await syncFromManager()
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }

    private func syncFromManager() async {
        await MainActor.run {
            networks = mgr.networks
        }
    }

    func inspect(_ id: String) async -> String {
        (try? await mgr.inspectNetwork(id)) ?? "检查失败"
    }

    func prune() {
        Task {
            do {
                try await mgr.pruneNetworks()
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - 列表行
struct NetworkRow: View {
    let net: NetworkInfo
    var onDelete: (() -> Void)? = nil

    @State private var showConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(net.displayName).font(.headline)
                Text(net.subnet).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(net.driver.replacingOccurrences(of: "container-network-", with: ""))
                        .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                    Text(net.mode).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer()
            if let onDelete, net.id != "default" {
                Button(action: { showConfirm = true }) {
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showConfirm) {
                    VStack(spacing: 12) {
                        Text("删除「\(net.displayName)」？").font(.callout)
                        HStack {
                            Button("取消") { showConfirm = false }
                            Button("删除", role: .destructive) { onDelete(); showConfirm = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .frame(width: 220)
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - 详情面板
struct NetworkDetailView: View {
    let network: NetworkInfo
    @ObservedObject var vm: NetworkViewModel
    @Binding var showInspect: Bool
    @Binding var inspectOutput: String
    @State private var showDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(network.displayName).font(.largeTitle).bold()
                        Text(network.driver).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "circle.fill").font(.caption2)
                            .foregroundStyle(network.isInternal ? .orange : .green)
                        Text(network.isInternal ? "内部" : "外部").font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(network.isInternal ? Color.orange.opacity(0.15) : Color.green.opacity(0.15))
                    .cornerRadius(8)
                }

                Divider()

                GroupBox("网络配置") {
                    VStack(alignment: .leading, spacing: 6) {
                        row("ID", network.id)
                        row("驱动", network.driver)
                        row("模式", network.mode)
                        if !network.subnet.isEmpty { row("IPv4 子网", network.subnet) }
                        if !network.gateway.isEmpty { row("IPv4 网关", network.gateway) }
                        if !network.subnetV6.isEmpty { row("IPv6 子网", network.subnetV6) }
                        if let created = network.createdAt { row("创建时间", created) }
                    }.padding(.vertical, 4)
                }

                // Labels
                if !network.labels.isEmpty {
                    GroupBox("标签") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(network.labels.keys.sorted()), id: \.self) { key in
                                HStack {
                                    Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(network.labels[key] ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                }

                HStack(spacing: 10) {
                    Button("检查详情") {
                        Task {
                            inspectOutput = await vm.inspect(network.id)
                            showInspect = true
                        }
                    }.buttonStyle(.bordered)

                    if network.id != "default" {
                        Button("删除", role: .destructive) { showDelete = true }
                            .buttonStyle(.bordered)
                    }
                }

                if showInspect && !inspectOutput.isEmpty {
                    GroupBox("Inspect 输出") {
                        ScrollView {
                            Text(inspectOutput)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }
            .padding()
        }
        .alert("确认删除", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { vm.delete(network.id) }
        } message: {
            Text("删除网络「\(network.displayName)」？")
        }
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack {
            Text(l).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.system(.body, design: .monospaced))
            Spacer()
        }
    }
}

// MARK: - 创建网络 Sheet
struct CreateNetworkSheet: View {
    @ObservedObject var vm: NetworkViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var subnet = ""
    @State private var subnetV6 = ""
    @State private var internalOnly = false
    @State private var plugin = ""
    @State private var optionsText = ""   // 逗号分隔 KEY=VALUE

    private var parsedOptions: [String: String] {
        optionsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }
            .reduce(into: [String: String]()) { dict, pair in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                dict[String(parts[0]).trimmingCharacters(in: .whitespaces)] = String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("网络名称", text: $name).textFieldStyle(.roundedBorder)
                    Toggle("仅内部网络", isOn: $internalOnly)
                        .help("限制为仅主机可访问")
                }
                Section("子网（可选）") {
                    TextField("IPv4 子网 (如 10.0.0.0/24)", text: $subnet).textFieldStyle(.roundedBorder)
                    TextField("IPv6 子网", text: $subnetV6).textFieldStyle(.roundedBorder)
                    Text("留空则自动分配").font(.caption).foregroundStyle(.secondary)
                }
                Section("高级（可选）") {
                    TextField("插件 (--plugin)", text: $plugin).textFieldStyle(.roundedBorder)
                    TextField("选项 (--option, 逗号分隔 KEY=VALUE)", text: $optionsText).textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("创建网络")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        vm.create(name: name, subnet: subnet.nilIfEmpty, subnetV6: subnetV6.nilIfEmpty, internalOnly: internalOnly, plugin: plugin.nilIfEmpty, options: parsedOptions)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
