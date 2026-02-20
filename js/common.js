// js/common.js

// 全局变量（将被页面中的具体值覆盖）
let AUTHOR_NAME = '';

// 夜间模式切换
function toggleTheme() {
    const body = document.body;
    const themeBtn = document.getElementById('themeToggle');
    body.classList.toggle('dark-mode');
    const isDark = body.classList.contains('dark-mode');
    themeBtn.innerText = isDark ? '☀️ 白天模式' : '🌙 夜间模式';
    localStorage.setItem('theme', isDark ? 'dark' : 'light');
}

function initTheme() {
    const savedTheme = localStorage.getItem('theme');
    const body = document.body;
    const themeBtn = document.getElementById('themeToggle');
    if (savedTheme === 'dark') {
        body.classList.add('dark-mode');
        if (themeBtn) themeBtn.innerText = '☀️ 白天模式';
    } else {
        if (themeBtn) themeBtn.innerText = '🌙 夜间模式';
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

    if (!VIDEOS || VIDEOS.length === 0) {
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
