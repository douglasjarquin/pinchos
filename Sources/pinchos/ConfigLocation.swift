import Foundation

enum ConfigLocation {
    static func resolve() -> String {
        let base: String
        if let xdgConfigHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdgConfigHome.isEmpty {
            base = xdgConfigHome
        } else {
            base = NSHomeDirectory() + "/.config"
        }
        return base + "/pinchos/pinchos.toml"
    }
}
