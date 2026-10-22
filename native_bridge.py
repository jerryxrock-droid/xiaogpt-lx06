"""Single app identity for native control; migration is explicit and reversible."""
import asyncio,json,time,uuid,logging
from pathlib import Path
BASE=Path(__file__).resolve().parent
CENTER=BASE/'XiaoGPT 控制中心.app'
def center_enabled():
    try:return bool(json.loads((BASE/'mac_features.json').read_text()).get('control_center_enabled',False))
    except (OSError,ValueError):return False
async def center_request(action,data=None,timeout=30):
    from extended_control import atomic_json
    state=BASE/'state/extensions';rid=str(uuid.uuid4()).upper()
    out=state/'results'/(rid+'.json');cancel=state/'cancelled'/(rid+'.json')
    atomic_json(state/'requests'/(rid+'.json'),{'action':action,'created':time.time(),**(data or {})})
    p=await asyncio.create_subprocess_exec('/usr/bin/open','-g','-n','-a',str(CENTER),'--args',rid,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
    try:
        await asyncio.wait_for(p.wait(),8)
        if p.returncode:return {'status':'launch_failed','message':'控制中心未能启动'}
        until=time.monotonic()+timeout
        while not out.exists() and time.monotonic()<until:await asyncio.sleep(.12)
        if not out.exists():
            atomic_json(cancel,{'cancelled':time.time()});return {'status':'timeout','message':'控制中心操作超时，未确认完成'}
        result=json.loads(out.read_text())
        if result.get('request_id')!=rid or result.get('action')!=action:return {'status':'invalid_result','message':'控制中心返回结果不匹配'}
        logging.getLogger('xiaogpt').info('控制中心执行: %s，%s',action,result.get('status','unknown'))
        return result
    except asyncio.CancelledError:
        atomic_json(cancel,{'cancelled':time.time()});raise
