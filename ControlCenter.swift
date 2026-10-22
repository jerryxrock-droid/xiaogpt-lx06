import AppKit
import ApplicationServices
import Foundation
import CoreAudio
import EventKit
import ScreenCaptureKit
import Vision

func runMusic() {

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
    finish("permission_required", "请在系统设置的辅助功能中允许XiaoGPT 控制中心")
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
    finish("permission_required", "已打开网易云音乐，请先为XiaoGPT 控制中心开启辅助功能权限")
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

}

func runExtension() {

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let base = Bundle.main.bundleURL.deletingLastPathComponent()
let directory = base.appendingPathComponent("state/extensions", isDirectory: true)
let argument = CommandLine.arguments.dropFirst().first ?? ""
guard let uuid = UUID(uuidString: argument) else { exit(2) }
let requestID = uuid.uuidString
let requestFile = directory.appendingPathComponent("requests/" + requestID + ".json")
guard let bytes = try? Data(contentsOf: requestFile), let request = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any], let action = request["action"] as? String else { exit(2) }
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func finish(_ status: String, _ message: String, _ extra: [String: Any] = [:]) -> Never {
    var result: [String: Any] = ["status": status, "message": message, "action": action, "request_id": requestID]
    for (k,v) in extra { result[k] = v }
    do {
        let destination = directory.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = destination.appendingPathComponent(requestID + ".json")
        try JSONSerialization.data(withJSONObject: result).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {}
    exit(status == "ok" ? 0 : 1)
}
func requireAX() {
    if !AXIsProcessTrusted() { finish("permission_required", "请在系统设置辅助功能中允许XiaoGPT 控制中心") }
}
func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func descriptionOf(_ e: AXUIElement) -> String { attribute(e, kAXDescriptionAttribute) as? String ?? "" }
func actions(_ e: AXUIElement) -> [(String,String)] {
    var array: CFArray?
    guard AXUIElementCopyActionNames(e, &array) == .success, let names = array as? [String] else { return [] }
    return names.map { name in
        var label: CFString?
        AXUIElementCopyActionDescription(e, name as CFString, &label)
        return (name, label as String? ?? name)
    }
}
func find(_ e: AXUIElement, depth: Int = 0, predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if depth > 14 { return nil }
    if predicate(e) { return e }
    for child in children(e).prefix(150) {
        if let found = find(child, depth: depth + 1, predicate: predicate) { return found }
    }
    return nil
}
func launch(_ id: String, path: String? = nil) -> NSRunningApplication {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { return running }
    let location = path.map { URL(fileURLWithPath: $0) } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    guard let location else { finish("not_installed", "未找到目标应用") }
    var target: NSRunningApplication?
    var complete = false
    NSWorkspace.shared.openApplication(at: location, configuration: NSWorkspace.OpenConfiguration()) { app,error in
        target=app;complete=true
    }
    let deadline = Date().addingTimeInterval(12)
    while !complete && Date() < deadline { pump(0.1) }
    // iPad apps can be launched through a wrapper and reported under another URL.
    if target == nil { target = NSRunningApplication.runningApplications(withBundleIdentifier: id).first }
    guard let target else { finish("launch_failed", "应用尚未成功打开，请稍后重试") }
    return target
}

let calendarStore = EKEventStore()
func requestAccess(_ kind: EKEntityType, prompt: Bool) -> Bool {
    let status = EKEventStore.authorizationStatus(for: kind)
    if status == .fullAccess { return true }
    if !prompt { return false }
    var done = false, success = false
    let callback: (Bool, Error?) -> Void = { ok,error in success=ok;done=true }
    if kind == .event { calendarStore.requestFullAccessToEvents(completion: callback) }
    else { calendarStore.requestFullAccessToReminders(completion: callback) }
    let deadline = Date().addingTimeInterval(110)
    while !done && Date() < deadline { pump(0.1) }
    return success
}
func requireCalendar(_ kind: EKEntityType) {
    if !requestAccess(kind, prompt: false) {
        finish("permission_required", kind == .event ? "请先允许XiaoGPT 控制中心访问日历" : "请先允许XiaoGPT 控制中心访问提醒事项")
    }
}
func invokeScript(_ source: String, handler: String? = nil, parameters: [String] = []) -> NSAppleEventDescriptor {
    guard let script = NSAppleScript(source: source) else { finish("script_error", "系统操作脚本未能加载") }
    var error: NSDictionary?
    let result: NSAppleEventDescriptor
    if let handler {
        let event=NSAppleEventDescriptor(eventClass: AEEventClass(0x61736372), eventID: AEEventID(0x70736272), targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(0x736E616D))
        let list=NSAppleEventDescriptor.list()
        for (index,value) in parameters.enumerated() { list.insert(NSAppleEventDescriptor(string:value), at:index+1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        result=script.executeAppleEvent(event, error: &error)
    } else { result=script.executeAndReturnError(&error) }
    if let error {
        let number=error[NSAppleScript.errorNumber] as? Int ?? 0
        finish(number == -1743 ? "permission_required" : "operation_failed", number == -1743 ? "请允许XiaoGPT 控制中心自动化控制目标应用" : "目标应用暂未完成操作，请检查是否已打开文稿", ["error_code":number])
    }
    return result
}

switch action {
case "authorize":
    let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
    let ax=AXIsProcessTrustedWithOptions(options)
    let events=requestAccess(.event, prompt:true)
    let reminders=requestAccess(.reminder, prompt:true)
    if !ax { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    finish("ok", "权限请求已完成", ["accessibility":AXIsProcessTrusted(),"calendar":events,"reminders":reminders])
case "permissions":
    finish("ok", "权限状态", ["accessibility":AXIsProcessTrusted(),"calendar":requestAccess(.event,prompt:false),"reminders":requestAccess(.reminder,prompt:false)])
case "volume_get", "volume_set", "volume_mute":
    var device=AudioDeviceID(0), size=UInt32(MemoryLayout<AudioDeviceID>.size)
    var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr,device != 0 else { finish("audio_unavailable","未找到Mac音频输出设备") }
    func volumeAddresses() -> [AudioObjectPropertyAddress] {
        var list:[AudioObjectPropertyAddress]=[]
        for element:AudioObjectPropertyElement in [kAudioObjectPropertyElementMain,1,2] {
            var p=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:element)
            if AudioObjectHasProperty(device,&p) { list.append(p);if element == kAudioObjectPropertyElementMain { break } }
        }
        return list
    }
    let addresses=volumeAddresses()
    guard !addresses.isEmpty else { finish("volume_unsupported","当前音频输出设备不支持Mac软件调音量，请使用设备自身音量控制") }
    func getVolume() -> Int {
        var total:Float32=0;var count:Float32=0
        for var p in addresses {
            var value:Float32=0;var bytes=UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device,&p,0,nil,&bytes,&value)==noErr {total += value;count += 1}
        }
        return count > 0 ? Int((100*total/count).rounded()) : -1
    }
    var muteAddress=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
    let hasMute=AudioObjectHasProperty(device,&muteAddress)
    var muted:UInt32=0;var muteSize=UInt32(MemoryLayout<UInt32>.size)
    if hasMute {AudioObjectGetPropertyData(device,&muteAddress,0,nil,&muteSize,&muted)}
    if action == "volume_get" {finish("ok","Mac当前音量百分之\(getVolume())",["volume":getVolume(),"muted":muted != 0])}
    if action == "volume_mute" && hasMute {
        var value:UInt32=(request["muted"] as? Bool ?? true) ? 1 : 0
        guard AudioObjectSetPropertyData(device,&muteAddress,0,nil,UInt32(MemoryLayout<UInt32>.size),&value)==noErr else {finish("audio_failed","未能调整Mac静音状态")}
        finish("ok",value == 1 ? "Mac已静音" : "Mac已取消静音",["muted":value == 1])
    }
    let percent=action == "volume_mute" ? ((request["muted"] as? Bool ?? true) ? 0 : (request["restore_volume"] as? Int ?? 20)) : (request["volume"] as? Int ?? -1)
    guard (0...100).contains(percent) else {finish("invalid","音量必须在零到一百之间")}
    var value=Float32(percent)/100
    for var p in addresses {
        var writable:DarwinBoolean=false
        if AudioObjectIsPropertySettable(device,&p,&writable)==noErr && writable.boolValue {
            guard AudioObjectSetPropertyData(device,&p,0,nil,UInt32(MemoryLayout<Float32>.size),&value)==noErr else {finish("audio_failed","音量调整未成功")}
        } else {finish("volume_unsupported","当前音频设备不允许软件调整音量")}
    }
    if action == "volume_set" && percent > 0 && hasMute {var unmute:UInt32=0;AudioObjectSetPropertyData(device,&muteAddress,0,nil,UInt32(MemoryLayout<UInt32>.size),&unmute)}
    finish("ok","Mac音量已调到百分之\(getVolume())",["volume":getVolume()])
case "podcast_open", "podcast_play", "podcast_pause", "podcast_status", "podcast_inspect":
    let target=launch("app.podcast.cosmos",path:"/Applications/小宇宙.app")
    if action == "podcast_open" {target.activate(options:[]);finish("ok","已在Mac上打开小宇宙")}
    requireAX()
    let ax=AXUIElementCreateApplication(target.processIdentifier)
    AXUIElementSetMessagingTimeout(ax,1)
    var bar:AXUIElement?
    for _ in 0..<30 {
        bar=find(ax,predicate: {descriptionOf($0).hasPrefix("播放栏")})
        if bar != nil {break};pump(0.2)
    }
    guard let bar else {finish("no_episode","已打开小宇宙，请先选择一集播客，再说继续播放")}
    let available=actions(bar)
    if action == "podcast_inspect" {finish("ok","播放器操作",["actions":available.map{["name":$0.0,"label":$0.1]}])}
    let play=available.first{["播放","play"].contains($0.1.lowercased()) || ["播放","play"].contains($0.0.lowercased())}
    let pause=available.first{["暂停","pause"].contains($0.1.lowercased()) || ["暂停","pause"].contains($0.0.lowercased())}
    if action == "podcast_status" {finish("ok",pause != nil ? "小宇宙正在播放" : "小宇宙当前已暂停",["playing":pause != nil,"state_known":play != nil || pause != nil])}
    let wantsPlay=action == "podcast_play"
    if (wantsPlay && pause != nil) || (!wantsPlay && play != nil) {finish("ok",wantsPlay ? "小宇宙已在播放" : "小宇宙已暂停",["playing":wantsPlay])}
    guard let selected=wantsPlay ? play : pause else {finish("controls_unavailable","小宇宙播放状态暂不可识别，请在主窗口打开播放器后重试")}
    guard AXUIElementPerformAction(bar,selected.0 as CFString) == .success else {finish("control_failed","小宇宙未接受播放控制")}
    for _ in 0..<25 {
        pump(0.15)
        if let updated=find(ax,predicate:{descriptionOf($0).hasPrefix("播放栏")}) {
            let labels=actions(updated).flatMap{[$0.0.lowercased(),$0.1.lowercased()]}
            if wantsPlay ? labels.contains("暂停") || labels.contains("pause") : labels.contains("播放") || labels.contains("play") {
                finish("ok",wantsPlay ? "已在Mac上继续播放小宇宙" : "已暂停Mac上的小宇宙",["playing":wantsPlay])
            }
        }
    }
    finish("not_confirmed","已发送小宇宙控制指令，但未确认播放状态")
case "calendar_today", "calendar_tomorrow":
    requireCalendar(.event)
    var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:"Asia/Shanghai")!
    let start=cal.startOfDay(for:Date()).addingTimeInterval(action == "calendar_tomorrow" ? 86400:0)
    let end=cal.date(byAdding:.day,value:1,to:start)!
    let events=calendarStore.events(matching:calendarStore.predicateForEvents(withStart:start,end:end,calendars:nil)).sorted{$0.startDate < $1.startDate}
    let formatter=DateFormatter();formatter.timeZone=cal.timeZone;formatter.dateFormat="HH:mm"
    let items=events.prefix(8).map{["title":$0.title ?? "未命名日程","time":$0.isAllDay ? "全天":formatter.string(from:$0.startDate)]}
    finish("ok",items.isEmpty ? "这一天的Mac日历没有日程" : "已读取日历",["events":items,"count":events.count])
case "calendar_create", "reminder_create":
    let isEvent=action == "calendar_create"
    requireCalendar(isEvent ? .event:.reminder)
    guard let title=request["title"] as? String,!title.isEmpty,title.count<=300,let timestamp=request["timestamp"] as? Double,timestamp>Date().timeIntervalSince1970 else {finish("invalid","请提供未来的明确时间和事项内容")}
    let date=Date(timeIntervalSince1970:timestamp)
    do {
        if isEvent {
            guard let destination=calendarStore.defaultCalendarForNewEvents else {finish("no_calendar","Mac尚无可写日历，请在日历应用中配置账户")}
            let event=EKEvent(eventStore:calendarStore);event.title=title;event.startDate=date
            event.endDate=date.addingTimeInterval(3600);event.calendar=destination
            try calendarStore.save(event,span:.thisEvent)
            finish("ok","日程已保存到Mac日历",["item_id":event.eventIdentifier ?? ""])
        } else {
            guard let destination=calendarStore.defaultCalendarForNewReminders() else {finish("no_calendar","Mac尚无可写提醒列表，请先打开提醒事项配置账户")}
            let reminder=EKReminder(eventStore:calendarStore);reminder.title=title;reminder.calendar=destination
            var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:"Asia/Shanghai")!
            reminder.dueDateComponents=cal.dateComponents([.year,.month,.day,.hour,.minute],from:date)
            reminder.addAlarm(EKAlarm(absoluteDate:date))
            try calendarStore.save(reminder,commit:true)
            finish("ok","提醒已保存到Mac提醒事项",["item_id":reminder.calendarItemIdentifier])
        }
    } catch {finish("save_failed","系统未能保存事项，请检查日历或提醒账户")}
case "calendar_status":
    requireCalendar(.event);requireCalendar(.reminder)
    finish("ok","日历与提醒接口已就绪",["event_calendar":calendarStore.defaultCalendarForNewEvents != nil,"reminder_list":calendarStore.defaultCalendarForNewReminders() != nil])
case "notes_add":
    guard let text=request["text"] as? String,!text.isEmpty,text.count<=3000 else {finish("invalid","笔记内容为空或过长")}
    let html=text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\n",with:"<br>")
    _=invokeScript("""
    on addvoicenote(noteBody)
        tell application id "com.apple.Notes"
            if not (exists folder "小爱语音笔记") then make new folder with properties {name:"小爱语音笔记"}
            make new note at folder "小爱语音笔记" with properties {name:"语音灵感", body:noteBody}
        end tell
        return "ok"
    end addvoicenote
    """,handler:"addvoicenote",parameters:[html])
    finish("ok","已保存到Mac备忘录的小爱语音笔记文件夹")
case "notes_authorize":
    _=invokeScript("tell application id \"com.apple.Notes\" to get version")
    finish("ok","备忘录接口已就绪")
case "keynote_open", "keynote_start", "keynote_next", "keynote_previous", "keynote_stop", "keynote_status":
    let target=launch("com.apple.iWork.Keynote")
    if action == "keynote_open" {target.activate(options:[]);finish("ok","已打开Keynote")}
    let preamble="tell application id \"com.apple.iWork.Keynote\"\n"
    var script=""
    switch action {
    case "keynote_status":script="return (playing as text) & \",\" & (count of documents as text)"
    case "keynote_start":script="if (count of documents) is 0 then return \"no_document\"\nif playing then return \"ok\"\nstart front document\nreturn \"ok\""
    case "keynote_stop":script="if playing then stop\nreturn \"ok\""
    case "keynote_next":script="if not playing then return \"not_playing\"\nshow next\nreturn \"ok\""
    default:script="if not playing then return \"not_playing\"\nshow previous\nreturn \"ok\""
    }
    let result=invokeScript(preamble+script+"\nend tell").stringValue ?? ""
    if result == "no_document" {finish("no_document","请先在Keynote中打开要演示的文稿")}
    if result == "not_playing" {finish("not_playing","Keynote尚未开始演示，请先说开始演示")}
    finish("ok",action == "keynote_start" ? "Keynote演示已开始":action == "keynote_stop" ? "Keynote演示已结束":action == "keynote_next" ? "已切换到演示下一步":action == "keynote_previous" ? "已切换到演示上一步":"Keynote接口已就绪",["state":result])
default:finish("unsupported","不支持此操作")
}

}

func runKeynote() {
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let base=Bundle.main.bundleURL.deletingLastPathComponent()
let state=base.appendingPathComponent("state/extensions",isDirectory:true)
guard let raw=CommandLine.arguments.dropFirst().first,let id=UUID(uuidString:raw) else{exit(2)}
let requestID=id.uuidString
let file=state.appendingPathComponent("requests/"+requestID+".json")
guard let data=try? Data(contentsOf:file),let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let action=request["action"] as? String,["keynote_next","keynote_previous","keynote_position"].contains(action) else{exit(2)}
func finish(_ status:String,_ message:String,_ extra:[String:Any]=[:])->Never{
 var output:[String:Any]=["status":status,"message":message,"action":action,"request_id":requestID]
 for(k,v) in extra{output[k]=v}
 let folder=state.appendingPathComponent("results",isDirectory:true)
 try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
 let out=folder.appendingPathComponent(requestID+".json")
 if let bytes=try? JSONSerialization.data(withJSONObject:output){try? bytes.write(to:out,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:out.path)}
 exit(status=="ok" ? 0:1)
}
let step=action=="keynote_next" ? 1:-1
let command=action=="keynote_position" ? "return (slide number of current slide of front document) as text" : """
if not playing then return "not_playing"
set documentToControl to front document
set currentNumber to slide number of current slide of documentToControl
set newNumber to currentNumber + \(step)
if newNumber < 1 then return "first_slide"
if newNumber > (count slides of documentToControl) then return "last_slide"
set slideToShow to slide newNumber of documentToControl
stop documentToControl
set current slide of documentToControl to slideToShow
start documentToControl from slideToShow
return newNumber as text
"""
let source="""
tell application id "com.apple.iWork.Keynote"
    if (count of documents) is 0 then return "no_document"
    \(command)
end tell
"""
guard let script=NSAppleScript(source:source) else{finish("script_error","Keynote翻页脚本未能加载")}
var error:NSDictionary?
let answer=script.executeAndReturnError(&error).stringValue ?? ""
if let error{
 let code=error[NSAppleScript.errorNumber] as? Int ?? 0
 finish(code == -1743 ? "permission_required":"operation_failed",code == -1743 ? "请允许XiaoGPT 控制中心控制Keynote":"Keynote翻页暂未成功",["error_code":code])
}
switch answer{
case "no_document":finish("no_document","请先在Keynote中打开文稿")
case "not_playing":finish("not_playing","请先开始Keynote演示")
case "first_slide":finish("ok","已经是第一页")
case "last_slide":finish("ok","已经是最后一页")
default:
 guard let number=Int(answer) else{finish("not_confirmed","未能确认Keynote页码")}
 finish("ok",action=="keynote_position" ? "当前第\(number)页":"已跳到第\(number)页",["slide":number])
}

}

func runReminder() {
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let base=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state/extensions")
guard let arg=CommandLine.arguments.dropFirst().first,let uid=UUID(uuidString:arg) else{exit(2)}
let id=uid.uuidString
let file=base.appendingPathComponent("requests/"+id+".json")
guard let d=try? Data(contentsOf:file),let req=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any],let action=req["action"] as? String else{exit(2)}
func pump(){RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
func finish(_ status:String,_ message:String,_ more:[String:Any]=[:])->Never {
 var result:[String:Any]=["status":status,"message":message,"request_id":id,"action":action];for(k,v) in more{result[k]=v}
 let out=base.appendingPathComponent("results/"+id+".json");try? FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let data=try? JSONSerialization.data(withJSONObject:result){try? data.write(to:out,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:out.path)};exit(status == "ok" ? 0:1)
}
guard ["reminders_authorize","reminders_today"].contains(action) else{finish("unsupported","不支持此操作")}
let store=EKEventStore()
if action == "reminders_authorize" && EKEventStore.authorizationStatus(for:.reminder) != .fullAccess {
 var done=false;store.requestFullAccessToReminders{_,_ in done=true}
 let until=Date().addingTimeInterval(110);while !done && Date()<until{pump()}
}
guard EKEventStore.authorizationStatus(for:.reminder) == .fullAccess else{finish("permission_required","晨报提醒尚未获得提醒事项读取权限")}
if action == "reminders_authorize"{finish("ok","晨报提醒权限已就绪")}
var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!
let end=calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:Date()))!
var items:[EKReminder]?;store.fetchReminders(matching:store.predicateForIncompleteReminders(withDueDateStarting:nil,ending:end,calendars:nil)){items=$0 ?? []}
let until=Date().addingTimeInterval(12);while items == nil && Date()<until{pump()}
guard let items else{finish("timeout","提醒事项读取超时")}
let sorted=items.sorted{($0.dueDateComponents?.date ?? .distantFuture)<($1.dueDateComponents?.date ?? .distantFuture)}
let titles=sorted.prefix(8).map{$0.title ?? "未命名提醒"}
finish("ok",titles.isEmpty ? "今天没有到期或逾期的未完成提醒":"今天到期或已逾期的未完成提醒有\(items.count)项。"+titles.joined(separator:"；"),["count":items.count])

}

func runFive() {
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let directory=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state/extensions")
guard let arg=CommandLine.arguments.dropFirst().first,let uid=UUID(uuidString:arg) else{exit(2)}
let rid=uid.uuidString
guard let bytes=try? Data(contentsOf:directory.appendingPathComponent("requests/"+rid+".json")),let input=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],let action=input["action"] as? String else{exit(2)}
func pump(_ n:Double=0.2){RunLoop.current.run(until:Date().addingTimeInterval(n))}
func finish(_ status:String,_ message:String,_ more:[String:Any]=[:])->Never{
 var result:[String:Any]=["request_id":rid,"action":action,"status":status,"message":message];for(k,v) in more{result[k]=v}
 let out=directory.appendingPathComponent("results/"+rid+".json");try? FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let d=try? JSONSerialization.data(withJSONObject:result){try? d.write(to:out,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:out.path)}
 exit(status == "ok" ? 0:1)
}
let allowed:Set<String>=["five_permissions","five_authorize","five_music_inspect","five_like","five_playlist","five_podcast_rate","five_podcast_jump","five_podcast_snapshot","five_browser"]
guard allowed.contains(action) else{finish("unsupported","不支持此操作")}
if action == "five_permissions"{finish("ok","权限状态",["accessibility":AXIsProcessTrusted(),"screen_capture":CGPreflightScreenCaptureAccess()])}
if action == "five_authorize"{
 let opts=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
 let ax=AXIsProcessTrustedWithOptions(opts)
 let screen=CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
 if !ax{NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}
 finish("ok","请在系统设置中完成收藏与播客的辅助功能和屏幕录制授权",["accessibility":ax,"screen_capture":screen])
}
func attr(_ e:AXUIElement,_ name:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,name as CFString,&v) == .success ? v:nil}
func kids(_ e:AXUIElement)->[AXUIElement]{attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []}
func title(_ e:AXUIElement)->String{attr(e,kAXTitleAttribute) as? String ?? ""}
func desc(_ e:AXUIElement)->String{attr(e,kAXDescriptionAttribute) as? String ?? ""}
func label(_ e:AXUIElement)->String{let d=desc(e);return d.isEmpty ? title(e):d}
func value(_ e:AXUIElement)->String{if let v=attr(e,kAXValueAttribute){return String(describing:v)};return ""}
func nodes(_ root:AXUIElement)->[AXUIElement]{
 var queue:[(AXUIElement,Int)]=[(root,0)];var result:[AXUIElement]=[];var i=0
 while i<queue.count && i<1600{let(e,depth)=queue[i];i+=1;result.append(e);if depth<17{queue += kids(e).prefix(160).map{($0,depth+1)}}};return result
}
func find(_ root:AXUIElement,_ predicate:(AXUIElement)->Bool)->AXUIElement?{
 var queue:[(AXUIElement,Int)]=[(root,0)];var i=0
 while i<queue.count && i<1600{let(e,depth)=queue[i];i+=1;if predicate(e){return e};if depth<17{queue += kids(e).prefix(160).map{($0,depth+1)}}};return nil
}
func requireAX(){if !AXIsProcessTrusted(){finish("permission_required","请为XiaoGPT 控制中心开启辅助功能")}}
func running(_ id:String)->NSRunningApplication{
 if let target=NSRunningApplication.runningApplications(withBundleIdentifier:id).first{return target}
 finish("not_running","请先打开目标应用并选好歌曲或播客")
}
func axApp(_ target:NSRunningApplication)->AXUIElement{let e=AXUIElementCreateApplication(target.processIdentifier);AXUIElementSetMessagingTimeout(e,0.4);return e}
func activate(_ target:NSRunningApplication){target.activate(options:[]);pump(0.4)}
func checkRequest(){
 if FileManager.default.fileExists(atPath:directory.appendingPathComponent("cancelled/"+rid+".json").path){finish("cancelled","当前操作已取消")}
 if let created=input["created"] as? Double,Date().timeIntervalSince1970-created>120{finish("expired","当前操作已超时取消")}
}
func press(_ e:AXUIElement){checkRequest();guard AXUIElementPerformAction(e,kAXPressAction as CFString) == .success else{finish("control_failed","应用未接受操作")};pump(0.2)}
func ensureFront(_ pid:pid_t){checkRequest();guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else{finish("focus_changed","前台应用已变化，为避免误操作已停止。请重试")}}
func click(_ p:CGPoint,_ pid:pid_t){ensureFront(pid);CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap);CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap);pump(0.35)}
func escape(_ pid:pid_t){ensureFront(pid);CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true)?.post(tap:.cghidEventTap);CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false)?.post(tap:.cghidEventTap);pump()}
struct Word{let text:String;let point:CGPoint;let rect:CGRect}
func ocr(_ target:NSRunningApplication)->(CGRect,[Word]){
 guard CGPreflightScreenCaptureAccess() else{finish("screen_permission_required","加入指定歌单和倍速定位需要为XiaoGPT 控制中心开启屏幕录制；只在本机识别目标应用窗口，不保存或上传截图")}
 var content:SCShareableContent?;var done=false
 SCShareableContent.getExcludingDesktopWindows(true,onScreenWindowsOnly:true){c,_ in content=c;done=true}
 let until=Date().addingTimeInterval(8);while !done && Date()<until{pump(0.05)}
 guard let w=content?.windows.filter({$0.owningApplication?.processID == target.processIdentifier && $0.windowLayer == 0 && $0.frame.width>400 && $0.frame.height>300}).max(by:{$0.frame.width*$0.frame.height < $1.frame.width*$1.frame.height}) else{finish("no_window","请打开目标应用的主窗口")}
 let config=SCStreamConfiguration();config.width=Int(w.frame.width*2);config.height=Int(w.frame.height*2);config.showsCursor=false
 var image:CGImage?;done=false
 SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:w),configuration:config){img,_ in image=img;done=true}
 let deadline=Date().addingTimeInterval(8);while !done && Date()<deadline{pump(0.05)}
 guard let image else{finish("capture_failed","目标窗口暂时无法识别，请检查屏幕录制权限")}
 let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["zh-Hans","en-US"];request.usesLanguageCorrection=false
 do{try VNImageRequestHandler(cgImage:image).perform([request])}catch{finish("ocr_failed","目标窗口文字识别失败")}
 let words=(request.results ?? []).compactMap{ob->Word? in
  guard let text=ob.topCandidates(1).first?.string else{return nil};let b=ob.boundingBox
  let rect=CGRect(x:w.frame.minX+b.minX*w.frame.width,y:w.frame.minY+(1-b.maxY)*w.frame.height,width:b.width*w.frame.width,height:b.height*w.frame.height)
  return Word(text:text,point:CGPoint(x:rect.midX,y:rect.midY),rect:rect)
 }
 return(w.frame,words)
}
func normalized(_ s:String)->String{s.replacingOccurrences(of:" ",with:"").trimmingCharacters(in:.whitespacesAndNewlines)}
func browser(){
 let ids=["Safari":"com.apple.Safari","Chrome":"com.google.Chrome"]
 var name=input["browser"] as? String ?? ""
 if name.isEmpty{
  let front=NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
  name=ids.first(where:{$0.value == front})?.key ?? ""
  if name.isEmpty{
   let candidates=ids.filter{!NSRunningApplication.runningApplications(withBundleIdentifier:$0.value).isEmpty}
   if candidates.count == 1{name=candidates.first!.key}
  }
 }
 guard ids[name] != nil else{finish("ambiguous_browser","请说明浏览器，例如电脑把Chrome当前网页记到Obsidian")}
 let source=name == "Chrome" ? "tell application \"Google Chrome\"\nif (count of windows) is 0 then return {}\nset t to active tab of front window\nreturn {title of t, URL of t}\nend tell":"tell application \"Safari\"\nif (count of windows) is 0 then return {}\nreturn {name of current tab of front window, URL of current tab of front window}\nend tell"
 var error:NSDictionary?;guard let script=NSAppleScript(source:source) else{finish("failed","浏览器读取脚本未加载")}
 let result=script.executeAndReturnError(&error)
 if let error{let n=error[NSAppleScript.errorNumber] as? Int ?? 0;finish(n == -1743 ? "automation_permission_required":"browser_error",n == -1743 ? "请在系统弹窗允许XiaoGPT 控制中心读取浏览器当前网页":"浏览器当前页面暂时无法读取",["error_code":n])}
 guard result.numberOfItems==2,let pageTitle=result.atIndex(1)?.stringValue,let url=result.atIndex(2)?.stringValue else{finish("no_page","浏览器没有可保存的当前标签页")}
 finish("ok","已读取当前网页标题和地址",["title":pageTitle,"url":url,"browser":name])
}
if action == "five_browser"{browser()}
requireAX()
if action.hasPrefix("five_music") || action == "five_like" || action == "five_playlist"{
 let target=running("com.netease.163music");let ax=axApp(target)
 func control()->AXUIElement{
  guard let raw=attr(ax,kAXMenuBarAttribute) else{finish("no_menu","网易云控制菜单尚未就绪")}
  let bar=raw as! AXUIElement
  guard let item=kids(bar).first(where:{["控制","Control","Controls"].contains(title($0))}) else{finish("no_menu","网易云控制菜单尚未就绪")}
  return item
 }
 func favorite()->(AXUIElement,Bool){
  let c=control();if kids(c).isEmpty{press(c)}
  guard let menu=kids(c).first,let item=kids(menu).first(where:{["喜欢歌曲","取消喜欢歌曲","取消喜欢","Like Song","Unlike Song"].contains(title($0))}) else{finish("no_favorite","未找到网易云原生喜欢歌曲菜单")}
  let mark=attr(item,"AXMenuItemMarkChar") as? String ?? ""
  return(item,!mark.isEmpty || title(item).contains("取消") || title(item)=="Unlike Song")
 }
 if action == "five_like" || action == "five_music_inspect"{
  let(item,liked)=favorite()
  if action == "five_music_inspect"{finish("ok","已读取收藏状态",["liked":liked,"label":title(item)])}
  if liked{finish("ok","这首歌已经在网易云我喜欢中",["liked":true])}
  guard (attr(item,kAXEnabledAttribute) as? Bool) != false else{finish("disabled","请先在网易云中选好可收藏歌曲")}
  press(item)
  for _ in 0..<15{pump();let(_,now)=favorite();if now{finish("ok","已把当前歌曲加入网易云我喜欢",["liked":true])}}
  finish("unconfirmed","已发送喜欢指令，但尚未确认收藏状态；没有重复点击")
 }
 if action == "five_playlist"{
  guard let name=input["playlist"] as? String,!name.isEmpty,name.count<=60,let expected=input["title"] as? String,!expected.isEmpty else{finish("invalid_request","请说明六十字以内的现有歌单名称")}
  activate(target);escape(target.processIdentifier)
  var(frame,words)=ocr(target)
  guard words.contains(where:{normalized($0.text).contains(normalized(expected)) && $0.point.y>frame.minY+frame.height*0.84}) else{finish("song_changed","没有确认到目标歌曲，未修改歌单。请保持网易云主窗口及当前歌曲不变后重试")}
  if !words.contains(where:{normalized($0.text)=="收藏到歌单"}){click(CGPoint(x:frame.maxX-164,y:frame.maxY-40),target.processIdentifier)}
  var seen:Set<String>=[]
  for _ in 0..<16{
   (frame,words)=ocr(target)
   guard words.contains(where:{normalized($0.text)=="收藏到歌单"}) else{finish("no_playlist_dialog","未找到网易云收藏到歌单窗口，未选择任何歌单")}
   let matches=words.filter{[normalized(name),normalized(name+"歌单")].contains(normalized($0.text)) && $0.point.x>frame.minX+frame.width*0.28 && $0.point.x<frame.minX+frame.width*0.72 && $0.point.y<frame.minY+frame.height*0.85 && $0.point.y>frame.minY+frame.height*0.25}
   if matches.count>1{escape(target.processIdentifier);finish("ambiguous_playlist","存在多个匹配歌单，请说明完整名称")}
   if let item=matches.first{
    click(item.point,target.processIdentifier)
    for _ in 0..<8{pump(0.25);let(_,after)=ocr(target);if after.contains(where:{$0.text.contains("收藏成功") || $0.text.contains("已收藏") || $0.text.contains("已存在") || $0.text.contains("重复歌曲")}){finish("ok","网易云已确认将歌曲收藏到"+name+"歌单")}}
    finish("unconfirmed","已选择"+name+"歌单，但没有识别到成功提示，请在网易云确认；不会重复提交")
   }
   let signature=words.filter{$0.point.x>frame.minX+frame.width*0.3 && $0.point.x<frame.minX+frame.width*0.7}.map{$0.text}.joined(separator:"|")
   if seen.contains(signature){break};seen.insert(signature)
   let p=CGPoint(x:frame.midX,y:frame.minY+frame.height*0.65);ensureFront(target.processIdentifier)
   CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:p,mouseButton:.left)?.post(tap:.cghidEventTap)
   CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:-420,wheel2:0,wheel3:0)?.post(tap:.cghidEventTap);pump(0.45)
  }
  escape(target.processIdentifier);finish("playlist_not_found","没有找到名为"+name+"的现有歌单。请先在网易云创建，或说出完整歌单名称")
 }
}
let target=running("app.podcast.cosmos");let ax=axApp(target);activate(target)
func currentPlayer(){
 if find(ax,{["设置","前进30秒","后退15秒"].contains(label($0))}) != nil{return}
 if let bar=find(ax,{desc($0).hasPrefix("播放栏")}){press(bar);pump(0.3)}
}
if action == "five_podcast_snapshot"{
 if let bar=find(ax,{desc($0).hasPrefix("播放栏")}){finish("ok","已读取小宇宙当前单集",["description":desc(bar),"position":value(bar)])}
 if let share=find(ax,{label($0).hasPrefix("分享单集")}){finish("ok","已读取小宇宙当前单集",["title":String(label(share).dropFirst(4))])}
 finish("no_episode","请先在小宇宙中选择一集节目")
}
if action == "five_podcast_rate"{
 guard let rate=input["rate"] as? Double,rate>=0.5,rate<=3,abs(rate*10-(rate*10).rounded())<0.001 else{finish("invalid_rate","小宇宙倍速支持零点五到三点零之间的一位小数")}
 currentPlayer()
 if find(ax,{desc($0).contains("倍速播放")}) == nil{guard let settings=find(ax,{label($0)=="设置"}) else{finish("no_settings","请打开小宇宙当前单集播放器后重试")};press(settings)}
 guard let slider=find(ax,{desc($0).contains("倍速播放")}) else{finish("no_slider","未找到小宇宙倍速滑块")}
 func speed()->Double?{let v=value(slider);let pattern="[0-9]+(?:\\.[0-9]+)?";if let r=v.range(of:pattern,options:.regularExpression){return Double(v[r])};return nil}
 if let old=speed(),abs(old-rate)<0.01{finish("ok","小宇宙已是\(rate)倍速",["rate":rate])}
 _=AXUIElementSetAttributeValue(slider,kAXValueAttribute as CFString,NSNumber(value:rate));pump()
 if let got=speed(),abs(got-rate)<0.01{finish("ok","已将小宇宙调到\(rate)倍速",["rate":rate])}
 let(_,words)=ocr(target)
 let left=words.filter{normalized($0.text)=="0.5"}.max(by:{$0.point.y<$1.point.y})
 let right=words.filter{normalized($0.text)=="3.0"}.max(by:{$0.point.y<$1.point.y})
 guard let left,let right,abs(left.point.y-right.point.y)<25,right.point.x>left.point.x else{finish("no_speed_scale","没有确认倍速刻度，未进行坐标点击")}
 let x=left.point.x+(rate-0.5)/2.5*(right.point.x-left.point.x)
 click(CGPoint(x:x,y:(left.point.y+right.point.y)/2+18),target.processIdentifier)
 for _ in 0..<12{pump();if let got=speed(),abs(got-rate)<0.01{finish("ok","已将小宇宙调到\(rate)倍速",["rate":rate])}}
 finish("unconfirmed","已调整倍速滑块，但没有确认到目标速度。请在小宇宙中检查")
}
if action == "five_podcast_jump"{
 guard let delta=input["delta"] as? Int,delta != 0,abs(delta)<=600,delta>0 ? delta%30==0:delta%15==0 else{finish("invalid_jump","快进支持三十秒的倍数，后退支持十五秒的倍数，每次最多十分钟")}
 currentPlayer()
 let name=delta>0 ? "前进30秒":"后退15秒"
 guard let button=find(ax,{label($0)==name}) else{finish("no_control","未找到小宇宙快进或后退按钮")}
 let count=abs(delta)/(delta>0 ? 30:15)
 for _ in 0..<count{press(button)}
 finish("ok","已向小宇宙发送"+(delta>0 ? "快进":"后退")+"\(abs(delta))秒指令")
}
finish("unsupported","未执行操作")

}

func runMedia() {
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let base=Bundle.main.bundleURL.deletingLastPathComponent()
let dir=base.appendingPathComponent("state/extensions")
guard let arg=CommandLine.arguments.dropFirst().first, let uuid=UUID(uuidString:arg) else {exit(2)}
let id=uuid.uuidString
guard let data=try? Data(contentsOf:dir.appendingPathComponent("requests/"+id+".json")),let req=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let action=req["action"] as? String else {exit(2)}
func pump(_ n:Double){RunLoop.current.run(until:Date().addingTimeInterval(n))}
func finish(_ status:String,_ message:String,_ extra:[String:Any]=[:])->Never {
 var result:[String:Any]=["request_id":id,"action":action,"status":status,"message":message]
 for(k,v) in extra{result[k]=v}
 let out=dir.appendingPathComponent("results/"+id+".json")
 try? FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
 if let d=try? JSONSerialization.data(withJSONObject:result){try? d.write(to:out,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:out.path)}
 exit(status == "ok" ? 0:1)
}
func attr(_ e:AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,n as CFString,&v) == .success ? v:nil}
func children(_ e:AXUIElement)->[AXUIElement]{attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []}
func label(_ e:AXUIElement)->String{(attr(e,kAXDescriptionAttribute) as? String) ?? (attr(e,kAXTitleAttribute) as? String) ?? ""}
func flatten(_ e:AXUIElement,_ depth:Int=0)->[AXUIElement]{if depth>16{return []};return [e]+children(e).prefix(150).flatMap{flatten($0,depth+1)}}
if action == "media_authorize" {
 let opts=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
 let trusted=AXIsProcessTrustedWithOptions(opts)
 if !trusted{NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}
 finish(trusted ? "ok":"permission_required",trusted ? "媒体扩展权限已就绪":"请为XiaoGPT 控制中心开启辅助功能")
}
if !["podcast_select","podcast_detail","podcast_full_play","podcast_full_pause"].contains(action){finish("unsupported","不支持此操作")}
guard AXIsProcessTrusted() else{finish("permission_required","请为XiaoGPT 控制中心开启辅助功能")}
if action == "podcast_select" {
 guard let eid=req["eid"] as? String,eid.range(of:"^[a-f0-9]{24}$",options:.regularExpression) != nil else{finish("invalid_request","单集编号无效")}
 NSWorkspace.shared.open(URL(string:"cosmos://page.cos/player/"+eid)!)
}
var target:NSRunningApplication?
for _ in 0..<60{target=NSRunningApplication.runningApplications(withBundleIdentifier:"app.podcast.cosmos").first;if target != nil{break};pump(0.2)}
guard let target else{finish("not_running","请先打开小宇宙")}
let ax=AXUIElementCreateApplication(target.processIdentifier)
AXUIElementSetMessagingTimeout(ax,1)
let expected=req["title"] as? String ?? ""
for _ in 0..<60 {
 let items=flatten(ax)
 let labels=items.map{label($0)}
 let selected=expected.isEmpty || labels.contains(where:{$0 == expected || $0.hasPrefix("分享单集"+expected)})
 if selected, let button=items.first(where:{["播放","暂停"].contains(label($0))}) {
  let wasPlaying=label(button) == "暂停"
  if action == "podcast_detail"{finish("ok",wasPlaying ? "小宇宙正在播放":"小宇宙当前暂停",["playing":wasPlaying])}
  if action == "podcast_full_pause" {
   if !wasPlaying {finish("ok","小宇宙已暂停",["playing":false])}
   guard AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else{finish("failed","小宇宙未接受暂停操作")}
   for _ in 0..<25{pump(0.2);if flatten(ax).contains(where:{label($0) == "播放"}){finish("ok","已暂停Mac小宇宙",["playing":false])}}
   finish("unconfirmed","已发送暂停指令，但未确认小宇宙停止播放")
  }
  if !wasPlaying {
   guard AXUIElementPerformAction(button,kAXPressAction as CFString) == .success else{finish("failed","小宇宙未接受播放操作")}
   for _ in 0..<25{pump(0.2);if flatten(ax).contains(where:{label($0) == "暂停"}){finish("ok","已在Mac小宇宙播放"+expected,["playing":true])}}
   finish("unconfirmed","已选择单集，但未确认小宇宙开始播放")
  }
  finish("ok","Mac小宇宙已在播放"+expected,["playing":true])
 }
 pump(0.2)
}
finish("unconfirmed","未确认指定单集播放器，请打开小宇宙主窗口后重试")

}

func runPodcast() {
 let base=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("state/extensions")
 guard let raw=CommandLine.arguments.dropFirst().first,let uuid=UUID(uuidString:raw),let data=try? Data(contentsOf:base.appendingPathComponent("requests/\(uuid.uuidString).json")),let req=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let action=req["action"] as? String else{exit(2)}
 let rid=uuid.uuidString
 func finish(_ status:String,_ message:String,_ extra:[String:Any]=[:])->Never{
  var r:[String:Any]=["request_id":rid,"action":action,"status":status,"message":message];for(k,v) in extra{r[k]=v}
  let out=base.appendingPathComponent("results/\(rid).json");try? FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let d=try? JSONSerialization.data(withJSONObject:r){try? d.write(to:out,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:out.path)};exit(status == "ok" ? 0:1)
 }
 func pump(_ t:Double=0.15){RunLoop.current.run(until:Date().addingTimeInterval(t))}
 func check(){if FileManager.default.fileExists(atPath:base.appendingPathComponent("cancelled/\(rid).json").path){finish("cancelled","操作已取消")};if let t=req["created"] as? Double,Date().timeIntervalSince1970-t>120{finish("expired","操作已过期")}}
 func attr(_ e:AXUIElement,_ k:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v:nil}
 func label(_ e:AXUIElement)->String{(attr(e,kAXDescriptionAttribute) as? String) ?? (attr(e,kAXTitleAttribute) as? String) ?? ""}
 func nodes(_ e:AXUIElement)->[AXUIElement]{var q:[(AXUIElement,Int)]=[(e,0)];var out:[AXUIElement]=[];var i=0;while i<q.count && i<1800{let(n,d)=q[i];i+=1;out.append(n);if d<18{q += ((attr(n,kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(150).map{($0,d+1)}}};return out}
 func actions(_ e:AXUIElement)->[(String,String)]{var raw:CFArray?;guard AXUIElementCopyActionNames(e,&raw) == .success,let names=raw as? [String] else{return []};return names.map{n in var d:CFString?;AXUIElementCopyActionDescription(e,n as CFString,&d);return(n,(d as String?) ?? n)}}
 guard AXIsProcessTrusted() else{finish("permission_required","请为XiaoGPT 控制中心开启辅助功能；尚未执行播放操作")}
 let id="app.podcast.cosmos"
 var target=NSRunningApplication.runningApplications(withBundleIdentifier:id).first
 if target == nil{var done=false;NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/Applications/小宇宙.app"),configuration:NSWorkspace.OpenConfiguration()){a,_ in target=a;done=true};let until=Date().addingTimeInterval(10);while !done && Date()<until{pump()}}
 guard let target else{finish("launch_failed","小宇宙未能启动")}
 target.activate(options:[]);pump(0.35)
 if action == "podcast_open"{finish("ok","已打开Mac小宇宙")}
 let ax=AXUIElementCreateApplication(target.processIdentifier);AXUIElementSetMessagingTimeout(ax,0.4)
 // Read only the actual compact playback bar or full-player play/pause button.
 func state()->(AXUIElement,String,Bool,String)?{
  let all=nodes(ax)
  if let bar=all.first(where:{label($0).hasPrefix("播放栏")}){
   let a=actions(bar)
   if let pause=a.first(where:{["暂停","pause"].contains($0.1.lowercased())}){return(bar,pause.0,true,label(bar))}
   if let play=a.first(where:{["播放","play"].contains($0.1.lowercased())}){return(bar,play.0,false,label(bar))}
  }
  if let b=all.first(where:{["播放","暂停"].contains(label($0)) && (attr($0,kAXRoleAttribute) as? String) == kAXButtonRole}){return(b,kAXPressAction as String,label(b)=="暂停",all.map{label($0)}.first(where:{$0.hasPrefix("分享单集")}) ?? "")}
  return nil
 }
 if action == "podcast_status" || action == "podcast_inspect"{
  guard let s=state() else{finish("unknown","无法确认小宇宙当前播放状态",["state_known":false])};finish("ok",s.2 ? "小宇宙正在播放":"小宇宙已暂停",["playing":s.2,"state_known":true,"title":s.3])
 }
 var expected=""
 if action == "podcast_random" || action == "podcast_subscriptions" || action == "podcast_subscription_play"{
  func tap(_ e:AXUIElement){
   check() // iOS-on-Mac controls may report AXPress success without navigating; use the verified AX frame.
   guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier,let pv=attr(e,kAXPositionAttribute),let sv=attr(e,kAXSizeAttribute) else{finish("control_failed","无法定位小宇宙控件")}
   var p=CGPoint.zero;var z=CGSize.zero
   guard AXValueGetValue(pv as! AXValue,.cgPoint,&p),AXValueGetValue(sv as! AXValue,.cgSize,&z),z.width>0,z.height>0 else{finish("control_failed","小宇宙控件不可点击")}
   let point=CGPoint(x:p.x+z.width/2,y:p.y+z.height/2)
   CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap);pump(0.4)
  }
  let subscription=(req["subscription"] as? Bool) == true || action != "podcast_random"
  for _ in 0..<6{
   let all=nodes(ax)
   if all.contains(where:{label($0)=="订阅" && (attr($0,kAXValueAttribute) != nil)}){break}
   guard let back=all.first(where:{["返回","返回上一页"].contains(label($0))}) else{break};tap(back)
  }
  if let tab=nodes(ax).first(where:{label($0)==(subscription ? "订阅":"发现") && attr($0,kAXValueAttribute) != nil}){tap(tab)}
  if action == "podcast_subscriptions" || action == "podcast_subscription_play"{
   guard let mine=nodes(ax).first(where:{label($0)=="我的订阅"}) else{finish("no_subscriptions","无法打开我的订阅，请先登录小宇宙")};tap(mine)
   for _ in 0..<20{if nodes(ax).contains(where:{label($0)=="全部订阅"}){break};pump(0.15)}
   guard nodes(ax).contains(where:{label($0)=="全部订阅"}) else{finish("not_confirmed","未确认我的订阅列表已打开")}
   if action == "podcast_subscriptions"{finish("ok","已打开小宇宙我的订阅")}
   let name=req["name"] as? String ?? ""
   var found:AXUIElement?
   var previous=""
   for _ in 0..<25{
    let all=nodes(ax);found=all.first(where:{label($0)==name});if found != nil{break}
    let signature=all.map{label($0)}.joined(separator:"|");if signature==previous{break};previous=signature
    guard let scroller=all.first(where:{actions($0).contains(where:{$0.1=="Scroll Down"})}),let scroll=actions(scroller).first(where:{$0.1=="Scroll Down"}) else{break};check();_ = AXUIElementPerformAction(scroller,scroll.0 as CFString);pump(0.25)
   }
   guard let found else{finish("not_found","在小宇宙我的订阅中没有找到“"+name+"”，请说完整节目名")};tap(found)
   for _ in 0..<20{if nodes(ax).contains(where:{label($0)=="已订阅"}){break};pump(0.15)}
   guard nodes(ax).contains(where:{label($0)=="已订阅"}) else{finish("not_confirmed","未确认进入已订阅节目，未播放")}
  }

  var all=nodes(ax)
  if !all.contains(where:{label($0).hasPrefix("播放栏")}),let back=all.first(where:{label($0)=="返回上一页"}){check();_ = AXUIElementPerformAction(back,kAXPressAction as CFString);pump(0.3);all=nodes(ax)}
  if !subscription, let discover=all.first(where:{label($0)=="发现" && (attr($0,kAXRoleAttribute) as? String) == kAXRadioButtonRole}){check();_ = AXUIElementPerformAction(discover,kAXPressAction as CFString);pump(0.3);all=nodes(ax)}
  let current=state()?.3 ?? ""
  let choices=all.filter{e in let s=label(e);return s.contains("的单集") && !s.hasPrefix("播放栏") && !current.contains(String(s.split(separator:"，").first ?? "")) && actions(e).contains(where:{$0.1=="播放暂停"})}
  guard let chosen=(action == "podcast_subscription_play" ? choices.first:choices.randomElement()),let play=actions(chosen).first(where:{$0.1=="播放暂停"}) else{finish("no_recommendations","未找到可播放的推荐单集，请在小宇宙打开“发现”页面后重试")}
  let description=label(chosen);let segment=String(description.split(separator:"，").first ?? "")
  expected=segment.components(separatedBy:"的单集").dropFirst().joined(separator:"的单集")
  guard !expected.isEmpty else{finish("unknown_episode","未能确认随机单集名称，未播放")}
  check();guard AXUIElementPerformAction(chosen,play.0 as CFString) == .success else{finish("control_failed","小宇宙未接受随机播放操作")}
 }else{
  guard let s=state() else{finish("no_episode","未找到可控制的播放器，请先在小宇宙选择一集节目")}
  let wanted=action == "podcast_play"
  if s.2 == wanted{finish("ok",wanted ? "小宇宙已在播放":"小宇宙已暂停",["playing":wanted,"verified_by":"accessibility"])}
  check();guard AXUIElementPerformAction(s.0,s.1 as CFString) == .success else{finish("control_failed","小宇宙未接受播放控制")}
 }
 let wanted=action != "podcast_pause"
 for _ in 0..<40{pump();check();if let s=state(),s.2==wanted,(expected.isEmpty || s.3.contains(expected)){finish("ok",["podcast_random","podcast_subscription_play"].contains(action) ? "已在Mac小宇宙播放："+expected : wanted ? "已在Mac小宇宙继续播放":"已暂停Mac小宇宙",["playing":wanted,"title":s.3,"verified_by":"accessibility"])}}
 finish("not_confirmed","已发送小宇宙操作，但未确认实际播放状态，请检查应用")
}


let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let root=Bundle.main.bundleURL.deletingLastPathComponent()
func centralResult(_ rid:String,_ action:String,_ more:[String:Any]) {
 var r:[String:Any]=["request_id":rid,"action":action,"status":"ok","message":"控制中心权限状态"];for(k,v) in more{r[k]=v}
 let path=root.appendingPathComponent("state/extensions/results/"+rid+".json");try? FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);if let d=try? JSONSerialization.data(withJSONObject:r){try? d.write(to:path,options:.atomic);try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)}
}
let args=Array(CommandLine.arguments.dropFirst())
if args.count>1 {runMusic();exit(0)}
if let raw=args.first,let uuid=UUID(uuidString:raw),let d=try? Data(contentsOf:root.appendingPathComponent("state/extensions/requests/"+uuid.uuidString+".json")),let r=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any],let a=r["action"] as? String {
 if a=="center_permissions" || a=="center_authorize_accessibility" {
  if a=="center_authorize_accessibility" {_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)}
  centralResult(uuid.uuidString,a,["accessibility":AXIsProcessTrusted(),"screen_capture":CGPreflightScreenCaptureAccess(),"calendar":EKEventStore.authorizationStatus(for:.event) == .fullAccess,"reminders":EKEventStore.authorizationStatus(for:.reminder) == .fullAccess]);exit(0)
 }
 if ["podcast_open","podcast_play","podcast_pause","podcast_random","podcast_subscriptions","podcast_subscription_play","podcast_status","podcast_inspect"].contains(a){runPodcast()}
 else if a.hasPrefix("five_"){runFive()}
 else if ["keynote_next","keynote_previous","keynote_position"].contains(a){runKeynote()}
 else if ["reminders_authorize","reminders_today"].contains(a){runReminder()}
 else if ["media_authorize","podcast_select","podcast_detail","podcast_full_play","podcast_full_pause"].contains(a){runMedia()}
 else {runExtension()}
 exit(0)
}
let alert=NSAlert();alert.messageText="XiaoGPT 控制中心";alert.informativeText="统一承载网易云、小宇宙、收藏、浏览器与日历等本地动作。辅助功能当前："+(AXIsProcessTrusted() ? "已授权":"未授权")+"。macOS 仍按辅助功能、日历、提醒与自动化分别管理权限。屏幕录制不会自动请求。旧程序在迁移验证完成前保留。";alert.addButton(withTitle:"打开辅助功能设置");alert.addButton(withTitle:"关闭")
app.activate(ignoringOtherApps:true)
if alert.runModal() == .alertFirstButtonReturn{NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}
