// ============================================================
// preview/ui-nav.js — 全站新版界面预览（预览目录专用，不动正式文件）
// 用法：在页面 common.js 引用之后加入 <script src="ui-nav.js"></script>
// 功能：
//   1. 自动把页面现有的旧版导航（.nav-container）替换为"新版通栏导航"
//      （Logo + 主菜单 + 登录按钮 + 快捷入口条），页面原有链接全部保留
//   2. 右下角 🖥️/📄 按钮在"新版/旧版"界面之间切换（localStorage: nb_ui_preview）
//   3. 旧版 = 保留页面原始导航不动
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
        // 同步执行时若导航已解析则立即替换；否则等 DOM 就绪
        if (document.querySelector('.nav-container')) {
            replaceNav();
        } else {
            document.addEventListener('DOMContentLoaded', replaceNav);
        }
    } else {
        // 旧版：保留原导航，只加切换按钮
        injectToggle();
    }
})();
