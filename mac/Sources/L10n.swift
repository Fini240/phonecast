import Foundation

/// Translations: the Mac app follows the Mac's language (German Macs get German, everything else English).
/// One dictionary for everything: Resources/de.lproj/Localizable.strings. SwiftUI texts written as
/// literals look it up by themselves; tr() covers menus, banners and other strings built in code.
/// Templates use printf placeholders: tr("Remove %@?", name).
func tr(_ s: String, _ args: CVarArg...) -> String {
    let f = Bundle.main.localizedString(forKey: s, value: s, table: nil)
    return args.isEmpty ? f : String(format: f, arguments: args)
}
