import AppKit
import ApplicationServices
import Foundation
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
