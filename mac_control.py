"""Allowlisted local music commands, executed without any model or shell code."""
from __future__ import annotations
import asyncio
import json
import logging
import re
import time
import uuid
from pathlib import Path
from extended_control import EXTENSIONS, parse_extension
from song_control import parse_song_command, play_song
from mac_prefix import normalize_mac_query,has_mac_prefix

BASE=Path(__file__).resolve().parent
HELPER=BASE/'XiaoGPT Mac控制.app'
STATE=BASE/'state/mac-control'
LOG=logging.getLogger('xiaogpt')
MAC=re.compile(r'mac|电脑|计算机',re.I)
NEGATED=re.compile(r'不要|别|不想|不准|禁止|如果|假如|如何|怎么|是否|能否|能不能|可以吗|教程|示例|代码|故事|解释')
WORDS=['问ai','控制','请问','请帮我','帮我','请','让','在','我的','本地','上','mac','电脑','计算机',
       '网易云音乐','网易云','网易音乐','打开','启动','并且','然后','并','和','开始','继续','恢复',
       '播放','音乐','放歌','听歌','暂停','停止','下一首','下一个','切歌','上一首','上一个','一下','吧']
TOKENS=re.compile('|'.join(map(re.escape,sorted(WORDS,key=len,reverse=True))),re.I)

def parse_mac_command(query):
    song=parse_song_command(query)
    if song:return song
    q=re.sub(r'[\s，,。！？!?、：:；;]','',query)
    if not MAC.search(q) or NEGATED.search(q):return None
    if not (re.search(r'网易云|网易音乐',q) or re.search(r'播放音乐|暂停音乐|停止音乐|放歌|听歌',q)):
        return None
    # Unknown words (including song titles or command/code fragments) never become actions.
    if TOKENS.sub('',q):return 'unsupported'
    if re.search(r'暂停|停止',q):return 'pause'
    if re.search(r'下一首|下一个|切歌',q):return 'next'
    if re.search(r'上一首|上一个',q):return 'previous'
    if re.search(r'播放|放歌|听歌|继续|恢复',q):return 'play'
    if re.search(r'打开|启动',q):return 'open'
    return None

class MacMusicController:
    def __init__(self):
        self.lock=asyncio.Lock()
        self.last=None
        self.last_time=0.0
        self.last_message=''

    async def handle(self,query):
        extended=await EXTENSIONS.handle(query)
        if extended is not None:return extended
        action=parse_mac_command(query)
        if action is None:return None
        if action=='unsupported':
            return '请说，让电脑用网易云播放陶喆的歌，或者让电脑用网易云播放陶喆的普通朋友。'
        async with self.lock:
            if self.last==action and time.monotonic()-self.last_time<2:
                return self.last_message
            if isinstance(action,tuple):
                from media_features import MEDIA
                MEDIA.cancel_queue()
                if action[0]=='artist':MEDIA.last_artist=action[1]
                elif '的' in action[1]:MEDIA.last_artist=action[1].split('的',1)[0]
            result=await play_song(action) if isinstance(action,tuple) else await self.execute(action)
            self.last=action;self.last_time=time.monotonic();self.last_message=result
            return result

    async def execute(self,action):
        if action not in {'open','play','pause','next','previous'}:
            return '不支持此Mac操作。'
        from native_bridge import center_enabled,CENTER
        helper=CENTER if center_enabled() else HELPER
        if not helper.exists():return 'Mac控制辅助程序尚未安装。'
        STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
        request_id=str(uuid.uuid4()).upper()
        result_path=STATE/(request_id+'.json')
        try:
            process=await asyncio.create_subprocess_exec('/usr/bin/open','-g','-n','-a',str(helper),'--args',action,request_id,
                  stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE)
            await asyncio.wait_for(process.communicate(),8)
            if process.returncode:return 'Mac控制辅助程序未能启动。'
            deadline=time.monotonic()+25
            while not result_path.exists() and time.monotonic()<deadline:
                await asyncio.sleep(.15)
            if not result_path.exists():return 'Mac控制暂未收到执行结果，请检查网易云音乐和辅助功能权限。'
            result=json.loads(result_path.read_text())
            if result.get('request_id')!=request_id or result.get('action')!=action:
                return 'Mac操作结果无法匹配，请重试。'
            LOG.info('Mac音乐控制: %s，%s',action,result.get('status','unknown'))
            for old in sorted(STATE.glob('*.json'),key=lambda p:p.stat().st_mtime,reverse=True)[30:]:
                old.unlink(missing_ok=True)
            return result.get('message','Mac控制未返回结果。')
        except asyncio.CancelledError:raise
        except Exception as exc:
            LOG.warning('Mac音乐控制失败: %s',type(exc).__name__)
            return 'Mac控制暂时失败，请稍后重试。'

CONTROLLER=MacMusicController()


def parse_local_command(query):
    from assistant_features import parse_assistant
    original=query
    query=normalize_mac_query(query)
    return parse_assistant(query) or parse_extension(query) or parse_mac_command(query) or (('mac_prefix_unknown',{}) if has_mac_prefix(original) else None)
