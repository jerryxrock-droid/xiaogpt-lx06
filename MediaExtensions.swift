import AppKit
import ApplicationServices
import Foundation
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
 finish(trusted ? "ok":"permission_required",trusted ? "媒体扩展权限已就绪":"请为XiaoGPT 媒体扩展开启辅助功能")
}
if !["podcast_select","podcast_detail","podcast_full_play","podcast_full_pause"].contains(action){finish("unsupported","不支持此操作")}
guard AXIsProcessTrusted() else{finish("permission_required","请为XiaoGPT 媒体扩展开启辅助功能")}
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
