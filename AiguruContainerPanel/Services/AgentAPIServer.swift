import Foundation
import Network

/// Local/LAN automation bridge for agents. All requests require a bearer token.
final class AgentAPIServer {
    static let shared = AgentAPIServer()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aiguru.agent-api")
    private let tokenKey = "agent.api.token"
    private var tasks: [String: [String: Any]] = [:]
    private let taskLock = NSLock()
    private var token: String {
        if let value = UserDefaults.standard.string(forKey: tokenKey) { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(value, forKey: tokenKey)
        return value
    }

    func start(port: UInt16 = 18765) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let server = try NWListener(using: .tcp, on: nwPort)
            server.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("Agent API failed: \(error)") }
            }
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener = server
            server.start(queue: queue)
            print("Agent API listening on 0.0.0.0:\(port), token=Bearer \(token)")
        } catch { print("Agent API start failed: \(error)") }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
            let response = self.handle(request)
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func handle(_ request: String) -> String {
        let parts = request.components(separatedBy: "\r\n\r\n")
        let header = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = header.split(separator: "\n").map(String.init)
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let auth = lines.first(where: { $0.lowercased().hasPrefix("authorization:") }) ?? ""
        guard auth.trimmingCharacters(in: .whitespaces).hasSuffix(token) else { return json(401, ["error": "unauthorized"]) }
        if path == "/v1/health" { return json(200, ["ok": true, "service": "AiguruContainerPanel"]) }
        if path == "/v1/catalog" { return json(200, ["commands": CLICommandCatalog.shared.allCommandKeys]) }
        if path.hasPrefix("/v1/tasks/") && path.hasSuffix("/cancel") {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            taskLock.lock(); tasks[id]?["status"] = "cancel_requested"; taskLock.unlock()
            return json(202, ["taskId": id, "status": "cancel_requested"])
        }
        if path.hasPrefix("/v1/tasks/") && path.hasSuffix("/logs") {
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            taskLock.lock(); defer { taskLock.unlock() }
            return tasks[id].map { json(200, ["taskId": id, "status": $0["status"] ?? "unknown", "output": $0["output"] ?? ""]) } ?? json(404, ["error": "task_not_found"])
        }
        if path.hasPrefix("/v1/tasks/") {
            let id = String(path.dropFirst("/v1/tasks/".count))
            taskLock.lock(); defer { taskLock.unlock() }
            return tasks[id].map { json(200, $0) } ?? json(404, ["error": "task_not_found"])
        }
        if path == "/v1/resources/containers" { return submit(arguments: ["container", "list", "--all", "--format", "json"]) }
        if path == "/v1/resources/images" { return submit(arguments: ["image", "list", "--format", "json"]) }
        if path == "/v1/resources/networks" { return submit(arguments: ["network", "list", "--format", "json"]) }
        if path == "/v1/resources/machines" { return submit(arguments: ["machine", "list", "--format", "json"]) }
        if path == "/v1/resources/clusters" { return submit(arguments: ["cluster", "list"]) }
        if path.hasPrefix("/v1/actions/") {
            let components = path.split(separator: "/").map(String.init)
            guard components.count == 4, let args = actionArguments(resource: components[2], action: components[3], body: body) else { return json(400, ["error": "unsupported_action"]) }
            return submit(arguments: args)
        }
        guard path == "/v1/command" else { return json(404, ["error": "not_found"]) }
        guard let data = body.data(using: .utf8), let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let args = payload["arguments"] as? [String] else { return json(400, ["error": "arguments must be an array"]) }
        return submit(arguments: args)
    }

    private func submit(arguments: [String]) -> String {
        let id = UUID().uuidString
        taskLock.lock(); tasks[id] = ["id": id, "status": "running", "arguments": arguments, "startedAt": ISO8601DateFormatter().string(from: Date())]; taskLock.unlock()
        Task {
            do {
                let output = try await CommandExecutor.shared.executeSystemCommand(arguments: arguments)
                taskLock.lock(); tasks[id]?["status"] = "succeeded"; tasks[id]?["output"] = output; taskLock.unlock()
            } catch {
                taskLock.lock(); tasks[id]?["status"] = "failed"; tasks[id]?["error"] = error.localizedDescription; taskLock.unlock()
            }
        }
        return json(202, ["taskId": id, "status": "running"])
    }

    private func actionArguments(resource: String, action: String, body: String) -> [String]? {
        let payload = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        if let args = payload["arguments"] as? [String] { return args }
        let name = payload["name"] as? String
        switch (resource, action) {
        case ("containers", "list"): return ["container", "list", "--all", "--format", "json"]
        case ("containers", "start"), ("containers", "stop"), ("containers", "delete"):
            guard let name else { return nil }; return ["container", action, name] + ((action == "delete") ? ["--force"] : [])
        case ("images", "list"): return ["image", "list", "--format", "json"]
        case ("images", "pull"):
            guard let image = payload["image"] as? String else { return nil }; return ["image", "pull", image]
        case ("images", "delete"):
            guard let image = payload["image"] as? String else { return nil }; return ["image", "delete", image]
        case ("networks", "list"): return ["network", "list", "--format", "json"]
        case ("networks", "delete"):
            guard let name else { return nil }; return ["network", "delete", name]
        case ("machines", "list"): return ["machine", "list", "--format", "json"]
        case ("machines", "start"), ("machines", "stop"), ("machines", "delete"):
            guard let name else { return nil }; return ["machine", action, name]
        case ("clusters", "list"): return ["cluster", "list"]
        case ("clusters", "delete"):
            guard let name else { return nil }; return ["cluster", "delete", "--name", name]
        default: return nil
        }
    }

    private func json(_ status: Int, _ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n\(text)"
    }
}
