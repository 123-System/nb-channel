# -*- coding: utf-8 -*-
"""
NB频道 - PythonAnywhere 一体化 Flask 应用
====================================================
功能：
  GET  /                网站本体（静态文件服务，需配置 SITE_DIR）
  POST /upload          上传作品（存 S3，multipart/form-data + 头 X-User-Id）
  POST /download        下载/购买作品（JSON + 头 X-User-Id）
  GET  /files/<key>     从 S3 代理下载文件（附件方式）
  POST /webhook         GitHub push 后自动 git pull 同步代码
  GET  /health          健康检查

部署前必读：pythonanywhere/README.md
依赖：pip install flask supabase boto3
"""
import os
import re
import uuid
import hmac
import hashlib
import datetime
import subprocess

from flask import Flask, request, jsonify, send_from_directory, Response
from supabase import create_client, Client

try:
    import boto3
    from botocore.client import Config as BotoConfig
    from botocore.exceptions import ClientError as BotoClientError
except ImportError:
    boto3 = None

# ==================== 配置 ====================
SUPABASE_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co'
SUPABASE_ANON_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg'
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50 MB
ALLOWED_EXT = re.compile(r'^[a-zA-Z0-9]{1,10}$')  # 扩展名白名单格式

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
UPLOAD_DIR = os.path.join(BASE_DIR, 'uploads')  # 兼容旧版本地存储（新文件全部走 S3）
os.makedirs(UPLOAD_DIR, exist_ok=True)

# 网站静态文件目录（git 仓库目录，供 / 和 /webhook 使用）
SITE_DIR = os.environ.get('SITE_DIR', '/home/nbchannel/nb-channel')
# GitHub webhook secret（与 GitHub 仓库 Webhooks 配置保持一致；不配置则跳过校验）
GITHUB_WEBHOOK_SECRET = os.environ.get('GITHUB_WEBHOOK_SECRET', '')

# ---------- S3 存储配置（从环境变量读取，密钥不要写进代码/仓库） ----------
S3_ENDPOINT = os.environ.get('S3_ENDPOINT', 'https://s3.cstcloud.cn')
S3_REGION = os.environ.get('S3_REGION', 'us-east-1')
S3_BUCKET = os.environ.get('S3_BUCKET', 'nb-products')
S3_ACCESS_KEY = os.environ.get('S3_ACCESS_KEY', '')
S3_SECRET_KEY = os.environ.get('S3_SECRET_KEY', '')

s3_client = None
if boto3 is not None and S3_ACCESS_KEY and S3_SECRET_KEY:
    s3_client = boto3.client(
        's3',
        endpoint_url=S3_ENDPOINT,
        region_name=S3_REGION,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        config=BotoConfig(proxies={}),  # 禁用代理（关键）
    )

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = MAX_FILE_SIZE

supabase: Client = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)

# 允许的跨域来源（你的三个站点 + PythonAnywhere 站）
ALLOWED_ORIGINS = {
    'https://nb-channel.top',
    'https://www.nb-channel.top',
    'https://github.nb-channel.top',
    'https://cloudflare.nb-channel.top',
    'https://pythonanywhere.nb-channel.top',
    'https://nbchannel.pythonanywhere.com',
    'https://nb-channel.pages.dev',
}

def _cors_headers():
    origin = request.headers.get('Origin', '')
    allow = origin if origin in ALLOWED_ORIGINS else ''
    return {
        'Access-Control-Allow-Origin': allow if allow else '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, X-User-Id',
        'Access-Control-Max-Age': '86400',
    }

@app.after_request
def after_request(resp):
    for k, v in _cors_headers().items():
        resp.headers[k] = v
    return resp

# ==================== 工具函数 ====================

def get_user_id():
    """从请求头获取用户 ID 并校验其存在。返回 (user_id, error_msg)。"""
    uid = request.headers.get('X-User-Id', '').strip()
    if not uid:
        return None, '缺少 X-User-Id 请求头'
    try:
        res = supabase.table('profiles').select('id').eq('id', uid).maybe_single().execute()
    except Exception as e:
        return None, '后端数据库连接失败: %s' % e
    if not res.data:
        return None, '用户不存在或登录已失效'
    return res.data['id'], None


def safe_filename(original_name):
    """生成安全的存储文件名：uuid + 白名单扩展名。"""
    ext = ''
    if '.' in original_name:
        cand = original_name.rsplit('.', 1)[1]
        if ALLOWED_EXT.match(cand):
            ext = '.' + cand.lower()
    return str(uuid.uuid4().hex) + ext


def rpc(name, params):
    """调用 Supabase RPC，返回 (data, error)。"""
    try:
        res = supabase.rpc(name, params).execute()
        return res.data, None
    except Exception as e:
        return None, str(e)


# ==================== 接口 ====================

@app.route('/health')
def health():
    return jsonify({'ok': True, 'time': datetime.datetime.now().isoformat()})


@app.route('/upload', methods=['POST'])
def upload():
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    title = (request.form.get('title') or '').strip()
    description = (request.form.get('description') or '').strip()
    price_str = (request.form.get('price') or '0').strip()
    file = request.files.get('file')

    if not title:
        return jsonify({'success': False, 'message': '请输入作品标题'}), 400
    if len(title) > 100:
        return jsonify({'success': False, 'message': '标题不能超过100字'}), 400
    if len(description) > 1000:
        return jsonify({'success': False, 'message': '简介不能超过1000字'}), 400
    if not file or file.filename == '':
        return jsonify({'success': False, 'message': '请选择要上传的文件'}), 400

    try:
        price = int(price_str)
    except ValueError:
        return jsonify({'success': False, 'message': '定价必须是数字'}), 400
    if price < 0 or price > 999999999:
        return jsonify({'success': False, 'message': '价格需在 0~999999999 之间'}), 400

    # 大小校验（Flask 的 MAX_CONTENT_LENGTH 超限会抛 413，这里再兜底）
    file.seek(0, os.SEEK_END)
    size = file.tell()
    file.seek(0)
    if size > MAX_FILE_SIZE:
        return jsonify({'success': False, 'message': '文件不能超过 50 MB'}), 400

    # ---------- 存储：S3 优先，未配置 S3 时退回本地磁盘 ----------
    key = safe_filename(file.filename)
    if s3_client is not None:
        try:
            s3_client.put_object(
                Bucket=S3_BUCKET,
                Key=key,
                Body=file.stream,
                ContentType=file.mimetype or 'application/octet-stream',
            )
        except Exception as e:
            return jsonify({'success': False, 'message': '上传到对象存储失败: %s' % e}), 500
        # 下载走 PythonAnywhere 代理（/files/<key>），桶保持私有
        file_url = request.host_url.rstrip('/') + '/files/' + key
    else:
        filepath = os.path.join(UPLOAD_DIR, key)
        try:
            file.save(filepath)
        except Exception as e:
            return jsonify({'success': False, 'message': '文件保存失败: %s' % e}), 500
        file_url = request.host_url.rstrip('/') + '/uploads/' + key

    data, rpc_err = rpc('create_product', {
        'p_user_id': user_id,
        'p_title': title,
        'p_description': description,
        'p_price': price,
        'p_file_url': file_url,
        'p_file_name': file.filename,
        'p_file_size': size,
        'p_mime_type': file.mimetype or '',
    })
    if rpc_err or not data or data.get('success') is not True:
        # 数据库写入失败时清理已上传的文件，避免孤儿文件
        try:
            if s3_client is not None:
                s3_client.delete_object(Bucket=S3_BUCKET, Key=key)
            else:
                os.remove(filepath)
        except Exception:
            pass
        msg = (rpc_err or (data and data.get('message')) or '写入数据库失败，请检查 SQL 脚本是否已执行')
        return jsonify({'success': False, 'message': msg}), 500

    return jsonify({'success': True, 'message': '发布成功', 'product_id': data.get('id')})


@app.route('/download', methods=['POST'])
def download():
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    body = request.get_json(silent=True) or {}
    try:
        product_id = int(body.get('product_id'))
    except (TypeError, ValueError):
        return jsonify({'success': False, 'message': '无效的作品 ID'}), 400

    # 1. 查产品信息（价格/作者/文件地址）
    try:
        prod = supabase.table('products').select('id, price, author_id, file_url, status') \
            .eq('id', product_id).maybe_single().execute()
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    if not prod.data or prod.data.get('status') != 'active':
        return jsonify({'success': False, 'message': '作品不存在或已下架'}), 404

    price = prod.data['price'] or 0
    author_id = prod.data['author_id']

    # 2. 作者本人：直接返回下载地址（不扣费）
    if str(author_id) == str(user_id):
        return jsonify({'success': True, 'file_url': prod.data['file_url'], 'message': '你的作品，直接下载'})

    # 3. 免费作品：走 download_product（记录下载次数）
    if price == 0:
        data, rpc_err = rpc('download_product', {'p_product_id': product_id, 'p_user_id': user_id})
        if rpc_err:
            return jsonify({'success': False, 'message': '后端错误: %s' % rpc_err}), 500
        if not data or data.get('success') is not True:
            return jsonify({'success': False, 'message': (data and data.get('message')) or '下载失败'}), 400
        return jsonify({'success': True, 'file_url': data.get('file_url'), 'message': data.get('message', '下载成功')})

    # 4. 付费作品：先查是否已购买（避免重复扣费）
    try:
        pur = supabase.table('product_purchases').select('id') \
            .eq('product_id', product_id).eq('buyer_id', user_id).maybe_single().execute()
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    if pur.data:
        return jsonify({'success': True, 'file_url': prod.data['file_url'], 'message': '已购买，直接下载'})

    # 5. 未购买：走 purchase_product（扣款并返回下载地址）
    data, rpc_err = rpc('purchase_product', {'p_product_id': product_id, 'p_buyer_id': user_id})
    if rpc_err:
        return jsonify({'success': False, 'message': '后端错误: %s' % rpc_err}), 500
    if not data or data.get('success') is not True:
        return jsonify({'success': False, 'message': (data and data.get('message')) or '购买失败'}), 400

    return jsonify({'success': True, 'file_url': data.get('file_url'), 'message': data.get('message', '购买成功')})


@app.route('/uploads/<path:filename>')
def serve_file(filename):
    """旧版本地存储的文件下载（新文件已走 S3）。"""
    if not re.match(r'^[a-f0-9]{32}(\.[a-zA-Z0-9]{1,10})?$', filename):
        return jsonify({'success': False, 'message': '非法文件名'}), 400
    return send_from_directory(UPLOAD_DIR, filename, as_attachment=True)


@app.route('/files/<path:key>')
def serve_s3_file(key):
    """从 S3 代理下载文件（附件方式）。桶保持私有，下载统一走本端点。"""
    if not re.match(r'^[a-f0-9]{32}(\.[a-zA-Z0-9]{1,10})?$', key):
        return jsonify({'success': False, 'message': '非法文件名'}), 400
    if s3_client is None:
        return jsonify({'success': False, 'message': 'S3 未配置（缺少 S3_ACCESS_KEY / S3_SECRET_KEY）'}), 500
    try:
        obj = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
        body = obj['Body'].read()
        resp = Response(body, mimetype=obj.get('ContentType', 'application/octet-stream'))
        resp.headers['Content-Disposition'] = 'attachment; filename="%s"' % key
        return resp
    except BotoClientError as e:
        code = e.response.get('ResponseMetadata', {}).get('HTTPStatusCode', 404)
        return jsonify({'success': False, 'message': '文件不存在或已删除'}), code if code == 404 else 502
    except Exception as e:
        return jsonify({'success': False, 'message': '下载失败: %s' % e}), 502


# ==================== GitHub 自动同步 ====================

@app.route('/webhook', methods=['POST'])
def github_webhook():
    """GitHub Webhook：push 后自动 git pull 网站代码和本后端代码。"""
    payload = request.get_data()
    signature = request.headers.get('X-Hub-Signature-256', '')
    if GITHUB_WEBHOOK_SECRET:
        expected = 'sha256=' + hmac.new(
            GITHUB_WEBHOOK_SECRET.encode('utf-8'), payload, hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return jsonify({'success': False, 'message': '签名校验失败'}), 403
    else:
        print('[webhook] 警告：未配置 GITHUB_WEBHOOK_SECRET，跳过签名校验')

    event = request.headers.get('X-GitHub-Event', 'push')
    if event != 'push':
        return jsonify({'success': True, 'message': '忽略事件: ' + event})

    # 需要同步的目录：网站代码目录 + 本后端目录
    sync_dirs = [SITE_DIR]
    api_dir = os.path.dirname(os.path.abspath(__file__))
    if os.path.abspath(api_dir) not in [os.path.abspath(d) for d in sync_dirs]:
        sync_dirs.append(api_dir)

    for d in sync_dirs:
        if not os.path.isdir(os.path.join(d, '.git')):
            print('[webhook] 跳过（不是 git 仓库）: %s' % d)
            continue
        log_name = 'pull_site.log' if d == SITE_DIR else 'pull_api.log'
        log_path = os.path.join('/tmp', log_name)
        try:
            with open(log_path, 'a') as log:
                subprocess.Popen(['git', '-C', d, 'pull'], stdout=log, stderr=log, cwd=d)
            print('[webhook] 已在后台触发 git pull: %s' % d)
        except Exception as e:
            print('[webhook] 触发失败 %s: %s' % (d, e))

    return jsonify({'success': True, 'message': '同步已触发'})


# ==================== 网站本体（静态文件服务） ====================
# 注意：此路由放在最后定义，避免吞掉 /upload /download /webhook 等 API 路由

@app.route('/', defaults={'path': ''})
@app.route('/<path:path>')
def serve_site(path):
    """服务 NB频道 静态站点文件。"""
    if path.startswith('uploads/'):
        return serve_file(path[len('uploads/'):])

    if not path:
        path = 'index.html'
    full = os.path.join(SITE_DIR, path)
    if not os.path.isfile(full):
        # 支持无 .html 后缀的访问（/about -> about.html）
        alt = full + '.html'
        if os.path.isfile(alt):
            full = alt
        else:
            return '404 Not Found - %s' % path, 404
    return send_from_directory(SITE_DIR, os.path.relpath(full, SITE_DIR))


if __name__ == '__main__':
    # 本地调试用：python app.py
    app.run(host='127.0.0.1', port=5000, debug=True)
