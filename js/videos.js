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
            <div class="video-card" onclick="window.open('${b23Url}', '_blank')">
                <div class="cover-wrapper">
                    <img class="video-cover" 
                         src="${video.cover}" 
                         alt="${video.title}"
                         loading="lazy"
                         onerror="this.onerror=null; this.src='https://via.placeholder.com/640x360?text=封面加载失败';">
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