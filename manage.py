import asyncio, json, os, sys, plistlib, subprocess
from pathlib import Path
BASE=Path(__file__).resolve().parent
os.umask(0o077)
os.environ['XIAOGPT_MI_TOKEN_PATH']=str(BASE/'state/mi.token')
LABEL='local.xiaogpt.lx06'
def load():
    c=json.loads((BASE/'config.json').read_text())
    defaults=dict(hardware='LX06',bot='chatgptapi',keyword=['问AI','问ai','问 AI','问 Ai'],mute_xiaoai=True,stream=False,tts='mi',verbose=0,prompt='请用简洁自然的中文回答，控制在100字以内，不使用Markdown或链接。',gpt_options={'model':'MiniMax-M3','extra_body':{'reasoning_split':True,'thinking':{'type':'disabled'}}})
    return defaults|c
def save(c):
    (BASE/'config.json').write_text(json.dumps(c,ensure_ascii=False,indent=2))
    (BASE/'config.json').chmod(0o600)
async def otp(method):
    prompt='请输入小米'+str(method)+'验证码（短信或邮件）'
    script='text returned of (display dialog '+json.dumps(prompt,ensure_ascii=False)+' default answer "" with hidden answer with title "XiaoGPT 小米认证")'
    result=await asyncio.to_thread(subprocess.run,['osascript','-e',script],capture_output=True,text=True)
    if result.returncode: raise RuntimeError('验证码输入已取消')
    return result.stdout.strip()
async def discover(c):
    from aiohttp import ClientSession
    from xiaogpt.xiaogpt import MiAccount
    from miservice import MiNAService, MiIOService
    async with ClientSession() as s:
        account=MiAccount(s,c['account'],c['password'],str(BASE/'state/mi.token'),otp_callback=otp)
        devices=await MiNAService(account).device_list()
        matches=[d for d in devices if d.get('hardware','').upper()=='LX06']
        if not matches: raise RuntimeError('账号下没有发现 LX06')
        if len(matches)>1: raise RuntimeError('发现多台 LX06，需要明确选择设备')
        d=matches[0]
        did=d.get('miotDID')
        if not did:
            iodevs=await MiIOService(account).device_list()
            candidates=[x for x in iodevs if x.get('model','').lower().endswith('lx06')]
            if len(candidates)!=1: raise RuntimeError('DID 无法唯一匹配')
            did=candidates[0]['did']
        c['mi_did']=str(did); save(c)
        print('已识别 LX06，DID:',did)
async def api(c):
    from openai import AsyncOpenAI
    async with AsyncOpenAI(api_key=c['openai_key'],base_url=c['api_base'],timeout=60,max_retries=1) as client:
        response=await client.chat.completions.create(messages=[{'role':'user','content':'请只回复：小爱音箱连接测试成功。'}],**c['gpt_options'])
        answer=response.choices[0].message.content
        if not answer or '<think>' in answer: raise RuntimeError('API 没有返回干净的播报文本')
        print('MiniMax 测试回复:',answer)
        return answer
async def tts(c):
    from aiohttp import ClientSession
    from xiaogpt.xiaogpt import MiAccount
    from miservice import MiNAService
    async with ClientSession() as s:
        service=MiNAService(MiAccount(s,c['account'],c['password'],str(BASE/'state/mi.token')))
        devices=await service.device_list()
        device=next(d for d in devices if str(d.get('miotDID'))==c['mi_did'])
        result=await service.text_to_speech(device['deviceID'],'小爱音箱连接测试成功。请说，小爱同学，问AI，你好。')
        print('音箱播报接口返回:',result)
def install():
    target=Path.home()/'Library/LaunchAgents'/f'{LABEL}.plist'
    target.parent.mkdir(parents=True,exist_ok=True)
    spec={'Label':LABEL,'ProgramArguments':[str(BASE/'.venv/bin/python'),str(BASE/'manage.py'),'run'],'WorkingDirectory':str(BASE),'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':30,'StandardOutPath':str(BASE/'state/service.log'),'StandardErrorPath':str(BASE/'state/error.log'),'EnvironmentVariables':{'PYTHONUNBUFFERED':'1'},'Umask':63}
    target.write_bytes(plistlib.dumps(spec)); target.chmod(0o600)
    domain=f'gui/{os.getuid()}'
    subprocess.run(['launchctl','bootout',domain,str(target)],capture_output=True)
    subprocess.run(['launchctl','bootstrap',domain,str(target)],check=True)
    print('已设置登录自动启动:',target)
if __name__=='__main__':
    mode=sys.argv[1]; c=load();save(c)
    if mode=='discover': asyncio.run(discover(c))
    elif mode=='api': asyncio.run(api(c))
    elif mode=='tts': asyncio.run(tts(c))
    elif mode=='install':
        if not c.get('mi_did'): raise SystemExit('先完成设备识别')
        install()
    elif mode=='run':
        from xiaogpt.config import Config
        from xiaogpt.bot.chatgptapi_bot import ChatGPTBot
        ChatGPTBot.name = 'MiniMax'
        from runtime import LocalMiGPT as MiGPT
        async def run():
            print('当前模型:', c['gpt_options']['model'], flush=True)
            app=MiGPT(Config(**c))
            try: await app.run_forever()
            finally: await app.close()
        asyncio.run(run())
