// ============================================================
// js/ui-nav.js — 新版界面驱动（正式版，与 preview 效果完全一致）
// 由 js/common.js 自动加载（全站生效，无需改页面）
// 功能：
//   1. 自动把页面现有的旧版导航（.nav-container）替换为"新版通栏导航"
//   2. 全站玻璃拟态（背景光斑 + 毛玻璃卡片）+ 鼠标特效 + 滚动渐显
//   3. 页面渐变 Hero 横幅（已有 .hero 的页面跳过）；首页注入完整官网效果
//   4. 界面切换：localStorage 'nb_ui' = 'new' | 'old'（个人中心可设置）
// ============================================================
(function () {
    function getVer() {
        // -new 文件本身即新版版式，强制新版（不受本地偏好影响）
        var page = (location.pathname.split('/').pop() || '').toLowerCase();
        if (page.indexOf('-new.html') !== -1) return 'new';
        return typeof getUIVersion === 'function' ? getUIVersion() : 'new';
    }

    // 在新版文件中，站内链接自动指向 -new 版本（避免跳回旧版再被重定向）
    function newHref(h) {
        var page = (location.pathname.split('/').pop() || '').toLowerCase();
        if (page.indexOf('-new.html') !== -1 && h && h.indexOf('.html') !== -1 &&
            h.indexOf('http') !== 0 && h.indexOf('#') !== 0 && h.indexOf('-new.html') === -1) {
            return h.replace('.html', '-new.html');
        }
        return h;
    }

    // 批量转换 HTML 字符串内的站内链接为 -new 版本（仅 -new 文件生效）
    function newHrefHtml(html) {
        var page = (location.pathname.split('/').pop() || '').toLowerCase();
        if (page.indexOf('-new.html') === -1) return html;
        return html.replace(/href="([^"#]+)\.html"/g, function (m, p1) {
            return 'href="' + p1 + '-new.html"';
        });
    }

    // 注入界面切换按钮
    function injectToggle() {
        if (document.getElementById('uiToggleBtn')) return;
        var btn = document.createElement('button');
        btn.id = 'uiToggleBtn';
        btn.title = getVer() === 'new' ? '当前：新版界面，点击切换回旧版' : '当前：旧版界面，点击切换到新版';
        btn.textContent = getVer() === 'new' ? '🖥️' : '📄';
        btn.onclick = function () {
            var target = getVer() === 'new' ? 'old' : 'new';
            if (typeof setUIVersion === 'function') setUIVersion(target);
            // 跳转到对应版本文件（xxx.html <-> xxx-new.html）
            var rawPage = location.pathname.split('/').pop() || '';
            var lower = rawPage.toLowerCase();
            if (lower.indexOf('.html') !== -1) {
                var isNew = lower.indexOf('-new.html') !== -1;
                if (target === 'new' && !isNew) {
                    location.href = rawPage.replace(/\.html$/i, '-new.html');
                } else if (target === 'old' && isNew) {
                    location.href = rawPage.replace(/-new\.html$/i, '.html');
                } else {
                    location.reload();
                }
            } else {
                location.reload();
            }
        };
        document.body.appendChild(btn);
    }

    // 加载 css/premium.css（页面内容级高级感，旧版不加载）
    function loadPremiumCss() {
        if (document.getElementById('uiPremiumCss')) return;
        var src = '';
        try {
            src = (document.currentScript && document.currentScript.src) || '';
        } catch (e) {}
        var cssPath = 'css/premium.css';
        if (src) {
            // js/ui-nav.js → 上一级目录的 css/premium.css
            var i = src.lastIndexOf('/');
            if (i !== -1) {
                var jsDir = src.substring(0, i);
                var j = jsDir.lastIndexOf('/');
                if (j !== -1) cssPath = jsDir.substring(0, j + 1) + 'css/premium.css';
                else cssPath = jsDir + '/css/premium.css';
            }
        }
        var link = document.createElement('link');
        link.id = 'uiPremiumCss';
        link.rel = 'stylesheet';
        link.href = cssPath;
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
        banner.innerHTML = newHrefHtml(
            '<div style="position:absolute; top:-60px; right:-60px; width:200px; height:200px; border-radius:50%; background:rgba(255,255,255,0.08);"></div>' +
            '<div style="position:absolute; bottom:-80px; left:-40px; width:220px; height:220px; border-radius:50%; background:rgba(255,255,255,0.06);"></div>' +
            '<div style="font-size:1.9rem; font-weight:900; color:#fff; text-shadow:0 2px 8px rgba(0,0,0,0.2);">' + title + '</div>' +
            '<div style="font-size:0.95rem; opacity:0.92; color:#fff; margin-top:6px;">📺 NB频道 · 虚拟公司 · 官网</div>');
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
            /* ===== 极致高级感：字体渲染 / 滚动条 / 选区 ===== */
            body { -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; text-rendering: optimizeLegibility; }
            ::selection { background: rgba(0,161,214,0.25); }
            ::-webkit-scrollbar { width: 10px; height: 10px; }
            ::-webkit-scrollbar-thumb { background: rgba(0,161,214,0.35); border-radius: 10px; }
            ::-webkit-scrollbar-thumb:hover { background: rgba(0,161,214,0.55); }
            ::-webkit-scrollbar-track { background: transparent; }
            /* 玻璃拟态导航（滚动吸顶时半透明毛玻璃） */
            .top-nav {
                position: sticky; top: 0; z-index: 300;
                display: flex; align-items: center; gap: 14px;
                background: rgba(255,255,255,0.78);
                -webkit-backdrop-filter: blur(16px) saturate(1.4);
                backdrop-filter: blur(16px) saturate(1.4);
                border: 1px solid rgba(0,161,214,0.14);
                border-radius: 18px; padding: 10px 18px; margin-bottom: 24px;
                box-shadow: 0 1px 2px rgba(0,0,0,0.04), 0 12px 30px -12px rgba(0,161,214,0.18);
            }
            body.dark-mode .top-nav { background: rgba(24,26,32,0.78); border-color: rgba(0,161,214,0.22); }
            .top-nav .nav-logo {
                font-size: 1.2rem; font-weight: 800; color: var(--status-border);
                text-decoration: none; white-space: nowrap; letter-spacing: 0.5px;
            }
            .top-nav .nav-menu { display: flex; flex-wrap: wrap; gap: 4px; flex: 1; justify-content: center; }
            .top-nav .nav-menu .nav-btn {
                padding: 8px 16px; font-size: 0.92rem; border-radius: 30px; text-decoration: none;
                color: var(--nav-btn-text); background: transparent; transition: all 0.25s; white-space: nowrap;
            }
            .top-nav .nav-menu .nav-btn:hover {
                background: rgba(0,161,214,0.12); color: var(--status-border);
            }
            .top-nav .nav-menu .nav-btn.active {
                background: linear-gradient(135deg, #00a1d6, #0a84c1); color: #fff;
                box-shadow: 0 6px 16px -6px rgba(0,161,214,0.5);
            }
            .top-nav .nav-right { display: flex; gap: 8px; white-space: nowrap; align-items: center; }
            .top-nav .auth-btn, .top-nav .profile-btn {
                background: transparent; color: var(--text-color);
                border: 1px solid var(--card-border); border-radius: 30px; padding: 7px 16px; font-size: 0.88rem;
                cursor: pointer; transition: all 0.25s;
            }
            .top-nav .auth-btn:hover, .top-nav .profile-btn:hover {
                border-color: #00a1d6; color: var(--status-border);
                background: rgba(0,161,214,0.08);
            }
            .quick-nav {
                display: flex; justify-content: center; align-items: center; flex-wrap: wrap;
                gap: 8px; margin-bottom: 24px; padding: 10px 14px;
                background: transparent; border: 1px solid var(--card-border);
                border-radius: 16px;
            }
            .quick-nav .nav-btn {
                padding: 6px 14px; font-size: 0.88rem; border-radius: 30px; text-decoration: none;
                color: var(--count-text); background: transparent; transition: all 0.25s; white-space: nowrap;
            }
            .quick-nav .nav-btn:hover { color: var(--status-border); background: rgba(0,161,214,0.08); }
            .quick-nav .share-btn {
                background: linear-gradient(135deg, #00a1d6, #0a84c1); color: #fff;
                border: none; border-radius: 30px; padding: 6px 14px; font-size: 0.88rem;
                cursor: pointer; transition: all 0.25s; font-weight: 500; white-space: nowrap;
                box-shadow: 0 6px 16px -6px rgba(0,161,214,0.5);
            }
            .quick-nav .share-btn:hover { transform: translateY(-1px); filter: brightness(1.05); }
            /* 页面 Hero 横幅：光斑 + 细字重副标题 + 入场动画 */
            @keyframes uiHeroIn { from { opacity: 0; transform: translateY(18px) scale(0.99); } to { opacity: 1; transform: none; } }
            #uiPageBanner, .hero { animation: uiHeroIn 0.7s cubic-bezier(0.16, 1, 0.3, 1) both; }
            #uiPageBanner { position: relative; overflow: hidden; }
            #uiPageBanner::before {
                content: ''; position: absolute; inset: 0;
                background:
                    radial-gradient(600px 220px at 12% 0%, rgba(255,255,255,0.14), transparent 60%),
                    radial-gradient(500px 200px at 88% 100%, rgba(255,255,255,0.10), transparent 60%);
                pointer-events: none;
            }
            #uiPageBanner > div { position: relative; }
            /* 首屏错峰入场 */
            @keyframes uiFadeUp { from { opacity: 0; transform: translateY(16px); } to { opacity: 1; transform: none; } }
            .top-nav { animation: uiFadeUp 0.5s ease both; }
            .quick-nav { animation: uiFadeUp 0.5s 0.08s ease both; }
            /* 滚动渐显 */
            .ui-reveal { opacity: 0; transform: translateY(20px); transition: opacity 0.65s cubic-bezier(0.16,1,0.3,1), transform 0.65s cubic-bezier(0.16,1,0.3,1); }
            .ui-reveal-in { opacity: 1; transform: none; }
            #uiToggleBtn {
                position: fixed; bottom: 98px; right: 30px; z-index: 9996;
                width: 50px; height: 50px; border-radius: 50%;
                border: 1px solid rgba(0,161,214,0.3);
                background: rgba(255,255,255,0.8);
                -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);
                color: var(--text-color); font-size: 20px; cursor: pointer;
                box-shadow: 0 8px 24px -8px rgba(0,161,214,0.35);
                transition: transform 0.2s;
            }
            body.dark-mode #uiToggleBtn { background: rgba(24,26,32,0.8); }
            #uiToggleBtn:hover { transform: scale(1.08); }
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
                box-shadow: 0 1px 2px rgba(0,0,0,0.04), 0 16px 32px -18px rgba(0,0,0,0.25) !important;
                border: 1px solid var(--card-border) !important;
            }
            .home-card { transition: transform 0.3s, box-shadow 0.3s; }
            .home-card:hover { transform: translateY(-3px); box-shadow: 0 2px 4px rgba(0,0,0,0.05), 0 28px 48px -24px rgba(0,161,214,0.3) !important; }
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
            /* ===== 极致玻璃拟态：背景光斑 + 全卡片毛玻璃 ===== */
            body::before {
                content: ''; position: fixed; inset: 0; z-index: -1; pointer-events: none;
                background:
                    radial-gradient(900px 520px at 6% -8%, rgba(0,161,214,0.16), transparent 62%),
                    radial-gradient(760px 540px at 96% 12%, rgba(108,92,231,0.14), transparent 62%),
                    radial-gradient(860px 640px at 50% 112%, rgba(0,161,214,0.12), transparent 65%),
                    radial-gradient(500px 400px at 82% 60%, rgba(255,152,0,0.08), transparent 60%);
            }
            body.dark-mode::before {
                background:
                    radial-gradient(900px 520px at 6% -8%, rgba(0,161,214,0.20), transparent 62%),
                    radial-gradient(760px 540px at 96% 12%, rgba(108,92,231,0.18), transparent 62%),
                    radial-gradient(860px 640px at 50% 112%, rgba(0,161,214,0.14), transparent 65%);
            }
            .ui-orb { position: fixed; border-radius: 50%; filter: blur(70px); opacity: 0.5; z-index: -1; pointer-events: none; }
            @keyframes uiOrbA { 0%,100% { transform: translate(0,0) scale(1); } 50% { transform: translate(45px, -32px) scale(1.15); } }
            @keyframes uiOrbB { 0%,100% { transform: translate(0,0) scale(1); } 50% { transform: translate(-38px, 28px) scale(1.1); } }
            .home-card, .about-content, .changelog-content, .comment-section, .product-card,
            .upload-section, .info-card, .chat-container, .messages-container, .profile-container,
            .records-container, .ach-container, .register-card, .login-card, .comment, .video-card,
            .ach-card, .record-item, .notification-item, .stat-card, .stat-item, .feature-card,
            .balance-card, .my-company-card, .distribution-card, .chart-wrapper, .canvas-container,
            .data-table-wrapper, .quick-nav, .msg.other .bubble, .top-nav,
            .toolbar, .stats, .slider-container, .history-chart-container, .histogram-container,
            .mini-pie-container, .btn-group, .update-badge, .countdown-badge {
                background: rgba(255,255,255,0.62) !important;
                -webkit-backdrop-filter: blur(16px) saturate(1.5);
                backdrop-filter: blur(16px) saturate(1.5);
                border-color: rgba(255,255,255,0.55) !important;
            }
            body.dark-mode .home-card, body.dark-mode .about-content, body.dark-mode .changelog-content,
            body.dark-mode .comment-section, body.dark-mode .product-card, body.dark-mode .upload-section,
            body.dark-mode .info-card, body.dark-mode .chat-container, body.dark-mode .messages-container,
            body.dark-mode .profile-container, body.dark-mode .records-container, body.dark-mode .ach-container,
            body.dark-mode .register-card, body.dark-mode .login-card, body.dark-mode .comment,
            body.dark-mode .video-card, body.dark-mode .ach-card, body.dark-mode .record-item,
            body.dark-mode .notification-item, body.dark-mode .stat-card, body.dark-mode .stat-item,
            body.dark-mode .feature-card, body.dark-mode .balance-card, body.dark-mode .my-company-card,
            body.dark-mode .distribution-card, body.dark-mode .chart-wrapper, body.dark-mode .canvas-container,
            body.dark-mode .data-table-wrapper, body.dark-mode .quick-nav, body.dark-mode .msg.other .bubble,
            body.dark-mode .top-nav, body.dark-mode .toolbar, body.dark-mode .stats,
            body.dark-mode .slider-container, body.dark-mode .history-chart-container,
            body.dark-mode .histogram-container, body.dark-mode .mini-pie-container,
            body.dark-mode .btn-group, body.dark-mode .update-badge, body.dark-mode .countdown-badge {
                background: rgba(24,26,32,0.60) !important;
                border-color: rgba(255,255,255,0.09) !important;
            }
        `;
        document.head.appendChild(st);
    }

    // 注入漂浮光斑（毛玻璃的"透出物"）
    function injectOrbs() {
        if (document.getElementById('uiOrbA')) return;
        var mk = function (id, size, left, top, color, anim) {
            var d = document.createElement('div');
            d.id = id;
            d.className = 'ui-orb';
            d.style.cssText = 'width:' + size + 'px; height:' + size + 'px; left:' + left + '; top:' + top + '; background:' + color + '; animation:' + anim + ' 16s ease-in-out infinite;';
            document.body.appendChild(d);
        };
        mk('uiOrbA', 320, '6%', '14%', 'rgba(0,161,214,0.35)', 'uiOrbA');
        mk('uiOrbB', 260, '84%', '66%', 'rgba(108,92,231,0.32)', 'uiOrbB');
    }

    // 滚动渐显（IntersectionObserver，卡片进入视口淡入上移）
    function injectReveal() {
        if (!('IntersectionObserver' in window)) return;
        var sel = '.home-card, .video-card, .product-card, .comment, .ach-card, .record-item, ' +
                  '.notification-item, .feature-card, .stat-item, .friend-card, .info-card, ' +
                  '.about-content, .changelog-content, .comment-section, .chat-container, ' +
                  '.messages-container, .upload-section, .balance-card, .my-company-card, ' +
                  '.data-table-wrapper, .profile-container, .records-container, .ach-container, ' +
                  '.register-card, .login-card, .distribution-card, .chart-wrapper, .stats';
        var els = document.querySelectorAll(sel);
        if (!els.length) return;
        var io = new IntersectionObserver(function (entries) {
            entries.forEach(function (en) {
                if (en.isIntersecting) {
                    en.target.classList.add('ui-reveal-in');
                    io.unobserve(en.target);
                }
            });
        }, { threshold: 0.06, rootMargin: '0px 0px -30px 0px' });
        els.forEach(function (el) { el.classList.add('ui-reveal'); io.observe(el); });
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
            return '<a href="' + newHref(l.href) + '" class="nav-btn' + (l.active ? ' active' : '') + '">' + l.text + '</a>';
        }).join('');
        var funcHtml = funcLinks.concat(extraLinks).map(function (l) {
            return '<a href="' + newHref(l.href) + '" class="nav-btn" ' + (/^https?:/i.test(l.href) ? 'target="_blank" rel="noopener noreferrer"' : '') + '>' + l.text + '</a>';
        }).join('');

        // 页面已有原版登录胶囊（.auth-area）时，导航内不再渲染重复的登录按钮
        var hasAuthArea = !!document.querySelector('.auth-area');
        var authHtml = hasAuthArea
            ? ''
            : '<div class="nav-right">' +
                '<button id="profileBtn" class="profile-btn">👤 个人中心</button>' +
                '<button id="authButton" class="auth-btn">登录/注册</button>' +
              '</div>';

        var newHtml =
            '<nav class="top-nav">' +
                '<a class="nav-logo" href="' + newHref('index.html') + '">📺 NB频道</a>' +
                '<div class="nav-menu">' + mainHtml + '</div>' +
                authHtml +
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

// ===== 新版首页注入：给原版首页运行时加上官网 hero/数据条/功能卡片 =====
    function injectHomeHero() {
        // 仅原版首页（无 .hero 且含 .video-container）
        if (document.querySelector('.hero')) return;
        var vc = document.querySelector('.video-container');
        if (!vc) return;
        var container = document.querySelector('.container') || document.body;

        // 1. 隐藏原版顶部标题与 UP主信息（内容由 hero 承担）
        var h1 = container.querySelector(':scope > h1');
        if (h1) h1.style.display = 'none';
        var ai = document.getElementById('authorInfo');
        if (ai) ai.style.display = 'none';

        // 2. 取 LOGO 视频
        var logoVideo = document.getElementById('logoVideo');
        if (logoVideo) logoVideo.parentNode.removeChild(logoVideo);

        // 3. Hero
        var hero = document.createElement('div');
        hero.className = 'hero';
        hero.innerHTML = newHrefHtml(
            '<div class="hero-badges">' +
                '<span class="hero-badge">🏢 虚拟公司</span>' +
                '<span class="hero-badge">📺 10万+粉丝</span>' +
                '<span class="hero-badge">🧪 化学·物理·作死</span>' +
            '</div>' +
            '<h1>📺 NB频道官网</h1>' +
            '<div class="hero-sub">UP主：NB搞事局 · 热爱理科（和作死）的畜中生 · 虚拟公司 NB圈</div>' +
            '<div class="hero-btns">' +
                '<a class="hero-btn" href="videos.html">🎬 看视频</a>' +
                '<a class="hero-btn" href="comments-beta.html">💬 进评论区</a>' +
                '<a class="hero-btn ghost" href="Virtual stock.html">📈 虚拟股票</a>' +
                '<a class="hero-btn ghost" href="https://space.bilibili.com/3493259582114264" target="_blank" rel="noopener noreferrer">⭐ B站关注</a>' +
            '</div>' +
            '<div class="hero-video"></div>');
        if (logoVideo) {
            logoVideo.muted = true;
            hero.querySelector('.hero-video').appendChild(logoVideo);
            var playP = logoVideo.play ? logoVideo.play() : null;
            if (playP && playP.catch) playP.catch(function () {});
        }
        vc.style.display = 'none';

        // 4. 数据条
        var days = Math.floor((Date.now() - new Date('2026-02-17').getTime()) / 86400000);
        var statBar = document.createElement('div');
        statBar.className = 'stat-bar';
        statBar.innerHTML = newHrefHtml(
            '<div class="stat-item"><div class="num">10w+</div><div class="label">B站粉丝</div></div>' +
            '<div class="stat-item"><div class="num">11</div><div class="label">友商官网</div></div>' +
            '<div class="stat-item"><div class="num">' + days + ' 天</div><div class="label">建站天数</div></div>' +
            '<div class="stat-item"><div class="num">6</div><div class="label">核心功能</div></div>');

        // 5. 功能卡片
        var featureGrid = document.createElement('div');
        featureGrid.className = 'feature-grid';
        featureGrid.innerHTML = newHrefHtml(
            '<a class="feature-card" href="videos.html"><div class="f-icon">🎬</div><div class="f-name">视频</div><div class="f-desc">化学实验、物理趣味与日常作死</div><div class="f-go">去看看 →</div></a>' +
            '<a class="feature-card" href="comments-beta.html"><div class="f-icon">💬</div><div class="f-name">评论区</div><div class="f-desc">和友商交流，支持图片与@提及</div><div class="f-go">去逛逛 →</div></a>' +
            '<a class="feature-card" href="Virtual stock.html"><div class="f-icon">📈</div><div class="f-name">NB虚拟股票</div><div class="f-desc">NB币炒股，市场 8:00-20:00 自主运转</div><div class="f-go">去炒股 →</div></a>' +
            '<a class="feature-card" href="chat.html"><div class="f-icon">👥</div><div class="f-name">好友私信</div><div class="f-desc">实时聊天，支持发送图片</div><div class="f-go">去聊天 →</div></a>' +
            '<a class="feature-card" href="product_share.html"><div class="f-icon">🛍️</div><div class="f-name">作品分享</div><div class="f-desc">上传你的作品，或购买他人作品</div><div class="f-go">去看看 →</div></a>' +
            '<a class="feature-card" href="messages.html"><div class="f-icon">🔔</div><div class="f-name">消息中心</div><div class="f-desc">评论回复、点赞与私信通知</div><div class="f-go">去看看 →</div></a>');

        // 6. 友商网格（与预览版一致）+ 隐藏原版友商文字卡
        var friendGrid = document.createElement('div');
        friendGrid.className = 'friend-grid';
        friendGrid.innerHTML = newHrefHtml(
            '<div class="friend-card"><div><div class="fc-name">Orgent</div><div class="fc-note">已注销 · 仅留念</div></div><a href="https://orgent.pythonanywhere.com/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">AWM</div><div class="fc-note">友商官网</div></div><a href="https://45d.cn/AWM/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">Fafat</div><div class="fc-note">友商官网</div></div><a href="https://fafat.uuk.pp.ua/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">Lemon（齐喜）</div><div class="fc-note">友商官网</div></div><a href="https://nb-qx.top/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">GaoHanTu</div><div class="fc-note">友商官网</div></div><a href="https://gaohantu.cn/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">Utw</div><div class="fc-note">友商官网</div></div><a href="https://utw.pages.dev" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">PTC(GoodPTC)</div><div class="fc-note">友商官网</div></div><a href="https://pipetrainingcamp.github.io/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">UVS</div><div class="fc-note">友商官网</div></div><a href="https://yoyo-user-awa.github.io/UVS/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">UwLS</div><div class="fc-note">友商官网</div></div><a href="https://3f7ceb4e.pinit.eth.limo/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">Oganesson</div><div class="fc-note">友商官网</div></div><a href="https://45d.cn/nb-og.top/" target="_blank" rel="noopener noreferrer">访问</a></div>' +
            '<div class="friend-card"><div><div class="fc-name">SOT</div><div class="fc-note">友商官网</div></div><a href="https://78439049.pinit.eth.limo/" target="_blank" rel="noopener noreferrer">访问</a></div>');
        var friendTitle = document.createElement('div');
        friendTitle.className = 'section-title';
        friendTitle.textContent = '🌐 友商链接';
        // 隐藏原版友商文字卡（含"友商"文本的 home-card）
        var cards = container.querySelectorAll('.home-card');
        Array.prototype.forEach.call(cards, function (card) {
            if (/友商/.test(card.textContent || '')) card.style.display = 'none';
        });

        // 7. 新页脚（隐藏原版页脚文字）
        var afterStats = container.querySelectorAll(':scope > .stats-container ~ p');
        Array.prototype.forEach.call(afterStats, function (p) { p.style.display = 'none'; });
        var siteFooter = document.createElement('footer');
        siteFooter.className = 'site-footer';
        siteFooter.innerHTML = newHrefHtml(
            '<div>© 2026 NB频道 · 虚拟公司 · <a href="https://nb-channel.top" target="_blank" rel="noopener noreferrer">nb-channel.top（导航页）</a> · <a href="https://github.nb-channel.top" target="_blank" rel="noopener noreferrer">github站</a> · <a href="https://cloudflare.nb-channel.top" target="_blank" rel="noopener noreferrer">cloudflare站</a> · <a href="https://pythonanywhere.nb-channel.top" target="_blank" rel="noopener noreferrer">pythonanywhere站</a></div>' +
            '<div>如有任何问题或建议，请联系：<a href="mailto:nbchannel@163.com">nbchannel@163.com</a> 或 <a href="mailto:NBchannel@163.com">NBchannel@163.com</a></div>' +
            '<div>制作：<a href="https://space.bilibili.com/3493259582114264" target="_blank" rel="noopener noreferrer">NB搞事局（原NB实验室-作死）</a></div>' +
            '<div style="font-size:0.78rem;">托管：<a href="https://github.com/" target="_blank" rel="noopener noreferrer">Github</a> · <a href="https://www.cloudflare-cn.com/developer-platform/products/pages/" target="_blank" rel="noopener noreferrer">Cloudflare</a> · <a href="https://www.pythonanywhere.com/" target="_blank" rel="noopener noreferrer">PythonAnywhere</a> · 视频托管：<a href="https://imgbed.cn/" target="_blank" rel="noopener noreferrer">图床小镇</a></div>');

        // 7. 插入：导航之后（hero → 数据条 → 功能卡片区 → 友商网格）
        var featTitle = document.createElement('div');
        featTitle.className = 'section-title';
        featTitle.textContent = '🚀 核心功能';
        var navHost = document.querySelector('.top-nav') || document.querySelector('.quick-nav');
        var insertChain = [hero, statBar, featTitle, featureGrid, friendTitle, friendGrid];
        var ref = navHost && navHost.nextSibling ? navHost.nextSibling : container.firstChild;
        for (var k = 0; k < insertChain.length; k++) {
            container.insertBefore(insertChain[k], ref);
            ref = insertChain[k].nextSibling;
        }
        container.appendChild(siteFooter);
    }

    // 新版初始化（必须在 DOM 就绪后执行：injectMouseFx/injectOrbs 需要 document.body）
    function initNewUI() {
        loadPremiumCss();
        injectMouseFx();
        injectOrbs();
        if (document.querySelector('.nav-container')) {
            replaceNav();
        }
        injectHomeHero();   // 首页：注入完整官网效果（= preview/index.html）
        injectBanner();     // 其他页面：注入 Hero 横幅（已有 .hero 的页面自动跳过）
        // 滚动渐显：等首屏元素就位后观察
        setTimeout(injectReveal, 50);
    }

    // 旧版初始化：只需要切换按钮
    function initOldUI() {
        injectToggle();
    }

    if (getVer() === 'new') {
        injectStyle();   // 新版样式只在新版界面注入，旧版保持原始外观
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initNewUI);
        } else {
            initNewUI();
        }
    } else {
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initOldUI);
        } else {
            initOldUI();
        }
    }
})();
