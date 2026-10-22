"""Observed media state, explicit artist queue and persistent stop timers."""
import asyncio
import base64
import json
import logging
import os
from pathlib import Path
import random
import re
import time
from extended_control import atomic_json,native,number,NUMBER
from song_control import request
from mac_prefix import normalize_mac_query

BASE=Path(__file__).resolve().parent
STATE=BASE/'state/advanced'
CLI='/opt/homebrew/bin/nowplaying-cli'
MUSIC='com.netease.163music'
PODCAST='app.podcast.cosmos'
LOG=logging.getLogger('xiaogpt')

def simplify(text):return re.sub(r'[^\w\u4e00-\u9fff]','',text).casefold()

def compact(query):
    q=re.sub(r'[\s，,。？！!?《》“”]','',query)
    return re.sub(r'^(?:问ai|请问|请帮我|帮我|请)','',q,flags=re.I)

def parse_media(query):
    q=compact(normalize_mac_query(query))
    if re.match(r'不要|别|禁止|如何|怎么|如果',q):return None
    if q in ('这首歌叫什么','这首叫什么歌','这首叫什么','这首是什么歌','这是什么歌','当前歌曲','正在播放什么','电脑正在播放什么','现在播放什么歌'):return ('now',{})
    if q in ('换一首他的歌','再放一首他的歌','再来一首他的歌','播放他的另一首歌'):return ('queue_relative',{})
    if q in ('取消连续播放','结束连续播放','取消歌手队列'):return ('queue_clear',{})
    if q in ('取消定时停止','取消停止播放计时','取消音乐定时'):return ('timer_cancel',{})
    m=re.fullmatch(rf'(半小时|{NUMBER}(?:分钟|小时))后(?:让电脑)?(?:停止播放|停止音乐|停止播客|暂停音乐|暂停播放)',q)
    if m:
        s=m[1];seconds=1800 if s=='半小时' else number(re.sub('分钟|小时','',s))*(3600 if '小时' in s else 60)
        return ('timer',{'seconds':seconds})
    m=re.fullmatch(rf'(?:让电脑|让Mac)?(?:网易云(?:音乐)?|小宇宙)?(?:从|跳到|跳转到)({NUMBER})分(?:钟)?(?:(?:零)?({NUMBER})秒)?(?:开始)?播放',q,re.I)
    if m:return ('seek',{'seconds':number(m[1])*60+(number(m[2]) if m[2] else 0),'target':PODCAST if '小宇宙' in q else MUSIC if '网易云' in q else None})
    m=re.fullmatch(r'(?:让|在)?(?:Mac|电脑)(?:上)?(?:用|打开)?网易云(?:音乐)?(?:并)?(随机|连续)?播放(.{1,50})的(?:歌|歌曲)(?:不要现场版|排除现场版)?',q,re.I)
    if m and (m[1] or re.search('不要现场版|排除现场版',q)):
        return ('queue',{'artist':m[2],'shuffle':m[1]=='随机','exclude_live':'现场版' in q})
    if q in ('让电脑网易云下一首','让Mac网易云下一首','让电脑网易云音乐下一首'):return ('queue_next',{})
    if q in ('让电脑网易云上一首','让Mac网易云上一首','让电脑网易云音乐上一首'):return ('queue_previous',{})
    return None

async def media_state():
    # Use the metadata backend shipped by the installed CLI directly: its public
    # CLI drops the timestamp, which makes an anchored elapsed time look frozen.
    env=dict(os.environ);env['MEDIAREMOTEADAPTER_OPTION_now']='1'
    p=await asyncio.create_subprocess_exec('/usr/bin/perl','/opt/homebrew/share/nowplaying-cli/scripts/mediaremote-mini.pl','/opt/homebrew/lib/nowplaying-cli/MediaRemoteMini.dylib','adapter_get_env',env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL)
    try:out,_=await asyncio.wait_for(p.communicate(),6)
    except asyncio.TimeoutError:
        p.kill();await p.communicate();raise
    raw=json.loads(out or '{}')
    if not isinstance(raw,dict):return {'available':False,'reason':'no_media'}
    bundle=raw.get('bundleIdentifier','')
    if bundle not in {MUSIC,PODCAST}:return {'available':False,'reason':'other_application' if bundle else 'no_media'}
    return {'available':True,'bundle':bundle,'title':raw.get('title',''),'artist':raw.get('artist',''),'elapsed':float(raw.get('elapsedTimeNow',raw.get('elapsedTime',0)) or 0),'duration':float(raw.get('duration',0) or 0),'playing':bool(raw.get('playing',False)),'timestamp':raw.get('timestamp')}

async def send_song(song):
    payload={'type':'song','id':int(song['id']),'cmd':'play'}
    url='orpheus://'+base64.b64encode(json.dumps(payload,separators=(',',':')).encode()).decode()
    p=await asyncio.create_subprocess_exec('/usr/bin/open','-a','/Applications/NeteaseMusic.app',url,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
    await asyncio.wait_for(p.wait(),8)
    if p.returncode:raise RuntimeError('launch failed')


def artist_songs(name,exclude_live=False):
    artists=request('search/get/web',{'s':name,'type':100,'limit':5}).get('result',{}).get('artists',[])
    a=next((a for a in artists if a.get('name','').casefold()==name.casefold()),None)
    if not a:return []
    songs=request('artist/'+str(int(a['id']))).get('hotSongs',[])
    seen=set();result=[]
    for s in songs:
        if s.get('id') in seen:continue
        if exclude_live and re.search(r'live|现场|演唱会',s.get('name','')+' '+s.get('album',{}).get('name',''),re.I):continue
        seen.add(s['id']);result.append({'id':int(s['id']),'title':s['name'],'artist':a['name']})
    return result[:30]

class MediaFeatures:
    def __init__(self):
        self.lock=asyncio.Lock();self.queue=[];self.index=0;self.active=False;self.seen=False;self.near_end=False;self.changed_at=0;self.last_artist=None
        self.last_error='';self.task=None;self.last_tick=0;self.missing_since=None;self.matches=0
    async def start(self):
        if self.task is None or self.task.done():self.task=asyncio.create_task(self.supervise())
    def cancel_queue(self):
        self.active=False;self.near_end=False
    async def shutdown(self):
        if self.task:
            self.task.cancel()
            try:await self.task
            except asyncio.CancelledError:pass
    def timer(self):
        try:return json.loads((STATE/'stop_timer.json').read_text())
        except (OSError,ValueError):return None
    async def stop_media(self):
        from mac_control import CONTROLLER
        self.cancel_queue()
        results=await asyncio.gather(CONTROLLER.execute('pause'),native('podcast_pause'),return_exceptions=True)
        return '；'.join(r['message'] if isinstance(r,dict) else r if isinstance(r,str) else '部分播放暂停失败' for r in results)
    async def handle(self,query):
        c=parse_media(query)
        if c is None:return None
        a,d=c
        # Leave original next/previous behavior intact if no custom queue exists.
        if a in ('queue_next','queue_previous') and not self.active:return None
        async with self.lock:
            try:return await self.execute(a,d)
            except asyncio.CancelledError:raise
            except Exception as exc:
                self.last_error=type(exc).__name__;LOG.warning('媒体扩展失败: %s',self.last_error)
                return '这次媒体操作未完成，请检查网易云或小宇宙后重试。'
    async def execute(self,a,d):
        if a=='now':
            s=await media_state()
            for _ in range(2):
                if s.get('available') and s.get('title'):break
                if s.get('reason')=='other_application':break
                await asyncio.sleep(.3);s=await media_state()
            if not s.get('available') or not s.get('title'):return '系统没有提供网易云或小宇宙的当前播放信息，暂时无法确认歌名。'
            return ('Mac上的网易云' if s['bundle']==MUSIC else 'Mac上的小宇宙')+('正在播放' if s['playing'] else '当前暂停的是')+(s['artist']+'的' if s['artist'] else '')+s['title']+'。'
        if a=='timer':
            seconds=d['seconds']
            if not 60<=seconds<=86400:return '停止播放计时支持一分钟到二十四小时。'
            atomic_json(STATE/'stop_timer.json',{'due':time.time()+seconds,'created':time.time()})
            await self.start()
            return f'已设置{seconds//60}分钟后暂停Mac网易云和小宇宙。Mac需要保持开机运行。'
        if a=='timer_cancel':
            (STATE/'stop_timer.json').unlink(missing_ok=True);return '已取消定时停止播放。'
        if a=='queue_clear':self.cancel_queue();return '已取消歌手连续队列，当前歌曲继续播放。'
        if a=='seek':
            s=await media_state()
            if not s['available'] or (d.get('target') and s.get('bundle')!=d['target']):return '系统当前没有提供对应音乐应用的播放状态，请先播放歌曲或播客。'
            seconds=d['seconds']
            if seconds<0 or (s['duration'] and seconds>=s['duration']):return '这个位置超出当前音频长度。'
            # Recheck identity immediately before dispatch, avoid another app receiving seek.
            check=await media_state()
            if check.get('bundle')!=s['bundle'] or check.get('title')!=s['title']:return '播放器刚刚发生变化，请重试。'
            p=await asyncio.create_subprocess_exec(CLI,'seek',str(seconds),stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
            await asyncio.wait_for(p.wait(),6)
            for _ in range(8):
                await asyncio.sleep(.4);after=await media_state()
                if after.get('bundle')==s['bundle'] and after.get('title')==s['title'] and abs(after.get('elapsed',-100)-seconds)<5:return f'已跳到{seconds//60}分{seconds%60}秒。'
            return '已发送进度跳转指令，但系统尚未确认新的播放位置。'
        if a=='queue':
            current=await media_state()
            if current.get('bundle')==PODCAST:await native('podcast_pause')
            songs=await asyncio.to_thread(artist_songs,d['artist'],d.get('exclude_live',False))
            if not songs:return '没有找到匹配歌手的可选歌曲。'
            if d.get('exclude_title'):songs=[s for s in songs if simplify(s['title'])!=simplify(d['exclude_title'])]
            if not songs:return '没有找到其他歌曲。'
            if d.get('shuffle'):random.shuffle(songs)
            self.queue=songs;self.index=0;self.active=True;self.last_artist=d['artist']
            await self.play_index();await self.start()
            return f'已准备{d["artist"]}的{len(songs)}首'+('随机' if d.get('shuffle') else '连续')+'队列，发送播放'+songs[0]['title']+'。系统确认当前曲目后开始接续；版权限制仍由网易云处理。'
        if a=='queue_relative':
            if not self.queue:
                if self.last_artist:
                    current=await media_state()
                    return await self.execute('queue',{'artist':self.last_artist,'shuffle':True,'exclude_title':current.get('title','')})
                return '请先指定歌手，例如让电脑用网易云连续播放陶喆的歌。'
            self.active=True
        if a in ('queue_relative','queue_next','queue_previous'):
            self.index=(self.index+(-1 if a=='queue_previous' else 1))%len(self.queue)
            await self.play_index();await self.start()
            return '已发送播放'+self.queue[self.index]['artist']+'的'+self.queue[self.index]['title']+'的指令。'
        return None
    async def play_index(self):
        await send_song(self.queue[self.index]);self.seen=False;self.matches=0;self.near_end=False;self.missing_since=None;self.changed_at=time.monotonic()
    async def tick(self):
        focus_path=STATE/'focus_timer.json'
        try:focus=json.loads(focus_path.read_text())
        except (OSError,ValueError):focus=None
        if focus and time.time()>=focus['due']:
            focus_path.unlink(missing_ok=True)
            atomic_json(STATE/'notification.json',{'message':'二十五分钟专注计时已结束，可以休息一下。','created':time.time()})
        timer=self.timer()
        if timer and time.time()>=timer['due']:
            (STATE/'stop_timer.json').unlink(missing_ok=True)
            # After sleep/restart, pause once; never start playback as timer recovery.
            result=await self.stop_media();atomic_json(STATE/'last_timer.json',{'finished':time.time(),'message':result})
        if not self.active or not self.queue:return
        s=await media_state();expected=self.queue[self.index]
        if not s.get('available') and s.get('reason')=='no_media':
            if self.missing_since is None:self.missing_since=time.monotonic()
            if time.monotonic()-self.missing_since>15:
                self.cancel_queue();self.last_error='系统播放信息连续缺失，已停止自动接续'
            return
        self.missing_since=None
        matches=s.get('bundle')==MUSIC and simplify(s.get('title',''))==simplify(expected['title']) and simplify(expected['artist']) in simplify(s.get('artist',''))
        if matches:
            self.matches+=1
            self.seen=self.matches>=2
            if self.near_end and s['playing'] and s['elapsed']<5:
                await asyncio.sleep(.8)
                self.index=(self.index+1)%len(self.queue);await self.play_index();return
            if s['duration']>0 and s['playing'] and s['duration']-s['elapsed']<=5:self.near_end=True
            # Pausing at the end is still a pause, never a command to advance.
        elif self.seen:
            if self.near_end and s.get('bundle')==MUSIC:
                await asyncio.sleep(.8)
                self.index=(self.index+1)%len(self.queue);await self.play_index()
            else:self.cancel_queue() # Manual song/app switch wins over the custom queue.
        elif time.monotonic()-self.changed_at>35:
            self.cancel_queue();self.last_error='未确认队列曲目，已停止自动接续'
    async def supervise(self):
        while True:
            try:
                async with self.lock:await self.tick()
                self.last_tick=time.time()
            except asyncio.CancelledError:raise
            except Exception as exc:self.last_error=type(exc).__name__;LOG.warning('媒体定时检查失败: %s',type(exc).__name__)
            await asyncio.sleep(1)

MEDIA=MediaFeatures()
