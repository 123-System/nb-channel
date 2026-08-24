# -*- coding: utf-8 -*-
"""
NB频道 - 称号图片批量上传脚本（一次性）
====================================================
在 PythonAnywhere 上运行：图片已随 git pull 同步到服务器，
本脚本把 images/titles/*.png 批量上传到 Supabase images 桶的 titles/ 前缀，
同名文件用 upsert 覆盖（URL 保持不变）。

运行方式（PythonAnywhere Bash 控制台）：
    cd ~/nb-channel/pythonanywhere
    python upload_titles.py

依赖：pip install supabase
"""
import os
import sys

from supabase import create_client

# 与 app.py 一致的 Supabase 配置
SUPABASE_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co'
SUPABASE_ANON_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg'

# 12 个称号的文件名（与仓库 images/titles/ 一致）
TITLE_FILES = [
    '签到之神.png', '评论大师.png', '红包豪侠.png', '点赞大师.png',
    '霸道总裁.png', '化学狂人.png', '作品大亨.png', '成就猎人.png',
    '人脉达人.png', '抽奖欧皇.png', '现金为王.png', '至尊皇冠.png',
]

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
IMAGES_DIR = os.path.join(os.path.dirname(BASE_DIR), 'images', 'titles')


def main():
    supabase = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    bucket = supabase.storage.from_('images')

    ok_count = 0
    fail_count = 0
    urls = []
    for name in TITLE_FILES:
        path = os.path.join(IMAGES_DIR, name)
        if not os.path.isfile(path):
            print('❌ 文件不存在: %s' % path)
            fail_count += 1
            continue
        with open(path, 'rb') as f:
            data = f.read()
        size_kb = len(data) / 1024
        key = 'titles/%s' % name
        try:
            # upsert=true 覆盖同名文件（URL 不变）
            bucket.upload(key, data, {'content-type': 'image/png', 'upsert': 'true'})
        except Exception as e:
            # 部分 supabase-py 版本不支持 upsert 参数 → 先删再传
            try:
                bucket.remove([key])
                bucket.upload(key, data, {'content-type': 'image/png'})
            except Exception as e2:
                print('❌ %s 上传失败: %s' % (name, e2))
                fail_count += 1
                continue
        url = SUPABASE_URL.rstrip('/') + '/storage/v1/object/public/images/' + key
        urls.append('%s: %s' % (name.replace('.png', ''), url))
        print('✅ %s (%.0fKB) -> %s' % (name, size_kb, url))
        ok_count += 1

    print('\n==================== 结果 ====================')
    print('成功 %d 张，失败 %d 张' % (ok_count, fail_count))
    if urls:
        print('\n所有链接（可直接复制）：')
        for u in urls:
            print(u)
    return 0 if fail_count == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
