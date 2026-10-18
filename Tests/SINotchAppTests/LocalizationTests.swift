import XCTest
import SINotchCore
@testable import SINotch

final class LocalizationTests: XCTestCase {
    func testScriptLanguageResolvesLowercaseSwiftPMResourceDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let language = root.appendingPathComponent("zh-hans.lproj")
        try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
        try "\"probe\" = \"设置\";".write(to: language.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let resources = try XCTUnwrap(Bundle(url: root))
        let localized = try XCTUnwrap(L10n.localizedResourceBundle("zh-Hans", in: resources))
        XCTAssertEqual(localized.localizedString(forKey: "probe", value: nil, table: "Localizable"), "设置")
        XCTAssertNil(L10n.localizedResourceBundle("ru", in: resources))
    }

    func testLanguageSelectionAndPluralForms() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "appLanguage")
        defer {
            if let previous { defaults.set(previous, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }

        defaults.set("en", forKey: "appLanguage")
        XCTAssertEqual(L10n.tr("Настройки"), "Settings")
        XCTAssertEqual(L10n.count("sessions", 1), "1 session")
        XCTAssertEqual(L10n.count("sessions", 2), "2 sessions")

        defaults.set("ru", forKey: "appLanguage")
        XCTAssertEqual(L10n.tr("Настройки"), "Настройки")
        XCTAssertEqual(L10n.count("sessions", 1), "1 сессия")
        XCTAssertEqual(L10n.count("sessions", 2), "2 сессии")
        XCTAssertEqual(L10n.count("sessions", 5), "5 сессий")
        XCTAssertEqual(L10n.count("sessions", 11), "11 сессий")
        XCTAssertEqual(L10n.count("sessions", 21), "21 сессия")

        defaults.set("zh-Hans", forKey: "appLanguage")
        XCTAssertEqual(L10n.tr("Настройки"), "设置")
        XCTAssertEqual(L10n.count("sessions", 2), "2 个会话")
        XCTAssertEqual(AppDisplayError.missingTarget.text, "此会话没有应用地址。请在事件中提供 target_url 或 terminal_bundle_id。")
        XCTAssertEqual(L10n.eventError(AgentEventError.invalidField("status")), "status 中的值无效。")
    }
}
