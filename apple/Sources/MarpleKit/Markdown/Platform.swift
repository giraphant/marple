import Foundation

#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformBezierPath = NSBezierPath
public typealias PlatformView = NSView
public typealias PlatformFontDescriptor = NSFontDescriptor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformBezierPath = UIBezierPath
public typealias PlatformView = UIView
public typealias PlatformFontDescriptor = UIFontDescriptor

/// Dynamic semantic colors — UIKit equivalents of the AppKit color names the renderer uses.
extension UIColor {
    static var textColor: UIColor { .label }
    static var linkColor: UIColor { .link }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var separatorColor: UIColor { .separator }
}
#endif

/// Bold/italic symbolic-trait cases differ by platform: AppKit spells them
/// `.bold`/`.italic`, UIKit `.traitBold`/`.traitItalic`. These aliases let the
/// renderer use one name for both.
extension PlatformFontDescriptor.SymbolicTraits {
    static var boldTrait: PlatformFontDescriptor.SymbolicTraits {
        #if canImport(AppKit)
        .bold
        #else
        .traitBold
        #endif
    }
    static var italicTrait: PlatformFontDescriptor.SymbolicTraits {
        #if canImport(AppKit)
        .italic
        #else
        .traitItalic
        #endif
    }
}
