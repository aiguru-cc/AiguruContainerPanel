//
//  RegistrySheets.swift
//  AiguruContainerPanel
//
//  私有镜像仓库（Registry）管理 Sheet：融合进镜像视图。
//  登录密码经 stdin 传入，不写入日志。
//

import SwiftUI

// MARK: - 私有库管理（融合进镜像视图）

struct RegistryManageSheet: View {
    @StateObject private var manager = RegistryManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLoginSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("私有镜像仓库").font(.title2.weight(.semibold))
                Spacer()
            }

            if manager.registries.isEmpty {
                Label("暂无已登录的私有仓库", systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ForEach(manager.registries) { reg in
                    HStack(spacing: 10) {
                        Image(systemName: "shippingbox").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reg.hostname).font(.headline)
                            Text("用户: \(reg.username.isEmpty ? "-" : reg.username)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { try? await manager.logout(server: reg.hostname) }
                        } label: {
                            Label("登出", systemImage: "escape")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Divider()
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("刷新") { Task { await manager.fetchRegistries() } }
                    .buttonStyle(.bordered)
                Button("登录新仓库") { showLoginSheet = true }
                    .buttonStyle(.borderedProminent)
               

            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { Task { await manager.fetchRegistries() } }
        .sheet(isPresented: $showLoginSheet) {
            RegistryLoginSheet(manager: manager, isPresented: $showLoginSheet)
        }
    }
}

// MARK: - 登录表单

struct RegistryLoginSheet: View {
    @ObservedObject var manager: RegistryManager
    @Binding var isPresented: Bool
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var scheme = "https"
    @State private var isLoggingIn = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("登录镜像仓库").font(.title2.weight(.semibold))
            TextField("服务器地址（如 docker.io）", text: $server).textFieldStyle(.roundedBorder)
            TextField("用户名", text: $username).textFieldStyle(.roundedBorder)
            SecureField("密码 / Token", text: $password).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Picker("协议", selection: $scheme) {
                    Text("自动").tag("auto")
                    Text("HTTPS").tag("https")
                    Text("HTTP").tag("http")
                }
                .frame(width: 140)
                Text("密码通过 stdin 传入，不写入日志").font(.caption2).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("取消") { isPresented = false }
                Spacer()
                Button("登录") {
                    let s = server.trimmingCharacters(in: .whitespaces)
                    let u = username.trimmingCharacters(in: .whitespaces)
                    guard !s.isEmpty, !u.isEmpty, !password.isEmpty else {
                        errorMessage = "请填写服务器、用户名和密码"
                        return
                    }
                    isLoggingIn = true
                    errorMessage = nil
                    Task {
                        do {
                            try await manager.login(server: s, username: u, password: password, scheme: scheme)
                            isPresented = false
                        } catch {
                            errorMessage = "登录失败: \(error.localizedDescription)"
                            isLoggingIn = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoggingIn || server.trimmingCharacters(in: .whitespaces).isEmpty
                          || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
