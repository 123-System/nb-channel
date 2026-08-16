# NB频道 PythonAnywhere 一体化部署指南

这个 Flask 应用同时承担三件事：
1. **网站本体**：服务 NB频道 的静态页面（`/` → 网站文件目录）
2. **作品分享后端**：`/upload`（上传到 S3）、`/download`（购买/下载）、`/files/<key>`（从 S3 代理下载）
3. **GitHub 自动同步**：`/webhook` 收到 push 通知后自动 `git pull`

> ⚠️ 重要：原来 GitHub Webhook 投递到 `https://nbchannel.pythonanywhere.com/webhook` 一直返回 404，
> 因为旧站点是纯静态站、没有这个端点。部署本应用后，404 会消失，自动同步才能真正工作。

---

## 〇、S3 存储配置（作品文件存放）

作品文件存在**数据胶囊 S3**（`nb-products` 桶），PythonAnywhere 只做中转代理（桶保持私有，下载走 `/files/<key>`）。

1. **重新生成 S3 密钥**（旧密钥已泄露过，务必轮换）：
   登录数据胶囊控制台 → 删除旧的 Access Key → 新建一对
2. **配置环境变量**（Web 面板 → 你的 app → Environment variables）：

   | 变量 | 值 |
   |------|-----|
   | `S3_ENDPOINT` | `https://s3.cstcloud.cn` |
   | `S3_REGION` | `us-east-1` |
   | `S3_BUCKET` | `nb-products` |
   | `S3_ACCESS_KEY` | 你的新 Access Key |
   | `S3_SECRET_KEY` | 你的新 Secret Key |

3. 若未配置 S3 密钥，上传会**自动退回本地磁盘存储**（`pythonanywhere/uploads/`，仅 512MB 限额，不建议长期使用）

---

## 一、把网站代码放进 PythonAnywhere（并变成 git 仓库）

1. 登录 PythonAnywhere → **Bash 控制台**，执行（把 `/home/nbchannel` 换成你的实际用户名路径）：

```bash
cd /home/nbchannel
# 如果网站文件已经直接在 /home/nbchannel/ 下（旧静态站），先备份再 clone
mv nb-channel nb-channel_backup 2>/dev/null   # 若存在旧目录则改名备份
git clone https://github.com/NB-Channel/nb-channel.git
```

2. **配置 git 自动拉取凭据**（二选一）：

   **方式 A（推荐，SSH 密钥）**：
   ```bash
   cd /home/nbchannel/nb-channel
   git remote set-url origin git@github.com:NB-Channel/nb-channel.git
   cd ~
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "pythonanywhere-sync"
   cat ~/.ssh/id_ed25519.pub
   # 把输出的公钥添加到 GitHub：Settings → SSH and GPG keys → New SSH key
   ```
   **方式 B（HTTPS + token）**：
   ```bash
   cd /home/nbchannel/nb-channel
   git remote set-url origin https://<你的GitHub用户名>:<PersonalAccessToken>@github.com/NB-Channel/nb-channel.git
   # token 创建：GitHub → Settings → Developer settings → Personal access tokens（repo 权限）
   ```

3. 验证：`cd /home/nbchannel/nb-channel && git pull` 应能正常拉取。

## 二、部署 Flask 应用

1. 上传本目录的 `app.py`、`wsgi.py`、`requirements.txt` 到 `/home/nbchannel/nb_api/`（若已通过 git clone 则跳过，仓库内已有）
2. Bash 安装依赖：
   ```bash
   pip3 install --user flask supabase boto3
   ```
3. Web 面板 → 新建 web app（**Flask、Python 3.10**；若已有 web app 则编辑它）
   - **WSGI configuration file** 改为：`/home/nbchannel/nb_api/wsgi.py`
4. **配置环境变量**（Web 面板 → Web → 你的 app → **Environment variables**）：
   | 变量 | 值 | 说明 |
   |------|-----|------|
   | `SITE_DIR` | `/home/nbchannel/nb-channel` | 网站代码目录（就是上面 clone 的）|
   | `GITHUB_WEBHOOK_SECRET` | 你自定义的一串随机字符 | 与 GitHub webhook 里配置的 secret 一致 |
5. **配置出站白名单**（重要！）：
   https://www.pythonanywhere.com/account/allowed_hosts/ 加入 `pbaafgjkwdbwcmsikcmg.supabase.co`
6. **Reload** web app。

## 三、配置 GitHub Webhook

1. 打开 https://github.com/NB-Channel/nb-channel/settings/hooks → **Add webhook**
2. 填写：
   - **Payload URL**：`https://nbchannel.pythonanywhere.com/webhook`
   - **Content type**：`application/json`
   - **Secret**：与上面的 `GITHUB_WEBHOOK_SECRET` 相同
   - **Which events**：Just the push event
3. 保存后，GitHub 会立即发送一次测试投递，应显示绿色 ✓（200）

## 四、验证

- 访问 `https://nbchannel.pythonanywhere.com/health` → `{"ok": true, ...}`
- 访问 `https://nbchannel.pythonanywhere.com/` → 网站首页正常
- 访问 `https://nbchannel.pythonanywhere.com/webhook`（GET）→ 405（方法不允许，说明端点存在 ✅）
- 在 GitHub 上 push 一次 → Webhook 投递记录 200 → 等几秒刷新 PythonAnywhere 站，代码已更新

## 五、注意事项

- **自动同步只更新网站代码目录**；本后端（nb_api）更新后需要手动在 Web 面板点 Reload
- `git pull` 在后台执行（不阻塞 webhook 响应），约 1-3 秒完成
- 免费版 PythonAnywhere 出站流量/磁盘有限，作品文件（uploads/）请勿上传过大文件
- 若 `SITE_DIR` 路径不对，网站会 404，检查环境变量是否生效（Web 面板设置后必须 **Reload** 才生效）
