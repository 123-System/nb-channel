# update_videos.py
import re
import json
import sys
import asyncio
import aiohttp
from bilibili_api import user, sync

# ==================== 配置区域 ====================
BILIBILI_UID = 3493259582114264  # 你的UID

# 合集ID配置（已填入你提供的ID）
SEASON_IDS = {
    '化学': 4802326,      # 《逝验室·化学》
    '物理': 7287248,      # 《逝验室·物理》
    '救人': 4802339,      # 《“救”人》
    '官网': 7460546,      # 《官网》
}
# ==================================================

def format_count(num):
    """格式化播放量"""
    if not num:
        return '0'
    try:
        num = int(num)
    except:
        return str(num)
    return f"{num/10000:.1f}万" if num >= 10000 else str(num)

def seconds_to_time(seconds):
    """将秒数转换为 mm:ss 或 hh:mm:ss 格式"""
    if not seconds:
        return '00:00'
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    else:
        return f"{m}:{s:02d}"

async def fetch_videos_from_season(season_id, category_key):
    """从指定合集获取视频列表，返回 (视频列表, 合集标题)"""
    try:
        url = "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list"
        params = {
            'mid': BILIBILI_UID,
            'season_id': season_id,
            'page_num': 1,
            'page_size': 50,
            'sort_reverse': 0  # 关键修改：将 False 改为 0
        }
        async with aiohttp.ClientSession() as session:
            async with session.get(url, params=params) as resp:
                if resp.status != 200:
                    print(f"合集 {category_key} 请求失败: HTTP {resp.status}")
                    return [], None
                data = await resp.json()
                if data['code'] != 0:
                    print(f"合集 {category_key} 返回错误: {data.get('message')}")
                    return [], None

                # 获取合集标题
                season_name = data.get('data', {}).get('info', {}).get('season_name', '')

                archives = data.get('data', {}).get('archives', [])
                videos = []
                for item in archives:
                    video = {
                        'bvid': item.get('bvid'),
                        'title': item.get('title'),
                        'cover': item.get('pic', '').replace('http://', 'https://'),
                        'play': format_count(item.get('stat', {}).get('view', 0)),
                        'duration': seconds_to_time(item.get('duration', 0)),
                        'pubdate': item.get('pubdate', 0),
                        'category_key': category_key,
                        'category_name': season_name  # 保存合集标题
                    }
                    videos.append(video)
                print(f"合集 {category_key} 获取到 {len(videos)} 个视频，标题: {season_name}")
                return videos, season_name
    except Exception as e:
        print(f"获取合集 {category_key} 失败: {e}")
        return [], None

async def fetch_all_videos():
    """获取所有合集的视频，并合并"""
    all_videos = []
    seen_bvids = set()
    category_names = {}  # 记录每个分类的合集标题

    # 1. 获取各个合集的视频
    for category_key, season_id in SEASON_IDS.items():
        if season_id == 0:
            print(f"跳过合集 {category_key}：season_id 未配置")
            continue
        videos, season_name = await fetch_videos_from_season(season_id, category_key)
        if season_name:
            category_names[category_key] = season_name
        for v in videos:
            if v['bvid'] not in seen_bvids:
                seen_bvids.add(v['bvid'])
                all_videos.append(v)

    # 2. 获取用户所有视频，找出未在合集中的视频归为“其他”
    try:
        u = user.User(uid=BILIBILI_UID)
        page = await u.get_videos(ps=50)
        vlist = page.get('list', {}).get('vlist', [])

        for item in vlist:
            bvid = item.get('bvid')
            if bvid not in seen_bvids:
                video = {
                    'bvid': bvid,
                    'title': item.get('title'),
                    'cover': item.get('pic', '').replace('http://', 'https://'),
                    'play': format_count(item.get('play', 0)),
                    'duration': item.get('length', '00:00'),
                    'pubdate': item.get('created', 0),
                    'category_key': '其他',
                    'category_name': '《其他》'  # 固定名称
                }
                all_videos.append(video)
                seen_bvids.add(bvid)
    except Exception as e:
        print(f"获取用户视频列表失败: {e}")

    # 按发布时间倒序排序
    all_videos.sort(key=lambda x: x['pubdate'], reverse=True)
    print(f"总计获取 {len(all_videos)} 个视频")
    return all_videos

def update_html(videos):
    """更新 index.html 中的 VIDEOS 数组"""
    try:
        with open('index.html', 'r', encoding='utf-8') as f:
            content = f.read()

        new_array_str = json.dumps(videos, ensure_ascii=False, indent=4)

        start_marker = '/*<VIDEOS>*/'
        end_marker = '/*</VIDEOS>*/'

        start_idx = content.find(start_marker)
        end_idx = content.find(end_marker)

        if start_idx == -1 or end_idx == -1:
            print("错误：未找到标记 /*<VIDEOS>*/ 或 /*</VIDEOS>*/")
            return False

        start_content = content[:start_idx + len(start_marker)]
        end_content = content[end_idx:]

        new_content = start_content + new_array_str + end_content

        if new_content == content:
            print("无变化，跳过写入")
            return False
        else:
            with open('index.html', 'w', encoding='utf-8') as f:
                f.write(new_content)
            print("index.html 已更新")
            return True
    except Exception as e:
        print(f"更新失败: {e}")
        return False

def main():
    print("开始从B站合集获取视频数据...")
    videos = asyncio.run(fetch_all_videos())
    if not videos:
        print("获取视频失败，退出")
        sys.exit(1)
    update_html(videos)

if __name__ == '__main__':
    main()
