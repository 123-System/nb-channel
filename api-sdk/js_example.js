/**
 * NB频道 市值 API - JavaScript 示例
 * 浏览器：直接 <script src="js_example.js"> 后使用 window.NBMarket
 * Node.js：const NBMarket = require('./js_example');
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.NBMarket = factory();
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const BASE_URL = 'https://api.nb-channel.top';

  async function getJSON(path, params) {
    const url = new URL(BASE_URL + path);
    if (params) {
      Object.keys(params).forEach(k => {
        if (params[k] !== undefined && params[k] !== null) url.searchParams.set(k, params[k]);
      });
    }
    const resp = await fetch(url);
    if (!resp.ok) {
      let msg = 'HTTP ' + resp.status;
      try { const j = await resp.json(); msg = (j && j.message) || msg; } catch (e) { /* 忽略 */ }
      throw new Error(msg);
    }
    return resp.json();
  }

  const NBMarket = {
    /** 全市场快照；name 可选，按公司名模糊查询 */
    market: (name) => getJSON('/api/market', { name }),

    /** 单家公司市值 */
    marketById: (companyId) => getJSON('/api/market/' + companyId),

    /** 历史K线（市值走势点），days 1~30 */
    history: (companyId, days) => getJSON('/api/market/' + companyId + '/history', { days }),

    /** 最新评论（只读） */
    comments: (page, limit, pagePath) => getJSON('/api/comments', { page, limit, page_path: pagePath }),

    /** 全市场 CSV 导出，返回文本 */
    async exportCsv() {
      const resp = await fetch(BASE_URL + '/api/market/export?format=csv');
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      return resp.text();
    },
  };

  return NBMarket;
});

/* 用法示例（浏览器控制台）：
const m = await NBMarket.market();
console.log('总市值', m.total_market_value, '公司数', m.count);
const one = await NBMarket.marketById(3);
const k = await NBMarket.history(3, 7);
const cs = await NBMarket.comments(1, 5);
*/
