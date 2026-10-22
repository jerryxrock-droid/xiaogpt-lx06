"""Song metadata lookup and fixed NetEase desktop play links. No audio extraction."""
import asyncio
import base64
import json
import re
import urllib.parse
import urllib.request


def parse_song_command(query):
    q=re.sub(r'[\s，,。！？!?、：:；;《》“”\"\']','',query)
    if not re.search(r'mac|电脑|计算机',q,re.I):return None
    if re.search(r'^(?:问AI|请问)?(?:不要|别|不想|禁止)|如何|怎么|是否|能否|能不能|可以吗',q,re.I):return None
    # Only the fixed Mac + NetEase + play grammar accepts free-text song data.
    match=re.fullmatch(r'(?:问AI|请问)?(?:请帮我|帮我|请)?(?:让|在|控制)?(?:我的|本地)?(?:Mac|电脑|计算机)(?:上)?(?:打开|启动)?(?:用)?(?:网易云音乐|网易云|网易音乐)(?:并且|然后|并)?(?:给我)?播放(.{1,80})',q,re.I)
    if not match:return None
    name=match[1]
    if name in {'音乐','列表','播放列表'}:return None
    if name.endswith(('的歌曲','的歌')):
        artist=re.sub(r'的歌曲$|的歌$','',name)
        if artist:return ('artist',artist)
    return ('song',name)


def request(path,params=None):
    url='https://music.163.com/api/'+path
    if params:url+='?'+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0','Referer':'https://music.163.com/'})
    with urllib.request.urlopen(req,timeout=10) as response:
        data=json.loads(response.read(2_000_000))
    if data.get('code')!=200:raise ValueError('search unavailable')
    return data


def resolve(command):
    kind,name=command
    if kind=='artist':
        artists=request('search/get/web',{'s':name,'type':100,'limit':5}).get('result',{}).get('artists',[])
        artist=next((a for a in artists if a.get('name','').casefold()==name.casefold()),None)
        if not artist:return None
        songs=request('artist/'+str(int(artist['id']))).get('hotSongs',[])
        if not songs:return None
        song=songs[0]
    else:
        # Chinese singer 的 title is a search separator, never executable syntax.
        parts=name.split('的',1)
        keyword=' '.join(parts) if len(parts)==2 else name
        songs=request('search/get/web',{'s':keyword,'type':1,'limit':10}).get('result',{}).get('songs',[])
        full_title=[s for s in songs if s.get('name','').casefold()==name.casefold()]
        if full_title:
            songs=full_title
        elif len(parts)==2:
            singer,title=parts
            songs=[s for s in songs if any(a.get('name','').casefold()==singer.casefold() for a in s.get('artists',[])) and s.get('name','').casefold()==title.casefold()]
        else:
            exact=[s for s in songs if s.get('name','').casefold()==name.casefold()]
            songs=exact or songs
        if not songs:return None
        song=songs[0]
    song_id=int(song['id'])
    if song_id<=0:raise ValueError('invalid song id')
    artists='、'.join(a['name'] for a in song.get('artists',[]) if a.get('name'))
    payload=json.dumps({'type':'song','id':song_id,'cmd':'play'},separators=(',',':'))
    return 'orpheus://'+base64.b64encode(payload.encode()).decode(),artists,song['name']


async def play_song(command):
    try:
        result=await asyncio.to_thread(resolve,command)
        if result is None:return '没有找到匹配的歌曲或歌手，请把歌手和歌名说完整。'
        url,artist,title=result
        process=await asyncio.create_subprocess_exec('/usr/bin/open','-a','/Applications/NeteaseMusic.app',url,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.DEVNULL)
        await asyncio.wait_for(process.wait(),8)
        if process.returncode:return '网易云音乐未能启动，请检查Mac上的应用。'
        return f'已向Mac网易云发送播放{artist}的{title}的指令。实际播放以网易云的版权和会员权限为准。'
    except asyncio.CancelledError:raise
    except Exception:return '网易云歌曲搜索暂时失败，请稍后再试。'
