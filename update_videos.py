# update_videos.py
import re
import json
import asyncio
from bilibili_api import user

# ==================== 配置区域 ====================
BILIBILI_UID = 3493259582114264  # 你的UID
# ==================================================

def format_count(num):
    """格式化播放量（小于1万显示原数字，大于等于1万显示x.x万）"""
    if not num:
        return '0'
    try:
        num = int(num)
    except:
        return str(num)
    return f"{num/10000:.1f}万" if num >= 10000 else str(num)

async def fetch_user_videos(uid):
    """获取用户最新发布的50个视频"""
    try:
        u = user.User(uid=uid)
        page = await u.get_videos(ps=50)
        vlist = page.get('list', {}).get('vlist', [])
        videos = []
        for item in vlist:
            videos.append({
                'bvid': item.get('bvid'),
                'title': item.get('title'),
                'cover': item.get('pic'),          # 注意：这里返回的是 http，后面再统一处理
                'play': format_count(item.get('play', 0)),
                'duration': item.get('length', '00:00'),
                'pubdate': item.get('created', 0)
            })
        videos.sort(key=lambda x: x['pubdate'], reverse=True)
        return videos
    except Exception as e:
        print(f"获取用户视频失败: {e}")
        return []

def update_html(videos):
    """读取 index.html，替换 VIDEOS 数组为新数据"""
    try:
        with open('index.html', 'r', encoding='utf-8') as f:
            content = f.read()

        # 将视频列表转换为格式化的 JSON 字符串
        # 注意：确保生成的字符串与原来的缩进风格一致（4空格缩进）
        new_array_str = json.dumps(videos, ensure_ascii=False, indent=4)

        # 使用正则替换 VIDEOS 数组内容
        # 匹配从 "const VIDEOS = [" 到 "];" 之间的所有内容（包括跨行）
        pattern = r'(const VIDEOS = \[).*?(\];)'
        replacement = r'\1' + new_array_str + r'\2'
        new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

        if new_content == content:
            print("未发现变化，跳过写入")
        else:
            with open('index.html', 'w', encoding='utf-8') as f:
                f.write(new_content)
            print("index.html 已更新")
    except Exception as e:
        print(f"更新 HTML 失败: {e}")

def main():
    # 运行异步任务获取视频
    videos = asyncio.run(fetch_user_videos(BILIBILI_UID))
    if videos:
        # 注意：B站返回的封面地址是 http，如果你的网站是 https，需要替换为 https
        for v in videos:
            if v['cover'].startswith('http://'):
                v['cover'] = v['cover'].replace('http://', 'https://')
        update_html(videos)
    else:
        print("获取视频失败，不更新 HTML")

if __name__ == '__main__':
    main()