# NB频道 作品分享后端 — PythonAnywhere 部署指南

`product_share.html` 页面（作品上传/下载）需要本后端提供文件存储接口。
本目录包含完整的 Flask 应用，部署到 PythonAnywhere 后即可工作。

## 一、文件说明

| 文件 | 作用 |
|------|------|
| `app.py` | Flask 应用：`/upload`（上传）、`/download`（购买/下载）、`/uploads/<文件名>`（文件下载） |
| `wsgi.py` | PythonAnywhere 的 WSGI 入口 |
| `requirements.txt` | 依赖清单（flask、supabase） |

## 二、部署步骤（PythonAnywhere）

1. **把本目录代码上传到 PythonAnywhere**
   - 登录 https://www.pythonanywhere.com/ → Files 页
   - 在 `/home/你的用户名/` 下创建目录 `nb_api/`，把 `app.py`、`wsgi.py`、`requirements.txt` 上传进去
   - 上传后确认路径为：`/home/你的用户名/nb_api/app.py`、`/home/你的用户名/nb_api/wsgi.py`

2. **安装依赖**
   - 打开 Bash 控制台，执行：
     ```
     pip3 install --user flask supabase
     ```

3. **创建 Web 应用**
   - Web 页 → Add a new web app → 选 **Flask** → Python 3.10
   - 在 **Code** 区把 "WSGI configuration file" 路径改为：`/home/你的用户名/nb_api/wsgi.py`
   - 在 **Virtualenv** 区可以创建虚拟环境（可选，建议：`mkvirtualenv nb_api` 后 `pip install flask supabase`）

4. **配置静态文件目录（可选）**
   - 不需要额外配置，文件下载已由 `/uploads/<文件名>` 接口处理（附件方式）

5. **配置出站请求白名单（重要！）**
   - PythonAnywhere 免费版只允许访问白名单内的外部网站
   - 打开 https://www.pythonanywhere.com/account/allowed_hosts/ 把下面地址加入白名单：
     - `pbaafgjkwdbwcmsikcmg.supabase.co`（主 Supabase 项目）

6. **Reload 应用**（Web 页顶部绿色按钮）

7. **验证**
   - 浏览器访问 `https://你的用户名.pythonanywhere.com/health`，应返回 `{"ok": true, ...}`
   - 打开 `product_share.html`，登录后上传一个小文件测试

## 三、必须先执行 SQL 脚本

在 Supabase 后台（https://supabase.com/dashboard → 你的项目 → SQL Editor）执行：
`sql/product_share.sql`

该脚本会创建 `products`、`product_purchases` 表和相关 RPC 函数。
如果执行报错说函数/表已存在，请把脚本内容发给我，我根据你的实际结构调整。

## 四、常见问题

| 现象 | 原因与解决 |
|------|-----------|
| 上传报"网络错误" | 后端没部署成功，或 CORS 没生效（检查 Web 应用是否 Reload） |
| 上传报"写入数据库失败" | 没执行 SQL 脚本，或 RPC 名称不一致 |
| 下载付费作品提示余额不足 | NB币余额不够，去首页签到攒币 |
| 文件下载后打不开 | 文件上传时损坏（网络中断），重新上传 |
| PythonAnywhere 免费版限制 | 磁盘 512MB、每月出站流量有限，适合小文件分享 |

## 五、安全说明

- 所有数据库写入都通过 Supabase RPC（`create_product`、`purchase_product`）完成，
  不需要也不应该把 Supabase service_role key 放到前端。
- 上传文件以 UUID 重命名并以"附件下载"方式提供，避免上传 HTML 被浏览器直接执行。
- 上传身份靠 `X-User-Id` 头 + 后端校验用户存在性；完整防伪造需要迁移到 Supabase Auth（后续可做）。
