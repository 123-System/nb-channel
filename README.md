# NB频道官网

[![GitHub Pages](https://img.shields.io/badge/hosting-GitHub%20Pages%20%7C%20Cloudflare%20Pages%20%7C%20PythonAnywhere-blue)](https://github.nb-channel.top)
[![Auto Update Videos](https://github.com/NB-Channel/nb-channel/actions/workflows/auto-update.yml/badge.svg)](https://github.com/NB-Channel/nb-channel/actions/workflows/auto-update.yml)

NB频道（NoBook频道）官网，UP主 **NB搞事局** 的虚拟公司网站。
主要分享有趣的化学、物理实验和日常作死小技巧，欢迎关注！

- 🌐 导航页：https://nb-channel.top
- 🟢 GitHub 站：https://github.nb-channel.top
- ⛅ Cloudflare 站：https://cloudflare.nb-channel.top
- 🐍 PythonAnywhere 站：https://pythonanywhere.nb-channel.top

## 功能

- 📺 **视频展示**：自动同步 B 站合集视频（GitHub Actions 每日更新）
- 💬 **评论区**：登录/注册、@提及、点赞/点踩、热门/最新排序、楼层、举报、违禁词过滤
- 📈 **NB虚拟股票**：注册虚拟公司、NB币支持、**股票买入/卖出/持仓**、自动支持规则、K线图、市值排行
- 💰 **NB币体系**：每日签到、余额、消费
- 📦 **作品分享**：上传/下载作品（PythonAnywhere 后端 + Supabase 存储元数据）
- 🔔 **消息中心**：回复/提及通知、实时推送
- 🏢 **公司认证**：虚拟公司认证（蓝标）、举报与封禁管理

## 技术架构

| 组件 | 用途 |
|------|------|
| GitHub + GitHub Actions | 代码托管、视频数据每日自动更新 |
| Cloudflare Pages / GitHub Pages / PythonAnywhere | 静态站点托管（三站同步） |
| Supabase（PostgreSQL） | 用户、评论、股票、消息、作品等数据存储 + RPC |
| PythonAnywhere（Flask） | 作品分享文件上传/下载后端 |
| 图床小镇 / 蓝奏云 | 视频 / 产品文件存储 |

## 目录结构

```
├── .github/workflows/   # GitHub Actions（视频自动更新）
├── css/                 # 全局样式（亮/暗色主题变量）
├── data/                # 视频数据（由 update_videos.py 自动生成）
├── js/                  # 公共脚本
├── pythonanywhere/      # 作品分享 Flask 后端（部署见其 README）
├── sql/                 # Supabase 数据库脚本（表 + RPC 函数）
├── archive/             # 已废弃页面归档
└── *.html               # 各功能页面
```

## 本地开发

```bash
# 静态页面直接用任意 HTTP 服务器打开即可
python -m http.server 8000
# 或
npx serve .
```

数据库结构变更请修改 `sql/` 下的脚本并在 Supabase SQL Editor 中执行。
作品分享后端部署步骤见 `pythonanywhere/README.md`。

## 联系我们

- 邮箱：nbchannel@163.com
- B站：[NB搞事局（原NB实验室-作死）](https://space.bilibili.com/3493259582114264)

## 致谢

GitHub、Cloudflare 和 PythonAnywhere 提供网站托管服务；图床小镇提供视频托管服务；Supabase 提供后端数据库服务。
