"""Read public account playlist metadata and play in logged-in desktop client."""
import asyncio,base64,json,random,re,time
from pathlib import Path
from extended_control import clean_lead
from mac_prefix import normalize_mac_query
from song_control import request
BASE=Path(__file__).resolve().parent
_CACHE=None
_CACHE_AT=0

def parse_library(query):
    q,mac=clean_lead(normalize_mac_query(query));q=re.sub(r'[\s，,。？！!?《》“”]','',q)
    if not mac or re.match(r'不要|别|禁止|如果|如何|怎么',q):return None
    q=re.sub(r'^(?:打开|用)?网易云(?:音乐)?(?:并)?','',q)
    if q in {'列出我的歌单','我的歌单','查看我的歌单'}:return ('list',{'scope':'all'})
    if q in {'列出我的收藏歌单','我的收藏歌单','查看我的收藏歌单'}:return ('list',{'scope':'collected'})
    if q in {'播放我喜欢的音乐','播放我的喜欢','播放我的红心歌曲'}:return ('play',{'scope':'liked'})
    if q in {'播放我的收藏歌单','随机播放我的收藏歌单','播放我收藏的歌单'}:return ('play',{'scope':'collected','random':True})
    m=re.fullmatch(r'(?:播放|打开并播放)(?:我的)?(?:收藏的)?歌单(.{1,80})',q)
    if not m:m=re.fullmatch(r'(?:播放|打开并播放)(?:我的)?(.{1,80}?)歌单',q)
    if m:return ('play',{'scope':'named','name':m[1]})
    return None

def load_library():
    global _CACHE,_CACHE_AT
    config=json.loads((BASE/'music_library.json').read_text())
    if _CACHE and time.monotonic()-_CACHE_AT<300:return config,_CACHE
    uid=int(config['user_id']);rows=[]
    for offset in range(0,1000,100):
        r=request('user/playlist',{'uid':uid,'limit':100,'offset':offset})
        for p in r.get('playlist',[]):
            creator=int(p.get('creator',{}).get('userId',0))
            rows.append({'id':int(p['id']),'name':p['name'],'creator':creator,'collected':creator!=uid,'count':p.get('trackCount',0),'liked':p.get('specialType')==5 or p['name']==config['nickname']+'喜欢的音乐'})
        if not r.get('more'):break
    _CACHE=rows;_CACHE_AT=time.monotonic();return config,rows

async def execute_library(action,data):
    try:
        config,rows=await asyncio.to_thread(load_library)
        scope=data.get('scope')
        choices=[p for p in rows if scope=='all' or scope=='collected' and p['collected'] or scope=='liked' and p['liked'] or scope=='named']
        if action=='list':
            return '可读取到'+str(len(choices))+'个'+('收藏' if scope=='collected' else '')+'歌单。'+('；'.join(p['name'] for p in choices[:10]) if choices else '请确认歌单可公开访问。')+('。可说电脑网易云播放歌单，加歌单名称。' if choices else '')
        if scope=='named':
            name=data['name'];name=config.get('aliases',{}).get(name,name)
            choices=[p for p in rows if p['name'].casefold()==name.casefold()]
            if len(choices)>1:return '存在多个同名歌单，暂未播放；请先修改歌单名称以便准确区分。'
        if not choices:return '没有找到可读取的对应歌单。当前只读取账号公开可见的歌单，私密内容不会通过搜索猜测。'
        chosen=random.choice(choices) if data.get('random') else choices[0]
        detail=await asyncio.to_thread(request,'playlist/detail',{'id':chosen['id']})
        playlist=detail.get('playlist') or detail.get('result') or {}
        tracks=playlist.get('tracks') or []
        if not tracks:return '此歌单暂无可核对的曲目，未发送播放指令。'
        first=tracks[0];expected_title=first.get('name','');expected_artist={a.get('name','') for a in first.get('artists',first.get('ar',[]))}
        from media_features import MEDIA,media_state,MUSIC,PODCAST
        MEDIA.cancel_queue()
        before=await media_state()
        if before.get('bundle')==PODCAST:
            from extended_control import native
            await native('podcast_pause')
        payload={'type':'playlist','id':chosen['id'],'cmd':'play'}
        url='orpheus://'+base64.b64encode(json.dumps(payload,separators=(',',':')).encode()).decode()
        p=await asyncio.create_subprocess_exec('/usr/bin/open','-a','/Applications/NeteaseMusic.app',url,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
        await asyncio.wait_for(p.wait(),8)
        if p.returncode:return '网易云未接受歌单播放请求。'
        for _ in range(20):
            await asyncio.sleep(.35);state=await media_state()
            if state.get('bundle')==MUSIC and state.get('playing') and state.get('title')==expected_title and (not expected_artist or any(a in state.get('artist','') for a in expected_artist)):
                return '已在Mac网易云播放'+('随机选中的收藏歌单' if data.get('random') else '歌单')+'“'+chosen['name']+'”，当前是'+state['title']+'。'
        return '已向网易云发送歌单“'+chosen['name']+'”的播放指令，但未核实实际歌曲，不能确认已播放。请检查会员版权、加载状态或播放顺序。'
    except asyncio.CancelledError:raise
    except Exception:return '歌单读取或播放暂时失败，未能确认操作完成。'
