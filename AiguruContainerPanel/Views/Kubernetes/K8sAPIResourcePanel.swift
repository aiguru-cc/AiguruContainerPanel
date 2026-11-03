import SwiftUI

/// Discovery 驱动的标准 Kubernetes API 资源面板；CRD 与聚合 API 无需硬编码即可出现。
struct K8sAPIResourcePanel: View {
    @ObservedObject var manager: KubernetesManager
    let cluster: KubernetesCluster
    let category: KubernetesResourceCategory

    @State private var resources: [KubernetesAPIResource] = []
    @State private var selectedResourceID: KubernetesAPIResource.ID?
    @State private var objects: [KubernetesAPIObject] = []
    @State private var selectedObjectID: KubernetesAPIObject.ID?
    @State private var yaml = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showEditor = false
    @State private var editorTitle = ""
    @State private var objectToDelete: KubernetesAPIObject?

    private var selectedResource: KubernetesAPIResource? {
        resources.first { $0.id == selectedResourceID } ?? resources.first
    }
    private var selectedObject: KubernetesAPIObject? {
        objects.first { $0.id == selectedObjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if isLoading && resources.isEmpty {
                Spacer(); ProgressView("发现 Kubernetes API…"); Spacer()
            } else if let errorMessage, resources.isEmpty {
                ContentUnavailableView("API Discovery 失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                HSplitView {
                    resourceList.frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                    objectTable.frame(minWidth: 430, maxWidth: .infinity)
                }
            }
        }
        .task(id: "\(cluster.name)/\(category.rawValue)") { await discover() }
        .onChange(of: selectedResourceID) { _, _ in Task { await loadObjects() } }
        .onChange(of: selectedObjectID) { _, _ in Task { await loadSelectedYAML() } }
        .sheet(isPresented: $showEditor) {
            K8sManifestEditor(title: editorTitle, yaml: $yaml) {
                try await manager.applyManifest(cluster: cluster.name, yaml: yaml)
                await loadObjects()
            }
        }
        .confirmationDialog("删除 Kubernetes 资源", isPresented: Binding(get: { objectToDelete != nil }, set: { if !$0 { objectToDelete = nil } })) {
            Button("删除 \(objectToDelete?.name ?? "")", role: .destructive) {
                guard let resource = selectedResource, let object = objectToDelete else { return }
                Task {
                    do { try await manager.deleteAPIObject(cluster: cluster.name, resource: resource, object: object); await loadObjects() }
                    catch { errorMessage = error.localizedDescription }
                }
                objectToDelete = nil
            }
            Button("取消", role: .cancel) { objectToDelete = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label(category.rawValue, systemImage: icon).font(.headline)
            if let profile = manager.apiProfile {
                Text(profile.label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let resource = selectedResource {
                Text("\(resource.groupVersion) · \(resource.namespaced ? "Namespaced" : "Cluster")")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Button("新建") { newManifest(resource) }
                    .controlSize(.small).disabled(!resource.canCreate)
                Button("编辑 YAML") { editSelected() }
                    .controlSize(.small).disabled(selectedObject == nil || !resource.canUpdate)
                Button("删除", role: .destructive) { objectToDelete = selectedObject }
                    .controlSize(.small).disabled(selectedObject == nil || !resource.canDelete)
            }
            Button(action: { Task { await discover(force: true) } }) { Label("刷新", systemImage: "arrow.clockwise") }
                .controlSize(.small).disabled(isLoading)
        }
        .padding(10)
    }

    private var resourceList: some View {
        List(resources, selection: $selectedResourceID) { resource in
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.kind).font(.caption.weight(.medium))
                Text(resource.group).font(.caption2).foregroundStyle(.secondary)
            }
            .tag(resource.id)
        }
        .listStyle(.sidebar)
    }

    private var objectTable: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            Table(objects, selection: $selectedObjectID) {
                TableColumn("名称") { Text($0.name).fontWeight(.medium) }
                TableColumn("命名空间") { Text($0.namespace ?? "—") }
                TableColumn("状态") { Text($0.phase ?? "—") }
                TableColumn("创建时间") { Text($0.createdAt ?? "—").font(.caption) }
            }
            if !yaml.isEmpty {
                Divider()
                ScrollView {
                    Text(yaml).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(minHeight: 110, idealHeight: 180, maxHeight: 260)
            }
        }
    }

    private var icon: String {
        switch category {
        case .workloads: return "square.stack.3d.up"
        case .networking: return "network"
        case .configuration: return "externaldrive"
        case .access: return "person.badge.key"
        case .extensions: return "puzzlepiece.extension"
        }
    }

    @MainActor private func discover(force: Bool = false) async {
        isLoading = true; errorMessage = nil
        do {
            resources = try await manager.discoverAPIResources(cluster: cluster.name, force: force)
                .filter { $0.category == category && $0.canList }
            if !resources.contains(where: { $0.id == selectedResourceID }) { selectedResourceID = resources.first?.id }
            await loadObjects()
        } catch { resources = []; errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor private func loadObjects() async {
        guard let resource = selectedResource else { objects = []; return }
        isLoading = true; errorMessage = nil; yaml = ""
        do {
            objects = try await manager.fetchAPIObjects(cluster: cluster.name, resource: resource)
            if !objects.contains(where: { $0.id == selectedObjectID }) { selectedObjectID = objects.first?.id }
            await loadSelectedYAML()
        } catch { objects = []; errorMessage = error.localizedDescription }
        isLoading = false
    }

    @MainActor private func loadSelectedYAML() async {
        guard let resource = selectedResource, let object = selectedObject else { yaml = ""; return }
        do { yaml = try await manager.fetchAPIObjectYAML(cluster: cluster.name, resource: resource, object: object) }
        catch { yaml = ""; errorMessage = error.localizedDescription }
    }

    private func newManifest(_ resource: KubernetesAPIResource) {
        yaml = "apiVersion: \(resource.groupVersion)\nkind: \(resource.kind)\nmetadata:\n  name: new-\(resource.singularName.isEmpty ? resource.name : resource.singularName)\(resource.namespaced ? "\n  namespace: default" : "")\nspec: {}\n"
        editorTitle = "新建 \(resource.kind)"
        showEditor = true
    }

    private func editSelected() {
        guard let resource = selectedResource, selectedObject != nil else { return }
        editorTitle = "编辑 \(resource.kind) YAML"
        showEditor = true
    }
}

private struct K8sManifestEditor: View {
    let title: String
    @Binding var yaml: String
    let onApply: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack { Text(title).font(.title3.weight(.semibold)); Spacer(); Button("关闭") { dismiss() } }
            TextEditor(text: $yaml).font(.body.monospaced()).border(Color.secondary.opacity(0.25))
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Text("将通过当前集群 API Server 执行 kubectl apply").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isApplying { ProgressView().controlSize(.small) }
                Button("应用") {
                    Task {
                        isApplying = true; errorMessage = nil
                        do { try await onApply(); dismiss() } catch { errorMessage = error.localizedDescription }
                        isApplying = false
                    }
                }
                .buttonStyle(.borderedProminent).disabled(isApplying || yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18).frame(width: 720, height: 620)
    }
}
