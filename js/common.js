// js/common.js

// 全局变量（将被页面中的具体值覆盖）
let AUTHOR_NAME = '';

function toggleTheme() {
    const body = document.body;
    body.classList.toggle('dark-mode');
    const isDark = body.classList.contains('dark-mode');
    localStorage.setItem('theme', isDark ? 'dark' : 'light');
}

function initTheme() {
    const savedTheme = localStorage.getItem('theme');
    const body = document.body;
    if (savedTheme === 'dark') {
        body.classList.add('dark-mode');
    } else {
        body.classList.remove('dark-mode');
    }
}

// 回到顶部
function scrollToTop() {
    window.scrollTo({ top: 0, behavior: 'smooth' });
}

window.addEventListener('scroll', function() {
    const backBtn = document.getElementById('backToTop');
    if (backBtn) {
        if (window.scrollY > 300) {
            backBtn.classList.add('show');
        } else {
            backBtn.classList.remove('show');
        }
    }
});

// 建站统计
function updateSiteStats() {
    const statsDiv = document.getElementById('siteStats');
    if (!statsDiv) return;

    if (typeof VIDEOS === 'undefined' || !VIDEOS || VIDEOS.length === 0) {
        statsDiv.innerHTML = '📊 建站日期：2026-02-17 | 暂无视频数据';
        return;
    }

    const latest = VIDEOS.reduce((max, v) => Math.max(max, v.pubdate || 0), 0);
    if (latest === 0) {
        statsDiv.innerHTML = '📊 建站日期：2026-02-17 | 暂无更新记录';
        return;
    }

    const date = new Date(latest * 1000);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hour = String(date.getHours()).padStart(2, '0');
    const minute = String(date.getMinutes()).padStart(2, '0');

    statsDiv.innerHTML = `📊 建站日期：2026-02-17 | 最后更新：${year}-${month}-${day} ${hour}:${minute}（根据最新视频发布时间）`;
}

// 将播放量字符串转换为数字（用于排序）
function parsePlayCount(playStr) {
    if (!playStr) return 0;
    if (typeof playStr === 'number') return playStr;
    const match = playStr.match(/^([\d.]+)万$/);
    if (match) {
        return parseFloat(match[1]) * 10000;
    }
    return parseInt(playStr) || 0;

}

// ==========================================================
// 分享按钮
// ==========================================================
function initShareButton() {
    const shareBtn = document.getElementById('shareButton');
    if (!shareBtn) return;

    shareBtn.addEventListener('click', async () => {
        const shareData = {
            title: 'NB频道官网',
            text: '频道主要分享有趣的化学、物理实验和日常作死小技巧，以后还会有产品问世，欢迎关注！',
            url: window.location.href
        };
        if (navigator.share) {
            try {
                await navigator.share(shareData);
                console.log('分享成功');
            } catch (err) {
                if (err.name !== 'AbortError') {
                    console.error('分享失败', err);
                    fallbackCopy();
                }
            }
        } else {
            fallbackCopy();
        }
    });
}

function fallbackCopy() {
    const input = document.createElement('input');
    input.value = window.location.href;
    document.body.appendChild(input);
    input.select();
    document.execCommand('copy');
    document.body.removeChild(input);
    alert('链接已复制到剪贴板！');
}
