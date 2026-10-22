import json, os, subprocess
from pathlib import Path
base=Path(__file__).resolve().parent
os.umask(0o077)
def ask(label, hidden=False, default=''):
    script='text returned of (display dialog '+json.dumps(label,ensure_ascii=False)+' default answer '+json.dumps(default)+' with title "XiaoGPT 本机配置"'+(' with hidden answer' if hidden else '')+')'
    result=subprocess.run(['osascript','-e',script],capture_output=True,text=True)
    if result.returncode: raise SystemExit('输入已取消，未保存配置。')
    return result.stdout.strip()
values={
 'account':ask('请输入绑定小爱音箱的小米账号（手机号或 ID）'),
 'password':ask('请输入小米账号密码',True),
 'openai_key':ask('请输入 MiniMax API Key（仅保存在本机权限 600 的配置文件）',True),
 'api_base':ask('MiniMax OpenAI 兼容接口地址；国内默认如下，国际账号请改为 https://api.minimax.io/v1',default='https://api.minimax.cn/v1'),
}
if not all(values.values()): raise SystemExit('有空字段，未保存。')
config=base/'config.json'
existing=json.loads(config.read_text()) if config.exists() else {}
existing.update(values)
config.write_text(json.dumps(existing,ensure_ascii=False,indent=2))
config.chmod(0o600)
print('凭据已保存（内容未输出）。')
