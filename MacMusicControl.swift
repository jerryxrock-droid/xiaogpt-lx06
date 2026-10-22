import AppKit
import ApplicationServices
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let allowed: Set<String> = ["authorize", "open", "play", "pause", "next", "previous", "status"]
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "authorize"
let suppliedID = args.count > 1 ? args[1] : UUID().uuidString
let requestID = UUID(uuidString: suppliedID)?.uuidString ?? UUID().uuidString
let root = Bundle.main.bundleURL.deletingLastPathComponent()
let state = root.appendingPathComponent("state/mac-control", isDirectory: true)

func finish(_ status: String, _ message: String, _ extra: [String: Any] = [:]) -> Never {
    var result: [String: Any] = ["status": status, "message": message, "action": command,
        "request_id": requestID, "time": ISO8601DateFormatter().string(from: Date())]
    for (key, value) in extra { result[key] = value }
    do {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = state.appendingPathComponent(requestID + ".json")
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch { }
    exit(status == "ok" ? 0 : 1)
}
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    return attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
func title(_ element: AXUIElement) -> String { attribute(element, kAXTitleAttribute) as? String ?? "" }

if !allowed.contains(command) { finish("unsupported", "不支持此操作") }
if command == "authorize" {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { finish("ok", "辅助功能权限已就绪") }
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    pump(1)
    finish("permission_required", "请在系统设置的辅助功能中允许XiaoGPT Mac控制")
}
let bundleID = "com.netease.163music"
guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
    finish("not_installed", "未找到网易云音乐")
}
var running: NSRunningApplication? = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
if running == nil {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    var done = false
    NSWorkspace.shared.openApplication(at: url, configuration: config) { target, error in
        running = target; done = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !done && Date() < deadline { pump(0.1) }
}
guard let target = running else { finish("launch_failed", "网易云音乐未能打开") }
if command == "open" {
    target.activate(options: [])
    finish("ok", "已打开Mac上的网易云音乐")
}
guard AXIsProcessTrusted() else {
    finish("permission_required", "已打开网易云音乐，请先为XiaoGPT Mac控制开启辅助功能权限")
}
let ax = AXUIElementCreateApplication(target.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 2)
func menu() -> (AXUIElement, AXUIElement)? {
    guard let raw = attribute(ax, kAXMenuBarAttribute) else { return nil }
    let bar = raw as! AXUIElement
    guard let control = children(bar).first(where: { ["控制", "Controls", "Control"].contains(title($0)) }) else { return nil }
    if let menu = children(control).first { return (control, menu) }
    AXUIElementPerformAction(control, kAXPressAction as CFString)
    pump(0.15)
    guard let menu = children(control).first else { return nil }
    return (control, menu)
}
func stateIsPlaying() -> Bool? {
    guard let (_, m) = menu() else { return nil }
    let names = children(m).map { title($0) }
    if names.contains("暂停") || names.contains("Pause") { return true }
    if names.contains("播放") || names.contains("Play") { return false }
    return nil
}
var initial: Bool?
for _ in 0..<25 {
    initial = stateIsPlaying()
    if initial != nil { break }
    pump(0.2)
}
guard let before = initial else { finish("menu_unavailable", "网易云音乐尚未就绪，请打开主窗口后重试") }
if command == "status" { finish("ok", before ? "正在播放" : "当前未播放", ["playing": before]) }
if command == "play" && before { finish("ok", "Mac上的网易云音乐已在播放", ["playing": true]) }
if command == "pause" && !before { finish("ok", "Mac上的网易云音乐已暂停", ["playing": false]) }
let labels: [String]
switch command {
case "play": labels = ["播放", "Play"]
case "pause": labels = ["暂停", "Pause"]
case "next": labels = ["下一个", "Next", "Next Track"]
case "previous": labels = ["上一个", "Previous", "Previous Track"]
default: finish("unsupported", "不支持此操作")
}
guard let (control, controls) = menu(), let item = children(controls).first(where: { labels.contains(title($0)) }) else {
    finish("menu_unavailable", "未找到网易云播放控制菜单")
}
if let enabled = attribute(item, kAXEnabledAttribute) as? Bool, !enabled {
    finish("no_track", "请先在网易云音乐中选择一首可播放的歌曲")
}
let error = AXUIElementPerformAction(item, kAXPressAction as CFString)
AXUIElementPerformAction(control, kAXCancelAction as CFString)
guard error == .success else { finish("control_failed", "网易云未接受播放控制，请打开主窗口后重试") }
if command == "next" || command == "previous" {
    finish("ok", command == "next" ? "已向Mac网易云发送下一首指令" : "已向Mac网易云发送上一首指令")
}
let wanted = command == "play"
for _ in 0..<30 {
    pump(0.15)
    if stateIsPlaying() == wanted {
        finish("ok", wanted ? "已在Mac上播放网易云音乐" : "已暂停Mac上的网易云音乐", ["playing": wanted])
    }
}
finish("not_confirmed", "已发送指令，但未确认播放状态。请在网易云中选择可播放歌曲后重试")
