import AppKit
import EventKit
import Foundation
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
