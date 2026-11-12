import AppKit

/// ~/.config/terminail/config.conf を読む設定クラス（「key = value」形式）。
/// デフォルト値を先に読み、その上にユーザー設定を重ねる。
final class Config {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/terminail")
    static let path = (dir as NSString).appendingPathComponent("config.conf")

    private var base: [String: Any] = [:]
    private var user: [String: Any] = [:]

    static func load() -> Config {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            try? defaultText.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let c = Config()
        c.base = parse(hiddenDefaults).merging(parse(defaultText)) { _, new in new }
        if let s = try? String(contentsOfFile: path, encoding: .utf8) { c.user = parse(s) }
        return c
    }

    // MARK: - 値の取り出し

    private func get<T>(_ k: String, _ conv: (Any) -> T?) -> T? {
        if let v = user[k], let t = conv(v) { return t }
        if let v = base[k] { return conv(v) }
        return nil
    }
    func string(_ k: String) -> String { get(k) { $0 as? String } ?? "" }
    /// 数値。nan / inf など使えない値が書かれていたら、書かれていないものとして既定値を使う
    func double(_ k: String) -> Double {
        get(k) { v in
            let d = (v as? Double) ?? (v as? String).flatMap { Double($0) }
            return d.flatMap { $0.isFinite ? $0 : nil }
        } ?? 0
    }
    /// 整数。範囲の外なら端に寄せる（巨大な数や nan で落ちないように、Int にする前に範囲を決める）
    func int(_ k: String, _ lo: Int, _ hi: Int) -> Int {
        let d = double(k)
        return Int(max(Double(lo), min(Double(hi), d.rounded())))
    }
    func bool(_ k: String) -> Bool { get(k) { $0 as? Bool } ?? false }
    /// 数値。true / false が書かれていたら ifTrue / 0 として扱う（古い設定との互換用）
    func number(_ k: String, ifTrue: Double) -> Double {
        get(k) { v in ((v as? Double).flatMap { $0.isFinite ? $0 : nil }) ?? (v as? Bool).map { $0 ? ifTrue : 0 } } ?? 0
    }
    func strings(_ k: String) -> [String] {
        get(k) { ($0 as? [Any])?.compactMap { $0 as? String } } ?? []
    }
    /// その色が設定に書かれているときだけ返す
    func colorIfSet(_ k: String) -> NSColor? {
        get(k) { ($0 as? String).flatMap { NSColor(hex: $0) } }
    }

    // MARK: - conf パーサ
    //
    // ・1行に「key = value」。# で始まる行はコメント（値の中の # は色として扱う）
    // ・値の "" は付けても付けなくてもいい
    // ・font-family を2回書くと、2つ目以降は日本語などの代わりのフォント
    // ・palette = 1=#F7768E のように、番号で16色のどれかを変えられる

    /// 設定ファイルのキー → 中で使う名前
    private static let keys: [String: String] = [
        "window-columns": "window.columns", "window-rows": "window.rows",
        "window-width": "window.width", "window-height": "window.height",
        "background-opacity": "window.opacity", "background-opacity-cells": "window.opacity_cells",
        "background-blur": "window.blur", "background-blur-mode": "window.blur_mode",
        "corner-radius": "window.corner_radius", "always-on-top": "window.always_on_top",
        "window-theme": "window.appearance",
        "window-padding": "window.padding", "window-padding-balance": "window.padding_balance",
        "window-padding-x": "window.padding_x", "window-padding-y": "window.padding_y",
        "window-padding-top": "window.padding_top", "window-padding-bottom": "window.padding_bottom",
        "window-padding-left": "window.padding_left", "window-padding-right": "window.padding_right",
        "font-family": "font.family", "font-fallback": "font.fallback", "font-size": "font.size",
        "line-height": "font.line_height", "font-thicken": "font.thicken",
        "theme": "colors.theme", "background": "colors.background", "foreground": "colors.foreground",
        "cursor-color": "colors.cursor", "selection-background": "colors.selection",
        "bold-is-bright": "colors.bold_is_bright",
        "hotkey": "hotkey.key",
        "summon-animation": "summon.animation", "summon-random": "summon.random_pool", "summon-speed": "summon.speed",
        "bell-shake": "fx.bell_shake", "bell-sound": "fx.bell_sound",
        "cursor-sparkles": "fx.cursor_trail", "cursor-sparkle-count": "fx.trail_sparkles",
        "enter-sparkles": "fx.enter_burst", "enter-sparkle-count": "fx.enter_sparkles",
        "cursor-glide": "fx.cursor_glide", "delete-sparkles": "fx.delete_sparkles",
        "delete-sparkle-count": "fx.delete_sparkle_count",
        "secure-keyboard-entry": "security.secure_input",
        "smooth-scroll": "fx.smooth_scroll", "tab-colors": "tabs.colors", "notify-after": "notify.after",
        "idle-effect": "fx.idle", "idle-after": "fx.idle_after",
        "tab-style": "tabs.style", "tab-icons": "tabs.icons", "tab-bar": "tabs.bar",
        "command": "shell.program", "scrollback-limit": "shell.scrollback", "macos-option-as-alt": "shell.option_as_meta",
    ]

    static func parse(_ text: String) -> [String: Any] {
        var out: [String: Any] = [:]
        var fallbacks: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }

            switch key {
            case "font-family":
                if out["font.family"] == nil { out["font.family"] = val } else { fallbacks.append(val) }
            case "palette":   // palette = 1=#F7768E
                let parts = val.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i) {
                    out["colors." + (i < 8 ? "" : "bright_") + Theme.colorNames[i % 8]] = parts[1]
                }
            case "notify":          // notify = toast, system, dock, tab
                out["notify.style"] = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "notify-ignore":
                out["notify.ignore"] = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "tab-icon-list":   // tab-icon-list = ★, ☆, ♠
                out["tabs.icon_list"] = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case "summon-random":
                out["summon.random_pool"] = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            default:
                if let k = keys[key] {
                    out[k] = value(val)
                } else if let name = colorKey(key) {   // red = #... のような書き方も受け付ける
                    out[name] = val
                }
            }
        }
        if !fallbacks.isEmpty { out["font.fallback"] = fallbacks }
        return out
    }

    /// red / bright-red / bright_red → colors.red / colors.bright_red
    private static func colorKey(_ k: String) -> String? {
        let n = k.replacingOccurrences(of: "-", with: "_")
        let base = n.hasPrefix("bright_") ? String(n.dropFirst(7)) : n
        return Theme.colorNames.contains(base) ? "colors." + n : nil
    }

    private static func value(_ s: String) -> Any {
        if s == "true" { return true }
        if s == "false" { return false }
        if let d = Double(s) { return d }
        return s
    }

    // MARK: - デフォルト設定

    /// 初回に作る config.conf。よく触る項目だけ。
    static let defaultText = """
    # ✦ Terminail config
    # Changes apply as soon as you save. See the README for more options.
    # (Lines starting with # are comments.)

    # Starting size (in cells)
    window-columns = 120
    window-rows = 25

    # Background opacity: 0.0 (clear) to 1.0 (solid)
    background-opacity = 0.80
    # Background blur: 0 (none) to 100
    background-blur = 0
    # Corner roundness
    corner-radius = 8
    # Keep the window above everything else
    always-on-top = false

    # The second font-family is used for characters the first one lacks (like Japanese)
    font-family = Menlo
    font-family = Hiragino Sans W4
    font-size = 13
    line-height = 1.0

    # tokyonight / catppuccin / dracula / nord / gruvbox / onedark
    theme = tokyonight
    # To change just a few colors, list only those (examples)
    # background = #1A1B26
    # foreground = #C0CAF5
    # palette = 1=#F7768E

    # The key that shows / hides the windows (e.g. ctrl+` / cmd+shift+t / f12)
    hotkey = option+space

    # Entrance animation: fade (0.2s) / particle (0.4s) / glitch (0.4s) / random
    summon-animation = glitch
    summon-random = fade, particle, glitch
    # Animation speed (0.5 = twice as fast, 2.0 = slow)
    summon-speed = 1.0

    # Wiggle the screen on a bell
    bell-shake = true
    # Sparkles while typing
    cursor-sparkles = true
    # Sparkles on Enter (how many: enter-sparkle-count)
    enter-sparkles = true
    enter-sparkle-count = 4
    # The cursor glides with a little trail when it moves
    cursor-glide = true
    # Scroll smoothly instead of line by line
    smooth-scroll = true
    # Sparkles get sucked in when you delete (how many: delete-sparkle-count)
    delete-sparkles = true
    delete-sparkle-count = 2

    # Tabs (⌘T to open, exit to close)
    # Look: dots (a row of icons) / pill (round tabs with names)
    tab-style = pill
    # Icons: symbol (✦ ☾ ♪ ♡ ...) / none / custom (list them in tab-icon-list)
    tab-icons = symbol
    # tab-icon-list = ★, ☆, ♠
    # Tab bar: auto (hidden when there's only one tab) / always
    tab-bar = auto
    # Tab colors: cursor (cursor and sparkles too) / icon (icon only) / edge (cursor + glowing window edge) / off
    tab-colors = edge

    # Tell you when a long command finishes (only for tabs and windows you aren't looking at)
    # toast (small, top right) / system (macOS notification) / dock (Dock bounce) / tab (glowing tab icon) / off
    # Combine as many as you like (e.g. notify = toast, tab)
    notify = toast, dock, tab
    # How many seconds counts as "long"
    notify-after = 10

    # The cursor gently breathes when you leave it alone: breathe / off
    idle-effect = breathe
    # Seconds of idle time before it starts
    idle-after = 1

    # Keep other apps from peeking at your keystrokes
    secure-keyboard-entry = true
    """

    /// ファイルには書かないけど、書けば変えられる項目の既定値
    static let hiddenDefaults = """
    window-columns = 120
    window-rows = 25
    window-width = 860
    window-height = 520
    background-opacity = 0.80
    background-opacity-cells = true
    background-blur = 0
    background-blur-mode = layer
    corner-radius = 8
    window-theme = dark
    window-padding = 4
    window-padding-balance = true
    window-padding-x = -1
    window-padding-y = -1
    window-padding-top = -1
    window-padding-bottom = -1
    window-padding-left = -1
    window-padding-right = -1
    always-on-top = false
    font-family = Menlo
    font-family = Hiragino Sans W4
    font-size = 13
    line-height = 1.0
    font-thicken = false
    theme = tokyonight
    bold-is-bright = false
    hotkey = option+space
    summon-animation = glitch
    summon-random = fade, particle, glitch
    summon-speed = 1.0
    bell-shake = true
    bell-sound = false
    cursor-sparkles = true
    cursor-sparkle-count = 2
    enter-sparkles = true
    enter-sparkle-count = 4
    cursor-glide = true
    delete-sparkles = true
    delete-sparkle-count = 2
    tab-style = pill
    tab-icons = symbol
    tab-bar = auto
    tab-colors = edge
    smooth-scroll = true
    notify = toast, dock, tab
    notify-after = 10
    notify-ignore = vim, nvim, vi, nano, emacs, less, more, man, top, htop, btop, ssh, mosh, tmux, screen
    idle-effect = breathe
    idle-after = 1
    secure-keyboard-entry = true
    command =
    scrollback-limit = 5000
    macos-option-as-alt = false
    """
}

extension NSColor {
    /// "#RRGGBB" または "#RRGGBBAA"
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if h.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
