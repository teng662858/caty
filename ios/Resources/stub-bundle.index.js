// 打桩 bundle（自检用）—— 不碰真源，只验证这条链路：
//   宿主 → node_start → bootstrap.js → catServerFactory 起本地服务
//        → POST /msg 回报 serverStarted → 宿主取 /config 拿站点目录 → 浏览/播放
//
// 契约与真源**完全一致**（M0 实测的 POST + 三段式，见 docs/contract-notes.md）：
//   GET  /config                      站点目录
//   POST /spider/demo/3/home          body {}                → {class, filters}
//   POST /spider/demo/3/category      body {tid, pg}         → {page, pagecount, list}
//   POST /spider/demo/3/detail        body {id}              → {list:[ 含 vod_play_from/url ]}
//   POST /spider/demo/3/search        body {wd}              → {list}
//   POST /spider/demo/3/play          body {flag, id}        → {url, header, parse}
//
// 第 01 集是直链（直接播），第 02 集是标识（必须先问 play）—— 两条路都能测。

'use strict'

const SITES = [
  { key: 'demo', name: '打桩站点', type: 3, searchable: 1, enable: 1 },
]

// 公开的 HLS 测试流（Apple 官方示例）
const DEMO_STREAM = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8'

function sendJson(res, payload, status = 200) {
  const body = JSON.stringify(payload)
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(body)
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = ''
    req.on('data', (chunk) => {
      raw += chunk
      if (raw.length > 1 << 20) req.destroy()
    })
    req.on('end', () => {
      try { resolve(raw ? JSON.parse(raw) : {}) } catch { resolve({}) }
    })
    req.on('error', () => resolve({}))
  })
}

module.exports = {
  async start(config) {
    console.log('[stub] node=' + process.version
      + ' arch=' + process.arch
      + ' WebAssembly=' + (typeof WebAssembly)
      + ' fetch=' + (typeof fetch))
    console.log('[stub] cwd=' + process.cwd())
    console.log('[stub] config 顶层键: ' + Object.keys(config || {}).join(','))

    const server = globalThis.catServerFactory(async (req, res) => {
      const url = new URL(req.url, 'http://127.0.0.1')
      const path = url.pathname
      const body = req.method === 'POST' ? await readBody(req) : {}
      console.log('[stub] ' + req.method + ' ' + req.url + (req.method === 'POST' ? ' body=' + JSON.stringify(body).slice(0, 60) : ''))

      if (path === '/') return sendJson(res, { hello: 'caty-stub', name: 'CatVodSpiderios' })
      if (path === '/versioning') return sendJson(res, { version: '0.0.0-stub', node: process.version })
      if (path === '/health') return sendJson(res, { ok: true, name: 'CatVodSpiderios' })
      if (path === '/check') return sendJson(res, { run: true })

      // 站点目录（App 首屏数据源）
      if (path === '/config') {
        return sendJson(res, {
          video: { sites: SITES, lives: [], parses: [], flags: [], wallpapers: [] },
        })
      }
      if (path === '/config/sites/list') return sendJson(res, { list: SITES })

      // 站点路由：POST /spider/demo/3/<op>
      const prefix = '/spider/demo/3'
      if (path === prefix || path.startsWith(prefix + '/')) {
        const op = path === prefix ? '' : path.slice(prefix.length + 1)

        // 真源为每个站点单独注册了 /init，宿主必须先调它，站点才会去解析上游域名
        // （见 docs/contract-notes.md §8）；打桩这里回一个固定上游，让自检覆盖这条路径
        if (op === 'init') {
          return sendJson(res, { siteUrl: 'http://stub.local' })
        }

        if (op === 'home') {
          return sendJson(res, {
            class: [
              { type_id: '1', type_name: '打桩分类A' },
              { type_id: '2', type_name: '打桩分类B' },
            ],
            filters: { 1: [{ key: 'area', name: '地区', value: [{ n: '全部', v: '' }, { n: '美国', v: 'us' }] }] },
          })
        }

        if (op === 'category') {
          const tid = String(body.tid ?? '1')
          return sendJson(res, {
            page: Number(body.pg ?? 1) || 1,
            pagecount: 1,
            limit: 20,
            total: 1,
            list: [{
              vod_id: tid === '2' ? '2' : '1',
              vod_name: tid === '2' ? '打桩测试片（分类B）' : '打桩测试片',
              vod_pic: '',
              vod_remarks: '打桩源 ' + tid,
              type_name: '打桩分类' + tid,
            }],
          })
        }

        if (op === 'detail') {
          const id = String(body.id ?? body.ids ?? '')
          if (!id) return sendJson(res, { list: [] })
          return sendJson(res, {
            list: [{
              vod_id: id,
              vod_name: '打桩测试片',
              vod_pic: '',
              vod_remarks: '打桩源',
              vod_content: '这是打桩 bundle 返回的假数据，用来验证 App 的数据通路。'
                + '第 01 集是直链（直接播），第 02 集是标识（要先问 play）—— 两条路都能测。',
              vod_year: '2026',
              vod_area: '打桩区',
              vod_actor: '打桩演员',
              vod_director: '打桩导演',
              vod_play_from: '打桩线路$$$备用线路',
              vod_play_url: '第01集$' + DEMO_STREAM + '#第02集$stub-episode-2'
                + '$$$第02集$stub-episode-2b',
            }],
          })
        }

        if (op === 'search') {
          const wd = String(body.wd ?? body.key ?? '')
          return sendJson(res, {
            list: [{ vod_id: '1', vod_name: '打桩测试片（搜索：' + wd + '）', vod_pic: '', vod_remarks: '打桩源' }],
          })
        }

        if (op === 'play') {
          console.log('[stub] play flag=' + (body.flag ?? '') + ' id=' + (body.id ?? ''))
          return sendJson(res, {
            parse: 0,
            url: DEMO_STREAM,
            header: { 'User-Agent': 'okhttp/3.15.0' },
          })
        }

        return sendJson(res, { message: '站点或操作不存在: ' + op }, 404)
      }

      sendJson(res, { message: 'Route ' + req.method + ':' + path + ' not found' }, 404)
    })

    // 宿主会把 listen 强制成 { host: '127.0.0.1', port: 0 }
    server.listen(() => {
      console.log('[stub] 本地服务已监听（宿主会回报 serverStarted）')
    })
  },
}
