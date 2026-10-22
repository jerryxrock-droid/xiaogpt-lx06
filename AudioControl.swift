import Foundation
import CoreAudio
let base=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let restoreFile=base.appendingPathComponent("state/extensions/audio_restore.json")
let input=FileHandle.standardInput.readDataToEndOfFile()
guard let request=(try? JSONSerialization.jsonObject(with:input)) as? [String:Any],let action=request["action"] as? String,["volume_get","volume_set","volume_mute"].contains(action) else {exit(2)}
func emit(_ status:String,_ message:String,_ extra:[String:Any]=[:])->Never {
 var value:[String:Any]=["status":status,"message":message,"action":action]
 for(k,v) in extra {value[k]=v}
 if let data=try? JSONSerialization.data(withJSONObject:value) {FileHandle.standardOutput.write(data)}
 exit(status=="ok" ? 0:1)
}
func address(_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal,_ element:AudioObjectPropertyElement=0)->AudioObjectPropertyAddress {AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:element)}
func string(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector)->String {
 var a=address(selector),size=UInt32(MemoryLayout<CFString?>.size);var raw:Unmanaged<CFString>?
 let ok=withUnsafeMutablePointer(to:&raw){AudioObjectGetPropertyData(id,&a,0,nil,&size,$0)}
 return ok==noErr ? raw?.takeUnretainedValue() as String? ?? "" : ""
}
func volumeProperties(_ id:AudioObjectID)->[AudioObjectPropertyAddress] {
 var result:[AudioObjectPropertyAddress]=[]
 for el:AudioObjectPropertyElement in [0,1,2] {
  var a=address(kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput,el)
  var writable:DarwinBoolean=false
  if AudioObjectHasProperty(id,&a) && AudioObjectIsPropertySettable(id,&a,&writable)==noErr && writable.boolValue {
   result.append(a);if el==0 {break}
  }
 }
 return result
}
func children(_ id:AudioObjectID)->[AudioDeviceID] {
 var a=address(kAudioAggregateDevicePropertyActiveSubDeviceList),size:UInt32=0
 guard AudioObjectGetPropertyDataSize(id,&a,0,nil,&size)==noErr,size>0 else{return []}
 var values=[AudioDeviceID](repeating:0,count:Int(size)/4)
 let ok=values.withUnsafeMutableBytes{AudioObjectGetPropertyData(id,&a,0,nil,&size,$0.baseAddress!)}
 return ok==noErr ? values:[]
}
func targets(_ id:AudioDeviceID,_ visited:Set<AudioDeviceID>=[])->[AudioDeviceID] {
 if visited.contains(id) || visited.count>8 {return []}
 if !volumeProperties(id).isEmpty {return [id]}
 return children(id).flatMap{targets($0,visited.union([id]))}
}
func readVolumes(_ id:AudioDeviceID)->[Float32] {
 volumeProperties(id).compactMap{ property in
  var a=property,value:Float32=0,size=UInt32(MemoryLayout<Float32>.size)
  return AudioObjectGetPropertyData(id,&a,0,nil,&size,&value)==noErr ? value:nil
 }
}
func writeVolumes(_ id:AudioDeviceID,_ values:[Float32])->Bool {
 let properties=volumeProperties(id)
 guard !properties.isEmpty,!values.isEmpty else{return false}
 for (index,var a) in properties.enumerated() {
  var v=min(1,max(0,values[min(index,values.count-1)]))
  if AudioObjectSetPropertyData(id,&a,0,nil,UInt32(MemoryLayout<Float32>.size),&v) != noErr {return false}
 }
 return true
}
func unmute(_ id:AudioDeviceID) {
 var a=address(kAudioDevicePropertyMute,kAudioDevicePropertyScopeOutput)
 if AudioObjectHasProperty(id,&a) {var value:UInt32=0;AudioObjectSetPropertyData(id,&a,0,nil,4,&value)}
}
var a=address(kAudioHardwarePropertyDefaultOutputDevice),device=AudioDeviceID(0),size=UInt32(4)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&size,&device)==noErr,device != 0 else {emit("audio_unavailable","未找到Mac音频输出设备")}
let devices=Array(Set(targets(device))).sorted()
guard !devices.isEmpty else {emit("volume_unsupported","当前输出设备不支持软件音量控制，请使用设备自身音量控制")}
func snapshot()->[[String:Any]] {
 devices.map { id in let values=readVolumes(id);return ["uid":string(id,kAudioDevicePropertyDeviceUID),"name":string(id,kAudioObjectPropertyName),"values":values.map{Double($0)},"volume":values.isEmpty ? 0:Int((values.reduce(0,+)/Float32(values.count)*100).rounded())] }
}
func average()->Int {let levels=devices.flatMap{readVolumes($0)};return levels.isEmpty ? 0:Int((levels.reduce(0,+)/Float32(levels.count)*100).rounded())}
if action=="volume_get" {emit("ok","Mac可控输出平均音量百分之\(average())",["volume":average(),"devices":snapshot(),"multiple_outputs":devices.count>1])}
if action=="volume_set" {
 guard let percentage=request["volume"] as? Int,(0...100).contains(percentage) else {emit("invalid","音量必须在零到一百之间")}
 var successes=0
 for id in devices {
  if writeVolumes(id,[Float32(percentage)/100]) {successes+=1;if percentage>0 {unmute(id)}}
 }
 guard successes==devices.count else {emit("partial","部分输出设备音量未能调整，请检查设备连接",["changed":successes])}
 try? FileManager.default.removeItem(at:restoreFile)
 emit("ok",devices.count>1 ? "已把Mac的\(devices.count)个可控输出音量调到百分之\(average())":"Mac音量已调到百分之\(average())",["volume":average(),"devices":snapshot()])
}
let muted=request["muted"] as? Bool ?? true
if muted {
 let before=snapshot()
 do {
  try FileManager.default.createDirectory(at:restoreFile.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  // Preserve the first snapshot if the user repeats mute.
  if !FileManager.default.fileExists(atPath:restoreFile.path) {
   try JSONSerialization.data(withJSONObject:before).write(to:restoreFile,options:.atomic)
   try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:restoreFile.path)
  }
 } catch {emit("save_failed","无法保存原音量，未执行静音")}
 if devices.map({writeVolumes($0,[0])}).allSatisfy({$0}) {emit("ok","Mac可控音频输出已静音",["volume":0])}
 emit("partial","部分输出设备未能静音")
}
let saved=(try? Data(contentsOf:restoreFile)).flatMap{try? JSONSerialization.jsonObject(with:$0) as? [[String:Any]]} ?? []
var successes=0
for id in devices {
 let uid=string(id,kAudioDevicePropertyDeviceUID)
 let values=(saved.first{($0["uid"] as? String)==uid}?["values"] as? [Double])?.map{Float32($0)} ?? (readVolumes(id).contains(where:{$0>0}) ? readVolumes(id) : [Float32(request["restore_volume"] as? Int ?? 20)/100])
 if writeVolumes(id,values) {successes+=1;unmute(id)}
}
if successes==devices.count {try? FileManager.default.removeItem(at:restoreFile);emit("ok","Mac已取消静音并恢复原音量",["volume":average(),"devices":snapshot()])}
emit("partial","部分输出设备未能恢复音量")
