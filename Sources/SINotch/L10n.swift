import Foundation
import SINotchCore

/// App language selection. Event protocol values and agent-authored content are never translated.
enum L10n {
    static let supported = ["auto", "en", "ru", "zh-Hans"]

    static var language: String {
        let choice = UserDefaults.standard.string(forKey: "appLanguage") ?? "auto"
        if choice != "auto", supported.contains(choice) { return choice }
        for preference in Locale.preferredLanguages {
            if preference.hasPrefix("zh") { return "zh-Hans" }
            if preference.hasPrefix("ru") { return "ru" }
            if preference.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    private static let resourceBundles: [String: Bundle] = {
        let resources = Bundle.main.url(forResource: "si-notch_SINotch", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        return Dictionary(uniqueKeysWithValues: supported.compactMap { code in
            localizedResourceBundle(code, in: resources).map { (code, $0) }
        })
    }()

    private static func resourceBundle(_ code: String) -> Bundle? { resourceBundles[code] }

    static func localizedResourceBundle(_ code: String, in resources: Bundle) -> Bundle? {
        guard let root = resources.resourceURL,
              let folders = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: nil),
              let folder = folders.first(where: {
                  $0.pathExtension == "lproj" &&
                  $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(code) == .orderedSame
              }) else { return nil }
        // SwiftPM versions differ in the case used for script subtags on disk.
        return Bundle(url: folder)
    }

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let english = resourceBundle("en")?.localizedString(forKey: key, value: nil, table: "Localizable") ?? key
        let result = resourceBundle(language)?.localizedString(forKey: key, value: english, table: "Localizable") ?? english
        guard !args.isEmpty else { return result }
        return String(format: result, locale: Locale(identifier: language), arguments: args)
    }

    /// CLDR cardinal categories needed by the supported languages.
    static func count(_ key: String, _ count: Int) -> String {
        let suffix: String
        switch language {
        case "ru":
            let n = abs(count)
            suffix = n % 10 == 1 && n % 100 != 11 ? "one" :
                (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "few" : "many"
        case "en": suffix = count == 1 ? "one" : "other"
        default: suffix = "other"
        }
        return tr("\(key).\(suffix)", count)
    }

    static func eventError(_ error: Error) -> String {
        guard let error = error as? AgentEventError else { return error.localizedDescription }
        switch error {
        case .payloadTooLarge: return tr("event.error.payloadTooLarge")
        case .missingSessionID: return tr("event.error.missingSessionID")
        case .invalidIdentifier(let field): return tr("event.error.invalidIdentifier", field)
        case .invalidProvider: return tr("event.error.invalidProvider")
        case .invalidTimestamp: return tr("event.error.invalidTimestamp")
        case .invalidSequence: return tr("event.error.invalidSequence")
        case .invalidUsage: return tr("event.error.invalidUsage")
        case .invalidField(let field): return tr("event.error.invalidField", field)
        }
    }
}

enum AppDisplayError {
    case channel(String)
    case launchAtLogin(String)
    case missingTarget
    case shortcut(Int)

    var text: String {
        switch self {
        case .channel(let detail): return L10n.tr("Локальный канал недоступен: %@", detail)
        case .launchAtLogin(let detail): return L10n.tr("Не удалось изменить автозапуск: %@", detail)
        case .missingTarget: return L10n.tr("У этой сессии нет адреса приложения. Передайте target_url или terminal_bundle_id в событии.")
        case .shortcut(let code): return L10n.tr("Сочетание ⌃⌥Пробел занято другим приложением (код %d). Панель доступна через меню.", code)
        }
    }
}
