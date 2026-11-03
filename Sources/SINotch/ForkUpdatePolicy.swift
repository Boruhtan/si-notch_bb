import Foundation

enum ForkUpdatePolicy {
    static func disabled(in bundle: Bundle = .main) -> Bool {
        bundle.object(forInfoDictionaryKey: "SIUpdatesDisabled") as? Bool == true
    }
}
