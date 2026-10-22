"""Local latency adjustments; upstream package stays unchanged."""
import asyncio
import functools
import re
import json
from pathlib import Path
from assistant_features import ASSISTANT,parse_assistant
from media_features import MEDIA
from realtime_bot import RealtimeBot, FORCE_SEARCH
import time
from xiaogpt.xiaogpt import MiGPT
from aiohttp import ClientSession
from mac_control import parse_local_command as parse_mac_command

class LocalMiGPT(MiGPT):
    def __init__(self, config):
        super().__init__(config)
        self._pause_lock = asyncio.Lock()
        self._last_pause = 0.0
        self._briefing_audio=None

    @functools.cached_property
    def chatbot(self):
        return RealtimeBot.from_config(self.config)

    def _get_last_query(self, data):
        try:
            payload=json.loads(data.get('data',''))
            if isinstance(payload.get('records'),list):self.last_poll_success=time.time()
        except (ValueError,TypeError,AttributeError):pass
        record = super()._get_last_query(data)
        if record:
            query = record.get('query', '').strip()
            force_notice = bool(FORCE_SEARCH.search(query))
            mac_notice = parse_mac_command(query) is not None
            record['mac_notice']=mac_notice and (parse_assistant(query) or ('',))[0]!='followup'
            record['search_notice']=force_notice
            if FORCE_SEARCH.match(query) or mac_notice:
                # Keep the command after upstream removes the trigger prefix.
                record['original_query'] = query
                record['query'] = '问AI' + query
            if self.need_ask_gpt(record):
                age = max(0, time.time() - record.get('time', int(time.time()*1000))/1000)
                self.log.info('AI触发记录同步耗时约 %.2f 秒', age)
        return record

    async def poll_latest_ask(self):
        # Query at most twice a second, including HTTP time. Only the main
        # handler stops audio; the poller cannot race and stop our own TTS.
        async with ClientSession(cookie_jar=self.cookie_jar) as session:
            while True:
                await self.polling_event.wait()
                started = time.monotonic()
                session._cookie_jar = self.cookie_jar
                try:
                    await self.get_latest_ask_from_xiaoai(session)
                except asyncio.CancelledError:
                    raise
                except Exception as exc:
                    self.log.warning('语音记录轮询失败: %s', type(exc).__name__)
                    await asyncio.sleep(3)
                await asyncio.sleep(max(0.1, 0.5 - (time.monotonic() - started)))

    async def _stop_native_once(self):
        try:
            ok = await asyncio.wait_for(self.mina_service.player_stop(self.device_id), 1.5)
            if not ok:
                ok = await asyncio.wait_for(self.mina_service.player_pause(self.device_id), 1.5)
            return bool(ok)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            self.log.warning('停止原厂回复失败: %s', type(exc).__name__)
            return False

    async def stop_if_xiaoai_is_playing(self):
        # Called by upstream only for a matched AI turn or conversation control.
        # Complete both stops before any acknowledgement/model speech begins.
        async with self._pause_lock:
            if time.monotonic() - self._last_pause < 1:
                return
            started = time.monotonic()
            first = await self._stop_native_once()
            await asyncio.sleep(0.3)
            second = await self._stop_native_once()
            self._last_pause = time.monotonic()
            self.log.info('AI播报前停止原厂回复: %s，用时 %.2f 秒',
                          '接口成功' if first or second else '接口失败', self._last_pause - started)

    async def do_tts(self, value):
        if value.startswith('正在问MiniMax'):
            value = '正在操作Mac' if getattr(self, '_mac_control_notice', False) else ('正在联网搜索' if getattr(self, '_force_search_notice', False) else '正在问MiniMax')
        return await super().do_tts(value)


    async def ask_gpt(self,query):
        stream=self.chatbot.ask_stream(query,**self.config.gpt_options)
        try:
            async for message in stream:
                if message:yield self._normalize(message)
        finally:
            await stream.aclose()

    async def _briefing_segment(self,text):
        yield self._normalize(text)

    async def _process_turn(self,record):
        original=record.get('original_query',record.get('query','')).strip()
        query=re.sub(rf"^({'|'.join(map(re.escape,self.config.keyword))})",'',record.get('query',''),count=1,flags=re.I).strip(' ，,。')
        self._mac_control_notice=record.get('mac_notice',False)
        self._force_search_notice=record.get('search_notice',False)
        try:
            await self.stop_if_xiaoai_is_playing()
            command=parse_assistant(original)
            if command and command[0]=='cancel':
                answer=await ASSISTANT.handle(original,self.chatbot,self.config.gpt_options)
                await self.do_tts(answer)
                return
            if command and command[0]=='briefing':
                from briefing_audio import BriefingAudio
                if getattr(self,'_briefing_audio',None) is None:self._briefing_audio=BriefingAudio(self)
                try:await self._briefing_audio.play()
                except asyncio.CancelledError:raise
                except Exception as exc:
                    self.log.warning('早报整段播放失败: %s',type(exc).__name__)
                    await self.do_tts('这次新闻音频未能成功播放，请稍后重试。')
                # News is a completed listening session; do not re-wake the
                # speaker here, which can trigger another native interaction.
                return
            if not self.chatbot.has_history():query+=','+self.config.prompt
            await self.do_tts(f'正在问{self.chatbot.name}请耐心等待')
            await self.speak(self.ask_gpt(query))
            if self.in_conversation:await self.wakeup_xiaoai()
        except asyncio.CancelledError:
            self.log.info('当前回答已取消')
            raise
        except StopAsyncIteration:pass
        except Exception as exc:
            self.log.warning('回答处理失败: %s',type(exc).__name__)
            await self.do_tts('这次操作未完成，请稍后再试。')

    async def _notifications(self):
        from media_features import STATE
        path=STATE/'notification.json'
        while True:
            await asyncio.sleep(2)
            if getattr(self,'_turn_busy',False) or not path.exists():continue
            try:
                item=json.loads(path.read_text());path.unlink(missing_ok=True)
                if time.time()-item['created']<1800:await self.do_tts(item['message'])
            except asyncio.CancelledError:raise
            except (OSError,ValueError,KeyError):pass

    async def run_forever(self):
        await self.init_all_data()
        ASSISTANT.runtime=self
        self.last_poll_success=0
        await MEDIA.start()
        self.polling_event.set()
        poller=asyncio.create_task(self.poll_latest_ask())
        notifier=asyncio.create_task(self._notifications())
        active=None
        print('XiaoGPT扩展已启动；支持联网、Mac控制、连续对话与打断',flush=True)
        try:
            while True:
                record=await self.last_record.get()
                original=record.get('original_query',record.get('query','')).strip()
                control=original in (self.config.start_conversation,self.config.end_conversation)
                if self.in_conversation and time.monotonic()-getattr(self,'_conversation_activity',time.monotonic())>600:self.in_conversation=False
                if not control and not self.need_ask_gpt(record):continue
                if active and not active.done():
                    active.cancel()
                    try:await active
                    except asyncio.CancelledError:pass
                    # Force-stop previous TTS even when the normal 1s debounce applies.
                    self._last_pause=0
                    await self.stop_if_xiaoai_is_playing()
                if control:
                    self.in_conversation=original==self.config.start_conversation
                    self._conversation_activity=time.monotonic()
                    await self.stop_if_xiaoai_is_playing()
                    if self.in_conversation:
                        self.chatbot.history.clear()
                        await self.do_tts('已开始连续对话。说结束持续对话可以退出。')
                        await self.wakeup_xiaoai()
                    else:await self.do_tts('已结束连续对话。')
                    continue
                self._conversation_activity=time.monotonic()
                self._turn_busy=True
                active=asyncio.create_task(self._process_turn(record))
                self._active_task=active
                active.add_done_callback(lambda task:setattr(self,'_turn_busy',False) if getattr(self,'_active_task',None) is task else None)
        finally:
            poller.cancel();notifier.cancel()
            if active:active.cancel()
            await asyncio.gather(poller,notifier,*([active] if active else []),return_exceptions=True)
            if getattr(self,'_briefing_audio',None):await self._briefing_audio.close()
            await MEDIA.shutdown()
            ASSISTANT.runtime=None
