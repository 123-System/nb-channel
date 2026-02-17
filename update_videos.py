# update_videos.py
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

        # 生成新的数组字符串（不带外层括号）
        new_array_str = json.dumps(videos, ensure_ascii=False, indent=4)

        # 使用标记定位：/*<VIDEOS>*/ 和 /*</VIDEOS>*/
        start_marker = '/*<VIDEOS>*/'
        end_marker = '/*</VIDEOS>*/'

        start_idx = content.find(start_marker)
        end_idx = content.find(end_marker)

        if start_idx == -1 or end_idx == -1:
            print("错误：未找到标记 /*<VIDEOS>*/ 或 /*</VIDEOS>*/")
            return False

        # 找到标记后的第一个 '[' 和结束标记前的最后一个 ']'，确保替换精确的数组内容
        # 更简单：直接替换两个标记之间的所有内容，但保留标记本身
        start_content = content[:start_idx + len(start_marker)]
        end_content = content[end_idx:]

        new_content = start_content + new_array_str + end_content

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
    print("开始获取 B站 视频数据...")
    videos = fetch_user_videos_sync(BILIBILI_UID)
    if not videos:
        print("获取失败，退出")
        sys.exit(1)
    print(f"成功获取 {len(videos)} 个视频")
    update_html(videos)

if __name__ == '__main__':
    main()
