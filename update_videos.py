# update_videos.py
import re
import json
import sys
from bilibili_api import user, sync

BILIBILI_UID = 3493259582114264

def format_count(num):
    if not num:
        return '0'
    try:
        num = int(num)
    except:
        return str(num)
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
        print(f"获取用户视频失败: {e}", file=sys.stderr)
        return []

def update_html(videos):
    try:
        with open('index.html', 'r', encoding='utf-8') as f:
            content = f.read()

        new_array_str = json.dumps(videos, ensure_ascii=False, indent=4)

        # 精确匹配 const VIDEOS = [  ...  ];
        # 使用非贪婪匹配，确保只替换最外层数组
        pattern = r'(const VIDEOS = \[)(.*?)(\];)'
        replacement = r'\1' + new_array_str + r'\3'
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

        if new_content == content:
            print("未发现变化，跳过写入")
            return False
        else:
            with open('index.html', 'w', encoding='utf-8') as f:
                f.write(new_content)
            print("index.html 已更新")
            return True
    except Exception as e:
        print(f"更新 HTML 失败: {e}", file=sys.stderr)
        return False

def main():
    print("开始获取 B站 视频数据...")
    videos = fetch_user_videos_sync(BILIBILI_UID)
    if not videos:
        print("获取视频失败，不更新 HTML")
        sys.exit(1)
    print(f"成功获取 {len(videos)} 个视频")
    update_html(videos)

if __name__ == '__main__':
    main()
