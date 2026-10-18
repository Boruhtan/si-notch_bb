import CryptoKit
import Foundation

/// One-off operator utility: compile with CodexHookSetup.swift and
/// CodexHookAuthorization.swift. `preview` reads hook metadata only; `apply`
/// trusts the same exact definitions through Codex's own config API.
@main
enum CodexAuthorizeRunner {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard (5...6).contains(args.count), ["preview", "apply"].contains(args[1]) else {
                throw RunnerError.usage
            }
            let binary = URL(fileURLWithPath: args[2])
            let hooksURL = args.count == 6 ? URL(fileURLWithPath: args[5])
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
            let setup = CodexHookSetup(adapterPath: args[3], helperPath: args[4], hooksURL: hooksURL)
            guard try !setup.preview().canApply else { throw RunnerError.notInstalled }
            let service = CodexHookAuthorization(command: setup.command, sourcePath: hooksURL.path)
            let plan = try await service.prepare(binary: binary)
            let digest = try planDigest(plan)
            if args[1] == "preview" {
                print("Command: \(plan.command)")
                print("Source: \(plan.sourcePath)")
                for hook in plan.hooks {
                    print("\(hook.eventName): \(hook.trustStatus), \(hook.currentHash)")
                }
                print("Review SHA-256: \(digest)")
                print("Pending definitions: \(plan.pendingCount)")
                return
            }
            guard let expected = ProcessInfo.processInfo.environment["SI_NOTCH_REVIEWED_HOOKS_SHA256"],
                  expected == digest else { throw RunnerError.reviewChanged }
            try await service.authorize(binary: binary, reviewed: plan)
            print("Codex reports all eight si-notch hook definitions trusted.")
        } catch {
            fputs("Codex hook authorization: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func planDigest(_ plan: CodexHookAuthorization.ReviewPlan) throws -> String {
        let object: [String: Any] = [
            "command": plan.command, "sourcePath": plan.sourcePath,
            "hooks": plan.hooks.map { ["eventName": $0.eventName, "key": $0.key,
                                       "currentHash": $0.currentHash, "trustStatus": $0.trustStatus] }
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum RunnerError: LocalizedError {
        case usage, notInstalled, reviewChanged
        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: runner preview|apply CODEX_CLI ADAPTER HELPER [HOOKS_FILE]; apply requires SI_NOTCH_REVIEWED_HOOKS_SHA256"
            case .notInstalled: return "Install the eight si-notch hooks before authorizing them."
            case .reviewChanged: return "The hook definitions differ from the reviewed SHA-256; preview again."
            }
        }
    }
}
