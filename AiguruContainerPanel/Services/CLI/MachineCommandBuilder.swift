import Foundation

enum MachineCommandBuilder {
    private static let catalog = CLICommandCatalog.shared
    private static let commandKey = "machine.create"

    static func createArguments(for configuration: MachineCreateConfiguration) -> [String] {
        var arguments = catalog.path(command: commandKey) ?? []
        arguments += [flag("name"), configuration.name]
        if let cpus = configuration.cpus { arguments += [flag("cpus"), String(cpus)] }
        if let memory = configuration.memory { arguments += [flag("memory"), memory] }
        arguments += [flag("homeMount"), configuration.homeMount.rawValue]
        if configuration.virtualization { arguments.append(flag("virtualization")) }
        if let kernelPath = configuration.kernelPath { arguments += [flag("kernel"), kernelPath] }
        if configuration.noBoot { arguments.append(flag("noBoot")) }
        if configuration.setDefault { arguments.append(flag("setDefault")) }
        if let architecture = configuration.architecture { arguments += ["--arch", architecture.rawValue] }
        if let os = configuration.os { arguments += ["--os", os] }
        if configuration.scheme != .auto { arguments += ["--scheme", configuration.scheme.rawValue] }
        if let maximum = configuration.maxConcurrentDownloads {
            arguments += ["--max-concurrent-downloads", String(maximum)]
        }
        arguments.append(configuration.image.imageReference())
        return arguments
    }

    private static func flag(_ key: String) -> String {
        catalog.flag(command: commandKey, option: key)
    }
}
