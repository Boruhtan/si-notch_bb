import AppKit
import Foundation
import SwiftUI
import SINotchCore
import SINotchTransport
import Darwin

/// Development-only inspection of this process's own NSView backing and NSWindow
/// geometry. This is not a desktop/compositor capture or a hardware notch test.
@MainActor
enum QAExporter {
    private static var running = false

    /// Call after configuring/showing the island, then return from the boot method
    /// before starting IPC, the model timer, or the global keyboard shortcut.
    static func run(delegate: AppDelegate, directory: URL) {
        guard !running else { return }
        running = true
        Task { @MainActor in
            await Runner(delegate: delegate, directory: directory).executeAndTerminate()
        }
    }

    private enum ExportError: LocalizedError {
        case invalidBootState, unavailableView, cannotEncodePNG
        case fixtureNotApplied(String)
        var errorDescription: String? {
            switch self {
            case .invalidBootState: return "QA requires a configured island before IPC, timers, and hotkeys start."
            case .unavailableView: return "The app-owned view has no drawable bounds or bitmap backing."
            case .cannotEncodePNG: return "The app-owned bitmap could not be encoded as PNG."
            case .fixtureNotApplied(let name): return "The in-memory UI fixture was rejected: \(name)."
            }
        }
    }

    private struct Frame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let midX: Double
        let maxY: Double
        init(_ rect: NSRect) {
            x = rect.minX; y = rect.minY; width = rect.width; height = rect.height
            midX = rect.midX; maxY = rect.maxY
        }
        func distance(to other: Frame) -> Double {
            [abs(x - other.x), abs(y - other.y), abs(width - other.width), abs(height - other.height)].max() ?? 0
        }
    }

    private struct Sample: Codable {
        let elapsed: Double
        let monotonicTime: Double
        let frame: Frame
        let expanded: Bool
        let png: String
        let captureSeconds: Double
    }

    private struct Action: Codable {
        let name: String
        let scheduledElapsed: Double
        let actualElapsed: Double
        let before: Frame
        let after: Frame
    }

    private struct Trace: Codable {
        let name: String
        let startedAtMonotonicTime: Double
        let expectedFinalFrame: Frame
        let requestedSamplesPerSecond: Double
        let samples: [Sample]
        let actions: [Action]
        let displayLinkFrames: [IslandWindowAnimator.FrameTiming]
    }

    private struct Check: Codable {
        let name: String
        let outcome: String // passed, failed, inconclusive, or not-applicable
        let detail: String
    }

    private struct StaticCapture: Codable {
        let name: String
        let png: String
        let language: String
        let viewWidth: Double
        let viewHeight: Double
        let pixelWidth: Int
        let pixelHeight: Int
        let captureSeconds: Double
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let evidenceKind = "own-app NSView backing and native NSWindow geometry"
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let reduceMotion: Bool
        let reduceTransparency: Bool
        let limitations = [
            "PNG files cache this application's own NSView; they are not desktop screenshots or compositor frames.",
            "Glass backdrop sampling, hardware camera occlusion, compositor presentation, and other apps are not validated.",
            "Display-link timestamps measure callbacks and frame-setting cost, not presented compositor FPS.",
            "Bitmap export runs on the main thread and can perturb animation timing; actual timestamps and capture costs are retained.",
            "Static settings captures cover the initial viewport. Scroll positions and control activation are not exercised.",
            "A passed geometry check does not establish subjective visual quality; inspect the PNG sequence separately."
        ]
        var screenName: String?
        var screenFrame: Frame?
        var screenMaximumFramesPerSecond: Int?
        var compactFrame: Frame?
        var expandedFrame: Frame?
        var traceFiles: [String] = []
        var staticCaptures: [StaticCapture] = []
        var checks: [Check] = []
        var fatalError: String?
        var outcome = "incomplete"
    }

    private struct ScheduledAction {
        let time: Double
        let name: String
        let apply: () -> Void
    }

    @MainActor
    private final class Runner {
        let delegate: AppDelegate
        let directory: URL
        let files = FileManager.default
        let defaults = UserDefaults.standard
        let geometryOnly = CommandLine.arguments.contains("--qa-motion-only")
        var samplesPerSecond: Double { geometryOnly ? 120 : 24 }
        var report: Report
        var ownsDirectory = false
        var previousArguments: [String: Any]?
        var overrides: [String: Any] = [:]

        init(delegate: AppDelegate, directory: URL) {
            self.delegate = delegate
            self.directory = directory
            report = Report(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        }

        func executeAndTerminate() async {
            do {
                guard directory.isFileURL, delegate.panel?.contentView != nil,
                      delegate.model.server == nil, delegate.model.timer == nil,
                      delegate.hotKey == nil else { throw ExportError.invalidBootState }
                // mkdir is exclusive even if another process creates the path
                // concurrently. Never reuse or overwrite a prior run directory.
                let created = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.mkdir(path, 0o700)
                }
                guard created == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                ownsDirectory = true
                for child in ["motion", "static"] {
                    try files.createDirectory(at: directory.appendingPathComponent(child), withIntermediateDirectories: false)
                }
                previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
                overrides = ["hoverExpand": false, "autoExpand": false, "keepOpen": true,
                             "quiet": true, "sound": false, "followFocus": false,
                             "screenID": "auto", "displayMode": "notch", "showOnlyWithSessions": false,
                             "panelWidth": 460.0, "panelHeight": 560.0,
                             "showCompanion": true, "companionStyle": "robot", "appLanguage": "en"]
                applyOverrides()
                clearFixtures()
                if let screen = delegate.selectedScreen() {
                    report.screenName = screen.localizedName
                    report.screenFrame = Frame(screen.frame)
                    report.screenMaximumFramesPerSecond = screen.maximumFramesPerSecond
                }
                if CommandLine.arguments.contains("--qa-screens-only") {
                    try await exportScreenViews()
                } else if CommandLine.arguments.contains("--qa-history-only") {
                    try await exportHistory()
                } else if CommandLine.arguments.contains("--qa-service-only") {
                    try await exportMemoryServices()
                } else if CommandLine.arguments.contains("--qa-interaction-only") {
                    try await verifyInteractions()
                } else if CommandLine.arguments.contains("--qa-display-only") {
                    try await exportDisplayViews()
                } else if CommandLine.arguments.contains("--qa-remote-only") {
                    try await exportRemoteViews()
                } else {
                try exportSounds()
                try await verifySoundDelivery()
                if !CommandLine.arguments.contains("--qa-sounds-only") {
                    try await exportMotion()
                    try await verifyWindowAnchorRecovery()
                    if !geometryOnly { try await exportStaticViews() }
                }
                }
                report.outcome = report.checks.contains { $0.outcome == "failed" } ? "failed" :
                    report.checks.contains { $0.outcome == "inconclusive" } ? "inconclusive" : "passed"
            } catch {
                report.fatalError = error.localizedDescription
                report.outcome = "failed"
            }
            if ownsDirectory {
                do { try writeJSON(report, relativePath: "report.json") }
                catch { log("QA report write failed: \(error.localizedDescription)", error: true) }
            }
            log("QA export \(report.outcome): \(directory.path)" + (report.fatalError.map { " — \($0)" } ?? ""),
                error: report.outcome == "failed")
            if report.outcome == "passed", CommandLine.arguments.contains("--qa-screens-only"),
               let index = CommandLine.arguments.firstIndex(of: "--qa-preview-screen"),
               CommandLine.arguments.indices.contains(index + 1),
               let screen = NSScreen.screens.first(where: { delegate.screenID($0) == CommandLine.arguments[index + 1] }) {
                overrides["screenID"] = delegate.screenID(screen)
                overrides["hoverExpand"] = true
                overrides["keepOpen"] = false
                applyOverrides()
                try? await settle(expanded: false)
                delegate.statusItem.button?.toolTip = "si-notch · Local preview (5 min)"
                log("Local interactive preview on \(screen.localizedName); no IPC or agent services; closes after 5 minutes.")
                try? await pause(300)
            }
            if let previousArguments {
                defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            }
            NSApp.terminate(nil)
        }

        func exportSounds() throws {
            let folder = directory.appendingPathComponent("audio", isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: false)
            for cue in EventSoundPlayer.Cue.allCases {
                guard let wav = EventSoundPlayer.wavData(for: cue), NSSound(data: wav) != nil else {
                    throw ExportError.fixtureNotApplied("bundled sound: \(cue.rawValue)")
                }
                try wav.write(to: folder.appendingPathComponent("\(cue.rawValue).wav"), options: .withoutOverwriting)
            }
            check("seven-audio-cues", try files.contentsOfDirectory(atPath: folder.path).count == 7,
                  "Bundled WAV export only; no audio device or user sound settings changed.")
        }

        func applyOverrides() {
            var arguments = previousArguments ?? [:]
            for (key, value) in overrides { arguments[key] = value }
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            delegate.model.revision += 1
        }

        func verifySoundDelivery() async throws {
            let suite = "si-notch.qa-sound." + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            // QA's process-local overrides mute its visible island; this
            // independent model exercises the audio sink without an audio device.
            var arguments = overrides
            arguments["quiet"] = false
            arguments["sound"] = true
            arguments["soundWorking"] = true
            preferences.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defer { applyOverrides(); preferences.removePersistentDomain(forName: suite) }
            var outputs = 0
            let player = EventSoundPlayer(defaults: preferences, output: { _, _ in outputs += 1; return true })
            let model = AppModel(defaults: preferences, soundPlayer: player)
            defer { model.shutdown() }
            // Darwin's Unix socket path is limited to 103 bytes; the per-user
            // temporary directory plus a UUID may already exceed that limit.
            let socketRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("si-notch-qa-" + UUID().uuidString)
            let socket = socketRoot.appendingPathComponent("events.sock").path
            let server = IPCServer(socketPath: socket) { data, reply in
                DispatchQueue.main.async { model.receive(data, reply: reply) }
            }
            try server.start()
            defer { server.stop(); try? files.removeItem(at: socketRoot) }
            func send(_ kind: AgentEventKind, id: String, session: String = "qa-one", turn: String = "t1") async throws {
                let data = try JSONEncoder().encode(AgentEvent(sessionID: session, provider: "custom", kind: kind, id: id, turnID: turn))
                let response = try await Task.detached { try IPCClient(socketPath: socket).send(data, awaitReply: true) }.value
                guard let response, (try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["ok"] as? Bool == true else {
                    throw ExportError.fixtureNotApplied("sound IPC")
                }
            }
            try await send(.sessionStarted, id: "hook:start")
            try await send(.working, id: "hook:working")
            try await send(.working, id: "hook:working")
            try await send(.sessionStarted, id: "file:start")
            try await send(.working, id: "stream:working")
            check("audio-ipc-single-start", outputs == 1,
                  "Five deliveries through separate real Unix-socket connections produce one audio output, including an exact retry and a second observer.")
            try await send(.completed, id: "hook:done")
            try await send(.working, id: "late:working")
            try await send(.completed, id: "stream:done")
            check("audio-ipc-terminal-replay", outputs == 2,
                  "A stale working/completed replay for the same turn produces no additional audio output.")
            for i in 0..<8 { try await send(.working, id: "start", session: "qa-parallel-\(i)") }
            check("audio-ipc-parallel-sessions", outputs == 10,
                  "All eight distinct sessions reach the audio sink; no global sound cooldown is applied.")
        }

        func verifyInteractions() async throws {
            let model = delegate.model
            guard let host = delegate.panel.contentView as? TrackingHost<IslandView> else { throw ExportError.unavailableView }
            let location = model.hoverLocation
            let hostLocation = host.pointerLocation
            let hostButtons = host.pointerButtons
            defer {
                model.hover(false)
                model.hoverLocation = location
                host.pointerLocation = hostLocation
                host.pointerButtons = hostButtons
                host.resetHover(requiringExit: false)
            }
            overrides["hoverExpand"] = true
            overrides["hoverDelay"] = 0.06 // The previous saved default must also be protected.
            overrides["keepOpen"] = false
            applyOverrides()
            model.hover(false)
            model.setExpanded(false, origin: .automatic)
            delegate.layout(allowAnimation: false)
            let region = model.compactHoverRegion!
            var point = CGPoint(x: region.midX, y: region.minY - 30)
            var buttons = 0
            model.hoverLocation = { point }
            host.pointerLocation = { point }
            host.pointerButtons = { buttons }
            host.resetHover(requiringExit: false)
            var eventTime = ProcessInfo.processInfo.systemUptime
            func move(_ destination: CGPoint) throws {
                point = destination
                eventTime = max(eventTime + 0.001, ProcessInfo.processInfo.systemUptime)
                guard let event = NSEvent.mouseEvent(with: buttons == 0 ? .mouseMoved : .leftMouseDragged,
                    location: .zero, modifierFlags: [], timestamp: eventTime,
                    windowNumber: delegate.panel.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 0, pressure: 0) else { throw ExportError.invalidBootState }
                host.mouseMoved(with: event)
            }
            var stayedOutside = true
            for gap in [20.0, 11, 1, 0.5] {
                try move(CGPoint(x: region.midX, y: region.minY - gap))
                try await pause(0.22)
                stayedOutside = stayedOutside && !model.expanded && !model.pointerInside && model.expansionTimer == nil
            }
            check("hover-below-visible-edge-stays-compact", stayedOutside,
                  "Native tracking ignores sustained pauses 20, 11, 1 and 0.5 points below the visible bottom.")
            try move(CGPoint(x: region.minX + 1, y: region.midY))
            try await pause(0.22)
            check("hover-transparent-shoulder-stays-compact", !model.pointerInside && !model.expanded,
                  "The transparent part of the native window is outside the drawn silhouette.")
            buttons = 1
            try move(CGPoint(x: region.midX, y: region.midY))
            try await pause(0.22)
            check("hover-drag-stays-compact", !model.pointerInside && !model.expanded,
                  "Dragging another window across the notch cannot arm hover.")
            buttons = 0
            try move(CGPoint(x: region.minX + 20, y: region.midY))
            try await pause(0.09)
            check("hover-brief-entry-stays-compact", !model.expanded,
                  "The legacy 60 ms setting does not open the panel on a brief accidental entry.")
            var crossedWithoutOpening = true
            for step in 1...12 {
                try move(CGPoint(x: region.minX + 20 + CGFloat(step) * (region.width - 40) / 12, y: region.midY))
                try await pause(0.025)
                crossedWithoutOpening = crossedWithoutOpening && !model.expanded
            }
            check("hover-crossing-stays-compact", crossedWithoutOpening,
                  "Moving continuously through the actual compact activation region never opens the panel.")
            try await pause(0.3)
            check("hover-pause-opens-native-panel", model.expanded && delegate.panel.frame.height > region.height,
                  "Stopping within the region opens the real NSWindow after the protected pause.")
            try move(CGPoint(x: region.midX, y: model.hoverRegion!.minY - 60))
            try await pause(0.6)
            check("hover-leave-collapses-native-panel", !model.expanded,
                  "Leaving still collapses the native panel and cancels intent sampling.")
            try move(CGPoint(x: region.midX, y: region.minY + 0.5))
            try await pause(0.09)
            check("hover-contact-requires-pause", model.pointerInside && !model.expanded,
                  "Touching the actual contour from below arms dwell without an immediate opening.")
            try await pause(0.3)
            check("hover-contact-pause-opens", model.expanded && delegate.panel.frame.height > region.height,
                  "A stationary pointer half a point inside the contour opens the native panel after dwell.")
            try move(CGPoint(x: region.midX, y: region.minY - 600))
            model.setExpanded(false, origin: .automatic)

            clearFixtures()
            for index in 0..<4 {
                model.inject(["event": "agent.completed", "session_id": "qa-clear-\(index)", "provider": "custom",
                    "title": "Completed task \(index + 1)", "message": "Finished reviewing the change."])
            }
            model.setExpanded(true, origin: .hover)
            try await pause(0.7)
            let beforeClear = delegate.panel.frame
            let footer = CGPoint(x: beforeClear.maxX - 80, y: beforeClear.minY + 18)
            try move(footer)
            try capturePanel(name: "clear-before", language: "en")
            model.clearFinished()
            try await pause(0.6)
            let afterClear = delegate.panel.frame
            check("clear-resizes-without-collapsing", model.sessions.isEmpty && model.expanded && model.pointerInside &&
                  afterClear.height < beforeClear.height && abs(afterClear.width - beforeClear.width) < 1,
                  "Clearing the real panel shrinks its content while preserving interaction at the stationary footer pointer.")
            try capturePanel(name: "clear-after", language: "en")
            try move(CGPoint(x: beforeClear.midX, y: beforeClear.minY + 35))
            try await pause(0.35)
            check("clear-allows-return-through-old-surface", model.expanded && model.pointerInside,
                  "The user can move back toward the shorter panel without racing its collapse timer.")
            try move(CGPoint(x: afterClear.midX, y: afterClear.midY))
            try move(footer)
            try await pause(0.6)
            check("clear-return-releases-old-surface", !model.expanded && !model.pointerInside,
                  "After entering the resized surface, leaving it collapses normally; the old footprint is no longer retained.")
            try move(footer)
            try await pause(0.25)
            check("clear-never-enlarges-compact-activation", !model.expanded && model.expansionTimer == nil,
                  "The collapsed notch cannot reopen from the previous Clear button location.")

            let suite = "si-notch.qa-settings-sound." + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            var arguments = overrides
            arguments["sound"] = true
            arguments["quiet"] = false
            preferences.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            defer { preferences.removePersistentDomain(forName: suite); applyOverrides() }
            var outputs: [Data] = []
            let player = EventSoundPlayer(defaults: preferences, output: { data, _ in outputs.append(data); return true })
            let settingsModel = AppModel(defaults: preferences, soundPlayer: player)
            let settingsDelegate = AppDelegate(model: settingsModel)
            defer { settingsDelegate.settingsWindow?.close(); settingsModel.shutdown() }
            settingsModel.setExpanded(true, origin: .automatic)
            settingsDelegate.showSettings()
            check("settings-navigation-is-silent", !settingsModel.expanded && outputs.isEmpty &&
                  settingsDelegate.settingsWindow?.isVisible == true,
                  "The real Settings action shows its NSWindow and collapses silently with sounds enabled.")
            settingsDelegate.settingsWindow?.close()
            settingsModel.setExpanded(true, origin: .automatic)
            settingsModel.setExpanded(false)
            check("explicit-collapse-keeps-sound", outputs == [EventSoundPlayer.wavData(for: .collapse)!],
                  "An explicit panel close still reaches the audio sink with the bundled collapse recording.")
        }

        func exportMemoryServices() async throws {
            let model = delegate.model
            overrides["panelWidth"] = 680.0
            let prompts = [
                "## Memory Writing Agent: Phase 2 (Consolidation) You are a Memory Writing Agent.",
                "Consolidate the supplied rollout summaries into `memory_summary.md` so another agent understands them.",
                "Review parser changes"
            ]
            for language in ["en", "ru", "zh-Hans"] {
                clearFixtures()
                overrides["appLanguage"] = language
                applyOverrides()
                for (index, prompt) in prompts.enumerated() {
                    model.inject(["event": "agent.working", "session_id": "qa-memory-\(index)", "provider": "codex",
                        "title": prompt, "first_prompt": prompt, "cwd": index == 0 ? "/work/memories" : "/work/memories_v2"])
                }
                check("memory-service-labels-\(language)", model.sessions.count == 3 &&
                      model.sessions.filter { SessionCardContent(session: $0).isMemoryService }.count == 2,
                      "The two observed memory jobs carry a service label; an ordinary task in the same folder remains ordinary.")
                try await settle(expanded: true)
                try capturePanel(name: "island-memory-services-\(language)", language: language)
            }
        }

        func exportHistory() async throws {
            let model = delegate.model
            // QA returns before AppModel.start(), so this exclusive fixture
            // directory can never touch the user's real archive.
            model.history.start(directory: directory.appendingPathComponent("history-fixture"))
            overrides["panelWidth"] = 680.0
            applyOverrides()
            for (index, request) in ["Fix panel navigation", "Review session permissions", "Polish the settings layout"].enumerated() {
                let items = [AgentHistoryItem(id: "request", role: .user, text: request),
                    AgentHistoryItem(id: "command", role: .command, text: "swift test --filter PanelTests"),
                    AgentHistoryItem(id: "reply", role: .assistant, text: "Updated the panel and verified the result.\nThe history remains available after completed sessions are cleared.")]
                let event = AgentEvent(sessionID: "qa-history-\(index)", provider: "codex", kind: .completed,
                    title: request, projectPath: "/work/si-notch", firstPrompt: request, turnID: "turn-\(index)", historyItems: items)
                model.receive(try JSONEncoder().encode(event), reply: { _ in })
            }
            model.history.shutdown()
            try await pause(0.1)
            model.clearFinished()
            check("history-survives-done", model.sessions.isEmpty && model.history.records.count == 3,
                  "Clearing live completed cards retains the three local text records.")
            let reopened = try HistoryStore(directory: directory.appendingPathComponent("history-fixture"), policy: .init())
            let saved = try reopened.ordered.first.flatMap { try reopened.entry($0.id) }
            check("history-reopens", reopened.ordered.count == 3 && saved?.items.count == 3,
                  "The private fixture archive reopens with request, reply and command; no command output is supplied or stored.")
            for (id, status, kind, prompt) in [
                ("working", AgentStatus.working, AgentEventKind.working, "Review the next change"),
                ("waiting", .waiting, .waiting, "Choose the update channel"),
                ("failed", .failed, .failed, "Verify the release archive"),
                ("memory", .completed, .completed, "Consolidate the supplied rollout summaries into `memory_summary.md` so another agent understands them.")
            ] {
                let session = AgentSession(id: "qa-history-" + id, provider: "codex", title: prompt,
                    projectPath: "/work/si-notch", status: status)
                let event = AgentEvent(sessionID: session.id, provider: "codex", kind: kind,
                    firstPrompt: prompt, turnID: "turn-" + id,
                    historyItems: [.init(id: "request", role: .user, text: prompt)])
                model.history.record(event, session: session)
            }
            model.history.shutdown()
            try await pause(0.1)
            for language in ["en", "ru", "zh-Hans"] {
                overrides["appLanguage"] = language; applyOverrides()
                model.activeFilter = "history.title"
                model.history.back()
                try await settle(expanded: true)
                try capturePanel(name: "island-history-list-\(language)", language: language)
                try await captureHosted(HistoryView(history: model.history).preferredColorScheme(.dark).background(.black),
                    name: "history-narrow-\(language)", language: language, size: NSSize(width: 360, height: 480))
                model.history.search = L10n.tr("history.memoryTitle")
                check("history-memory-title-search-\(language)", model.history.matching.count == 1 && model.history.matching.first?.memoryService == true,
                      "The compact localized memory title is searchable without knowing the original technical prompt.")
                check("history-memory-source-\(language)", model.history.matching.first?.historyProviderName == "Codex",
                      "Background memory records retain the originating agent name alongside their status.")
                model.history.search = ""
                if let id = model.history.records.first?.id {
                    model.history.open(id); try await pause(0.15)
                    try capturePanel(name: "island-history-detail-\(language)", language: language)
                }
                try await captureHosted(HistorySettingsView(history: model.history, defaults: model.defaults)
                    .padding(24).frame(maxHeight: .infinity, alignment: .top).background(SettingsPalette.background)
                    .preferredColorScheme(.dark).toggleStyle(SettingsSwitchStyle()),
                    name: "settings-history-\(language)", language: language, size: NSSize(width: 580, height: 620))
            }
            model.history.clear(); model.history.shutdown(); try await pause(0.1)
            check("history-clear", model.history.records.isEmpty && model.sessions.isEmpty,
                  "Clear removes only the isolated QA archive and leaves the live session store alone.")
        }

        func clearFixtures() {
            let model = delegate.model
            model.setExpanded(false)
            for id in Array(model.pending.keys) { model.cancelRequest(id) }
            model.store = SessionStore()
            model.selectedID = nil
            model.appOwnedTitles.removeAll()
            model.appOwnedMessages.removeAll()
            model.activity.removeAll()
            model.search = ""
            model.activeFilter = "Все"
            model.showAgents = false
            model.providerReceipts.removeAll()
        }

        func settle(expanded: Bool) async throws {
            delegate.model.setExpanded(expanded)
            delegate.layout(allowAnimation: false)
            try await pause(0.6)
        }

        func exportMotion() async throws {
            try await settle(expanded: true)
            let expanded = Frame(delegate.panel.frame)
            try await settle(expanded: false)
            let compact = Frame(delegate.panel.frame)
            report.compactFrame = compact
            report.expandedFrame = expanded
            if !delegate.model.floatingSurface, let screen = delegate.selectedScreen() {
                let bleed = 1.0
                check("top-edge-bleed", abs(compact.maxY - screen.frame.maxY - bleed) < 0.001 &&
                      abs(expanded.maxY - screen.frame.maxY - bleed) < 0.001,
                      "Both panel endpoints extend \(bleed) pt above the display; the visible top row stays covered.")
            }
            let width = Double(delegate.model.cameraWidth + delegate.model.compactWingWidth + delegate.model.compactStatusWidth + 2 * delegate.model.compactShoulderWidth)
            check("compact-menu-clearance", abs(compact.width - width) <= 1,
                  "The title and 18 pt status counter have separate wings; the status wing no longer grows with the title.")

            let open = try await trace(name: "open", duration: 0.70, expected: expanded, actions: [
                ScheduledAction(time: 0, name: "open", apply: { self.delegate.model.setExpanded(true) })
            ])
            validate(open, anchor: compact, expected: expanded)
            try await settle(expanded: false)
            let repeated = try await trace(name: "open-repeated-layout", duration: 0.85, expected: expanded, actions: [
                ScheduledAction(time: 0, name: "open", apply: { self.delegate.model.setExpanded(true) }),
                ScheduledAction(time: 0.08, name: "repeat-layout-1", apply: { self.delegate.layout() }),
                ScheduledAction(time: 0.16, name: "repeat-layout-2", apply: { self.delegate.layout() }),
                ScheduledAction(time: 0.24, name: "repeat-layout-3", apply: { self.delegate.layout() })
            ])
            validate(repeated, anchor: compact, expected: expanded)
            compareCompletion(open, repeated)

            try await settle(expanded: true)
            let close = try await trace(name: "close", duration: 0.70, expected: compact, actions: [
                ScheduledAction(time: 0, name: "close", apply: {
                    self.delegate.model.setExpanded(false)
                    let outsidePill = CGPoint(x: compact.x + compact.width / 2, y: expanded.y + 20)
                    self.check("collapse-hover-target-is-compact-immediately",
                        self.delegate.model.hoverRegion == self.delegate.model.compactHoverRegion &&
                        self.delegate.model.hoverRegion?.contains(outsidePill) == false,
                        "The departing expanded window must never remain an activation target during collapse.")
                })
            ])
            validate(close, anchor: expanded, expected: compact)
            try await settle(expanded: true)
            let reverse = try await trace(name: "close-fast-reverse", duration: 0.85, expected: expanded, actions: [
                ScheduledAction(time: 0, name: "close", apply: { self.delegate.model.setExpanded(false) }),
                ScheduledAction(time: 0.12, name: "reverse-open", apply: { self.delegate.model.setExpanded(true) })
            ])
            validate(reverse, anchor: expanded, expected: expanded)
            if let action = reverse.actions.first(where: { $0.name == "reverse-open" }) {
                if report.reduceMotion {
                    report.checks.append(Check(name: "reverse-starts-from-current-frame", outcome: "not-applicable",
                                               detail: "System Reduce Motion is enabled; reversal is an immediate frame change."))
                } else {
                    let intermediate = action.before.distance(to: compact) > 1 && action.before.distance(to: expanded) > 1
                    let noJump = action.before.distance(to: action.after) <= 1
                    report.checks.append(Check(name: "reverse-starts-from-current-frame",
                        outcome: !intermediate ? "inconclusive" : noJump ? "passed" : "failed",
                        detail: "Reversal at \(action.actualElapsed)s; intermediate=\(intermediate); synchronous frame change=\(action.before.distance(to: action.after)) pt."))
                }
            }

            clearFixtures()
            delegate.model.inject(["event": "agent.working", "session_id": "qa-filter-working", "provider": "custom",
                "title": "Build the app", "message": "Checking the current change."])
            delegate.model.inject(["event": "agent.completed", "session_id": "qa-filter-done", "provider": "custom",
                "title": "Review the release", "message": "The review is complete."])
            delegate.model.activeFilter = "Все"
            try await settle(expanded: true)
            let all = Frame(delegate.panel.frame)
            try capturePanel(name: "island-filter-all", language: "en")
            delegate.model.activeFilter = "В работе"
            try await settle(expanded: true)
            let working = Frame(delegate.panel.frame)
            try capturePanel(name: "island-filter-working", language: "en")
            let grow = try await trace(name: "filter-working-to-all", duration: 0.70, expected: all, actions: [
                ScheduledAction(time: 0, name: "select-all", apply: { self.delegate.model.activeFilter = "Все" })
            ])
            validate(grow, anchor: working, expected: all)
            check("filter-grows-without-an-agent-event", all.height > working.height &&
                  grow.samples.contains { $0.elapsed < 0.15 && $0.frame.height > working.height + 1 },
                  "Changing the filter must start resizing in the first 150 ms, even when every card is already measured.")
            let shrink = try await trace(name: "filter-all-to-working", duration: 0.70, expected: working, actions: [
                ScheduledAction(time: 0, name: "select-working", apply: { self.delegate.model.activeFilter = "В работе" })
            ])
            validate(shrink, anchor: all, expected: working)
            clearFixtures()
        }

        func trace(name: String, duration: Double, expected: Frame, actions scheduled: [ScheduledAction]) async throws -> Trace {
            let folder = "motion/\(name)"
            try files.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: false)
            let start = ProcessInfo.processInfo.systemUptime
            var samples: [Sample] = []
            var actions: [Action] = []
            var displayLinkFrames: [IslandWindowAnimator.FrameTiming] = []
            delegate.onAnimationFrame = { displayLinkFrames.append($0) }
            defer { delegate.onAnimationFrame = nil }
            var nextAction = 0
            while true {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                while nextAction < scheduled.count, scheduled[nextAction].time <= elapsed {
                    let action = scheduled[nextAction]
                    let before = Frame(delegate.panel.frame)
                    let actual = ProcessInfo.processInfo.systemUptime - start
                    action.apply()
                    actions.append(Action(name: action.name, scheduledElapsed: action.time,
                                          actualElapsed: actual, before: before, after: Frame(delegate.panel.frame)))
                    nextAction += 1
                }
                let timestamp = ProcessInfo.processInfo.systemUptime
                let frame = Frame(delegate.panel.frame)
                let path = geometryOnly ? "" : folder + String(format: "/frame-%04d.png", samples.count)
                if !geometryOnly {
                    guard let view = delegate.panel.contentView else { throw ExportError.unavailableView }
                    _ = try capture(view, relativePath: path)
                }
                samples.append(Sample(elapsed: timestamp - start, monotonicTime: timestamp,
                    frame: frame, expanded: delegate.model.expanded, png: path,
                    captureSeconds: ProcessInfo.processInfo.systemUptime - timestamp))
                let now = ProcessInfo.processInfo.systemUptime
                if now - start >= duration { break }
                // Skip missed sample slots instead of fabricating duplicate frames.
                let nextSlot = floor((now - start) * samplesPerSecond) + 1
                try await pause(max(0.001, start + nextSlot / samplesPerSecond - now))
            }
            let result = Trace(name: name, startedAtMonotonicTime: start, expectedFinalFrame: expected,
                               requestedSamplesPerSecond: samplesPerSecond, samples: samples, actions: actions,
                               displayLinkFrames: displayLinkFrames)
            let path = "motion/\(name).json"
            try writeJSON(result, relativePath: path)
            report.traceFiles.append(path)
            return result
        }

        func verifyWindowAnchorRecovery() async throws {
            for mode in ["notch", "belowMenu"] {
                overrides["displayMode"] = mode
                applyOverrides()
                for expanded in [false, true] {
                    try await settle(expanded: expanded)
                    let expected = delegate.panel.frame
                    // Reproduce a system move after the previous animation has
                    // completed while the layout cache still holds its destination.
                    delegate.panel.delegate = nil
                    delegate.panel.setFrameOrigin(NSPoint(x: expected.minX, y: expected.minY - 33))
                    delegate.layout()
                    check("\(mode)-\(expanded)-cached-destination-recovery", delegate.panel.frame == expected,
                          "A 33 pt external displacement is repaired even when the requested layout has not changed.")
                    delegate.panel.delegate = delegate
                    for shift in [12.0, 33.0, 80.0] {
                        delegate.panel.setFrameOrigin(NSPoint(x: expected.minX, y: expected.minY - shift))
                        try await pause(0.03)
                        check("\(mode)-\(expanded)-move-\(Int(shift))", delegate.panel.frame == expected,
                              "The live NSWindow move notification restores the top anchor without a second hover.")
                    }
                    delegate.panel.orderOut(nil)
                    delegate.panel.setFrameOrigin(NSPoint(x: expected.minX, y: expected.minY - 33))
                    delegate.layout(allowAnimation: false)
                    check("\(mode)-\(expanded)-hidden-stays-hidden", !delegate.panel.isVisible,
                          "Geometry repair never orders a hidden panel above the desktop or Exposé.")
                    delegate.panel.orderFrontRegardless()
                    try capturePanel(name: "island-anchor-\(mode)-\(expanded)", language: "en")
                }
            }
            overrides["displayMode"] = "notch"
            applyOverrides()
            try await settle(expanded: false)
        }

        func validate(_ trace: Trace, anchor: Frame, expected: Frame) {
            guard let final = trace.samples.last else { return }
            check(trace.name + "-final-frame", final.frame.distance(to: expected) <= 1,
                  "Final native frame differs from the calibrated destination by \(final.frame.distance(to: expected)) pt.")
            let minimumCenter = min(report.compactFrame?.midX ?? anchor.midX, anchor.midX, expected.midX)
            let maximumCenter = max(report.compactFrame?.midX ?? anchor.midX, anchor.midX, expected.midX)
            let centerError = trace.samples.map { max(0, minimumCenter - $0.frame.midX, $0.frame.midX - maximumCenter) }.max() ?? 0
            let topError = trace.samples.map { abs($0.frame.maxY - anchor.maxY) }.max() ?? 0
            check(trace.name + "-fixed-top-contained-center", centerError <= 0.5 && topError < 0.001,
                  "Maximum center overshoot beyond the asymmetric compact/expanded endpoints=\(centerError) pt; top displacement=\(topError) pt.")
            let gap = largestGap(trace)
            let slowestCapture = trace.samples.map(\.captureSeconds).max() ?? 0
            report.checks.append(Check(name: trace.name + "-sampling-quality",
                outcome: gap <= 0.10 && slowestCapture <= 0.10 ? "passed" : "inconclusive",
                detail: "\(trace.samples.count) actual samples; largest gap=\(gap)s; longest sample work=\(slowestCapture)s; PNG capture=\(!geometryOnly). Requested rate is \(samplesPerSecond) fps, not a claimed achieved rate."))
            if !report.reduceMotion && trace.name != "close-fast-reverse" {
                let intermediate = trace.samples.filter { $0.frame.distance(to: anchor) > 1 && $0.frame.distance(to: expected) > 1 }.count
                report.checks.append(Check(name: trace.name + "-intermediate-native-frames",
                    outcome: intermediate >= 2 ? "passed" : "inconclusive",
                    detail: "Observed \(intermediate) native frames distinct from both endpoints."))
                let lower = min(anchor.height, expected.height)
                let upper = max(anchor.height, expected.height)
                let bounce = max(2, (upper - lower) * 0.06)
                let bounded = trace.samples.allSatisfy { $0.frame.height >= lower - 1 && $0.frame.height <= upper + bounce }
                check(trace.name + "-bounded-spring", bounded, "The native drop may overshoot by at most 6 percent of its travel before settling.")
            }
        }

        func largestGap(_ trace: Trace) -> Double {
            zip(trace.samples, trace.samples.dropFirst()).map { $0.1.elapsed - $0.0.elapsed }.max() ?? 0
        }

        func completionTime(_ trace: Trace) -> Double? {
            trace.samples.indices.first { index in
                trace.samples[index...].allSatisfy { $0.frame.distance(to: trace.expectedFinalFrame) <= 1 }
            }.map { trace.samples[$0].elapsed }
        }

        func compareCompletion(_ baseline: Trace, _ repeated: Trace) {
            guard !report.reduceMotion else {
                report.checks.append(Check(name: "repeated-layout-does-not-restart", outcome: "not-applicable",
                                           detail: "System Reduce Motion is enabled; no animated duration can be compared."))
                return
            }
            guard largestGap(baseline) <= 0.10, largestGap(repeated) <= 0.10,
                  let baseTime = completionTime(baseline), let repeatTime = completionTime(repeated),
                  repeated.actions.filter({ $0.name.hasPrefix("repeat-layout") }).allSatisfy({ $0.actualElapsed < baseTime }) else {
                report.checks.append(Check(name: "repeated-layout-does-not-restart", outcome: "inconclusive",
                    detail: "Sampling or action timing did not expose a usable pre-completion repeat; inspect timestamps and rerun."))
                return
            }
            check("repeated-layout-does-not-restart", repeatTime <= baseTime + 0.12,
                  "Baseline first stable endpoint=\(baseTime)s; repeated-layout endpoint=\(repeatTime)s; allowed sampling difference=0.12s.")
        }

        func exportRemoteViews() async throws {
            let suite = "si-notch.qa.remote." + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let model = AppModel(defaults: preferences)
            guard let id = model.remoteConnections.add() else { throw ExportError.invalidBootState }
            var connection = model.remoteConnections.connections[0]
            connection.name = "lain"; connection.host = "user@trusted-host"
            connection.remoteSocketPath = "/home/user/.si-notch/run/events.sock"
            connection.profiles = ["lain", "Editor", "Researcher"].enumerated().map { index, name in
                RemoteHermesProfile(id: index == 0 ? "default" : name.lowercased(), home: "/home/user/.hermes",
                    displayName: name, enabled: true, showSessionText: index == 0, pluginInstalled: true, connectionId: "profile-\(index)")
            }
            model.remoteConnections.update(connection)
            for language in ["en", "ru", "zh-Hans"] {
                overrides["appLanguage"] = language; applyOverrides()
                try await captureHosted(SettingsView(model: model, tab: 10), name: "settings-remote-\(language)",
                    language: language, size: NSSize(width: 820, height: 660))
            }
            _ = model.remoteConnections.add()
            overrides["appLanguage"] = "en"; applyOverrides()
            try await captureHosted(SettingsView(model: model, tab: 10), name: "settings-remote-multiple",
                language: "en", size: NSSize(width: 820, height: 660))
            model.remoteConnections.remove(model.remoteConnections.connections[1].id)
            model.showAgents = true; model.expanded = true
            try await captureHosted(IslandView(model: model), name: "agents-remote-group", language: "en", size: NSSize(width: 680, height: 280))
            check("remote-fixtures-disconnected", model.remoteConnections.state(id) == .disconnected && model.store.sessions.isEmpty,
                "Rendering saved profiles must not open SSH or create tasks.")
        }

        func exportScreenViews() async throws {
            let model = delegate.model
            overrides["companionStyle"] = "cat"
            overrides["quiet"] = false
            applyOverrides()
            model.inject(["event": "agent.working", "session_id": "qa-screen", "provider": "custom",
                          "title": "External display preview"])
            for screen in NSScreen.screens {
                let id = delegate.screenID(screen)
                overrides["screenID"] = id
                applyOverrides()
                var compact = CGRect.zero
                var expandedFrame = CGRect.zero
                for expanded in [false, true] {
                    try await settle(expanded: expanded)
                    let name = "screen-\(id)-\(expanded ? "expanded" : "compact")"
                    try recordStatic(delegate.panel.contentView!, name: name, language: "en")
                    let frame = delegate.panel.frame
                    if expanded { expandedFrame = frame } else { compact = frame }
                    check(name + "-bounds", frame.minX >= screen.frame.minX && frame.maxX <= screen.frame.maxX &&
                          frame.minY >= screen.frame.minY && frame.maxY <= screen.frame.maxY + 1,
                          "\(screen.localizedName): screen=\(screen.frame), panel=\(frame), scale=\(screen.backingScaleFactor).")
                    if model.trailingSurface {
                        check(name + "-right-anchor", abs(frame.maxX - screen.frame.maxX + 12) <= 0.5,
                              "The external surface stays 12 pt from the right edge.")
                        check(name + "-menu-clearance", screen.visibleFrame.maxY - frame.maxY >= 8,
                              "The panel does not overlap the menu bar; its camera gap is \(model.cameraWidth) pt.")
                    }
                }
                if model.trailingSurface {
                    try await settle(expanded: false)
                    for opening in [true, false] {
                        let target = opening ? expandedFrame : compact
                        let trace = try await trace(name: "screen-\(id)-\(opening ? "open" : "close")",
                            duration: 0.75, expected: Frame(target), actions: [
                                ScheduledAction(time: 0, name: "toggle", apply: { model.setExpanded(opening) })
                            ])
                        check(trace.name + "-fixed-corner", trace.samples.allSatisfy {
                            abs($0.frame.x + $0.frame.width - target.maxX) <= 1 && abs($0.frame.maxY - target.maxY) <= 1
                        }, "Every sampled native frame retains the top-right anchor.")
                        check(trace.name + "-destination", trace.samples.last.map { $0.frame.distance(to: Frame(target)) <= 1 } == true,
                              "The native transition reaches its intended frame.")
                    }
                }
            }
            for style in CompanionStyle.allCases {
                overrides["companionStyle"] = style.rawValue
                applyOverrides()
                try await pause(0.1)
                check("menu-icon-follows-" + style.rawValue, delegate.statusIconStyle == style &&
                      delegate.statusItem.button?.image?.isTemplate == true,
                      "Changing the companion preference refreshes the actual status item without restarting.")
            }
            overrides["companionStyle"] = "cat"
            applyOverrides()
            let iconGallery = VStack(spacing: 0) {
                ForEach(CompanionStyle.allCases) { style in
                    HStack(spacing: 0) {
                        ForEach([false, true], id: \.self) { dark in
                            HStack(spacing: 20) {
                                Image(nsImage: StatusBarIcon.make(style: style))
                                Image(nsImage: StatusBarIcon.make(style: style)).resizable().frame(width: 80, height: 72)
                            }.foregroundStyle(dark ? Color.white : Color.black)
                                .frame(width: 160, height: 100).background(dark ? Color(white: 0.12) : Color(white: 0.93))
                        }
                    }
                }
            }
            for screen in NSScreen.screens {
                try await captureHosted(iconGallery, name: "menu-companions-\(delegate.screenID(screen))-light-dark",
                                        language: "en", size: NSSize(width: 320, height: 400), screen: screen)
            }
            overrides["screenID"] = "auto"
            applyOverrides()
            try await settle(expanded: false)
            check("screen-auto-return", delegate.selectedScreen() ==
                  (NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first),
                  "Automatic selection returns to the available notched display, or the primary screen.")
        }

        func exportDisplayViews() async throws {
            let model = delegate.model
            overrides["showOnlyWithSessions"] = true
            applyOverrides()
            let presentation = PresentationPolicy(defaults: defaults,
                state: { [unowned self] in
                    var state = model.presentationState
                    state.isSettingsVisible = delegate.settingsPresented
                    return state
                }, panel: { [unowned self] in delegate.panel },
                onVisibilityChange: { [unowned self] in delegate.applyIslandVisibility($0) },
                onAutoDismiss: { model.setExpanded(false, origin: .automatic) })
            model.presentationPolicy = presentation
            presentation.start()
            defer { presentation.stop(); model.presentationPolicy = nil }
            check("display-empty-hidden", !delegate.panel.isVisible, "An empty island is ordered out immediately.")
            model.inject(["event": "agent.presence", "session_id": "qa-presence", "provider": "qa-fixture"])
            model.inject(["event": "session.start", "session_id": "qa-idle", "provider": "qa-fixture"])
            check("display-presence-hidden", !delegate.panel.isVisible, "Connections without tasks do not show the island.")
            model.inject(["event": "agent.working", "session_id": "qa-task", "provider": "qa-fixture", "title": "Display check"])
            check("display-task-visible", delegate.panel.isVisible, "A first task shows the native panel without polling.")
            model.inject(["event": "agent.waiting", "session_id": "qa-task", "provider": "qa-fixture"])
            check("display-waiting-visible", delegate.panel.isVisible, "A question keeps the panel available.")
            model.inject(["event": "agent.completed", "session_id": "qa-task", "provider": "qa-fixture"])
            check("display-result-visible", delegate.panel.isVisible, "The result stays visible until dismissed.")
            model.setExpanded(true, origin: .hover)
            model.clearFinished()
            check("display-clear-preserves-open-panel", delegate.panel.isVisible && model.expanded && model.sessions.isEmpty,
                  "Explicit Clear keeps the panel open even after its last task is removed.")
            model.setExpanded(false)
            check("display-close-after-clear-hidden", !delegate.panel.isVisible,
                  "Closing the empty panel restores session-only hiding immediately.")
            model.setExpanded(true)
            check("display-manual-open", delegate.panel.isVisible, "Explicit menu or shortcut expansion remains available.")
            model.setExpanded(false)
            check("display-manual-close", !delegate.panel.isVisible, "Closing an empty manually opened panel hides it again.")
            delegate.settingsPresented = true
            presentation.refresh()
            check("display-settings-hidden", !delegate.panel.isVisible, "The session-only switch applies while Settings are open too.")
            delegate.settingsPresented = false
            presentation.refresh()
            check("display-settings-close-hidden", !delegate.panel.isVisible, "Closing Settings restores session-only visibility.")
            overrides["showOnlyWithSessions"] = false
            applyOverrides()
            presentation.refresh()
            check("display-toggle-off-visible", delegate.panel.isVisible, "Disabling session-only display restores the empty island.")
            for language in ["en", "ru", "zh-Hans"] {
                overrides["appLanguage"] = language
                applyOverrides()
                let settings = SettingsView(model: model, tab: 5)
                try await captureHosted(settings, name: "settings-display-\(language)", language: language,
                                        size: NSSize(width: 820, height: 660))
                try await captureHosted(settings.display.frame(maxHeight: .infinity, alignment: .top)
                    .padding(20).background(SettingsPalette.background)
                    .preferredColorScheme(.dark).toggleStyle(SettingsSwitchStyle())
                    .groupBoxStyle(SettingsCardGroupBoxStyle()).tint(NotchDesign.accent),
                    name: "settings-display-full-\(language)", language: language, size: NSSize(width: 600, height: 1450))
            }
            clearFixtures()
            overrides["appLanguage"] = "en"
            let detailKeys = ["showModel", "showReasoning", "showProject", "showTasks", "showSubagents", "showActivity"]
            for key in detailKeys { overrides[key] = true }
            applyOverrides()
            let id = "qa-metadata"
            model.inject(["event": "agent.working", "session_id": id, "provider": "hermes",
                "title": "Verify native session details", "model": "example-model", "reasoning_effort": "high",
                "cwd": "/work/metadata-project", "message": "Checking model metadata and card controls."])
            model.inject(["event": "tool.start", "session_id": id, "provider": "hermes", "tool_name": "read_file"])
            model.inject(["event": "task.update", "session_id": id, "provider": "hermes",
                "task": ["id": "metadata-task", "title": "Verify all six detail switches", "status": "working"]])
            model.inject(["event": "subagent.start", "session_id": id, "provider": "hermes",
                "subagent": ["id": "metadata-child", "name": "reviewer", "status": "working"]])
            model.selectedID = id
            guard let session = model.store.sessions[id] else { throw ExportError.fixtureNotApplied("session-metadata") }
            check("display-complete-metadata", session.modelName == "example-model" && session.reasoningEffort == "high" &&
                  session.projectPath != nil && session.tasks.count == 1 && session.subagents.count == 1 && !model.activity[id, default: []].isEmpty,
                  "A single native event stream supplies model, reasoning, project, tasks, subagents and activity.")
            for hidden in ["none"] + detailKeys {
                for key in detailKeys { overrides[key] = key != hidden }
                applyOverrides()
                try await captureHosted(SessionCard(session: session, model: model).padding(16)
                    .frame(maxHeight: .infinity, alignment: .top).background(Color.black).preferredColorScheme(.dark),
                    name: "session-details-hidden-\(hidden)", language: "en", size: NSSize(width: 600, height: 640))
            }
        }

        func exportStaticViews() async throws {
            for language in ["en", "ru", "zh-Hans"] {
                overrides["appLanguage"] = language
                applyOverrides()
                clearFixtures()
                try await settle(expanded: true)
                try capturePanel(name: "island-empty-\(language)", language: language)
                if language == "en" {
                    delegate.model.inject(["event": "agent.completed", "session_id": "qa-user-ping", "provider": "codex",
                        "title": "Ping", "first_prompt": "Ping", "message": "Pong."])
                    let service = "This is an app-generated request for a suggested next user message. The user did not write this message."
                    delegate.model.inject(["event": "agent.working", "session_id": "qa-service-suggestion", "provider": "codex",
                        "title": service, "first_prompt": service])
                    delegate.model.inject(["event": "agent.completed", "session_id": "qa-service-suggestion", "provider": "codex",
                        "message": "{\"suggestion\":null}"])
                    try await settle(expanded: true)
                    check("codex-suggestion-excluded", delegate.model.sessions.map(\.id) == ["qa-user-ping"],
                          "The user task remains visible; the suggestion request and its late completion do not affect the session count.")
                    try capturePanel(name: "island-user-task-only", language: language)
                    clearFixtures()
                    try await settle(expanded: true)
                }
                for (tab, name) in [(0, "behavior"), (5, "display"), (6, "notifications"), (7, "shortcuts"), (8, "usage"), (1, "integrations"), (3, "sound"), (4, "companions"), (2, "diagnostics"), (9, "about")] {
                    let root = SettingsView(model: delegate.model, tab: tab)
                    try await captureHosted(root, name: "settings-\(name)-\(language)", language: language,
                                            size: NSSize(width: 820, height: 660))
                }
                try await captureHosted(CompanionGallery(), name: "companion-states-\(language)", language: language,
                                        size: NSSize(width: 660, height: 440))
                if language == "en" {
                    try await captureHosted(PixelCompanionFrames(), name: "companion-pixel-frames", language: language,
                                            size: NSSize(width: 760, height: 530))
                    for provider in ["claude", "opencode", "hermes", "gemini", "copilot", "cursor", "custom"] {
                        try await captureHosted(SettingsView(model: delegate.model, tab: 1, selectedProvider: provider, showAgentDiscovery: false),
                            name: "settings-connect-\(provider)", language: language, size: NSSize(width: 820, height: 660))
                    }
                }
                clearFixtures()
                delegate.model.inject(["event": "working", "session_id": "qa-working", "provider": "qa-fixture",
                    "title": "A deliberately long task title / Длинное название / 很长的任务标题",
                    "message": "Local UI fixture. Several lines of task details exercise the card layout without contacting an agent.",
                    "tool_name": "fixture-check"])
                guard delegate.model.store.sessions["qa-working"]?.status == .working else {
                    throw ExportError.fixtureNotApplied("working")
                }
                delegate.model.selectedID = "qa-working"
                delegate.model.inject(["event": "tool.start", "session_id": "qa-working", "provider": "qa-fixture", "tool_name": "read_file"])
                delegate.model.inject(["event": "tool.finish", "session_id": "qa-working", "provider": "qa-fixture", "tool_name": "read_file"])
                delegate.model.inject(["event": "working", "session_id": "qa-working", "provider": "qa-fixture", "message": "Checking the layout and preparing the next change."])
                try await settle(expanded: true)
                try capturePanel(name: "island-selected-working-\(language)", language: language)
                let sessionFrame = delegate.panel.frame
                delegate.model.inject(["event": "session.start", "session_id": "qa-idle-pi", "provider": "pi"])
                delegate.model.selectAgents(true)
                try await settle(expanded: true)
                try capturePanel(name: "island-agents-separated-\(language)", language: language)
                // Saved remote profiles may also be present; assert only the
                // two fixtures rather than depending on the operator's settings.
                let fixtureAgents = delegate.model.agents.filter { ["qa-fixture", "pi"].contains($0.id) }
                check("agents-separated-\(language)", delegate.model.sessions.count == 1 && fixtureAgents.count == 2,
                      "An idle harness belongs to Agents and must not increase the task count.")
                check("tab-adaptive-height-\(language)", abs(delegate.panel.frame.height - delegate.model.panelHeight(limitedTo: 560) - 1) <= 1 &&
                      delegate.panel.frame.maxY == sessionFrame.maxY,
                      "Switching tabs adopts the new content height; the top navigation remains attached to the screen edge.")
                for connection in delegate.model.remoteConnections.connections.filter(\.showInAgents) {
                    let collapsed = delegate.panel.frame
                    delegate.model.setConnectorExpanded(connection.id, true)
                    try await settle(expanded: true)
                    check("agent-group-expand-\(connection.id)-\(language)",
                          abs(delegate.panel.frame.height - delegate.model.panelHeight(limitedTo: 560) - 1) <= 1 &&
                          delegate.panel.frame.maxY == collapsed.maxY,
                          "Opening a remote group follows its visible 32 pt rows within the display limit; height=\(delegate.panel.frame.height), expected=\(delegate.model.panelHeight(limitedTo: 560) + 1).")
                    try capturePanel(name: "island-agent-group-\(connection.id)-\(language)", language: language)
                    delegate.model.setConnectorExpanded(connection.id, false)
                    try await settle(expanded: true)
                    check("agent-group-collapse-\(connection.id)-\(language)", delegate.panel.frame.height <= collapsed.height + 1,
                          "Closing a remote group releases its extra height without an incoming event.")
                }
                delegate.model.selectAgents(false)
                delegate.model.activeFilter = "Готово"
                try await settle(expanded: true)
                check("empty-filter-resizes-\(language)", delegate.panel.frame.height < sessionFrame.height && delegate.panel.frame.maxY == sessionFrame.maxY,
                      "Top filters resize the panel without moving its top edge.")
                clearFixtures()
                for (index, provider) in ["codex", "pi", "claude", "opencode", "hermes", "gemini", "copilot", "cursor", "custom"].enumerated() {
                    delegate.model.inject(["event": index % 3 == 0 ? "working" : index % 3 == 1 ? "agent.completed" : "agent.waiting",
                        "session_id": "qa-provider-\(provider)", "provider": provider,
                        "title": "Check layout — \(provider)", "message": "Fixture: checking a deliberately long file name and a narrow viewport."])
                }
                try await settle(expanded: true)
                try capturePanel(name: "island-all-providers-\(language)", language: language)
                check("all-providers-\(language)", delegate.model.sessions.count == 9, "All nine provider fixtures must remain distinct.")
                if language == "en" {
                    try await captureHosted(ProviderColorGallery(model: delegate.model), name: "provider-colors",
                                            language: language, size: NSSize(width: 1100, height: 560))
                }
                delegate.model.selectedID = "qa-provider-custom"
                delegate.model.inject(["event": "working", "session_id": "qa-provider-custom", "provider": "custom",
                    "title": "A long selected task title / Проверка раскрытой карточки среди девяти сессий",
                    "message": String(repeating: "A bounded update stays inside its card. ", count: 12),
                    "model": "a-deliberately-long-model-name-to-test-narrow-layout"])
                try await settle(expanded: true)
                try capturePanel(name: "island-multiple-selected-\(language)", language: language)
                clearFixtures()
                delegate.model.inject(["event": "approval.request", "session_id": "qa-approval", "provider": "qa-fixture",
                    "title": "Local permission fixture", "message": "Synthetic request for visual QA. No external operation is attached.",
                    "await_response": true, "request_id": "qa-request", "response_timeout": 110])
                guard delegate.model.pending["qa-approval"] != nil else {
                    throw ExportError.fixtureNotApplied("approval")
                }
                try await settle(expanded: true)
                try capturePanel(name: "island-pending-\(language)", language: language)
                clearFixtures()
            }

        }

        func capturePanel(name: String, language: String) throws {
            guard let view = delegate.panel.contentView else { throw ExportError.unavailableView }
            try recordStatic(view, name: name, language: language)
            if name == "island-selected-working-en" {
                try verifyClearSideBands(name: name, viewWidth: view.bounds.width)
                try verifyOpaqueTopRow(name: name, viewWidth: view.bounds.width)
            }
        }

        func verifyOpaqueTopRow(name: String, viewWidth: CGFloat) throws {
            let data = try Data(contentsOf: directory.appendingPathComponent("static/\(name).png"))
            guard let bitmap = NSBitmapImageRep(data: data) else { throw ExportError.cannotEncodePNG }
            let margin = Int(16 * CGFloat(bitmap.pixelsWide) / viewWidth)
            let covered = (margin..<(bitmap.pixelsWide - margin)).allSatisfy { x in
                guard let color = bitmap.colorAt(x: x, y: 0)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent == 1 && max(color.redComponent, color.greenComponent, color.blueComponent) == 0
            }
            check("island-opaque-top-row", covered, "The top row between the shoulders is fully opaque black.")
        }

        func verifyClearSideBands(name: String, viewWidth: CGFloat) throws {
            let data = try Data(contentsOf: directory.appendingPathComponent("static/\(name).png"))
            guard let bitmap = NSBitmapImageRep(data: data), bitmap.hasAlpha else {
                check("island-clear-side-bands", false, "The island capture has no alpha channel.")
                return
            }
            let scale = CGFloat(bitmap.pixelsWide) / viewWidth
            let band = max(1, Int(8 * scale))
            let margin = Int(40 * scale)
            var maximumAlpha: CGFloat = 0
            var samples = 0
            if bitmap.pixelsHigh > margin * 2 {
                for y in margin..<(bitmap.pixelsHigh - margin) {
                    for x in 0..<band {
                        for column in [x, bitmap.pixelsWide - 1 - x] {
                            maximumAlpha = max(maximumAlpha, bitmap.colorAt(x: column, y: y)?.alphaComponent ?? 1)
                            samples += 1
                        }
                    }
                }
            }
            check("island-clear-side-bands", samples > 0 && maximumAlpha <= 1.0 / 255,
                  "\(samples) exterior pixels sampled; maximum alpha=\(maximumAlpha).")
        }

        func captureHosted<Content: View>(_ content: Content, name: String, language: String, size: NSSize,
                                        screen: NSScreen? = nil) async throws {
            let host = NSHostingView(rootView: content.environment(\.locale, Locale(identifier: language)))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: screen?.visibleFrame.origin ?? .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            defer { window.close() }
            // This private hosting window is never ordered on screen. Its content
            // is rendered directly through NSView's own bitmap caching API.
            host.layoutSubtreeIfNeeded()
            try await pause(0.15)
            try recordStatic(host, name: name, language: language)
        }

        func recordStatic(_ view: NSView, name: String, language: String) throws {
            let path = "static/\(name).png"
            let start = ProcessInfo.processInfo.systemUptime
            let pixels = try capture(view, relativePath: path)
            report.staticCaptures.append(StaticCapture(name: name, png: path, language: language,
                viewWidth: view.bounds.width, viewHeight: view.bounds.height,
                pixelWidth: pixels.width, pixelHeight: pixels.height,
                captureSeconds: ProcessInfo.processInfo.systemUptime - start))
        }

        func capture(_ view: NSView, relativePath: String) throws -> (width: Int, height: Int) {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw ExportError.unavailableView }
            view.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ExportError.cannotEncodePNG }
            try png.write(to: directory.appendingPathComponent(relativePath), options: .withoutOverwriting)
            return (bitmap.pixelsWide, bitmap.pixelsHigh)
        }

        func check(_ name: String, _ passed: Bool, _ detail: String) {
            report.checks.append(Check(name: name, outcome: passed ? "passed" : "failed", detail: detail))
        }

        func writeJSON<Value: Encodable>(_ value: Value, relativePath: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: directory.appendingPathComponent(relativePath), options: .withoutOverwriting)
        }

        func pause(_ seconds: Double) async throws {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }

        func log(_ message: String, error: Bool = false) {
            (error ? FileHandle.standardError : FileHandle.standardOutput).write(Data((message + "\n").utf8))
        }
    }

    private struct ProviderColorGallery: View {
        @ObservedObject var model: AppModel
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("AGENT COLORS").font(.system(size: 18, weight: .semibold, design: .monospaced))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(model.sessions) { session in SessionCard(session: session, model: model) }
                }
                Spacer(minLength: 0)
            }
            .padding(24).background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
        }
    }

    private struct CompanionGallery: View {
        let statuses: [AgentStatus] = [.idle, .working, .waiting, .approval, .completed, .failed]
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Companion state fixtures").font(.system(size: 17, weight: .semibold))
                ForEach(CompanionStyle.allCases) { style in
                    HStack(spacing: 12) {
                        Text(L10n.tr(style.displayNameKey)).font(.system(size: 12)).frame(width: 80, alignment: .leading)
                        ForEach(statuses, id: \.rawValue) { status in
                            VStack(spacing: 5) {
                                CompanionView(status: status, size: 46, interactive: false, style: style, animated: false)
                                Text(status.label).font(.system(size: 9)).lineLimit(2)
                            }.frame(width: 72, height: 72)
                        }
                    }
                }
            }.padding(20).frame(width: 660, height: 440, alignment: .topLeading)
                .background(Color(white: 0.08)).foregroundStyle(.white).preferredColorScheme(.dark)
        }
    }
    private struct PixelCompanionFrames: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Text("PIXEL COMPANIONS / REST → TYPE").font(.system(size: 17, weight: .medium, design: .monospaced))
                ForEach(CompanionStyle.allCases) { style in
                    HStack(spacing: 16) {
                        Text(style.rawValue).font(.system(size: 12, design: .monospaced)).frame(width: 70, alignment: .leading)
                        VStack(spacing: 6) {
                            CompanionView(status: .idle, size: 80, interactive: false, style: style, animated: false)
                            Text("REST").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        ForEach(0..<4) { frame in
                            VStack(spacing: 6) {
                                CompanionView(status: .working, size: 80, interactive: false, style: style,
                                              previewTime: Double(frame) / 6 + 0.01)
                                Text("0\(frame + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            CompanionView(status: .working, size: 20, interactive: false, style: style, animated: false)
                            CompanionView(status: .working, size: 22, interactive: false, style: style, animated: false)
                            CompanionView(status: .working, size: 32, interactive: false, style: style, animated: false)
                        }.frame(width: 130)
                    }
                }
            }.padding(24).frame(width: 760, height: 530, alignment: .topLeading)
                .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        }
    }

}
