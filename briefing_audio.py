"""On-demand cached, local synthesized news audio; one speaker playback request."""
import asyncio,hashlib,ipaddress,json,logging,os,secrets,socket,time
from datetime import datetime,timedelta
from pathlib import Path
from aiohttp import web
from news_briefing import TZ,voice_sections,briefing_sections
BASE=Path(__file__).resolve().parent
CACHE=BASE/'state/advanced/briefing_latest.json'
AUDIO=BASE/'state/advanced/briefing-audio'
LOG=logging.getLogger('xiaogpt')
# Microsoft Edge neural voice is primary; macOS say stays as the offline fallback.
EDGE_VOICE='zh-CN-XiaoxiaoNeural'
EDGE_RATE='+8%'
EDGE_TIMEOUT=90
SAY_VOICE='Meijia (中文（台湾）)'
SAY_RATE=195

def cached_news(now=None,max_age=30):
    now=now or datetime.now(TZ)
    try:
        data=json.loads(CACHE.read_text());generated=datetime.fromisoformat(data['generated_at'])
        if generated.tzinfo is None:return None
        if not timedelta(0)<=now-generated<=timedelta(minutes=max_age):return None
        groups=data['groups'];items=[a for g in groups for a in g['articles'] if a.get('voice_summary')]
        if not items:return None
        if any(not timedelta(0)<=now-datetime.fromisoformat(a['published_at'])<=timedelta(hours=48) for a in items):return None
        lines=voice_sections(groups)
        lines[0]='新闻速览，截至'+generated.astimezone(TZ).strftime('%m月%d日%H点%M分')+'。'+lines[0]
        return data,'\n'.join(lines)
    except (OSError,ValueError,KeyError,TypeError):return None

async def local_address():
    # Prefer a real LAN interface over a VPN/tunnel address.
    for interface in ('en0','en1','en2'):
        p=await asyncio.create_subprocess_exec('/usr/sbin/ipconfig','getifaddr',interface,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.DEVNULL)
        out,_=await p.communicate();host=out.decode().strip()
        try:
            ip=ipaddress.ip_address(host)
            if ip.is_private and not ip.is_loopback and not ip.is_link_local:return host
        except ValueError:pass
    raise RuntimeError('no_lan_address')

async def run_command(*args,timeout=35):
    p=await asyncio.create_subprocess_exec(*args,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:out,error=await asyncio.wait_for(p.communicate(),timeout)
    except BaseException:
        if p.returncode is None:p.kill();await p.communicate()
        raise
    if p.returncode:raise RuntimeError('audio_command_failed')
    return out

async def edge_to_mp3(text,path):
    import edge_tts
    await asyncio.wait_for(edge_tts.Communicate(text,EDGE_VOICE,rate=EDGE_RATE).save(str(path)),EDGE_TIMEOUT)
    if not path.exists() or path.stat().st_size<1024:raise RuntimeError('edge_empty_audio')

async def say_to_mp3(text,path,digest):
    txt=AUDIO/(digest+'.txt');aiff=AUDIO/(digest+'.aiff')
    txt.write_text(text);txt.chmod(0o600)
    try:
        await run_command('/usr/bin/say','-v',SAY_VOICE,'-r',str(SAY_RATE),'-f',str(txt),'-o',str(aiff))
        await run_command('/opt/homebrew/bin/ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(aiff),'-ar','24000','-ac','1','-b:a','64k',str(path))
    finally:txt.unlink(missing_ok=True);aiff.unlink(missing_ok=True)

async def duration_of(path):
    out=await run_command('/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(path))
    return float(out.decode().strip())

async def synthesize(text):
    AUDIO.mkdir(parents=True,exist_ok=True,mode=0o700)
    # Include both primary and fallback settings so a voice change never reuses old audio.
    digest=hashlib.sha256((f'edge:{EDGE_VOICE}:{EDGE_RATE}|say:{SAY_VOICE}:{SAY_RATE}:'+text).encode()).hexdigest()[:24]
    mp3=AUDIO/(digest+'.mp3');meta=AUDIO/(digest+'.json')
    if mp3.exists() and meta.exists():
        try:return mp3,float(json.loads(meta.read_text())['duration'])
        except (OSError,ValueError,KeyError,TypeError):
            mp3.unlink(missing_ok=True);meta.unlink(missing_ok=True)
    part=AUDIO/(digest+'.part.mp3');meta_part=AUDIO/(digest+'.part.json')
    try:
        try:
            await edge_to_mp3(text,part)
            provider,voice,rate='edge',EDGE_VOICE,EDGE_RATE
            LOG.info('早报音频由Edge合成: %s',EDGE_VOICE)
        except asyncio.CancelledError:raise
        except Exception as exc:
            LOG.warning('Edge语音合成失败，回退本地say: %s',type(exc).__name__)
            part.unlink(missing_ok=True)
            await say_to_mp3(text,part,digest)
            provider,voice,rate='say',SAY_VOICE,SAY_RATE
        duration=await duration_of(part)
        part.chmod(0o600);os.replace(part,mp3)
        meta_part.write_text(json.dumps({'duration':duration,'provider':provider,'voice':voice,'rate':rate},ensure_ascii=False))
        meta_part.chmod(0o600);os.replace(meta_part,meta)
        return mp3,duration
    finally:
        part.unlink(missing_ok=True);meta_part.unlink(missing_ok=True)

class BriefingAudio:
    def __init__(self,runtime):
        self.runtime=runtime;self.job=None;self.runner=None;self.urls={};self.port=None;self.host=None
    async def start_server(self):
        if self.runner:return
        self.host=await local_address()
        async def media(request):
            item=self.urls.get(request.match_info['token'])
            if not item or time.monotonic()>item['expires']:raise web.HTTPNotFound()
            if request.method=='GET':item['accessed'].set()
            return web.FileResponse(item['path'],headers={'Content-Type':'audio/mpeg','Cache-Control':'no-store'})
        app=web.Application();app.router.add_get('/news/{token}.mp3',media)
        runner=web.AppRunner(app,access_log=None);await runner.setup()
        try:
            site=web.TCPSite(runner,self.host,0);await site.start()
            self.port=site._server.sockets[0].getsockname()[1];self.runner=runner
        except BaseException:await runner.cleanup();raise
    async def refresh(self):
        start=time.monotonic()
        async for _ in briefing_sections(self.runtime.chatbot,self.runtime.config.gpt_options):pass
        cached=cached_news()
        if not cached:raise RuntimeError('no_fresh_news')
        path,duration=await synthesize(cached[1])
        LOG.info('新闻缓存准备完成: %.1f秒，音频%.1f秒',time.monotonic()-start,duration)
        return path,duration
    def ensure_job(self):
        if self.job is None or self.job.done():
            self.job=asyncio.create_task(self.refresh())
            self.job.add_done_callback(lambda t: LOG.warning('新闻缓存准备失败: %s',type(t.exception()).__name__) if not t.cancelled() and t.exception() else None)
        return self.job
    async def play(self):
        started=time.monotonic();cached=cached_news()
        if cached:
            path,duration=await synthesize(cached[1])
            LOG.info('早报命中30分钟缓存')
        else:
            # Start preparing immediately, then stay in this turn until the audio
            # is ready so playback begins without a second wake phrase.
            # Shield the job: a new command may interrupt waiting, but must not
            # cancel the expensive search/synthesis already in progress.
            job=self.ensure_job()
            await self.runtime.do_tts('正在准备今天的早报，完成后会自动播放。')
            try:
                path,duration=await asyncio.shield(job)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOG.warning('早报准备失败: %s',type(exc).__name__)
                await self.runtime.do_tts('这次早报没有准备成功，请稍后再试。')
                return
        await self.start_server()
        token=secrets.token_urlsafe(24);accessed=asyncio.Event()
        self.urls[token]={'path':path,'expires':time.monotonic()+duration+90,'accessed':accessed}
        url=f'http://{self.host}:{self.port}/news/{token}.mp3'
        try:
            accepted=await asyncio.wait_for(self.runtime.mina_service.play_by_url(self.runtime.device_id,url,_type=1),8)
            if not accepted:raise RuntimeError('speaker_rejected_audio')
            try:await asyncio.wait_for(accessed.wait(),10)
            except asyncio.TimeoutError:raise RuntimeError('speaker_did_not_fetch_audio')
            LOG.info('早报整段音频已被读取: 首次请求耗时%.1f秒，音频%.1f秒',time.monotonic()-started,duration)
            # Wait for one track; cancellation uses the existing new-command stop path.
            # A URL track can hand control back to the native news queue at EOF.
            # Do not wait on player status: that could be the resumed native track.
            await asyncio.sleep(duration+1)
            await self.finish_playback()
        finally:self.urls.pop(token,None)
    async def finish_playback(self):
        # This runs inside the active turn, so a new voice command cancels it
        # before the next turn starts. Never run a detached delayed stop.
        first=await self.runtime._stop_native_once()
        await asyncio.sleep(0.3)
        second=await self.runtime._stop_native_once()
        LOG.info('早报结束停止原厂接续: %s','接口成功' if first or second else '接口失败')
    async def close(self):
        if self.job and not self.job.done():
            self.job.cancel();await asyncio.gather(self.job,return_exceptions=True)
        if self.runner:await self.runner.cleanup()
