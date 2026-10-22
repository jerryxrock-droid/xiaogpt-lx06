import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import Foundation
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
func requireAX(){if !AXIsProcessTrusted(){finish("permission_required","请为XiaoGPT 收藏与播客开启辅助功能")}}
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
 guard CGPreflightScreenCaptureAccess() else{finish("screen_permission_required","加入指定歌单和倍速定位需要为XiaoGPT 收藏与播客开启屏幕录制；只在本机识别目标应用窗口，不保存或上传截图")}
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
 if let error{let n=error[NSAppleScript.errorNumber] as? Int ?? 0;finish(n == -1743 ? "automation_permission_required":"browser_error",n == -1743 ? "请在系统弹窗允许XiaoGPT 收藏与播客读取浏览器当前网页":"浏览器当前页面暂时无法读取",["error_code":n])}
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
