import Foundation
import Combine
import AppKit

/// Owned by the app, not the settings view. A cached reading keeps its original
/// age on errors; selecting another executable invalidates its in-flight result.
@MainActor
final class CodexQuotaController: ObservableObject {
    @Published private(set) var status: CodexUsageStatus?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var binary: URL?
    private let defaults: UserDefaults
    private let fetch: (URL) async throws -> CodexUsageStatus
    private var started = false
    private var timer: Timer?
    private var wake: NSObjectProtocol?
    private var generation = 0
    private var lastAttempt = Date.distantPast
    private let cacheKey = "codexQuotaSnapshot"
    private let pathKey = "codexQuotaSnapshotCLI"
    init(defaults: UserDefaults = .standard, fetch: @escaping (URL) async throws -> CodexUsageStatus = { try await CodexUsageService().refresh(binary: $0) }) {
        self.defaults = defaults; self.fetch = fetch
        binary = CodexBinaryLocator.detected(defaults: defaults)
        if defaults.string(forKey: pathKey) == binary?.path,
           let data = defaults.data(forKey: cacheKey), let value = try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data) {
            status = .limits(value)
        }
    }
    func start() {
        guard timer == nil else { return }
        started = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer?.tolerance = 30
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
    }
    func refreshIfNeeded(now: Date = Date()) { if started && now.timeIntervalSince(lastAttempt) >= 60 { refresh() } }
    func select(_ url: URL) {
        defaults.set(url.path, forKey: CodexBinaryLocator.preferenceKey)
        generation += 1; loading = false; status = nil; error = nil
        defaults.removeObject(forKey: cacheKey); defaults.removeObject(forKey: pathKey)
        binary = url; refresh()
    }
    func refresh() {
        guard !loading else { return }
        binary = CodexBinaryLocator.detected(defaults: defaults)
        guard let binary else { error = CodexUsageError.binaryMissing.localizedDescription; return }
        generation += 1; let request = generation
        loading = true; error = nil; lastAttempt = Date()
        Task {
            do {
                let result = try await fetch(binary)
                guard request == generation else { return }
                status = result; loading = false
                if case .limits(let snapshot) = result, let data = try? JSONEncoder().encode(snapshot) {
                    defaults.set(data, forKey: cacheKey); defaults.set(binary.path, forKey: pathKey)
                } else { defaults.removeObject(forKey: cacheKey) }
            } catch {
                guard request == generation else { return }
                self.error = error.localizedDescription; loading = false
            }
        }
    }
    func stop() {
        started = false; loading = false
        generation += 1; timer?.invalidate(); timer = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }; wake = nil
    }
}
