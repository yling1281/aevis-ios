// 由 design/spec/tokens.json 生成，不要手改。
// 生成器：design/spec/gen_tokens.py
import SwiftUI

enum Paper {
    static let bg = Color(.sRGB, red: 0.9922, green: 0.9686, blue: 0.9294, opacity: 1.000)
    static let bgAlt = Color(.sRGB, red: 0.9804, green: 0.9529, blue: 0.9020, opacity: 1.000)
    static let surface = Color(.sRGB, red: 1.0000, green: 0.9922, blue: 0.9686, opacity: 1.000)
    static let surfaceSunken = Color(.sRGB, red: 0.9529, green: 0.9294, blue: 0.8784, opacity: 1.000)
    static let ink = Color(.sRGB, red: 0.1412, green: 0.1216, blue: 0.1098, opacity: 1.000)
    static let inkSub = Color(.sRGB, red: 0.5412, green: 0.4784, blue: 0.3686, opacity: 1.000)
    static let inkMuted = Color(.sRGB, red: 0.6588, green: 0.5961, blue: 0.4784, opacity: 1.000)
    static let inkFaint = Color(.sRGB, red: 0.7529, green: 0.6980, blue: 0.5804, opacity: 1.000)
    static let line = Color(.sRGB, red: 0.9020, green: 0.8549, blue: 0.7647, opacity: 1.000)
    static let lineStrong = Color(.sRGB, red: 0.8471, green: 0.7882, blue: 0.6745, opacity: 1.000)
    static let accent = Color(.sRGB, red: 0.4941, green: 0.4196, blue: 0.8471, opacity: 1.000)
    static let accentInk = Color(.sRGB, red: 0.3569, green: 0.2902, blue: 0.6196, opacity: 1.000)
    static let accentSoft = Color(.sRGB, red: 0.9451, green: 0.9176, blue: 1.0000, opacity: 1.000)
    static let accentBorder = Color(.sRGB, red: 0.7255, green: 0.6510, blue: 0.9490, opacity: 1.000)
    static let onAccent = Color(.sRGB, red: 1.0000, green: 0.9725, blue: 0.9255, opacity: 1.000)
    static let danger = Color(.sRGB, red: 0.7529, green: 0.3255, blue: 0.2275, opacity: 1.000)
    static let badge = Color(.sRGB, red: 0.8863, green: 0.3765, blue: 0.2471, opacity: 1.000)
    static let ok = Color(.sRGB, red: 0.1843, green: 0.5412, blue: 0.4000, opacity: 1.000)
    static let okSoft = Color(.sRGB, red: 0.8941, green: 0.9608, blue: 0.9255, opacity: 1.000)
    static let okDot = Color(.sRGB, red: 0.3686, green: 0.7686, blue: 0.6039, opacity: 1.000)
    static let warn = Color(.sRGB, red: 0.5412, green: 0.4784, blue: 0.3686, opacity: 1.000)
    static let warnSoft = Color(.sRGB, red: 0.9608, green: 0.9333, blue: 0.8627, opacity: 1.000)
    static let pink = Color(.sRGB, red: 1.0000, green: 0.6078, blue: 0.6902, opacity: 1.000)
    static let paperTape = Color(.sRGB, red: 0.6078, green: 0.5412, blue: 0.9412, opacity: 0.360)
}

enum PaperRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 11
    static let lg: CGFloat = 13
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 18
    static let pill: CGFloat = 999
}

enum PaperSpace {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 10
    static let x4: CGFloat = 12
    static let x5: CGFloat = 14
    static let x6: CGFloat = 16
    static let x7: CGFloat = 22
    static let x8: CGFloat = 28
}

enum PaperStroke {
    static let hair: CGFloat = 0.5
    static let thin: CGFloat = 1.5
    static let thick: CGFloat = 2
}

enum PaperFont {
    static let displaySize: CGFloat = 30
    static let displayWeight: Font.Weight = .init(weightValue: 600)
    static let h1Size: CGFloat = 26
    static let h1Weight: Font.Weight = .init(weightValue: 600)
    static let h2Size: CGFloat = 17
    static let h2Weight: Font.Weight = .init(weightValue: 600)
    static let titleSize: CGFloat = 15
    static let titleWeight: Font.Weight = .init(weightValue: 600)
    static let bodySize: CGFloat = 12.5
    static let bodyWeight: Font.Weight = .init(weightValue: 400)
    static let labelSize: CGFloat = 12.5
    static let labelWeight: Font.Weight = .init(weightValue: 600)
    static let captionSize: CGFloat = 10.5
    static let captionWeight: Font.Weight = .init(weightValue: 400)
    static let microSize: CGFloat = 10
    static let microWeight: Font.Weight = .init(weightValue: 500)
    static let numberSize: CGFloat = 22
    static let numberWeight: Font.Weight = .init(weightValue: 600)
    static func size(_ key: String) -> CGFloat {
        switch key {
        case "display": return 30
        case "h1": return 26
        case "h2": return 17
        case "title": return 15
        case "body": return 12.5
        case "label": return 12.5
        case "caption": return 10.5
        case "micro": return 10
        case "number": return 22
        default: return 13
        }
    }
}

extension Font.Weight {
    /// 400/500/600 -> SwiftUI 字重
    init(weightValue: Int) {
        switch weightValue {
        case 300: self = .light
        case 500: self = .medium
        case 600: self = .semibold
        case 700: self = .bold
        default: self = .regular
        }
    }
}

enum PaperMotion {
    static let springDamping: CGFloat = 0.8
    static let springResponse: CGFloat = 0.34
    static let tabDamping: CGFloat = 0.8
    static let tabResponse: CGFloat = 0.36
    static let modalDamping: CGFloat = 0.86
    static let modalResponse: CGFloat = 0.28
    static var spring: Animation { .spring(response: springResponse, dampingFraction: springDamping) }
    static var tabSpring: Animation { .spring(response: tabResponse, dampingFraction: tabDamping) }
    static var modalSpring: Animation { .spring(response: modalResponse, dampingFraction: modalDamping) }
}
