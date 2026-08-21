# NB频道 市值 API - 官方 SDK 示例

使用 `api.nb-channel.top` 统一入口调用 NB频道 虚拟股票公开接口。

## 接口速览

| 端点 | 说明 |
|---|---|
| `GET /api/market` | 全市场快照（支持 `?name=` 模糊查询） |
| `GET /api/market/<company_id>` | 单家公司市值 |
| `GET /api/market/<company_id>/history?days=7` | 历史K线（市值走势点） |
| `GET /api/market/export?format=csv` | 全市场 CSV 导出 |
| `GET /api/comments?page=1&limit=20` | 最新评论（只读） |
| `GET /api/docs` | 接口文档 |

统一响应：成功 `{"success": true, "code": "OK", ...}`；失败 `{"success": false, "code": "错误码", "message": "..."}`。
限流：每 IP 每分钟 60 次。

## 示例文件

- `python_example.py` — Python 3（requests 库，无第三方依赖可选 urllib 版）
- `js_example.js` — 浏览器 / Node.js（fetch）

## Python 用法

```python
from python_example import NBMarket

nb = NBMarket()  # 或 NBMarket(base_url="https://nbchannel.pythonanywhere.com")

market = nb.market()                    # 全市场
found  = nb.market(name="NB")           # 按名模糊查
one    = nb.market_by_id(3)             # 单公司
kline  = nb.history(3, days=7)          # 历史K线
export = nb.export_csv()                # CSV 文本
comments = nb.comments(page=1, limit=10)  # 最新评论
```

## Node.js / 浏览器用法

```javascript
const nb = require('./js_example');   // Node；浏览器里直接 <script> 后 window.NBMarket

const market = await NBMarket.market();
const one = await NBMarket.marketById(3);
const kline = await NBMarket.history(3, 7);
const comments = await NBMarket.comments(1, 10);
```

## 常见错误码

| code | 含义 |
|---|---|
| `UNAUTHORIZED` | API Key 缺失/错误（配置了 key 时） |
| `RATE_LIMITED` | 请求过频（60次/分钟/IP） |
| `NOT_FOUND` | 公司不存在 |
| `INVALID_PARAM` | 参数不合法 |
| `DB_ERROR` | 后端异常（稍后重试） |

## 注意

- 数据只读、公开，请勿批量爬取（有每分钟限流）
- 有疑问联系站长：nbchannel@163.com
