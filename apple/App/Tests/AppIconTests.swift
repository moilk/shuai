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
    // `AppIcon` itself is an app-icon set, which UIImage(named:) cannot load by that name; the
    // compiler emits the home screen sizes under CFBundleIconFiles, loadable from the bundle.
    #expect(UIImage(named: "AppIcon60x60", in: Bundle.main, compatibleWith: nil) != nil)
}
