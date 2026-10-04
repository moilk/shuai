import Foundation
import Testing
import UIKit

// The unit tests are hosted by the app, so `Bundle.main` is the app bundle.

@Test func appBundleDeclaresPrimaryIconName() throws {
    let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
    let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
    #expect(primary["CFBundleIconName"] as? String == "AppIcon")
}

@Test func appIconAssetIsInTheCatalog() {
    #expect(UIImage(named: "AppIcon", in: Bundle.main, compatibleWith: nil) != nil)
}
