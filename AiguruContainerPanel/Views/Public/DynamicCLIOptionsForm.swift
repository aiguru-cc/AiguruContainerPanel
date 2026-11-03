import SwiftUI
import Combine

@MainActor
final class DynamicCLIFormState: ObservableObject {
    @Published var values: [String: [String]] = [:]

    func binding(for key: String) -> Binding<String> {
        Binding(
            get: { self.values[key]?.first ?? "" },
            set: { self.values[key] = $0.isEmpty ? [] : [$0] }
        )
    }

    func toggleBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { self.values[key]?.first == "true" },
            set: { self.values[key] = $0 ? ["true"] : [] }
        )
    }

    func listBinding(for key: String) -> Binding<String> {
        Binding(
            get: { self.values[key, default: []].joined(separator: ", ") },
            set: {
                self.values[key] = $0.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    func retainOptions(_ keys: Set<String>) {
        values = values.filter { keys.contains($0.key) }
    }
}

struct DynamicCLIOptionsForm: View {
    let command: String
    let version: CLIVersion
    @ObservedObject var state: DynamicCLIFormState

    private var definitions: [CLIOptionDefinition] {
        CLICommandCatalog.shared.dynamicOptions(command: command, version: version)
    }

    private var sections: [String] {
        Array(Set(definitions.compactMap { $0.ui?.section })).sorted()
    }

    var body: some View {
        ForEach(sections, id: \.self) { section in
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(definitions.filter { $0.ui?.section == section }) { option in
                        control(for: option)
                    }
                }
                .padding(.vertical, 4)
            } label: {
                Label(section, systemImage: "slider.horizontal.3")
                    .font(.headline)
            }
        }
        .onChange(of: version) { _, _ in
            state.retainOptions(Set(definitions.map(\.key)))
        }
    }

    @ViewBuilder
    private func control(for option: CLIOptionDefinition) -> some View {
        if let ui = option.ui {
            switch ui.control {
            case "toggle":
                Toggle(ui.label, isOn: state.toggleBinding(for: option.key))
                    .help(ui.help ?? "")
            case "select":
                Picker(ui.label, selection: state.binding(for: option.key)) {
                    ForEach(ui.choices ?? [], id: \.self) { Text($0).tag($0) }
                }
                .help(ui.help ?? "")
            case "list":
                VStack(alignment: .leading, spacing: 3) {
                    Text(ui.label).font(.caption).foregroundStyle(.secondary)
                    TextField(ui.placeholder ?? "逗号分隔", text: state.listBinding(for: option.key))
                        .textFieldStyle(.roundedBorder)
                        .help(ui.help ?? "")
                }
            default:
                VStack(alignment: .leading, spacing: 3) {
                    Text(ui.label).font(.caption).foregroundStyle(.secondary)
                    TextField(ui.placeholder ?? "", text: state.binding(for: option.key))
                        .textFieldStyle(.roundedBorder)
                        .help(ui.help ?? "")
                }
            }
        }
    }
}
