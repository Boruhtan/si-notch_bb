import Foundation

/// Product identity comes from native metadata, never conversation text.
enum CodexSessionOrigin {
    static func isWork(originator: Any?, serviceName: Any? = nil) -> Bool? {
        let names = [originator, serviceName].compactMap { $0 as? String }
        if names.contains("codex_work_desktop") { return true }
        if names.contains("Codex Desktop") { return false }
        return nil
    }
}
