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
        rows = _exec_rows(supabase.table('profiles').select('id').eq('id', uid).limit(1))
    except Exception as e:
        return None, '后端数据库连接失败: %s' % e
    if not rows:
        return None, '用户不存在或登录已失效'
    return rows[0]['id'], None


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
        prod_rows = _exec_rows(
            supabase.table('products').select('id, price, author_id, file_url, status') \
            .eq('id', product_id).limit(1)
        )
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    prod = prod_rows[0] if prod_rows else None
    if not prod or prod.get('status') != 'active':
        return jsonify({'success': False, 'message': '作品不存在或已下架'}), 404

    price = prod['price'] or 0
    author_id = prod['author_id']

    # 2. 作者本人：直接返回下载地址（不扣费）
    if str(author_id) == str(user_id):
        return jsonify({'success': True, 'file_url': prod['file_url'], 'message': '你的作品，直接下载'})

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
        pur_rows = _exec_rows(
            supabase.table('product_purchases').select('id') \
            .eq('product_id', product_id).eq('buyer_id', user_id).limit(1)
        )
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    if pur_rows:
        return jsonify({'success': True, 'file_url': prod['file_url'], 'message': '已购买，直接下载'})

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


# ==================== 股票市值 API（公开只读） ====================
# GET /api/market                       全市场快照（支持 ?name= 模糊查询）
# GET /api/market/<company_id>          单家公司市值
# GET /api/market/<company_id>/history  历史K线（?days=7，默认7天，最多30天）
# GET /api/docs                         接口文档页
# 别名：/api/virtual-market-value 与 /api/Virtual market value 等价于 /api/market
# 统一响应：{success, code, message?, ...data}
#   错误码：OK / UNAUTHORIZED / RATE_LIMITED / NOT_FOUND / INVALID_PARAM / DB_ERROR
# 可选保护：环境变量 API_KEY 配置后，需带 X-API-Key 请求头或 ?key= 参数访问；
# 节流：每 IP 每分钟最多 60 次（响应头 X-RateLimit-* 告知剩余额度）；
# 快照缓存 5 秒，避免刷爆 Supabase 免费额度。

API_KEY = os.environ.get('API_KEY', '')

_market_cache = {'ts': 0, 'data': None}
_rate_buckets = {}  # ip -> [请求时间戳]

def _rate_limited(ip, limit=60, window=60):
    """返回 (是否受限, 剩余次数)。"""
    now = datetime.datetime.now().timestamp()
    ts_list = [t for t in _rate_buckets.get(ip, []) if now - t < window]
    if len(ts_list) >= limit:
        _rate_buckets[ip] = ts_list
        return True, 0
    ts_list.append(now)
    _rate_buckets[ip] = ts_list
    return False, limit - len(ts_list)

def _check_api_key():
    if not API_KEY:
        return None
    key = request.headers.get('X-API-Key', '') or request.args.get('key', '')
    if key != API_KEY:
        return '无效或缺失 API Key'
    return None

def _exec_rows(query):
    """执行查询并返回行列表（兼容不同 supabase-py 版本的返回形态）。"""
    try:
        res = query.execute()
    except Exception:
        raise
    if res is None:
        return []
    if isinstance(res, dict):
        return [res]
    data = getattr(res, 'data', None)
    if data is None:
        return []
    if isinstance(data, list):
        return data
    return [data]
def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def _ok(data):
    """统一成功响应。"""
    return jsonify({'success': True, 'code': 'OK', **data})

def _err(code, message, status):
    """统一错误响应。"""
    return jsonify({'success': False, 'code': code, 'message': message}), status

def _guard():
    """统一前置检查（API Key + 限流），并附加限流响应头。
    返回 None 表示放行；否则返回应直接返回的响应。"""
    err = _check_api_key()
    if err:
        return _err('UNAUTHORIZED', err, 401)
    limited, remaining = _rate_limited(request.remote_addr or 'unknown')
    if limited:
        return _err('RATE_LIMITED', '请求过于频繁，请稍后再试', 429)
    # 挂上限流剩余信息（after_request 里统一加头）
    request.environ['_rate_remaining'] = remaining
    return None

@app.after_request
def after_request_api(resp):
    # 限流剩余额度头（CORS 头由上方原有的 after_request 统一处理）
    remaining = request.environ.get('_rate_remaining')
    if remaining is not None:
        resp.headers['X-RateLimit-Limit'] = '60'
        resp.headers['X-RateLimit-Remaining'] = str(remaining)
    return resp

def _parse_owner(c):
    p = c.get('profiles')
    if isinstance(p, list) and p:
        return p[0].get('username')
    if isinstance(p, dict):
        return p.get('username')
    return None

def _fetch_market():
    now = datetime.datetime.now().timestamp()
    if _market_cache['data'] and now - _market_cache['ts'] < 5:
        return _market_cache['data'], None
    try:
        rows = _exec_rows(
            supabase.table('user_companies') \
            .select('id, company_name, market_value, user_id, profiles(username)') \
            .order('market_value', desc=True)
        )
    except Exception as e:
        return None, str(e)
    companies = []
    total = 0
    for c in rows:
        companies.append({
            'id': c['id'],
            'name': c['company_name'],
            'market_value': c['market_value'],
            'owner': _parse_owner(c),
        })
        total += c['market_value'] or 0
    data = {'total_market_value': total, 'count': len(companies), 'companies': companies,
            'as_of': _now_iso()}
    _market_cache['ts'] = now
    _market_cache['data'] = data
    return data, None

def _fetch_company(company_id):
    """查单家公司，返回 (company dict, error)；不存在返回 (None, None)。"""
    try:
        rows = _exec_rows(
            supabase.table('user_companies') \
            .select('id, company_name, market_value, user_id, profiles(username)') \
            .eq('id', company_id).limit(1)
        )
    except Exception as e:
        return None, str(e)
    if not rows:
        return None, None
    return rows[0], None

@app.route('/api/market')
@app.route('/api/virtual-market-value')
@app.route('/api/Virtual market value')
def api_market():
    denied = _guard()
    if denied:
        return denied
    name = (request.args.get('name') or '').strip()
    if name:
        # 按公司名模糊查询（不缓存，保持实时；limit 保护）
        try:
            rows = _exec_rows(
                supabase.table('user_companies') \
                .select('id, company_name, market_value, user_id, profiles(username)') \
                .ilike('company_name', '%' + name + '%') \
                .limit(50)
            )
        except Exception as e:
            return _err('DB_ERROR', '后端数据库连接失败: %s' % e, 500)
        companies = [{
            'id': c['id'],
            'name': c['company_name'],
            'market_value': c['market_value'],
            'owner': _parse_owner(c),
        } for c in rows]
        total = sum(c['market_value'] or 0 for c in companies)
        return _ok({'as_of': _now_iso(), 'total_market_value': total,
                    'count': len(companies), 'companies': companies})
    data, db_err = _fetch_market()
    if db_err:
        return _err('DB_ERROR', '后端数据库连接失败: %s' % db_err, 500)
    return _ok({'as_of': data['as_of'], 'total_market_value': data['total_market_value'],
                'count': data['count'], 'companies': data['companies']})

@app.route('/api/market/<int:company_id>')
def api_market_one(company_id):
    denied = _guard()
    if denied:
        return denied
    c, db_err = _fetch_company(company_id)
    if db_err:
        return _err('DB_ERROR', '后端数据库连接失败: %s' % db_err, 500)
    if not c:
        return _err('NOT_FOUND', '公司不存在', 404)
    return _ok({'as_of': _now_iso(), 'id': c['id'], 'name': c['company_name'],
                'market_value': c['market_value'], 'owner': _parse_owner(c)})

@app.route('/api/market/<int:company_id>/history')
def api_market_history(company_id):
    denied = _guard()
    if denied:
        return denied
    try:
        days = int(request.args.get('days', 7))
    except ValueError:
        return _err('INVALID_PARAM', 'days 必须是数字', 400)
    if days < 1 or days > 30:
        return _err('INVALID_PARAM', 'days 需在 1~30 之间', 400)

    c, db_err = _fetch_company(company_id)
    if db_err:
        return _err('DB_ERROR', '后端数据库连接失败: %s' % db_err, 500)
    if not c:
        return _err('NOT_FOUND', '公司不存在', 404)

    try:
        rows = _exec_rows(supabase.rpc('get_company_kline', {'p_company_id': company_id}))
    except Exception as e:
        return _err('DB_ERROR', 'K线数据读取失败: %s' % e, 500)

    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    points = []
    for row in rows:
        t = row.get('t')
        if t is None:
            continue
        try:
            ts = datetime.datetime.fromisoformat(t.replace('Z', '+00:00'))
        except (ValueError, AttributeError):
            continue
        if ts >= cutoff:
            points.append({'t': row['t'], 'v': row['v']})

    return _ok({'as_of': _now_iso(), 'company_id': c['id'], 'name': c['company_name'],
                'days': days, 'points_count': len(points), 'points': points})

@app.route('/api/docs')
def api_docs():
    """接口文档页。"""
    return Response(DOCS_HTML, mimetype='text/html')

DOCS_HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NB频道 市值 API 文档</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:860px;margin:0 auto;padding:24px 16px;line-height:1.7;background:#f7f8fa;color:#222}
h1{border-bottom:2px solid #00a1d6;padding-bottom:8px}
h2{margin-top:32px;color:#00a1d6;border-left:4px solid #00a1d6;padding-left:10px}
code,pre{background:#eef1f5;border-radius:6px;font-size:0.9em}
code{padding:2px 6px}
pre{padding:12px 14px;overflow-x:auto}
table{border-collapse:collapse;width:100%;margin:12px 0}
th,td{border:1px solid #d5dae0;padding:8px 10px;text-align:left;font-size:0.92em}
th{background:#e9eef4}
.ep{background:#fff;border:1px solid #e1e6ec;border-radius:10px;padding:14px 16px;margin:14px 0}
.badge{display:inline-block;background:#00a1d6;color:#fff;border-radius:4px;padding:1px 8px;font-size:0.8em;margin-right:6px}
.badge.g{background:#28a745}
.footer{margin-top:40px;color:#888;font-size:0.85em;text-align:center}
</style>
</head>
<body>
<h1>📈 NB频道 虚拟股票市值 API</h1>
<p>公开只读接口，数据与网站前端实时一致。Base URL：<code>https://nbchannel.pythonanywhere.com</code> 或 <code>https://api.nb-channel.top</code></p>

<h2>统一响应结构</h2>
<p>成功：<code>{"success": true, "code": "OK", ...数据字段}</code>；失败：<code>{"success": false, "code": "错误码", "message": "说明"}</code></p>
<table>
<tr><th>错误码</th><th>HTTP</th><th>含义</th></tr>
<tr><td><code>OK</code></td><td>200</td><td>成功</td></tr>
<tr><td><code>UNAUTHORIZED</code></td><td>401</td><td>API Key 缺失或错误（仅配置了 API_KEY 时出现）</td></tr>
<tr><td><code>RATE_LIMITED</code></td><td>429</td><td>请求过于频繁（每 IP 每分钟 60 次）</td></tr>
<tr><td><code>NOT_FOUND</code></td><td>404</td><td>公司不存在</td></tr>
<tr><td><code>INVALID_PARAM</code></td><td>400</td><td>参数不合法</td></tr>
<tr><td><code>DB_ERROR</code></td><td>500</td><td>后端数据库异常</td></tr>
</table>

<h2>接口列表</h2>

<div class="ep">
<span class="badge">GET</span><code>/api/market</code> — 全市场快照
<p>参数：<code>name</code>（可选，按公司名模糊查询，最多50家）</p>
<pre>curl "https://api.nb-channel.top/api/market"
curl "https://api.nb-channel.top/api/market?name=NB"</pre>
</div>

<div class="ep">
<span class="badge">GET</span><code>/api/market/&lt;company_id&gt;</code> — 单家公司市值
<pre>curl "https://api.nb-channel.top/api/market/1"</pre>
</div>

<div class="ep">
<span class="badge">GET</span><code>/api/market/&lt;company_id&gt;/history</code> — 历史K线（市值走势点）
<p>参数：<code>days</code>（可选，默认 7，范围 1~30）</p>
<pre>curl "https://api.nb-channel.top/api/market/1/history?days=7"</pre>
</div>

<div class="ep">
<span class="badge">GET</span><code>/api/docs</code> — 本文档
</div>

<h2>响应示例（全市场）</h2>
<pre>{
  "success": true,
  "code": "OK",
  "as_of": "2026-08-19T12:00:00+00:00",
  "total_market_value": 1234567,
  "count": 54,
  "companies": [
    {"id": 1, "name": "NB频道", "market_value": 148467, "owner": "NB搞事局"}
  ]
}</pre>

<h2>响应示例（历史K线）</h2>
<pre>{
  "success": true,
  "code": "OK",
  "as_of": "2026-08-19T12:00:00+00:00",
  "company_id": 1,
  "name": "NB频道",
  "days": 7,
  "points_count": 900,
  "points": [
    {"t": "2026-08-19T03:55:00+00:00", "v": 148467}
  ]
}</pre>

<h2>字段说明</h2>
<table>
<tr><th>字段</th><th>说明</th></tr>
<tr><td><code>as_of</code></td><td>数据生成时间（UTC ISO8601），调用方可判断数据新旧</td></tr>
<tr><td><code>market_value</code></td><td>公司当前市值（NB币）</td></tr>
<tr><td><code>t / v</code></td><td>K线采样时间 / 该时刻市值</td></tr>
<tr><td><code>owner</code></td><td>公司归属用户名</td></tr>
</table>

<h2>限制与说明</h2>
<ul>
<li>限流：每 IP 每分钟最多 60 次，响应头 <code>X-RateLimit-Limit</code> / <code>X-RateLimit-Remaining</code> 可查剩余</li>
<li>数据只读，请勿用于批量爬取；如需更高额度可联系站长</li>
<li>别名：<code>/api/virtual-market-value</code>、<code>/api/Virtual market value</code> 与 <code>/api/market</code> 等价</li>
</ul>

<div class="footer">© 2026 NB频道 · 如有问题请联系 nbchannel@163.com</div>
</body>
</html>"""


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
