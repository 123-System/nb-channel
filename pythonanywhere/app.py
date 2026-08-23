# -*- coding: utf-8 -*-
"""
NB频道 - PythonAnywhere 一体化 Flask 应用
====================================================
功能：
  GET  /                网站本体（静态文件服务，需配置 SITE_DIR）
  POST /upload          上传作品（存 S3，multipart/form-data + 头 X-User-Id）
  POST /upload-image    上传图片（评论区/私信用，存 images 公开桶）
  POST /download        下载/购买作品（JSON + 头 X-User-Id；body 可选 pay_type: nb|market、company_id）
  GET  /files/<key>     从 S3 代理下载文件（附件方式）
  POST /webhook         GitHub push 后自动 git pull 同步代码
  GET  /health          健康检查

部署前必读：pythonanywhere/README.md
依赖：pip install flask supabase boto3
"""
import os
import re
import io
import csv
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

# 防连点：user_id -> 最近一次上传时间戳（进程内，防止手滑连点产生重复作品）
_upload_guard = {}

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


# 作品标题/简介违禁词（与数据库 bad_words 词库一致，防绕过前端）
_BAD_WORDS = [
    '操你妈', '傻逼', '废物', '脑残', '智障', 'nmsl', '吃屎', '大粪',
    '蟑螂', '臭水沟', '屁水', '呕吐物', '全家肉沫', '强酸', '甲醇',
    '放射性', '寄生虫', '尿液', '引战', '造谣', '骂给', '当给',
    '无家可归', '乱封号', 'gay', 'fuck', 'shit', 'bitch',
    '支那', '黑鬼', '白皮猪', '台巴子', '网暴', '喷子', '垃圾', '去死',
    '他妈', '尼玛', '妈逼', '操蛋', '王八蛋', '混蛋', '杂种', '狗日的',
    '法克', '卖淫', '嫖娼', '约炮', '裸聊', '毒品', '海洛因', '办证',
    '加微信', '兼职刷单', '返利', '垃圾频道', 'SB频道', '脑残UP',
]

def _has_bad_words(text):
    """检测文本是否含违禁词（大小写不敏感）。"""
    if not text:
        return False
    low = text.lower()
    for w in _BAD_WORDS:
        if w.lower() in low:
            return True
    return False


# ==================== 接口 ====================

@app.route('/health')
def health():
    return jsonify({'ok': True, 'time': datetime.datetime.now().isoformat()})


@app.route('/upload', methods=['POST'])
def upload():
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    # 防连点兜底：同一用户 10 秒内重复上传直接拒绝（前端已锁按钮，这里是双保险）
    _now = datetime.datetime.now().timestamp()
    _last = _upload_guard.get(str(user_id), 0)
    if _now - _last < 10:
        return jsonify({'success': False, 'message': '操作太快了，请稍候 10 秒再试'}), 429
    _upload_guard[str(user_id)] = _now

    title = (request.form.get('title') or '').strip()
    description = (request.form.get('description') or '').strip()
    price_str = (request.form.get('price') or '0').strip()
    file = request.files.get('file')

    if not title:
        return jsonify({'success': False, 'message': '请输入作品标题'}), 400
    if len(title) > 20:
        return jsonify({'success': False, 'message': '标题不能超过20字'}), 400
    if title.count('\n') >= 2:
        return jsonify({'success': False, 'message': '标题最多2行'}), 400
    if len(description) > 100:
        return jsonify({'success': False, 'message': '简介不能超过100字'}), 400
    if description.count('\n') >= 10:
        return jsonify({'success': False, 'message': '简介最多10行'}), 400
    if _has_bad_words(title) or _has_bad_words(description):
        return jsonify({'success': False, 'message': '标题或简介包含违禁词，禁止发布'}), 400
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

    # ---------- 存储：Supabase Storage（products 私有桶，下载走 /files/<key> 代理） ----------
    key = safe_filename(file.filename)
    file_bytes = file.read()   # supabase-py upload 需要 bytes，不接受文件流
    try:
        supabase.storage.from_('products').upload(key, file_bytes, {
            'content-type': file.mimetype or 'application/octet-stream'
        })
    except Exception as e:
        return jsonify({'success': False, 'message': '上传到存储失败: %s' % e}), 500
    file_url = request.host_url.rstrip('/') + '/files/' + key

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
            supabase.storage.from_('products').remove([key])
        except Exception:
            pass
        msg = (rpc_err or (data and data.get('message')) or '写入数据库失败，请检查 SQL 脚本是否已执行')
        return jsonify({'success': False, 'message': msg}), 500

    return jsonify({'success': True, 'message': '发布成功', 'product_id': data.get('id')})


@app.route('/upload-avatar', methods=['POST'])
def upload_avatar():
    """上传头像：X-User-Id 请求头 + multipart 文件。存 avatars 公开桶，更新 profiles.avatar_url。"""
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    file = request.files.get('file')
    if not file or file.filename == '':
        return jsonify({'success': False, 'message': '请选择图片文件'}), 400

    # 大小限制：头像不超过 2MB
    file.seek(0, os.SEEK_END)
    size = file.tell()
    file.seek(0)
    if size > 2 * 1024 * 1024:
        return jsonify({'success': False, 'message': '头像图片不能超过 2MB'}), 400

    # 只允许常见图片格式
    mime = (file.mimetype or '').lower()
    ext_map = {'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/webp': '.webp'}
    ext = ext_map.get(mime)
    if not ext:
        return jsonify({'success': False, 'message': '仅支持 JPG/PNG/GIF/WebP 图片'}), 400

    # 每次上传生成唯一文件名（避免覆盖冲突：upload 同 key 会 409、update 会被 RLS 拦）
    # 格式：user_<id>_<时间戳>.<ext>，新头像上传后更新 avatar_url 指向新文件
    key = 'user_%s_%d%s' % (str(user_id), int(datetime.datetime.now().timestamp() * 1000), ext)
    file_bytes = file.read()   # supabase-py upload 需要 bytes，不接受文件流
    try:
        supabase.storage.from_('avatars').upload(key, file_bytes, {
            'content-type': mime
        })
    except Exception as e:
        return jsonify({'success': False, 'message': '头像上传失败: %s' % e}), 500

    avatar_url = SUPABASE_URL.rstrip('/') + '/storage/v1/object/public/avatars/' + key
    # 走 SECURITY DEFINER RPC 更新 profiles（anon 无 UPDATE profiles 权限）
    data, rpc_err = rpc('update_avatar_url', {'p_user_id': user_id, 'p_url': avatar_url})
    if rpc_err or not data or data.get('success') is not True:
        # 地址保存失败时清理刚上传的文件，避免孤儿文件
        try:
            supabase.storage.from_('avatars').remove([key])
        except Exception:
            pass
        return jsonify({'success': False, 'message': '头像地址保存失败: %s' % (rpc_err or '未知错误')}), 500

    # 清理该用户的旧头像文件（保留刚上传的；删除策略已配置）
    try:
        prefix = 'user_%s' % str(user_id)
        old_rows = _exec_rows(supabase.storage.from_('avatars').list('', {}))
        for old in old_rows:
            old_name = old.get('name') or ''
            if old_name.startswith(prefix) and old_name != key:
                supabase.storage.from_('avatars').remove([old_name])
    except Exception:
        pass   # 清理失败不影响头像使用

    return jsonify({'success': True, 'avatar_url': avatar_url, 'message': '头像上传成功'})


@app.route('/upload-image', methods=['POST'])
def upload_image():
    """上传图片（评论区/私信用）：存 images 公开桶，返回 key + 完整 URL。
    消息/评论中存短标记 [img]<key>[/img]，前端渲染时拼公开 URL。"""
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    file = request.files.get('file')
    if not file or file.filename == '':
        return jsonify({'success': False, 'message': '请选择图片文件'}), 400

    # 大小限制：5MB
    file.seek(0, os.SEEK_END)
    size = file.tell()
    file.seek(0)
    if size > 5 * 1024 * 1024:
        return jsonify({'success': False, 'message': '图片不能超过 5MB'}), 400

    # 只允许常见图片格式
    mime = (file.mimetype or '').lower()
    ext_map = {'image/jpeg': '.jpg', 'image/png': '.png', 'image/gif': '.gif', 'image/webp': '.webp'}
    ext = ext_map.get(mime)
    if not ext:
        return jsonify({'success': False, 'message': '仅支持 JPG/PNG/GIF/WebP 图片'}), 400

    # 唯一短 key：i_<毫秒时间戳>_<8位随机hex>.<ext>（标记存进消息/评论时占字少）
    key = 'i_%d_%s%s' % (int(datetime.datetime.now().timestamp() * 1000), uuid.uuid4().hex[:8], ext)
    file_bytes = file.read()   # supabase-py upload 需要 bytes，不接受文件流
    try:
        supabase.storage.from_('images').upload(key, file_bytes, {'content-type': mime})
    except Exception as e:
        return jsonify({'success': False, 'message': '图片上传失败: %s' % e}), 500

    url = SUPABASE_URL.rstrip('/') + '/storage/v1/object/public/images/' + key
    return jsonify({'success': True, 'key': key, 'url': url, 'message': '图片上传成功'})


@app.route('/remove-avatar', methods=['POST'])
def remove_avatar():
    """移除头像：清空 avatar_url，并删除该用户的头像文件。"""
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    # 清空 avatar_url（走 RPC）
    data, rpc_err = rpc('update_avatar_url', {'p_user_id': user_id, 'p_url': ''})
    if rpc_err or not data or data.get('success') is not True:
        return jsonify({'success': False, 'message': '移除失败: %s' % (rpc_err or '未知错误')}), 500

    # 删除该用户的头像文件（尽力而为）
    try:
        prefix = 'user_%s' % str(user_id)
        old_rows = _exec_rows(supabase.storage.from_('avatars').list('', {}))
        for old in old_rows:
            old_name = old.get('name') or ''
            if old_name.startswith(prefix):
                supabase.storage.from_('avatars').remove([old_name])
    except Exception:
        pass

    return jsonify({'success': True, 'message': '头像已移除'})


def _storage_key_from_url(file_url):
    """从 file_url（形如 https://host/files/<key>）提取存储 key。"""
    if not file_url:
        return None
    parts = file_url.rstrip('/').split('/')
    key = parts[-1]
    return key if re.match(r'^[a-f0-9]{32}(\.[a-zA-Z0-9]{1,10})?$', key) else None


@app.route('/edit-product', methods=['POST'])
def edit_product():
    """编辑自己的作品：标题/简介/定价，可选替换文件。"""
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    try:
        product_id = int(request.form.get('product_id'))
    except (TypeError, ValueError):
        return jsonify({'success': False, 'message': '无效的作品 ID'}), 400

    title = (request.form.get('title') or '').strip()
    description = (request.form.get('description') or '').strip()
    price_str = (request.form.get('price') or '0').strip()

    if not title:
        return jsonify({'success': False, 'message': '请输入作品标题'}), 400
    if len(title) > 20:
        return jsonify({'success': False, 'message': '标题不能超过20字'}), 400
    if title.count('\n') >= 2:
        return jsonify({'success': False, 'message': '标题最多2行'}), 400
    if len(description) > 100:
        return jsonify({'success': False, 'message': '简介不能超过100字'}), 400
    if description.count('\n') >= 10:
        return jsonify({'success': False, 'message': '简介最多10行'}), 400
    if _has_bad_words(title) or _has_bad_words(description):
        return jsonify({'success': False, 'message': '标题或简介包含违禁词，禁止发布'}), 400
    try:
        price = int(price_str)
    except ValueError:
        return jsonify({'success': False, 'message': '定价必须是数字'}), 400
    if price < 0 or price > 999999999:
        return jsonify({'success': False, 'message': '价格需在 0~999999999 之间'}), 400

    # 校验作者身份 + 拿旧文件信息
    try:
        rows = _exec_rows(
            supabase.table('products').select('id, file_url').eq('id', product_id).eq('author_id', user_id).limit(1)
        )
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    if not rows:
        return jsonify({'success': False, 'message': '只能修改自己的作品'}), 403

    old_file_url = rows[0].get('file_url')
    new_file_url = old_file_url
    new_file_name = None
    new_file_size = None
    new_mime = None
    old_key = None

    file = request.files.get('file')
    if file and file.filename:
        file.seek(0, os.SEEK_END)
        size = file.tell()
        file.seek(0)
        if size > MAX_FILE_SIZE:
            return jsonify({'success': False, 'message': '文件不能超过 50 MB'}), 400
        key = safe_filename(file.filename)
        try:
            supabase.storage.from_('products').upload(key, file.read(), {
                'content-type': file.mimetype or 'application/octet-stream'
            })
        except Exception as e:
            return jsonify({'success': False, 'message': '新文件上传失败: %s' % e}), 500
        new_file_url = request.host_url.rstrip('/') + '/files/' + key
        new_file_name = file.filename
        new_file_size = size
        new_mime = file.mimetype or ''
        old_key = _storage_key_from_url(old_file_url)

    # 更新记录：走 SECURITY DEFINER RPC（anon 无 UPDATE 权限）
    data, rpc_err = rpc('edit_product', {
        'p_product_id': product_id,
        'p_user_id': user_id,
        'p_title': title,
        'p_description': description,
        'p_price': price,
        'p_file_url': new_file_url if new_file_url != old_file_url else None,
        'p_file_name': new_file_name if new_file_url != old_file_url else None,
        'p_file_size': new_file_size if new_file_url != old_file_url else None,
        'p_mime_type': new_mime if new_file_url != old_file_url else None,
    })
    if rpc_err or not data or data.get('success') is not True:
        # 记录更新失败时清理已上传的新文件
        if new_file_url != old_file_url:
            try:
                supabase.storage.from_('products').remove([_storage_key_from_url(new_file_url)])
            except Exception:
                pass
        return jsonify({'success': False, 'message': (rpc_err or (data and data.get('message')) or '保存失败')}), 500

    # 删除旧文件（替换场景）
    if old_key and new_file_url != old_file_url:
        try:
            supabase.storage.from_('products').remove([old_key])
        except Exception:
            pass

    return jsonify({'success': True, 'message': '作品已更新'})


@app.route('/delete-product', methods=['POST'])
def delete_product():
    """删除自己的作品（记录 + 存储文件 + 购买/下载记录）。"""
    user_id, err = get_user_id()
    if err:
        return jsonify({'success': False, 'message': err}), 401

    body = request.get_json(silent=True) or {}
    try:
        product_id = int(body.get('product_id'))
    except (TypeError, ValueError):
        return jsonify({'success': False, 'message': '无效的作品 ID'}), 400

    try:
        rows = _exec_rows(
            supabase.table('products').select('id, file_url').eq('id', product_id).eq('author_id', user_id).limit(1)
        )
    except Exception as e:
        return jsonify({'success': False, 'message': '后端数据库连接失败: %s' % e}), 500
    if not rows:
        return jsonify({'success': False, 'message': '只能删除自己的作品'}), 403

    key = _storage_key_from_url(rows[0].get('file_url'))
    # 走 SECURITY DEFINER RPC 删除记录（anon 无直接 DELETE 权限）
    data, rpc_err = rpc('delete_product', {'p_product_id': product_id, 'p_user_id': user_id})
    if rpc_err or not data or data.get('success') is not True:
        return jsonify({'success': False, 'message': (rpc_err or (data and data.get('message')) or '删除失败')}), 500
    if key:
        try:
            supabase.storage.from_('products').remove([key])
        except Exception:
            pass

    return jsonify({'success': True, 'message': '作品已删除'})


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
    #    支付方式：pay_type = 'nb'（给作者NB币，默认）| 'market'（加作者公司市值，需 company_id）
    pay_type = (body.get('pay_type') or 'nb').lower()
    company_id = body.get('company_id')
    rpc_kwargs = {'p_product_id': product_id, 'p_buyer_id': user_id, 'p_pay_type': pay_type}
    if company_id:
        try:
            rpc_kwargs['p_company_id'] = int(company_id)
        except (TypeError, ValueError):
            return jsonify({'success': False, 'message': '无效的公司 ID'}), 400
    data, rpc_err = rpc('purchase_product', rpc_kwargs)
    if rpc_err:
        return jsonify({'success': False, 'message': '后端错误: %s' % rpc_err}), 500
    if not data or data.get('success') is not True:
        return jsonify({'success': False, 'message': (data and data.get('message')) or '购买失败'}), 400

    return jsonify({'success': True, 'file_url': data.get('file_url'), 'message': data.get('message', '购买成功')})


@app.route('/uploads/<path:filename>')
def serve_file(filename):
    """旧版本地存储的文件下载（历史遗留，新文件已走 Supabase Storage）。"""
    if not re.match(r'^[a-f0-9]{32}(\.[a-zA-Z0-9]{1,10})?$', filename):
        return jsonify({'success': False, 'message': '非法文件名'}), 400
    return send_from_directory(UPLOAD_DIR, filename, as_attachment=True)


@app.route('/files/<path:key>')
def serve_s3_file(key):
    """下载作品文件（附件方式）。三级兜底：Supabase Storage → S3 → 本地磁盘（兼容历史文件）。"""
    if not re.match(r'^[a-f0-9]{32}(\.[a-zA-Z0-9]{1,10})?$', key):
        return jsonify({'success': False, 'message': '非法文件名'}), 400

    # 1) Supabase Storage（新文件）
    try:
        body = supabase.storage.from_('products').download(key)
        resp = Response(body, mimetype='application/octet-stream')
        resp.headers['Content-Disposition'] = 'attachment; filename="%s"' % key
        return resp
    except Exception:
        pass

    # 2) S3（历史文件，若仍配置可用）
    if s3_client is not None:
        try:
            obj = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
            body = obj['Body'].read()
            resp = Response(body, mimetype='application/octet-stream')
            resp.headers['Content-Disposition'] = 'attachment; filename="%s"' % key
            return resp
        except Exception:
            pass

    # 3) 本地磁盘（历史文件）
    local_path = os.path.join(UPLOAD_DIR, key)
    if os.path.isfile(local_path):
        return send_from_directory(UPLOAD_DIR, key, as_attachment=True)

    return jsonify({'success': False, 'message': '文件不存在或已删除'}), 404


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

# API 用量统计（进程内存；PythonAnywhere Reload 后清零）
_api_stats = {
    'since': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'day': None,           # 统计日期（UTC）
    'day_total': 0,        # 当日请求总数
    'by_endpoint': {},     # 当日各端点请求数
    'rate_limited': 0,     # 被限流的请求数
}

@app.before_request
def count_api_requests():
    if not request.path.startswith('/api/') or request.path == '/api/stats':
        return
    today = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    if _api_stats['day'] != today:
        _api_stats['day'] = today
        _api_stats['day_total'] = 0
        _api_stats['by_endpoint'] = {}
    _api_stats['day_total'] += 1
    _api_stats['by_endpoint'][request.path] = _api_stats['by_endpoint'].get(request.path, 0) + 1

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
        _api_stats['rate_limited'] += 1
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

@app.route('/api/comments')
def api_comments():
    """只读评论接口：支持 page/limit/page_path 参数。"""
    denied = _guard()
    if denied:
        return denied
    try:
        page = int(request.args.get('page', 1))
        limit = int(request.args.get('limit', 20))
    except ValueError:
        return _err('INVALID_PARAM', 'page/limit 必须是数字', 400)
    if page < 1 or limit < 1 or limit > 50:
        return _err('INVALID_PARAM', 'page 需>=1，limit 需在 1~50 之间', 400)
    q = supabase.table('comments') \
        .select('id, page_path, content, created_at, parent_id, profiles(username)') \
        .order('created_at', desc=True) \
        .range((page - 1) * limit, page * limit - 1)
    page_path = (request.args.get('page_path') or '').strip()
    if page_path:
        q = q.eq('page_path', page_path)

    # 总评论数（用于调用方计算总页数；查询失败时不阻塞主查询）
    total = None
    page_count = None
    try:
        cnt_q = supabase.table('comments').select('id', count='exact', head=True)
        if page_path:
            cnt_q = cnt_q.eq('page_path', page_path)
        cnt_res = cnt_q.execute()
        total = getattr(cnt_res, 'count', None)
        if total is not None:
            total = int(total)
            page_count = (total + limit - 1) // limit
    except Exception:
        total = None

    try:
        rows = _exec_rows(q)
    except Exception as e:
        return _err('DB_ERROR', '后端数据库连接失败: %s' % e), 500
    comments = [{
        'id': r['id'],
        'username': _parse_owner(r),
        'content': r['content'],
        'created_at': r['created_at'],
        'parent_id': r.get('parent_id'),
        'page_path': r.get('page_path'),
    } for r in rows]
    return _ok({'as_of': _now_iso(), 'page': page, 'limit': limit,
                'total': total, 'page_count': page_count,
                'count': len(comments), 'comments': comments})


@app.route('/api/market/export')
def api_market_export():
    """全市场快照导出（CSV）。"""
    denied = _guard()
    if denied:
        return denied
    fmt = (request.args.get('format') or 'csv').lower()
    if fmt != 'csv':
        return _err('INVALID_PARAM', '仅支持 format=csv', 400)
    data, db_err = _fetch_market()
    if db_err:
        return _err('DB_ERROR', '后端数据库连接失败: %s' % db_err), 500
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(['id', 'name', 'market_value', 'owner'])
    for c in data['companies']:
        writer.writerow([c['id'], c['name'], c['market_value'], c['owner'] or ''])
    resp = Response(buf.getvalue(), mimetype='text/csv; charset=utf-8')
    fname = 'market_%s.csv' % datetime.datetime.now().strftime('%Y%m%d')
    resp.headers['Content-Disposition'] = 'attachment; filename="%s"' % fname
    return resp


@app.route('/api/stats')
def api_stats():
    """API 用量统计：当日请求数、各端点分布、限流次数。"""
    denied = _guard()
    if denied:
        return denied
    return _ok({'date': _api_stats['day'],
                'day_total_requests': _api_stats['day_total'],
                'by_endpoint': _api_stats['by_endpoint'],
                'rate_limited': _api_stats['rate_limited'],
                'uptime_since': _api_stats['since']})


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
<span class="badge">GET</span><code>/api/market/export?format=csv</code> — 全市场快照导出（CSV 文件下载）
<pre>curl "https://api.nb-channel.top/api/market/export?format=csv" -o market.csv</pre>
</div>

<div class="ep">
<span class="badge">GET</span><code>/api/comments</code> — 最新评论（只读）
<p>参数：<code>page</code>（默认 1）、<code>limit</code>（默认 20，最大 50）、<code>page_path</code>（可选，按页面筛选，如 comments-beta.html）</p>
<p>响应含 <code>total</code>（总评论数）与 <code>page_count</code>（总页数，按当前 limit 计算）</p>
<pre>curl "https://api.nb-channel.top/api/comments?page=1&limit=20"
curl "https://api.nb-channel.top/api/comments?page_path=comments-beta.html"</pre>
</div>

<div class="ep">
<span class="badge">GET</span><code>/api/stats</code> — API 用量统计（当日请求数/端点分布/限流次数）
<pre>curl "https://api.nb-channel.top/api/stats"</pre>
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

<h2>代码示例</h2>
<p>完整 SDK 示例见仓库 <code>api-sdk/</code> 目录（<code>python_example.py</code> / <code>js_example.js</code>）。</p>

<div class="ep">
<span class="badge">Python</span> requests
<pre>from python_example import NBMarket

nb = NBMarket()   # 或 NBMarket(base_url="https://nbchannel.pythonanywhere.com")

market = nb.market()                       # 全市场
print(market["total_market_value"])
print(nb.market(name="NB"))                # 按名模糊查询
print(nb.market_by_id(3))                  # 单公司
print(nb.history(3, days=7))               # 历史K线
comments = nb.comments(page=1, limit=10)   # 评论（含 total / page_count）
print(comments["total"], comments["page_count"])</pre>
</div>

<div class="ep">
<span class="badge">JavaScript</span> fetch（浏览器 / Node）
<pre>// 浏览器：&lt;script src="js_example.js"&gt; 后直接用 window.NBMarket
const market = await NBMarket.market();
console.log(market.total_market_value);

const one = await NBMarket.marketById(3);
const kline = await NBMarket.history(3, 7);

const comments = await NBMarket.comments(1, 10);
console.log('共', comments.total, '条，', comments.page_count, '页');</pre>
</div>

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
