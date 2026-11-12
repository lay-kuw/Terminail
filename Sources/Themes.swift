import AppKit

/// 組み込みの配色テーマ。config.toml では `theme = "tokyonight"` のように名前だけ書けばよく、
/// 変えたい色があるときだけ `background = "#..."` や `red = "#..."` を足す。
struct Theme {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let palette: [String]   // black red green yellow blue magenta cyan white、続けて bright_ の8色

    static let all: [String: Theme] = [
        "tokyonight": Theme(
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selection: "#33467C",
            palette: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                      "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
        "catppuccin": Theme(
            background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#585B70",
            palette: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                      "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        "dracula": Theme(
            background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
            palette: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                      "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        "nord": Theme(
            background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
            palette: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                      "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        "gruvbox": Theme(
            background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
            palette: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                      "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
        "onedark": Theme(
            background: "#282C34", foreground: "#ABB2BF", cursor: "#528BFF", selection: "#3E4451",
            palette: ["#282C34", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                      "#5C6370", "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"]),
    ]

    static let colorNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
}

/// テーマと個別指定を合わせた、最終的な色
struct Colors {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let palette: [NSColor]   // 16色

    init(_ c: Config) {
        let name = c.string("colors.theme").lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let t = Theme.all[name] ?? Theme.all["tokyonight"]!
        func pick(_ keys: [String], _ fallback: String) -> NSColor {
            for k in keys { if let col = c.colorIfSet(k) { return col } }
            return NSColor(hex: fallback) ?? .white
        }
        background = pick(["colors.background"], t.background)
        foreground = pick(["colors.foreground"], t.foreground)
        cursor = pick(["colors.cursor"], t.cursor)
        let sel = pick(["colors.selection"], t.selection)
        selection = sel.alphaComponent < 1 ? sel : sel.withAlphaComponent(0.8)
        var p: [NSColor] = []
        for i in 0..<16 {
            let key = "colors." + (i < 8 ? "" : "bright_") + Theme.colorNames[i % 8]
            if let col = c.colorIfSet(key) { p.append(col); continue }
            p.append(NSColor(hex: t.palette[i]) ?? .gray)
        }
        palette = p
    }
}
