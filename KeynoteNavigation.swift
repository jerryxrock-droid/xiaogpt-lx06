import Foundation
import AppKit
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
 finish(code == -1743 ? "permission_required":"operation_failed",code == -1743 ? "请允许XiaoGPT Keynote翻页控制Keynote":"Keynote翻页暂未成功",["error_code":code])
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
