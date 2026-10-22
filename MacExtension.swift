import AppKit
import ApplicationServices
import CoreAudio
import EventKit
import Foundation

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
    if !AXIsProcessTrusted() { finish("permission_required", "请在系统设置辅助功能中允许XiaoGPT Mac扩展") }
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
        finish("permission_required", kind == .event ? "请先允许XiaoGPT Mac扩展访问日历" : "请先允许XiaoGPT Mac扩展访问提醒事项")
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
        finish(number == -1743 ? "permission_required" : "operation_failed", number == -1743 ? "请允许XiaoGPT Mac扩展自动化控制目标应用" : "目标应用暂未完成操作，请检查是否已打开文稿", ["error_code":number])
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
