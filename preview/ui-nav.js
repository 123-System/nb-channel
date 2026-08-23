// ============================================================
// preview/ui-nav.js — 全站新版界面预览（预览目录专用，不动正式文件）
// 用法：在页面 common.js 引用之后加入 <script src="ui-nav.js"></script>
// 功能：
//   1. 自动把页面现有的旧版导航（.nav-container）替换为"新版通栏导航"
//      （Logo + 主菜单 + 登录按钮 + 快捷入口条），页面原有链接全部保留
//   2. 为每个页面注入官网风格：渐变 Hero 横幅（页面标题）+ 鼠标特效
//      （跟随光晕 + 点击粒子），已有 .hero 的页面（官网首页）跳过横幅
//   3. 右下角 🖥️/📄 按钮在"新版/旧版"界面之间切换（localStorage: nb_ui_preview）
//   4. 旧版 = 保留页面原始导航不动
// ============================================================
(function () {
    var VERSION_KEY = 'nb_ui_preview';

    function getVer() {
        return localStorage.getItem(VERSION_KEY) === 'old' ? 'old' : 'new';
    }

    // 注入界面切换按钮
    function injectToggle() {
        if (document.getElementById('uiToggleBtn')) return;
        var btn = document.createElement('button');
        btn.id = 'uiToggleBtn';
        btn.title = getVer() === 'new' ? '当前：新版界面，点击切换回旧版' : '当前：旧版界面，点击切换到新版';
        btn.textContent = getVer() === 'new' ? '🖥️' : '📄';
        btn.onclick = function () {
            localStorage.setItem(VERSION_KEY, getVer() === 'new' ? 'old' : 'new');
            location.reload();
        };
        document.body.appendChild(btn);
    }

    // 新版时加载同目录 premium.css（页面内容级高级感，旧版不加载）
    function loadPremiumCss() {
        if (document.getElementById('uiPremiumCss')) return;
        var src = '';
        try {
            src = (document.currentScript && document.currentScript.src) || '';
        } catch (e) {}
        var base = '';
        if (src) {
            var i = src.lastIndexOf('/');
            if (i !== -1) base = src.substring(0, i + 1);
        }
        var link = document.createElement('link');
        link.id = 'uiPremiumCss';
        link.rel = 'stylesheet';
        link.href = base + 'premium.css';
        document.head.appendChild(link);
    }

    // 鼠标特效（仅鼠标设备）：跟随光晕 + 点击粒子/波纹
    function injectMouseFx() {
        if (document.getElementById('uiMouseFx') || !(window.matchMedia && window.matchMedia('(pointer: fine)').matches)) return;
        var st = document.createElement('style');
        st.id = 'uiMouseFx';
        st.textContent = `
            @keyframes uiFxPop { 0%{transform:scale(.4);opacity:0} 60%{transform:scale(1.15);opacity:1} 100%{transform:scale(1);opacity:1} }
            .ui-fx-burst { position:fixed; z-index:100000; font-weight:700; pointer-events:none; animation:uiFxPop .5s ease-out; }
        `;
        document.head.appendChild(st);

        // 跟随光晕
        var glow = document.createElement('div');
        glow.style.cssText = 'position:fixed; left:-999px; top:-999px; width:240px; height:240px; border-radius:50%; pointer-events:none; z-index:9997; transform:translate(-50%,-50%); background:radial-gradient(circle, rgba(0,161,214,0.20), rgba(108,92,231,0.10) 45%, transparent 65%);';
        document.body.appendChild(glow);
        var gx = -999, gy = -999, tx = -999, ty = -999;
        document.addEventListener('mousemove', function (e) { tx = e.clientX; ty = e.clientY; });
        document.addEventListener('mouseleave', function () { glow.style.opacity = '0'; });
        document.addEventListener('mouseenter', function () { glow.style.opacity = '1'; });
        (function loop() {
            gx += (tx - gx) * 0.14;
            gy += (ty - gy) * 0.14;
            glow.style.left = gx + 'px';
            glow.style.top = gy + 'px';
            requestAnimationFrame(loop);
        })();

        // 点击粒子 + 波纹
        var colors = ['#00a1d6', '#6c5ce7', '#ff9800', '#ffd700', '#4caf50'];
        document.addEventListener('click', function (e) {
            var ring = document.createElement('div');
            ring.style.cssText = 'position:fixed; left:' + e.clientX + 'px; top:' + e.clientY + 'px; width:12px; height:12px; border:2px solid rgba(0,161,214,0.75); border-radius:50%; pointer-events:none; z-index:9999; transform:translate(-50%,-50%);';
            document.body.appendChild(ring);
            ring.animate([
                { transform: 'translate(-50%,-50%) scale(1)', opacity: 0.9 },
                { transform: 'translate(-50%,-50%) scale(5.5)', opacity: 0 }
            ], { duration: 600, easing: 'ease-out' }).onfinish = function () { ring.remove(); };

            for (var i = 0; i < 8; i++) {
                var p = document.createElement('div');
                var size = 4 + Math.random() * 6;
                var ang = Math.random() * Math.PI * 2;
                var dist = 28 + Math.random() * 52;
                p.style.cssText = 'position:fixed; left:' + e.clientX + 'px; top:' + e.clientY + 'px; width:' + size + 'px; height:' + size + 'px; border-radius:50%; background:' + colors[i % colors.length] + '; pointer-events:none; z-index:9999;';
                document.body.appendChild(p);
                var dx = Math.cos(ang) * dist, dy = Math.sin(ang) * dist;
                p.animate([
                    { transform: 'translate(0,0) scale(1)', opacity: 1 },
                    { transform: 'translate(' + dx + 'px,' + dy + 'px) scale(0.1)', opacity: 0 }
                ], { duration: 500 + Math.random() * 250, easing: 'cubic-bezier(0.15,0.8,0.25,1)' }).onfinish = function () { p.remove(); };
            }
        });
    }

    // 页面 Hero 横幅（官网首页已有 .hero 则跳过）
    function injectBanner() {
        if (document.getElementById('uiPageBanner')) return;
        if (document.querySelector('.hero')) return;
        var banner = document.createElement('div');
        banner.id = 'uiPageBanner';
        // 标题：取 <title> 去 "- NB频道" 后缀
        var title = (document.title || '').replace(/\s*[-–—]\s*NB频道.*$/, '').trim() || 'NB频道';
        banner.innerHTML =
            '<div style="position:absolute; top:-60px; right:-60px; width:200px; height:200px; border-radius:50%; background:rgba(255,255,255,0.08);"></div>' +
            '<div style="position:absolute; bottom:-80px; left:-40px; width:220px; height:220px; border-radius:50%; background:rgba(255,255,255,0.06);"></div>' +
            '<div style="font-size:1.9rem; font-weight:900; color:#fff; text-shadow:0 2px 8px rgba(0,0,0,0.2);">' + title + '</div>' +
            '<div style="font-size:0.95rem; opacity:0.92; color:#fff; margin-top:6px;">📺 NB频道 · 虚拟公司 · 官网</div>';
        banner.style.cssText = 'position:relative; overflow:hidden; background:linear-gradient(135deg, #00a1d6 0%, #0a84c1 45%, #6c5ce7 100%); border-radius:24px; padding:36px 28px; text-align:center; margin-bottom:24px; box-shadow:0 18px 40px -12px rgba(0,161,214,0.5);';
        // 插入到导航之后（body 顶部附近）
        var navHost = document.querySelector('.top-nav') || document.querySelector('.quick-nav');
        var container = document.querySelector('.container') || document.body;
        if (navHost && navHost.nextSibling) {
            container.insertBefore(banner, navHost.nextSibling);
        } else {
            container.insertBefore(banner, container.firstChild);
        }
        // 隐藏页面原本的第一个 h1（避免与横幅重复）
        var h1 = document.querySelector('h1');
        if (h1) h1.style.display = 'none';
    }

    // 新版导航样式（内联注入，不依赖 style.css 修改）
    function injectStyle() {
        if (document.getElementById('uiNavStyle')) return;
        var st = document.createElement('style');
        st.id = 'uiNavStyle';
        st.textContent = `
            .nav-container { margin-bottom: 30px; }
            .top-nav {
                position: sticky; top: 0; z-index: 300;
                display: flex; align-items: center; gap: 14px;
                background: var(--card-bg); border: 1px solid var(--card-border);
                border-radius: 18px; padding: 10px 18px; margin-bottom: 24px;
                box-shadow: 0 8px 24px -10px rgba(0,0,0,0.14);
            }
            .top-nav .nav-logo {
                font-size: 1.2rem; font-weight: 800; color: var(--status-border);
                text-decoration: none; white-space: nowrap; letter-spacing: 0.5px;
            }
            .top-nav .nav-menu { display: flex; flex-wrap: wrap; gap: 4px; flex: 1; justify-content: center; }
            .top-nav .nav-menu .nav-btn {
                padding: 8px 16px; font-size: 0.92rem; border-radius: 30px; text-decoration: none;
                color: var(--nav-btn-text); background: var(--nav-btn-bg); transition: 0.2s; white-space: nowrap;
            }
            .top-nav .nav-menu .nav-btn:hover, .top-nav .nav-menu .nav-btn.active {
                background: var(--nav-btn-hover-bg); color: white;
            }
            .top-nav .nav-right { display: flex; gap: 8px; white-space: nowrap; align-items: center; }
            .top-nav .auth-btn, .top-nav .profile-btn {
                background: var(--nav-btn-bg); color: var(--nav-btn-text);
                border: none; border-radius: 30px; padding: 8px 16px; font-size: 0.88rem;
                cursor: pointer; transition: 0.2s;
            }
            .top-nav .auth-btn:hover, .top-nav .profile-btn:hover {
                background: var(--nav-btn-hover-bg); color: white;
            }
            .quick-nav {
                display: flex; justify-content: center; align-items: center; flex-wrap: wrap;
                gap: 8px; margin-bottom: 24px; padding: 12px 14px;
                background: var(--count-bg); border: 1px solid var(--card-border); border-radius: 16px;
            }
            .quick-nav .nav-btn {
                padding: 7px 15px; font-size: 0.9rem; border-radius: 30px; text-decoration: none;
                color: var(--nav-btn-text); background: var(--nav-btn-bg); transition: 0.2s; white-space: nowrap;
            }
            .quick-nav .nav-btn:hover { background: var(--nav-btn-hover-bg); color: white; }
            .quick-nav .share-btn {
                background: var(--nav-btn-bg); color: var(--nav-btn-text);
                border: none; border-radius: 30px; padding: 7px 15px; font-size: 0.9rem;
                cursor: pointer; transition: 0.2s; font-weight: 500; white-space: nowrap;
            }
            .quick-nav .share-btn:hover { background: var(--nav-btn-hover-bg); color: white; }
            #uiToggleBtn {
                position: fixed; bottom: 98px; right: 30px; z-index: 9996;
                width: 50px; height: 50px; border-radius: 50%;
                border: 1px solid var(--card-border);
                background: var(--nav-btn-bg); color: var(--nav-btn-text);
                font-size: 20px; cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.15);
            }
            #uiToggleBtn:hover { background: var(--nav-btn-hover-bg); color: white; }
            @media (max-width: 700px) {
                .top-nav { flex-wrap: wrap; justify-content: space-between; padding: 10px 14px; }
                .top-nav .nav-menu { order: 3; width: 100%; justify-content: center; }
                #uiToggleBtn { bottom: 82px; right: 20px; width: 40px; height: 40px; font-size: 17px; }
            }
            /* ===== 全局主体高级感（index-preview 设计语言） ===== */
            .container, .profile-container, .records-container, .ach-container, .register-card { max-width: 1080px; }
            .home-card, .about-content, .changelog-content, .comment-section, .product-card,
            .upload-section, .info-card, .chat-container, .profile-container, .records-container,
            .ach-container, .register-card, .changelog-content ul, .about-content ul {
                border-radius: 20px !important;
                box-shadow: 0 24px 48px -24px rgba(0,0,0,0.22) !important;
                border: 1px solid var(--card-border) !important;
            }
            .home-card { transition: transform 0.25s, box-shadow 0.25s; }
            .home-card:hover { transform: translateY(-3px); box-shadow: 0 32px 55px -26px rgba(0,0,0,0.28) !important; }
            .author-info {
                display: inline-block; margin: 4px auto 22px;
                background: linear-gradient(135deg, rgba(0,161,214,0.12), rgba(108,92,231,0.10));
                border: 1px solid rgba(0,161,214,0.28); border-radius: 30px;
                padding: 7px 20px; font-size: 0.95rem; color: var(--status-border) !important;
            }
            h2 {
                font-weight: 800; color: var(--text-color);
                letter-spacing: 0.5px;
            }
            .comment-content, .home-card p, .about-content p, .changelog-content li { line-height: 1.95; }
            a { color: var(--status-border); }
            .comment-author { color: var(--text-color) !important; }
            table.data-table, table {
                border-collapse: separate; border-spacing: 0; border-radius: 14px; overflow: hidden;
            }
            input, textarea, select { border-radius: 12px !important; }
            button { border-radius: 30px; }
            .chat-container { border-radius: 24px !important; }
            .chat-header { border-radius: 24px 24px 0 0; }
        `;
        document.head.appendChild(st);
    }

    var MAIN_HREFS = ['index.html', 'videos.html', 'about.html', 'changelog.html', 'product.html', 'APP.html'];

    // 从现有导航 DOM 收集链接 → 渲染新版导航并替换
    function replaceNav() {
        var host = document.querySelector('.nav-container');
        if (!host) { injectToggle(); return; }

        var links = Array.prototype.map.call(host.querySelectorAll('a.nav-btn'), function (a) {
            return { href: a.getAttribute('href') || '', text: (a.textContent || '').trim(), active: a.classList.contains('active') };
        });
        var shareBtn = host.querySelector('.share-btn');
        var shareHtml = shareBtn ? '<button class="share-btn" id="shareButton">' + (shareBtn.textContent || '📤 分享') + '</button>' : '';

        var mainLinks = links.filter(function (l) { return MAIN_HREFS.indexOf(l.href) !== -1; });
        var funcLinks = links.filter(function (l) { return MAIN_HREFS.indexOf(l.href) === -1 && !/^https?:/i.test(l.href); });
        var extraLinks = links.filter(function (l) { return /^https?:/i.test(l.href); });

        var mainHtml = mainLinks.map(function (l) {
            return '<a href="' + l.href + '" class="nav-btn' + (l.active ? ' active' : '') + '">' + l.text + '</a>';
        }).join('');
        var funcHtml = funcLinks.concat(extraLinks).map(function (l) {
            return '<a href="' + l.href + '" class="nav-btn" ' + (/^https?:/i.test(l.href) ? 'target="_blank" rel="noopener noreferrer"' : '') + '>' + l.text + '</a>';
        }).join('');

        var newHtml =
            '<nav class="top-nav">' +
                '<a class="nav-logo" href="index.html">📺 NB频道</a>' +
                '<div class="nav-menu">' + mainHtml + '</div>' +
                '<div class="nav-right">' +
                    '<button id="profileBtn" class="profile-btn">👤 个人中心</button>' +
                    '<button id="authButton" class="auth-btn">登录/注册</button>' +
                '</div>' +
            '</nav>' +
            '<div class="quick-nav">' +
                '<span style="font-size:0.85rem; color:var(--count-text);">⚡ 快捷入口：</span>' +
                funcHtml +
                shareHtml +
            '</div>';

        host.outerHTML = newHtml;

        // 登录按钮默认行为（页面自身逻辑若存在会覆盖）
        var ab = document.getElementById('authButton');
        if (ab && !ab.dataset.navBound) {
            ab.dataset.navBound = '1';
            ab.onclick = function () { window.location.href = 'login.html'; };
        }
        var pb = document.getElementById('profileBtn');
        if (pb && !pb.dataset.navBound) {
            pb.dataset.navBound = '1';
            pb.onclick = function () {
                window.location.href = 'login.html?redirect=' + encodeURIComponent(window.location.href);
            };
        }
        // 页面自身分享逻辑重新绑定（原按钮已被替换）
        if (shareBtn && typeof initShareButton === 'function') {
            try { initShareButton(); } catch (e) {}
        }
        injectToggle();
    }

    injectStyle();
    if (getVer() === 'new') {
        loadPremiumCss();
        injectMouseFx();
        if (document.querySelector('.nav-container')) {
            replaceNav();
            injectBanner();
        } else {
            document.addEventListener('DOMContentLoaded', function () {
                if (document.querySelector('.nav-container')) replaceNav();
                injectBanner();
            });
        }
    } else {
        // 旧版：保留原导航，只加切换按钮
        injectToggle();
    }
})();
