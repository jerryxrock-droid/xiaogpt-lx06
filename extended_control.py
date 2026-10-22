"""Fixed voice actions for Mac apps; no model-generated code is executed."""
from __future__ import annotations
import asyncio
from dataclasses import dataclass,field
from datetime import datetime,timedelta
import fcntl
import json
import logging
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import quote,urlparse
import uuid
from zoneinfo import ZoneInfo

BASE=Path(__file__).resolve().parent
STATE=BASE/'state/extensions'
HELPER=BASE/'XiaoGPT Mac扩展.app'
SETTINGS=BASE/'mac_features.json'
TZ=ZoneInfo('Asia/Shanghai')
LOG=logging.getLogger('xiaogpt')
DIGITS={'零':0,'〇':0,'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9}
NUMBER=r'[0-9零〇一二两三四五六七八九十百]+'
@dataclass
class Command:
    action:str
    data:dict=field(default_factory=dict)

def number(text):
    if text.isdigit():return int(text)
    if text in ('一百','百'):return 100
    if '十' in text:
        a,b=text.split('十',1)
        return (DIGITS.get(a,1) if a else 1)*10+(DIGITS.get(b,0) if b else 0)
    if len(text)==1 and text in DIGITS:return DIGITS[text]
    raise ValueError('无法识别数值')

def clean_lead(query):
    q=query.strip(' ，,。？！!?')
    while (m:=re.match(r'^(?:问\s*ai|请问|请帮我|帮我|请)[，,\s]*',q,re.I)):
        q=q[m.end():]
    m=re.match(r'^(?:让|在|把)?(?:我的)?(?:本地)?(?:mac|电脑|计算机)(?:上)?[，,\s]*',q,re.I)
    return (q[m.end():] if m else q),bool(m)

def parse_schedule(text,now=None):
    now=now or datetime.now(TZ)
    q=text.strip(' ，,。？！!?')
    if re.search(r'每天|每周|每月|每年|工作日',q):raise ValueError('目前只支持一次性事项，请说明具体日期和时间')
    q=re.sub(r'^在(?=(?:今天|明天|后天|下周|[0-9]))','',q)
    target=now.date();used=[]
    relative=re.search(r'今天|明天|后天',q)
    weekday=re.search(r'下周([一二三四五六日天])',q)
    absolute=re.search(r'(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号]',q)
    if relative:
        target+=timedelta(days={'今天':0,'明天':1,'后天':2}[relative[0]]);used.append(relative.span())
    elif weekday:
        idx='一二三四五六日'.index(weekday[1].replace('天','日'))
        target+=timedelta(days=7-now.weekday()+idx);used.append(weekday.span())
    elif absolute:
        target=target.replace(year=int(absolute[1] or target.year),month=int(absolute[2]),day=int(absolute[3]));used.append(absolute.span())
    timing=re.search(rf'(凌晨|早上|上午|中午|下午|傍晚|晚上)?\s*({NUMBER})(?:点|时|[:：])(?:(半)|\s*({NUMBER})分?)?',q)
    if len(list(re.finditer(rf'(?:凌晨|早上|上午|中午|下午|傍晚|晚上)?\s*({NUMBER})(?:点|时|[:：])',q)))>1:raise ValueError('请一次只说明一个开始时间；日程默认持续一小时，并在保存前复述确认')
    if not timing:raise ValueError('请说清楚日期、几点以及事项内容，例如明天下午三点开会')
    hour=number(timing[2]);minute=30 if timing[3] else number(timing[4]) if timing[4] else 0
    period=timing[1]
    if period in ('下午','晚上','傍晚') and hour<12:hour+=12
    elif period=='中午' and hour<11:hour+=12
    elif period=='凌晨' and hour==12:hour=0
    if hour>23 or minute>59:raise ValueError('时间数值不正确，请重新说明')
    target_time=datetime(target.year,target.month,target.day,hour,minute,tzinfo=TZ)
    if target_time<=now:raise ValueError('这个时间已经过去，请明确一个未来时间')
    used.append(timing.span())
    title=q
    for a,b in sorted(used,reverse=True):title=title[:a]+title[b:]
    title=re.sub(r'^[，,\s:：]*(?:提醒我|提醒|记得|要|去|安排|添加|新建|创建|日程|提醒事项|一个|一条|在)+','',title).strip(' ，,。:：')
    if not title or len(title)>300:raise ValueError('请说明要提醒或安排什么事项')
    return {'title':title,'timestamp':target_time.timestamp(),'display':target_time.strftime('%Y年%m月%d日 %H:%M')}

def parse_extension(query):
    q,mac=clean_lead(query)
    # Capture note content verbatim; it is data, never code or a second command.
    for pattern,action in [(r'^(?:帮我)?(?:记一条灵感|记个灵感|记录灵感|记灵感|记一条笔记|记到Obsidian)[：:,，\s]*(.*)$','inspiration_add'),(r'^(?:帮我)?(?:记到备忘录|保存到备忘录|备忘录记一条)[：:,，\s]*(.*)$','notes_add')]:
        if m:=re.fullmatch(pattern,q,re.I):return Command(action,{'text':m[1].strip()})
    if re.search(r'不要|不准|禁止|如果|假如|如何|怎么|是否|能否|教程|示例|代码',q):return None
    compact=re.sub(r'[\s，,。？！!?、]','',q)
    compact=re.sub(r'(?:一下|吧)$','',compact)
    if compact in ('确认创建提醒','确认提醒','确认创建日程','确认日程','确认保存事项'):
        return Command('schedule_confirm',{'kind':'reminder' if '提醒' in compact else 'calendar' if '日程' in compact else None})
    if compact in ('取消创建','取消创建提醒','取消创建日程','取消这条提醒','取消这条日程'):
        return Command('schedule_cancel')
    if compact in ('开始工作','进入工作模式'):return Command('scene_work')
    if compact in ('进入听播客模式','开始听播客','听播客模式'):return Command('scene_podcast')
    if compact in ('进入听音乐模式','听音乐模式'):return Command('scene_music')
    if compact in ('打开灵感笔记','打开语音笔记'):return Command('inspiration_open')
    if compact in ('开始演示','开始Keynote演示','Keynote开始演示','播放幻灯片'):return Command('keynote_start')
    if compact in ('下一页','演示下一页','Keynote下一页'):return Command('keynote_next')
    if compact in ('上一页','演示上一页','Keynote上一页'):return Command('keynote_previous')
    if compact in ('结束演示','退出演示','停止演示'):return Command('keynote_stop')
    if compact in ('读一下今天的日程','读今天的日程','今天的日程','查看今天日程','今天有什么日程'):return Command('calendar_today')
    if compact in ('读一下明天的日程','读明天的日程','明天的日程','查看明天日程','明天有什么日程'):return Command('calendar_tomorrow')
    for lead,kind in [('新增提醒','reminder'),('创建提醒','reminder'),('添加提醒','reminder'),('提醒我','reminder'),('新增日程','calendar'),('创建日程','calendar'),('添加日程','calendar'),('安排日程','calendar')]:
        if q.startswith(lead):return Command('schedule_prepare',{'kind':kind,'text':q[len(lead):].strip(' ，,:：')})
    # Explicit library intents precede generic podcast/title parsing. 博客 is a common ASR variant.
    podcast_q=compact.replace('博客','播客').replace('小宇宙中','小宇宙')
    podcast_q=re.sub(r'^(播放|随机播放)小宇宙',r'小宇宙\1',podcast_q)
    podcast_q=podcast_q.replace('我订阅的','我的订阅的')
    if '小宇宙' in podcast_q:
        if re.fullmatch(r'(?:打开|用)?小宇宙(?:并)?(?:随机播放|播放随机)播客',podcast_q):
            return Command('podcast_random',{'subscription':False})
        if re.fullmatch(r'(?:打开|用)?小宇宙(?:并)?(?:播放|随机播放|播放随机)(?:我的)?订阅(?:的)?(?:随机)?(?:播客|节目)?',podcast_q):
            return Command('podcast_random',{'subscription':True})
        if re.fullmatch(r'打开小宇宙(?:中)?(?:的)?我的订阅',podcast_q):return Command('podcast_subscriptions')
        if m:=re.fullmatch(r'(?:打开|用)?小宇宙(?:并)?播放(?:我的)?订阅(?:中|里|的)*(.{1,60}?)(?:的)?最新一期',podcast_q):
            return Command('podcast_subscription_play',{'name':m[1],'latest':True})
        if m:=re.fullmatch(r'(?:打开|用)?小宇宙(?:并)?播放(?:我的)?订阅(?:中|里|的)*(.{1,60}?)(?:的)?一集',podcast_q):
            return Command('podcast_subscription_play',{'name':m[1]})
    if '小宇宙' in compact:
        # Do not interpret song/program names as commands.
        rem=re.sub(r'小宇宙|打开|启动|继续|恢复|播放|播客|节目|暂停|停止|并且|并|然后|开始|听','',compact)
        if rem:return Command('unsupported',{'message':'小宇宙目前支持打开、继续播放和暂停；请先在应用中选好一集节目。'}) if mac or re.match(r'^(打开|继续|暂停|播放)',compact) else None
        if re.search(r'暂停|停止',compact):return Command('podcast_pause')
        if re.search(r'播放|继续|恢复|听',compact):return Command('podcast_play')
        if re.search(r'打开|启动',compact):return Command('podcast_open')
    if mac:
        if compact in ('静音','电脑静音','音量静音'):return Command('volume_mute',{'muted':True})
        if compact in ('取消静音','恢复声音','取消音量静音'):return Command('volume_mute',{'muted':False})
        if compact in ('音量多少','当前音量','音量是多少'):return Command('volume_get')
        if compact in ('音量大一点','音量调大','增大音量','升高音量'):return Command('volume_delta',{'delta':10})
        if compact in ('音量小一点','音量调小','减小音量','降低音量'):return Command('volume_delta',{'delta':-10})
        m=re.fullmatch(rf'(?:把)?音量(?:调到|设为|设置为|调整到)(?:百分之)?({NUMBER})(?:%|％)?',compact)
        if m:
            try:n=number(m[1])
            except ValueError:return Command('unsupported',{'message':'请把音量说成零到一百之间的整数。'})
            return Command('volume_set',{'volume':n}) if 0<=n<=100 else Command('unsupported',{'message':'音量只能设置在零到一百之间。'})
        app=re.fullmatch(r'(?:打开|启动)(Obsidian|备忘录|Safari|Chrome|谷歌浏览器|浏览器|Keynote)',compact,re.I)
        if app:return Command('app_open',{'app':app[1].lower()})
        site=re.fullmatch(r'打开(?:我的)?(.+?)(?:网站|网页|页面)',compact)
        if site:return Command('browser_open',{'site':site[1]})
    return None


def atomic_json(path,data):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,temp=tempfile.mkstemp(dir=path.parent,prefix='.xiao-')
    try:
        with os.fdopen(fd,'w') as f:json.dump(data,f,ensure_ascii=False,indent=2)
        os.replace(temp,path)
    finally:Path(temp).unlink(missing_ok=True)

async def native(action,data=None,timeout=30):
    from native_bridge import center_enabled,center_request
    if action=='podcast_subscription_play' and (data or {}).get('latest'):
        return {'status':'unsupported','message':'目前不能保证小宇宙列表的最新排序，尚未执行。可说，电脑小宇宙播放我订阅的节目名称的一集。'}
    if center_enabled() and not action.startswith('volume_'):
        # Existing calendar/automation permissions stay on the old identity until separately migrated.
        legacy=json.loads(SETTINGS.read_text()).get('control_center_legacy_actions',[])
        if any(action.startswith(prefix) for prefix in legacy):
            return await _legacy_native(action,data,timeout)
        if action=='podcast_subscription_play':
            # Opening the tab can asynchronously refresh the feed; prepare its list first.
            ready=None
            for attempt in range(2):
                ready=await center_request('podcast_subscriptions',timeout=timeout)
                if ready.get('status')=='ok':break
                if ready.get('message')!='未确认我的订阅列表已打开':return ready
                await asyncio.sleep(.6)
            if ready.get('status')!='ok':return ready
            await asyncio.sleep(.4)
        result=await center_request(action,data,timeout)
        if action in {'podcast_subscriptions','podcast_subscription_play'} and result.get('message')=='未确认我的订阅列表已打开':
            # This result is returned before any play action, so one retry is safe.
            await asyncio.sleep(.6)
            result=await center_request(action,data,timeout)
        return result
    if action in {'podcast_random','podcast_subscriptions','podcast_subscription_play'}:
        return {'status':'permission_required','message':'此功能需要统一控制中心完成辅助功能授权；尚未执行播放。'}
    return await _legacy_native(action,data,timeout)

async def _legacy_native(action,data=None,timeout=30):
    if action in {'podcast_play','podcast_pause'}:
        # Full-screen podcast player has no compact bar. Use its published media
        # session when it is the active media app; never touch browser media.
        from media_features import media_state,CLI,PODCAST
        try:
            current=await media_state()
            if current.get('bundle')==PODCAST:
                wanted=action=='podcast_play'
                if current['playing']==wanted:return {'status':'ok','message':'小宇宙已在播放' if wanted else '小宇宙已暂停','playing':wanted}
                p=await asyncio.create_subprocess_exec(CLI,'play' if wanted else 'pause',stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
                await asyncio.wait_for(p.wait(),6)
                for _ in range(8):
                    await asyncio.sleep(.3)
                    after=await media_state()
                    if after.get('bundle')==PODCAST and after['playing']==wanted:return {'status':'ok','message':'已继续播放Mac小宇宙' if wanted else '已暂停Mac小宇宙','playing':wanted}
        except (OSError,ValueError,asyncio.TimeoutError):pass
    if action in {'volume_get','volume_set','volume_mute'}:
        process=await asyncio.create_subprocess_exec(str(BASE/'bin/audio-control'),stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
        output,error=await asyncio.wait_for(process.communicate(json.dumps({'action':action,**(data or {})}).encode()),8)
        try:return json.loads(output)
        except (ValueError,TypeError):return {'status':'audio_failed','message':'音量控制程序未返回有效结果'}
    if action in {'podcast_play','podcast_pause','podcast_status','podcast_inspect'}:
        activate=await asyncio.create_subprocess_exec('/usr/bin/open','-a','/Applications/小宇宙.app',stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
        await asyncio.wait_for(activate.wait(),8)
    request_id=str(uuid.uuid4()).upper()
    req=STATE/'requests'/(request_id+'.json');out=STATE/'results'/(request_id+'.json')
    atomic_json(req,{'action':action,**(data or {})})
    helper=BASE/'XiaoGPT 晨报提醒.app' if action in {'reminders_authorize','reminders_today'} else BASE/'XiaoGPT 媒体扩展.app' if action in {'media_authorize','podcast_select','podcast_detail','podcast_full_play','podcast_full_pause'} else BASE/'XiaoGPT Keynote翻页.app' if action in {'keynote_next','keynote_previous','keynote_position'} else HELPER
    process=await asyncio.create_subprocess_exec('/usr/bin/open','-g','-n','-a',str(helper),'--args',request_id,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE)
    try:await asyncio.wait_for(process.communicate(),8)
    except asyncio.TimeoutError:
        process.kill();await process.communicate();return {'status':'launch_failed','message':'Mac扩展程序未能启动'}
    if process.returncode:return {'status':'launch_failed','message':'Mac扩展程序未能启动'}
    deadline=time.monotonic()+timeout
    while not out.exists() and time.monotonic()<deadline:await asyncio.sleep(.15)
    if not out.exists():return {'status':'timeout','message':'Mac操作暂未返回结果，请检查系统授权提示'}
    result=json.loads(out.read_text())
    if result.get('request_id')!=request_id or result.get('action')!=action:return {'status':'invalid_result','message':'操作结果不匹配'}
    for folder in ('requests','results'):
        paths=sorted((STATE/folder).glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)
        for old in paths[40:]:old.unlink(missing_ok=True)
    LOG.info('Mac扩展: %s，%s',action,result.get('status'))
    if action in {'podcast_play','podcast_pause'} and result.get('status')!='ok':
        return await native('podcast_full_play' if action=='podcast_play' else 'podcast_full_pause',timeout=20)
    return result

class ExtensionController:
    def __init__(self):self.lock=asyncio.Lock()
    def settings(self):return json.loads(SETTINGS.read_text())
    async def open_app(self,name):
        paths={'obsidian':'/Applications/Obsidian.app','备忘录':'/System/Applications/Notes.app','safari':'Safari','chrome':'/Applications/Google Chrome.app','谷歌浏览器':'/Applications/Google Chrome.app','浏览器':'Safari','keynote':'/Applications/Keynote.app'}
        path=paths.get(name)
        if not path:return {'status':'unsupported','message':'该应用尚未配置'}
        p=await asyncio.create_subprocess_exec('/usr/bin/open','-a',path,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE)
        await p.communicate()
        return {'status':'ok' if p.returncode==0 else 'failed','message':f'已打开{name}' if p.returncode==0 else f'暂时无法打开{name}'}
    async def handle(self,query):
        command=parse_extension(query)
        if command is None:return None
        async with self.lock:
            try:return await self.execute(command)
            except asyncio.CancelledError:raise
            except Exception as exc:
                LOG.warning('Mac扩展执行失败: %s',type(exc).__name__)
                return '这次Mac操作未完成，请检查应用和授权后重试。'
    async def execute(self,c):
        a,d=c.action,c.data
        if a=='unsupported':return d['message']
        if a.startswith('podcast_') or a.startswith('keynote_') or a=='notes_add':
            if a=='notes_add' and (not d.get('text') or len(d['text'])>3000):return '请提供三千字以内的笔记内容。'
            return (await native(a,d))['message']
        if a=='app_open':return (await self.open_app(d['app']))['message']
        if a=='browser_open':
            config=self.settings();url=config['sites'].get(d['site'])
            if not url:return f'尚未配置{d["site"]}网站，请先提供网站名称和链接。'
            parsed=urlparse(url)
            if parsed.scheme not in ('https','http') or not parsed.netloc or parsed.username or parsed.password:return '该网站地址不符合配置要求。'
            browser=config.get('browser','Safari')
            if browser not in ('Safari','Google Chrome'):return '浏览器配置无效。'
            p=await asyncio.create_subprocess_exec('/usr/bin/open','-a',browser,url,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE)
            await p.communicate()
            return f'已在Mac打开{d["site"]}页面。' if p.returncode==0 else '网页未能打开。'
        if a.startswith('volume_'):
            if a=='volume_delta':
                result=await native('volume_get')
                if result['status']!='ok':return result['message']
                d={'volume':min(100,max(0,result['volume']+d['delta']))};a='volume_set'
            if a=='volume_mute':
                config=self.settings()
                if d['muted']:
                    current=await native('volume_get')
                    if current['status']=='ok' and current['volume']>0:
                        config['restore_volume']=current['volume'];atomic_json(SETTINGS,config)
                d={**d,'restore_volume':config.get('restore_volume',20)}
            return (await native(a,d))['message']
        if a in ('inspiration_add','inspiration_open'):
            path=Path(self.settings()['inspiration_file']).expanduser()
            if a=='inspiration_add':
                text=d['text'].strip()
                if not text or len(text)>3000:return '请提供三千字以内的灵感内容，例如记一条灵感，周末去公园。'
                path.parent.mkdir(parents=True,exist_ok=True)
                with path.open('a',encoding='utf-8') as f:
                    fcntl.flock(f,fcntl.LOCK_EX)
                    if f.tell()==0:f.write('# 小爱语音灵感\n')
                    f.write('\n## '+datetime.now(TZ).strftime('%Y-%m-%d %H:%M')+'\n\n'+text+'\n')
                return '已保存到Obsidian的小爱语音灵感笔记。'
            if not path.exists():return '目前还没有灵感笔记，请先说，记一条灵感，加上内容。'
            p=await asyncio.create_subprocess_exec('/usr/bin/open','obsidian://open?path='+quote(str(path),safe=''),stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE)
            await p.communicate();return '已打开Obsidian灵感笔记。' if p.returncode==0 else '笔记已保存，但未能打开Obsidian。'
        if a in ('calendar_today','calendar_tomorrow'):
            result=await native(a)
            if result['status']!='ok':return result['message']
            if not result.get('events'):return result['message']
            lead='今天' if a=='calendar_today' else '明天'
            return lead+'有'+str(result['count'])+'项日程。'+('先读前八项。' if result['count']>8 else '')+'；'.join(x['time']+'，'+x['title'] for x in result['events'])+'。'
        if a=='schedule_prepare':
            try:item=parse_schedule(d['text'])
            except ValueError as exc:return str(exc)
            item.update(kind=d['kind'],expires=time.time()+180)
            atomic_json(STATE/'pending.json',item)
            kind='提醒' if d['kind']=='reminder' else '日程'
            duration='，持续一小时' if d['kind']=='calendar' else ''
            return f'准备创建{kind}：北京时间{item["display"]}，{item["title"]}{duration}。请说确认创建{kind}，或取消创建。'
        if a=='schedule_cancel':
            (STATE/'pending.json').unlink(missing_ok=True);return '已取消待确认事项。'
        if a=='schedule_confirm':
            path=STATE/'pending.json'
            if not path.exists():return '没有等待确认的事项。请先说明日期、时间和内容。'
            item=json.loads(path.read_text())
            if item['expires']<time.time():path.unlink(missing_ok=True);return '确认已超时，请重新说明事项。'
            if d.get('kind') and item['kind']!=d['kind']:return '确认的事项类型不一致，请重新确认。'
            # Consume first: a repeated cloud transcript cannot create duplicates.
            path.unlink(missing_ok=True)
            result=await native('reminder_create' if item['kind']=='reminder' else 'calendar_create',{'title':item['title'],'timestamp':item['timestamp']})
            return result['message']
        if a.startswith('scene_'):
            config=self.settings();messages=[]
            if a=='scene_work':
                for name in config.get('work_apps',['obsidian','safari']):
                    result=await self.open_app(name)
                    if result['status']!='ok':messages.append(result['message'])
                result=await native('volume_set',{'volume':config.get('work_volume',20)})
                if result['status']!='ok':messages.append(result['message'])
                if config['sites'].get('工作'):
                    messages.append(await self.execute(Command('browser_open',{'site':'工作'})))
                return '工作模式已执行。'+(''.join(messages) if messages else '已打开Obsidian和浏览器，音量百分之二十。')
            from mac_control import CONTROLLER
            if a=='scene_podcast':
                music=await CONTROLLER.execute('pause')
                podcast=await native('podcast_play')
                return music+'。'+podcast['message']
            podcast=await native('podcast_pause')
            music=await CONTROLLER.execute('play')
            return podcast['message']+'。'+music
        return '该操作尚未配置。'

EXTENSIONS=ExtensionController()
