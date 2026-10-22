"""Normalize explicit Mac voice prefixes into existing allowlisted commands."""
import re

PREFIX=re.compile(r'^(?:(?:问\s*AI|请问)[，,\s]*)?(电脑|Mac)(?=$|[\s，,。:：\u4e00-\u9fff])[，,\s:：]*',re.I)

def has_mac_prefix(query):return bool(PREFIX.match(query.strip()))

def normalize_mac_query(query):
    q=query.strip()
    m=PREFIX.match(q)
    if not m:return query
    body=q[m.end():].strip(' ，,。:：')
    # Only reshape syntax. The existing fixed-action parsers still authorize it.
    if re.match(r'不要|别|禁止|不准|不想|如果|假如',body):return '让电脑'+body
    if body in ('下一首','上一首','切歌'):return '让电脑网易云'+body
    if body in ('播放','继续','继续播放','恢复播放','暂停','停止','暂停音乐','停止音乐','播放音乐'):
        action='暂停' if body.startswith(('暂停','停止')) else '播放'
        return '让电脑'+action+'网易云音乐'
    if re.match(r'(?:连续|随机)?播放',body) and not re.search(r'网易云|网易音乐|小宇宙',body):
        return '让电脑用网易云'+body
    # Media metadata, timers and followups use standalone local command syntax.
    if re.match(r'这首|这是什么歌|当前歌曲|正在播放什么|现在播放什么歌|换一首他的歌|再放一首他的歌|再来一首他的歌|播放他的另一首歌|取消连续播放|结束连续播放|取消歌手队列|取消定时停止|取消停止播放计时|取消音乐定时|从|跳到|跳转到|(?:半小时|[0-9零〇一二两三四五六七八九十百]+(?:分钟|小时))后',body):return body
    return '让电脑'+body
