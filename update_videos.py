# update_videos.py (最终版)
import re
import json
import sys
from bilibili_api import user, sync

BILIBILI_UID = 3493259582114264

def format_count(num):
    if not num: return '0'
    try: num = int(num)
    except: return str(num)
    return f"{num/10000:.1f}万" if num >= 10000 else str(num)

def fetch_user_videos_sync(uid):
    try:
        u = user.User(uid=uid)
        page = sync(u.get_videos(ps=50))
        vlist = page.get('list', {}).get('vlist', [])
        videos = []
        for item in vlist:
            video = {
                'bvid': item.get('bvid', ''),
                'title': item.get('title', '无标题'),
                'cover': item.get('pic', ''),
                'play': format_count(item.get('play', 0)),
                'duration': item.get('length', '00:00'),
                'pubdate': item.get('created', 0)
            }
            if video['cover'].startswith('http://'):
                video['cover'] = video['cover'].replace('http://', 'https://')
            videos.append(video)
        videos.sort(key=lambda x: x['pubdate'], reverse=True)
        return videos
    except Exception as e:
        print(f"获取失败: {e}")
        return []

def update_html(videos):
    try:
        with open('index.html', 'r', encoding='utf-8') as f:
            content = f.read()

        new_array_str = json.dumps(videos, ensure_ascii=False, indent=4)

        # 匹配 const VIDEOS = [ 到 ]; 之间的所有内容（包括换行），采用非贪婪模式
        # 注意：确保原文件中的 VIDEOS 是一层数组，没有多余括号
        pattern = r'(const VIDEOS = \[)([\s\S]*?)(\];)'
        replacement = r'\1' + new_array_str + r'\3'
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

        if new_content == content:
            print("无变化，跳过")
            return False
        else:
            with open('index.html', 'w', encoding='utf-8') as f:
                f.write(new_content)
            print("已更新")
            return True
    except Exception as e:
        print(f"更新失败: {e}")
        return False

def main():
    videos = fetch_user_videos_sync(BILIBILI_UID)
    if videos:
        print(f"获取到 {len(videos)} 个视频")
        update_html(videos)
    else:
        print("获取失败，退出")
        sys.exit(1)

if __name__ == '__main__':
    main()
