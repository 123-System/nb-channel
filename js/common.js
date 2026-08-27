// js/common.js

// 全局变量（将被页面中的具体值覆盖）
let AUTHOR_NAME = '';

// ==========================================================
// IP 封禁检查（所有页面加载时自动执行，命中则整页替换为封禁提示）
// ==========================================================
async function checkBannedIP() {
    try {
        // 获取客户端公网 IP（多服务兜底：个别 IP 服务不可用时自动切换，不阻断访问）
        const services = [
            'https://icanhazip.com',
            'https://ifconfig.me/ip',
            'https://api.ipify.org?format=text'
        ];
        let ip = '';
        for (const url of services) {
            try {
                const resp = await fetch(url, { cache: 'no-store' });
                if (resp.ok) {
                    ip = (await resp.text()).trim();
                    if (ip) break;
                }
            } catch (e) { /* 尝试下一个 */ }
        }
        if (!ip) return;

        // 查询黑名单（直接走 REST API，不依赖页面各自的 supabaseClient）
        const SUPABASE_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co';
        const SUPABASE_ANON_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg';
        const res = await fetch(
            `${SUPABASE_URL}/rest/v1/banned_ips?ip=eq.${encodeURIComponent(ip)}&select=reason`,
            { headers: { apikey: SUPABASE_ANON_KEY, Authorization: 'Bearer ' + SUPABASE_ANON_KEY } }
        );
        if (!res.ok) return;
        const data = await res.json();
        if (data && data.length > 0) {
            const reason = data[0].reason || '违反网站规则';
            document.body.innerHTML = `
                <div style="display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:100vh; background:#1a1a1a; color:#e0e0e0; text-align:center; padding:20px; font-family:sans-serif;">
                    <div style="font-size:4rem; margin-bottom:16px;">🚫</div>
                    <h1 style="margin-bottom:12px;">您已被封禁</h1>
                    <p style="color:#aaa; margin-bottom:8px;">原因：${reason}</p>
                    <p style="color:#777; font-size:0.85rem;">如有疑问，请联系站长：nbchannel@163.com</p>
                </div>`;
            throw new Error('IP banned');
        }
    } catch (e) {
        if (e && e.message === 'IP banned') throw e;  // 已替换页面，停止后续脚本
        // 其他错误（网络等）忽略，不阻断正常访问
    }
}
checkBannedIP();

// ==========================================================
// 消息未读红点（自动注入到导航栏"🔔 消息"按钮上）
// ==========================================================
async function updateUnreadBadge() {
    const link = document.querySelector('a[href="messages.html"]');
    if (!link) return;
    const stored = localStorage.getItem('nb_user');
    if (!stored) return;
    try {
        const user = JSON.parse(stored);
        const SUPABASE_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co';
        const SUPABASE_ANON_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg';
        const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_unread_counts`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                apikey: SUPABASE_ANON_KEY,
                Authorization: 'Bearer ' + SUPABASE_ANON_KEY
            },
            body: JSON.stringify({ p_user_id: user.id })
        });
        if (!res.ok) return;
        const data = await res.json();
        const total = (data || []).reduce((s, x) => s + (x.count || 0), 0);

        let badge = link.querySelector('.nav-badge');
        if (!badge) {
            badge = document.createElement('span');
            badge.className = 'nav-badge';
            badge.style.cssText = 'display:none; background:#ff4757; color:#fff; border-radius:50%; font-size:0.65rem; min-width:16px; height:16px; line-height:16px; text-align:center; padding:0 4px; margin-left:4px; vertical-align:top;';
            link.appendChild(badge);
        }
        if (total > 0) {
            badge.textContent = total > 99 ? '99+' : total;
            badge.style.display = 'inline-block';
        } else {
            badge.style.display = 'none';
        }
    } catch (e) { /* 忽略，不阻断页面 */ }
}
updateUnreadBadge();
// 每 60 秒刷新一次未读数
setInterval(updateUnreadBadge, 60000);

// ==========================================================
// 私信未读红点（自动注入到导航栏"👥 好友"按钮上）
// ==========================================================
async function updateChatBadge() {
    const link = document.querySelector('a[href="chat.html"]');
    if (!link) return;
    const stored = localStorage.getItem('nb_user');
    if (!stored) return;
    try {
        const user = JSON.parse(stored);
        const SUPABASE_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co';
        const SUPABASE_ANON_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg';
        const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_unread_messages`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                apikey: SUPABASE_ANON_KEY,
                Authorization: 'Bearer ' + SUPABASE_ANON_KEY
            },
            body: JSON.stringify({ p_user: user.id })
        });
        if (!res.ok) return;
        const data = await res.json();
        const total = (data && data.count) || 0;

        let badge = link.querySelector('.nav-badge');
        if (!badge) {
            badge = document.createElement('span');
            badge.className = 'nav-badge';
            badge.style.cssText = 'display:none; background:#ff4757; color:#fff; border-radius:50%; font-size:0.65rem; min-width:16px; height:16px; line-height:16px; text-align:center; padding:0 4px; margin-left:4px; vertical-align:top;';
            link.appendChild(badge);
        }
        if (total > 0) {
            badge.textContent = total > 99 ? '99+' : total;
            badge.style.display = 'inline-block';
        } else {
            badge.style.display = 'none';
        }
    } catch (e) { /* 忽略，不阻断页面 */ }
}
updateChatBadge();
// 每 30 秒刷新一次私信未读
setInterval(updateChatBadge, 30000);

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

// ==========================================================
// 🪙 随机金币彩蛋：随机时间出现在页面随机位置，点击领 NB币
// 后端防刷：冷却 20 分钟/次 + 每日 5 次（admin_config 可调）
// ==========================================================
(function () {
    if (window.__nbCoinLoaded) return;
    window.__nbCoinLoaded = true;

    const C_URL = 'https://pbaafgjkwdbwcmsikcmg.supabase.co';
    const C_KEY = 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg';

    function coinGetUser() {
        try { return JSON.parse(localStorage.getItem('nb_user')); } catch (e) { return null; }
    }

    async function coinRpc(name, body) {
        const res = await fetch(`${C_URL}/rest/v1/rpc/${name}`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                apikey: C_KEY,
                Authorization: 'Bearer ' + C_KEY
            },
            body: JSON.stringify(body)
        });
        if (!res.ok) throw new Error('coin rpc ' + res.status);
        return res.json();
    }

    // 注入动画样式（一次性）
    if (!document.getElementById('nbCoinStyle')) {
        const st = document.createElement('style');
        st.id = 'nbCoinStyle';
        st.textContent = `
            @keyframes nbCoinFloat { 0%,100%{transform:translateY(0)} 50%{transform:translateY(-9px)} }
            @keyframes nbCoinGlow { 0%,100%{filter:drop-shadow(0 0 6px rgba(255,215,0,.7))} 50%{filter:drop-shadow(0 0 18px rgba(255,215,0,1))} }
            @keyframes nbCoinPop { 0%{transform:scale(.4);opacity:0} 60%{transform:scale(1.15);opacity:1} 100%{transform:scale(1);opacity:1} }
            .nb-coin-burst { position:fixed; z-index:100000; font-weight:700; font-size:1.1rem; color:#ff9800; text-shadow:0 0 6px rgba(255,215,0,.8); pointer-events:none; animation:nbCoinPop .5s ease-out; }
        `;
        document.head.appendChild(st);
    }

    function coinHide() {
        const c = document.getElementById('nbCoin');
        if (!c) return;
        c.style.transition = 'opacity .5s, transform .5s';
        c.style.opacity = '0';
        c.style.transform = 'scale(.2)';
        setTimeout(() => c.remove(), 600);
    }

    function coinBurst(x, y, text) {
        const el = document.createElement('div');
        el.className = 'nb-coin-burst';
        el.textContent = text;
        el.style.left = x + 'px';
        el.style.top = y + 'px';
        document.body.appendChild(el);
        setTimeout(() => el.remove(), 1200);
    }

    function coinShow() {
        if (document.getElementById('nbCoin')) return;
        const coin = document.createElement('div');
        coin.id = 'nbCoin';
        coin.title = '🪙 点击领取 NB币！';
        coin.textContent = '🪙';
        const size = 46;   // 估算金币尺寸（px）
        const vw = window.innerWidth, vh = window.innerHeight;
        const x = 20 + Math.random() * Math.max(vw - size - 40, 40);
        const y = 60 + Math.random() * Math.max(vh - size - 100, 40);
        // 随机方向、随机速度（0.6~1.2 px/帧，慢悠悠地飘）
        let dx = (Math.random() < 0.5 ? -1 : 1) * (0.6 + Math.random() * 0.6);
        let dy = (Math.random() < 0.5 ? -1 : 1) * (0.6 + Math.random() * 0.6);
        coin.style.cssText = `position:fixed; left:${x}px; top:${y}px; font-size:2.4rem; line-height:1; cursor:pointer; z-index:99999; user-select:none; -webkit-user-select:none; animation:nbCoinFloat 2s ease-in-out infinite, nbCoinGlow 1.2s ease-in-out infinite;`;
        document.body.appendChild(coin);

        // 移动 + 碰到视口边缘反弹（每次取最新视口尺寸，窗口缩放也不跑偏）
        let raf = null;
        function step() {
            const w = coin.offsetWidth || size;
            const h = coin.offsetHeight || size;
            const W = window.innerWidth, H = window.innerHeight;
            let nx = parseFloat(coin.style.left) + dx;
            let ny = parseFloat(coin.style.top) + dy;
            if (nx <= 4) { nx = 4; dx = Math.abs(dx); }
            else if (nx >= W - w - 4) { nx = W - w - 4; dx = -Math.abs(dx); }
            if (ny <= 4) { ny = 4; dy = Math.abs(dy); }
            else if (ny >= H - h - 4) { ny = H - h - 4; dy = -Math.abs(dy); }
            coin.style.left = nx + 'px';
            coin.style.top = ny + 'px';
            raf = requestAnimationFrame(step);
        }
        raf = requestAnimationFrame(step);

        function stopMove() {
            if (raf) { cancelAnimationFrame(raf); raf = null; }
        }

        coin.onclick = async (e) => {
            e.stopPropagation();
            coin.onclick = null;
            stopMove();
            const rect = coin.getBoundingClientRect();
            const cx = rect.left, cy = rect.top;
            try {
                const user = coinGetUser();
                if (!user) { coinHide(); return; }
                const data = await coinRpc('claim_coin', { p_user_id: user.id });
                if (data && data.success) {
                    coinBurst(cx, cy - 40, `+${data.amount} NB 🎉`);
                } else {
                    coinBurst(cx, cy - 40, '⏳ 下次再来~');
                }
                coinHide();
            } catch (err) { coinHide(); }
        };
        // 45 秒内没人点就消失
        setTimeout(() => { stopMove(); coinHide(); }, 45000);
    }

    function coinSchedule() {
        const user = coinGetUser();
        if (!user) {
            // 未登录：2 分钟后再看（用户可能刚登录）
            setTimeout(coinSchedule, 120000);
            return;
        }
        // 随机 5~10 分钟出现一次
        const delay = (5 + Math.random() * 5) * 60000;
        setTimeout(async () => {
            try {
                const data = await coinRpc('can_claim_coin', { p_user_id: user.id });
                if (data && data.can) coinShow();
            } catch (e) { /* 忽略 */ }
            coinSchedule();
        }, delay);
    }

    // 页面加载 3 秒后启动调度，首次出现随机 5~10 分钟
    setTimeout(() => {
        setTimeout(coinSchedule, (5 + Math.random() * 5) * 60000);
    }, 3000);
})();

// ==========================================================
// 界面版本（新版/旧版）：后端存储偏好 + 本地缓存，默认新版
// ==========================================================
function getUIVersion() {
    // -new 文件强制新版（页面本身即新版版式）
    var page = (location.pathname.split('/').pop() || '').toLowerCase();
    if (page.indexOf('-new.html') !== -1) return 'new';
    return localStorage.getItem('nb_ui') === 'old' ? 'old' : 'new';
}

function setUIVersion(v) {
    var ver = v === 'old' ? 'old' : 'new';
    localStorage.setItem('nb_ui', ver);
    // 登录用户同时写后端（换设备/浏览器也保持偏好）
    try {
        var stored = JSON.parse(localStorage.getItem('nb_user'));
        if (stored && stored.id) {
            fetch('https://pbaafgjkwdbwcmsikcmg.supabase.co/rest/v1/rpc/set_ui_version', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    apikey: 'sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg',
                    Authorization: 'Bearer sb_publishable_tv7YVJEisnvs3hvU8ImYUw_b0p6bmRg'
                },
                body: JSON.stringify({ p_user_id: stored.id, p_version: ver })
            }).catch(function () {});
        }
    } catch (e) {}
}

// ==========================================================
// uiHref：站内链接转 -new 版本（仅在新版文件内生效，旧版文件原样返回）
// ==========================================================
function uiHref(h) {
    var page = (location.pathname.split('/').pop() || '').toLowerCase();
    if (page.indexOf('-new.html') === -1) return h;
    return String(h).replace(/\.html(?=[?#]|$)/, '-new.html');
}

// 新版文件内：拦截所有站内链接点击，直接跳 -new 版本（消除"先跳旧版再重定向"的闪跳）
(function () {
    document.addEventListener('click', function (e) {
        var page = (location.pathname.split('/').pop() || '').toLowerCase();
        if (page.indexOf('-new.html') === -1) return;
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a || a.onclick) return;   // 有自定义 onclick 的链接交给页面逻辑
        var href = a.getAttribute('href') || '';
        if (href.indexOf('.html') === -1 || href.indexOf('http') === 0 ||
            href.indexOf('#') === 0 || href.indexOf('-new.html') !== -1) return;
        e.preventDefault();
        location.href = uiHref(href);
    });
})();

// ==========================================================
// 界面版本自动跳转（同步、零闪跳）：本地偏好决定进哪个文件
// 单文件双皮肤：xxx.html 同时承载新旧 UI，不再需要跳 -new
// -new 文件仍兼容访问（旧链接），偏好 old 时跳回单文件
// ==========================================================
(function () {
    var rawPage = location.pathname.split('/').pop() || '';
    var page = rawPage.toLowerCase();
    if (page.indexOf('.html') === -1) return;
    var isNew = page.indexOf('-new.html') !== -1;
    var base = isNew ? rawPage.replace(/-new\.html$/i, '.html') : rawPage;
    var known = ['index', 'videos', 'about', 'changelog', 'product', 'app', 'comments-beta',
                 'virtual stock', 'chat', 'product_share', 'messages', 'profile', 'achievements',
                 'lottery_records', 'register_company', 'comments', 'login', 'tools', 'titles', 'bank',
                 'shop', 'backpack'];
    if (known.indexOf(base.replace(/\.html$/i, '').toLowerCase()) === -1) return;

    var pref = localStorage.getItem('nb_ui') === 'old' ? 'old' : 'new';
    var qs = location.search || '';
    // -new 文件：偏好 old → 跳回单文件；偏好 new → 留在 -new（内容一致，无需跳）
    if (isNew && pref === 'old') {
        location.replace(base + qs);
    }
    // 单文件：无需任何跳转（新旧 UI 都在本文件内切换）
})();

// ==========================================================
// 自动加载新版界面驱动 js/ui-nav.js（全站生效，无需改页面）
// 用 currentScript 定位 js/ 目录，兼容任意目录下的页面
// ==========================================================
(function () {
    if (window.__uiNavLoaded) return;
    window.__uiNavLoaded = true;
    var src = '';
    try {
        src = (document.currentScript && document.currentScript.src) || '';
    } catch (e) {}
    var scriptPath = 'js/ui-nav.js?v=20260825';
    if (src) {
        var i = src.lastIndexOf('/');
        if (i !== -1) {
            var dir = src.substring(0, i);
            var j = dir.lastIndexOf('/');
            scriptPath = (j !== -1 ? dir.substring(0, j + 1) : dir + '/') + 'js/ui-nav.js?v=20260825';
        }
    }
    var s = document.createElement('script');
    s.src = scriptPath;
    s.async = false;   // 保持顺序执行
    document.head.appendChild(s);
})();
