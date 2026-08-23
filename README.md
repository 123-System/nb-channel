# NB频道官网

> 🚀 自动同步测试：如果你在 PythonAnywhere 站看到这行字，说明 webhook 全链路已打通！（2026-08-16）

[![GitHub Pages](https://img.shields.io/badge/hosting-GitHub%20Pages%20%7C%20Cloudflare%20Pages%20%7C%20PythonAnywhere-blue)](https://github.nb-channel.top)
[![Auto Update Videos](https://github.com/NB-Channel/nb-channel/actions/workflows/auto-update.yml/badge.svg)](https://github.com/NB-Channel/nb-channel/actions/workflows/auto-update.yml)

NB频道（NoBook频道）官网，UP主 **NB搞事局** 的虚拟公司网站。
主要分享有趣的化学、物理实验和日常作死小技巧，欢迎关注！

- 🌐 导航页：https://nb-channel.top
- 🟢 GitHub 站：https://github.nb-channel.top
- ⛅ Cloudflare 站：https://cloudflare.nb-channel.top
- 🐍 PythonAnywhere 站：https://pythonanywhere.nb-channel.top

## ✨ 功能

- 🎬 **视频展示**：自动同步 B 站合集视频（GitHub Actions 每日更新）
- 💬 **评论区**：登录/注册、@提及、发图片、蓝色链接、点赞/点踩、热门/最新排序、楼层、举报、违禁词过滤（三层拦截）
- 📈 **NB虚拟股票**：注册虚拟公司、NB币支持、买入/卖出/持仓（交易模型 v2，买卖不改市值）、自动支持规则、K线图、市值排行、破产
- 💰 **NB币体系**：每日签到（连续奖励）、随机金币彩蛋、成就徽章、幸运转盘
- 👥 **好友与私信**：加好友、实时聊天（Realtime + 轮询兜底）、图片消息、会话管理
- 🛍️ **作品分享**：上传/下载作品、付费购买（给NB币 / 加市值两种支付）、编辑/删除
- 🔔 **消息中心**：回复/提及通知、私信列表、评论跳转定位
- 🏢 **公司认证**：虚拟公司认证（蓝标）、举报与封禁管理
- 🎨 **新版/旧版双界面**：玻璃拟态官网风 / 经典卡片风，偏好云端保存（profiles.ui_version），登录后自动跳转对应版本

## 🏗️ 技术架构

| 组件 | 用途 |
|------|------|
| GitHub + GitHub Actions | 代码托管、视频数据每日自动更新 |
| Cloudflare Pages / GitHub Pages / PythonAnywhere | 静态站点托管（三站同步） |
| Supabase（PostgreSQL） | 用户、评论、股票、消息、作品等数据存储 + RPC + pg_cron 定时任务 |
| PythonAnywhere（Flask） | 作品上传/下载、图片上传、公开 API |
| Supabase Storage | 头像、图片、作品文件存储 |
| 图床小镇 / 蓝奏云 | 视频 / 产品文件存储 |

## 📁 目录结构

```
├── .github/workflows/   # GitHub Actions（视频自动更新）
├── css/                 # 样式（style.css 通用、premium.css 新版细节、ui-new.css 新版静态合并）
├── data/                # 视频数据（由 update_videos.py 自动生成）
├── js/                  # 脚本（common.js 公共、ui-nav.js 新版界面驱动、videos.js 等）
├── pythonanywhere/      # 作品分享 Flask 后端（部署见其 README，密钥走环境变量）
├── sql/                 # Supabase 数据库脚本（表 + RLS + RPC + pg_cron）
├── preview/             # 新版界面模板存档
├── archive/             # 已废弃页面归档
└── *.html / *-new.html  # 旧版页面 / 新版页面（双界面）
```

## 🔐 安全模型（重要）

- 前端使用 **Supabase anon key**（公开设计）：所有写操作走 **SECURITY DEFINER RPC**，数据库层校验权限（RLS 禁止匿名直接写表）
- **密钥永不入仓库**：Supabase service key、S3 密钥、Webhook secret 全部走服务器环境变量 / WSGI 配置
- 后端接口带限流（60 次/分钟/IP）与文件类型校验

## 🚀 部署要点

1. **Supabase**：按顺序执行 `sql/` 下的脚本（建表 → RLS → RPC → pg_cron 定时任务）
2. **PythonAnywhere**：部署 `pythonanywhere/app.py`，配置环境变量，配置 GitHub Webhook 自动拉取同步（改 app.py 后需手动 Reload）
3. **双界面机制**：`*-new.html` 由根目录 `gen_new.ps1` 生成（正式页面 + ui-nav 静态化 + 静态新版样式），修改正式页面或样式后重新生成即可
4. **本地预览**：
```bash
python -m http.server 8000   # 或 npx serve .
```

## 📄 许可

[MIT License](LICENSE) © NB频道（NB搞事局）

## 联系我们

- 邮箱：nbchannel@163.com
- B站：[NB搞事局（原NB实验室-作死）](https://space.bilibili.com/3493259582114264)

## 致谢

GitHub、Cloudflare 和 PythonAnywhere 提供网站托管服务；图床小镇提供视频托管服务；Supabase 提供后端数据库服务。
