// js/videos.js

let currentCategoryKey = 'all';
let categoryMap = {};
let searchKeyword = '';
let sortBy = 'time';

function initCategoryFilter() {
    const filterDiv = document.getElementById('categoryFilter');
    if (!filterDiv) return;

    categoryMap = {};
    VIDEOS.forEach(v => {
        if (v.category_key) {
            categoryMap[v.category_key] = v.category_name;
        }
    });

    const presetOrder = ['化学', '物理', '救人', '官网', '产品', '其他'];
    let buttonsHtml = '<button class="cat-btn active" data-category="all">全部</button>';

    presetOrder.forEach(key => {
        if (categoryMap[key] || key === '其他') {
            const displayName = categoryMap[key] || '《其他》';
            buttonsHtml += `<button class="cat-btn" data-category="${key}">${displayName}</button>`;
        }
    });

    filterDiv.innerHTML = buttonsHtml;

    filterDiv.addEventListener('click', (e) => {
        if (e.target.classList.contains('cat-btn')) {
            document.querySelectorAll('.cat-btn').forEach(btn => btn.classList.remove('active'));
            e.target.classList.add('active');
            currentCategoryKey = e.target.dataset.category;
            renderVideosByCategory();
        }
    });
}

function renderVideosByCategory() {
    const grid = document.getElementById('videoGrid');
    const countSpan = document.getElementById('videoCountDisplay');

    let filteredVideos = VIDEOS;
    if (currentCategoryKey !== 'all') {
        filteredVideos = VIDEOS.filter(v => v.category_key === currentCategoryKey);
    }

    if (searchKeyword.trim() !== '') {
        const keyword = searchKeyword.trim().toLowerCase();
        filteredVideos = filteredVideos.filter(v => v.title.toLowerCase().includes(keyword));
    }

    if (sortBy === 'time') {
        filteredVideos.sort((a, b) => (b.pubdate || 0) - (a.pubdate || 0));
    } else {
        filteredVideos.sort((a, b) => parsePlayCount(b.play) - parsePlayCount(a.play));
    }

    if (countSpan) {
        countSpan.innerText = `当前展示视频：${filteredVideos.length} 个`;
    }

    if (filteredVideos.length === 0) {
        grid.innerHTML = '<div style="grid-column:1/-1; text-align:center; padding:60px;">暂无该分类视频</div>';
        return;
    }

    grid.innerHTML = filteredVideos.map(video => {
        const b23Url = `https://www.bilibili.com/video/${video.bvid}`;
        return `
            <div class="video-card" data-bvid="${video.bvid}" data-title="${video.title.replace(/"/g, '&quot;')}" onclick="openVideoPlayer(this)">
                <div class="cover-wrapper">
                    <img class="video-cover" 
                         src="${video.cover}" 
                         alt="${video.title}"
                         loading="lazy"
                         onerror="this.onerror=null; this.src='data:image/svg+xml;charset=utf-8,%3Csvg xmlns=%27http://www.w3.org/2000/svg%27 width=%27640%27 height=%27360%27%3E%3Crect width=%27640%27 height=%27360%27 fill=%27%23e0e0e0%27/%3E%3Ctext x=%27320%27 y=%27185%27 font-size=%2724%27 fill=%27%23999%27 text-anchor=%27middle%27%3E封面加载失败%3C/text%3E%3C/svg%3E';">&nbsp;
                    <span class="duration-badge">${video.duration || '--:--'}</span>
                </div>
                <div class="video-info">
                    <div class="video-title">${video.title}</div>
                    <div class="video-meta">
                        <span class="meta-item">▶️ ${video.play || '0'}</span>
                        <span class="meta-item">📅 ${video.pubdate ? new Date(video.pubdate * 1000).toLocaleDateString() : '未知'}</span>
                    </div>
                    <div class="bv-text">${video.bvid}</div>
                </div>
            </div>
        `;
    }).join('');
}

// ========== B站视频内嵌播放（点击卡片弹窗，点"加载播放器"后内嵌，规避拦截器/浏览器干预） ==========
let currentPlayerBvid = null;
function openVideoPlayer(card) {
    const modal = document.getElementById('videoPlayerModal');
    const frame = document.getElementById('videoPlayerFrame');
    const cap = document.getElementById('videoPlayerTitle');
    if (!modal || !frame) {
        const bvid = card && card.dataset.bvid;
        if (bvid) window.open('https://www.bilibili.com/video/' + bvid, '_blank');
        return;
    }
    currentPlayerBvid = card.dataset.bvid;
    cap.innerText = card.dataset.title || '';
    // 先显示弹窗（不自动加载播放器，显示"点击加载"遮罩）
    frame.src = 'about:blank';
    const mask = document.getElementById('playerLoadMask');
    if (mask) mask.style.display = 'flex';
    modal.style.display = 'flex';
    document.body.style.overflow = 'hidden';
}

function loadPlayerIntoFrame() {
    const frame = document.getElementById('videoPlayerFrame');
    const mask = document.getElementById('playerLoadMask');
    if (!frame || !currentPlayerBvid) return;
    // 用户手势触发的加载（规避 Edge 懒加载干预与广告拦截器对自动 iframe 的拦截）
    frame.src = `https://player.bilibili.com/player.html?bvid=${currentPlayerBvid}`;
    if (mask) mask.style.display = 'none';
}

function closeVideoPlayer() {
    const modal = document.getElementById('videoPlayerModal');
    const frame = document.getElementById('videoPlayerFrame');
    if (modal) modal.style.display = 'none';
    if (frame) frame.src = 'about:blank';   // 卸载播放器，停止声音
    document.body.style.overflow = '';
    currentPlayerBvid = null;
}

function initVideoPlayerModal() {
    const modal = document.getElementById('videoPlayerModal');
    if (!modal) return;
    const closeBtn = document.getElementById('videoPlayerClose');
    if (closeBtn) closeBtn.onclick = closeVideoPlayer;
    // 用户点击才加载播放器
    const mask = document.getElementById('playerLoadMask');
    if (mask) mask.onclick = (e) => { e.stopPropagation(); loadPlayerIntoFrame(); };
    // 兜底：播放器不可用时去B站看
    const openBtn = document.getElementById('videoPlayerOpen');
    if (openBtn) openBtn.onclick = () => {
        if (currentPlayerBvid) window.open('https://www.bilibili.com/video/' + currentPlayerBvid, '_blank');
    };
    // 点击遮罩关闭
    modal.addEventListener('click', (e) => {
        if (e.target === modal) closeVideoPlayer();
    });
    // Esc 关闭
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && modal.style.display === 'flex') closeVideoPlayer();
    });
}

function initSearchAndSort() {
    const searchInput = document.getElementById('searchInput');
    const sortTimeBtn = document.getElementById('sortTime');
    const sortHotBtn = document.getElementById('sortHot');

    if (searchInput) {
        searchInput.addEventListener('input', (e) => {
            searchKeyword = e.target.value;
            renderVideosByCategory();
        });
    }

    if (sortTimeBtn && sortHotBtn) {
        sortTimeBtn.addEventListener('click', () => {
            sortBy = 'time';
            sortTimeBtn.classList.add('active');
            sortHotBtn.classList.remove('active');
            renderVideosByCategory();
        });
        sortHotBtn.addEventListener('click', () => {
            sortBy = 'hot';
            sortHotBtn.classList.add('active');
            sortTimeBtn.classList.remove('active');
            renderVideosByCategory();
        });
    }
}

function initVideos() {
    const sourceSpan = document.getElementById('dataSource');

    if (!VIDEOS || VIDEOS.length === 0) {
        document.getElementById('videoGrid').innerHTML = '<div style="grid-column:1/-1; text-align:center; padding:60px;">暂无视频数据</div>';
        if (sourceSpan) sourceSpan.innerText = '无数据';
        return;
    }

    initCategoryFilter();
    initSearchAndSort();
    initVideoPlayerModal();
    currentCategoryKey = 'all';
    searchKeyword = '';
    sortBy = 'time';
    const sortTimeBtn = document.getElementById('sortTime');
    const sortHotBtn = document.getElementById('sortHot');
    if (sortTimeBtn && sortHotBtn) {
        sortTimeBtn.classList.add('active');
        sortHotBtn.classList.remove('active');
    }
    renderVideosByCategory();
    if (sourceSpan) sourceSpan.innerText = '利用B站API同步配置';
}

// 页面加载完成后执行

document.addEventListener('DOMContentLoaded', initVideos);
