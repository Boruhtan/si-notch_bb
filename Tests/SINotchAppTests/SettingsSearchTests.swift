import XCTest
@testable import SINotch

final class SettingsSearchTests: XCTestCase {
    func testSearchFindsPreferenceLabelsInEachSupportedLanguage() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "appLanguage")
        defer {
            if let previous { defaults.set(previous, forKey: "appLanguage") }
            else { defaults.removeObject(forKey: "appLanguage") }
        }
        for (language, query, destination) in [
            ("en", "LOGIN", 0), ("en", "card   text", 5), ("en", "volume", 3),
            ("ru", "при входе", 0), ("ru", "размер текста", 5), ("ru", "громкость", 3),
            ("zh-Hans", "登录", 0), ("zh-Hans", "文字大小", 5), ("zh-Hans", "音量", 3)
        ] {
            defaults.set(language, forKey: "appLanguage")
            let matches = SettingsDestination.all.filter { $0.matches(query) }
            XCTAssertTrue(matches.contains { $0.id == destination }, "\(language): \(query)")
        }
    }

    func testBlankSearchKeepsEveryDestinationAndUnknownSearchIsEmpty() {
        XCTAssertEqual(Set(SettingsDestination.all.filter { $0.matches(" \n ") }.map(\.id)), Set(0...11))
        XCTAssertTrue(SettingsDestination.all.filter { $0.matches("unmatched-settings-query-4872") }.isEmpty)
    }

    func testSearchRequiresEveryWordAndIgnoresDiacritics() throws {
        let destination = try XCTUnwrap(SettingsDestination.all.first)
        let searchable = SettingsDestination(id: destination.id, title: "Café", subtitle: "Keyboard controls",
                                             symbol: destination.symbol, color: destination.color, group: 0)
        XCTAssertTrue(searchable.matches("CAFE keyboard"))
        XCTAssertFalse(searchable.matches("keyboard missing"))
    }
}
