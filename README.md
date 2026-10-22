# xiaogpt-lx06

小爱音箱 Pro（LX06）打通大模型 + Mac 语音助手。

不刷机、不改动原厂小爱。Mac 通过轮询小米云端对话记录接管语音入口，把音箱变成大模型的语音终端，并控制 Mac 上的应用与个人数据。

## 架构

```
小爱唤醒说话 → 小米云端 ASR → 小米对话记录
                            ↓ Mac 每约 0.5 秒轮询
                触发词匹配（问AI / 电脑…）
                            ↓
        停止原厂播报 → 本地固定意图路由（优先） → 大模型
                            ↓                        ↓
        Swift 辅助程序 / AppleScript      Chat 流式 / Responses + web_search
                            ↓                        ↓
        网易云 · 小宇宙 · 日历 · 笔记      小米 TTS / 本地合成音频
```

关键取舍：

- Mac 不接收音箱麦克风音频，而是桥接小米云端对话记录，因此存在固有延迟和原厂抢答。
- 所有本地动作走**白名单**，不执行大模型生成的 shell 或任意 AppleScript。
- 联网搜索校验真实搜索调用和来源引用，失败时明确说明，不退回猜测。

## 已实现功能

| 分类 | 能力 |
| --- | --- |
| 问答 | 自由问答、连续对话（6 轮上下文）、追问、打断取消、日期时间本地回答 |
| 联网 | 强制联网、时效性问题自动搜索、引用校验、搜索记录留存 |
| 音乐 | 网易云点歌、歌手连续/随机队列、排除现场版、曲目查询、进度跳转、定时停止 |
| 歌单 | 读取公开歌单、按名称/收藏/喜欢播放、当前歌曲加入我喜欢、加入指定歌单 |
| 播客 | 小宇宙播放暂停、指定单集、最新一期、倍速、快进后退、文字稿摘要 |
| Mac 控制 | 打开应用与固定网页、音量/静音、灵感笔记、Apple 备忘录、日历读取与确认后创建、Keynote 翻页 |
| 场景 | 工作、音乐、播客、专注（25 分钟计时）、开会、睡眠 |
| 晨报 | 5 个新闻源、24/48 小时分层、原文时间核验、跨站去重、归档到 Obsidian、本地整段合成音频、30 分钟缓存、说完自动播放 |
| 工具 | 本地笔记关键词检索、网页收藏、助手自检 |

## 播报声音

晨报使用 Microsoft Edge 神经语音（`zh-CN-XiaoxiaoNeural`，语速 +8%）在 Mac 本地合成整段 MP3，通过局域网交给音箱播放；Edge 不可用时自动回退到 macOS 本地 `say`（美佳，语速 195）。普通问答仍走小米 TTS。

## 环境要求

- macOS 14+，Apple Silicon
- 小米账号与一台小爱音箱（LX06）
- Python 3.12–3.14
- Homebrew：`ffmpeg`、`nowplaying-cli`
- Edge 语音需要联网（仅晨报合成）

## 安装

```bash
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt

# 语音合成与媒体状态
brew install ffmpeg nowplaying-cli

cp config.example.json config.json
cp mac_features.example.json mac_features.json
cp music_library.example.json music_library.json

./.venv/bin/python credentials.py   # 交互式填入小米账号与 API Key
./.venv/bin/python manage.py discover   # 识别音箱 DID
./.venv/bin/python manage.py api        # 测试模型接口
./.venv/bin/python manage.py tts        # 测试音箱播报
./.venv/bin/python manage.py install    # 安装登录自启 LaunchAgent
./.venv/bin/python manage.py run        # 前台运行
```

## 权限

统一由 `XiaoGPT 控制中心.app` 承载，需要按需授予：

- **辅助功能**：网易云菜单、小宇宙播放器、Keynote、日历创建
- **屏幕录制**：仅用于在本机识别网易云“收藏到歌单”窗口与倍速刻度；不保存、不上传截图
- **日历 / 提醒事项**：读取与确认后创建
- **自动化**：Safari / Chrome 读取当前标签页标题与链接

在「系统设置 → 隐私与安全性」中为 `XiaoGPT 控制中心` 开启对应项目即可。

## 语音指令

详见 [`docs/`](docs/)：

- [Mac语音指令](docs/Mac语音指令.md) — 基础指令
- [扩展功能使用指南](docs/扩展功能使用指南.md) — 队列、定时停止、播客单集、追问、晨报、场景
- [收藏与播客功能说明](docs/收藏与播客功能说明.md) — 喜欢、歌单、倍速、摘要、网页收藏
- [控制中心与个人媒体库](docs/控制中心与个人媒体库.md) — 统一授权与迁移状态
- [早报连续音频与缓存](docs/早报连续音频与缓存.md) — 合成、缓存与播放
- [十二条晨报配置说明](docs/十二条晨报配置说明.md) / [三源晨报配置说明](docs/三源晨报配置说明.md)

示例：

```
小爱同学，问AI 上海今天天气
小爱同学，联网搜索 最近的 AI 政策变化
小爱同学，电脑用网易云连续播放陶喆的歌
小爱同学，电脑把这首加入通勤歌单
小爱同学，小宇宙播放忽左忽右最新一期
小爱同学，小宇宙调到一点五倍速
小爱同学，记一条灵感，周末去公园
小爱同学，读一下今天的日程
小爱同学，在我的笔记里搜索项目结论
小爱同学，开始早报
小爱同学，检查一下电脑助手
```

## 模块

| 模块 | 职责 |
| --- | --- |
| `manage.py` | 配置、认证、设备发现、接口测试、启动项与运行入口 |
| `runtime.py` | 对话记录轮询、打断与停止原厂播报、连续对话、通知 |
| `realtime_bot.py` | 意图分流、日期与闲聊、联网搜索、引用校验 |
| `mac_control.py` / `song_control.py` | 网易云动作与歌曲元数据查询 |
| `media_features.py` | 媒体状态、进度跳转、定时停止、连续队列守护 |
| `extended_control.py` | 应用、网页、音量、笔记、日历/提醒、Keynote、基础场景 |
| `assistant_features.py` | 晨报、场景、自检、笔记检索、播客发现 |
| `five_features.py` / `library_features.py` | 收藏、歌单、倍速、摘要、网页收藏 |
| `news_briefing.py` / `briefing_audio.py` | 新闻采集核验归档、本地语音合成与播放 |
| `*.swift` | 原生辅助程序源码（辅助功能、CoreAudio、EventKit、OCR） |

## 安全说明

- 凭据只保存在本机 `config.json`（权限 600），仓库内只有 `.example` 模板。
- `state/` 目录含认证令牌、对话记录、搜索痕迹与晨报内容，已被 `.gitignore` 排除，不要公开分享。
- 网页抓取有域名、重定向与体积限制；模型输出不作为可执行内容。
- 播客文字稿需语音确认后才发送给模型，且校验内容哈希。

## 致谢

上游项目 [yihong0618/xiaogpt](https://github.com/yihong0618/xiaogpt)（MIT）。本仓库在其基础上扩展了本地意图路由、原生辅助层、晨报与连续播报。