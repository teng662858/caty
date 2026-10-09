// 打桩 bundle（P2 自检用）—— 不碰真源，只验证这条链路：
//   宿主 → node_start → bootstrap.js → catServerFactory 起本地服务
//        → POST /msg 回报 serverStarted → 宿主 GET /config 拿到站点目录
//
// 契约与真源一致（contract-b）：导出 default.start(config)，
// 用 globalThis.catServerFactory 拿 server，自己 listen（宿主会强制 127.0.0.1:随机端口）。
//
// 这份文件不会入库到 bundle 缓存里，只是 App 资源，由 BootstrapLoader 复制到沙箱。

'use strict'

const SITES = [
  { key: 'demo', name: '打桩站点', type: 3, searchable: 1, enable: 1 },
]

// 公开的 HLS 测试流（Apple 官方示例），P4 试播用
const DEMO_STREAM = 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8'

function sendJson(res, payload, status = 200) {
  const body = JSON.stringify(payload)
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(body)
}

module.exports = {
  async start(config) {
    // —— 这几行是排错时最值钱的信息：运行时版本、架构、无 JIT 下有没有 WebAssembly/fetch
    console.log('[stub] node=' + process.version
      + ' arch=' + process.arch
      + ' WebAssembly=' + (typeof WebAssembly)
      + ' fetch=' + (typeof fetch))
    console.log('[stub] HOME=' + process.env.HOME + ' cwd=' + process.cwd())
    console.log('[stub] config 顶层键: ' + Object.keys(config || {}).join(','))

    const server = globalThis.catServerFactory(async (req, res) => {
      const url = new URL(req.url, 'http://127.0.0.1')
      const path = url.pathname
      console.log('[stub] ' + req.method + ' ' + req.url)

      if (path === '/' ) return sendJson(res, { hello: 'caty-stub' })
      if (path === '/versioning') return sendJson(res, { version: '0.0.0-stub', node: process.version })

      // 站点目录（App 首屏数据源）
      if (path === '/config') {
        return sendJson(res, {
          video: { sites: SITES, lives: [], parses: [], flags: [], wallpapers: [] },
        })
      }
      if (path === '/config/sites/list') return sendJson(res, { list: SITES })

      // 站点路由：/spider/demo/3
      if (path === '/spider/demo/3') {
        const ac = url.searchParams.get('ac') || 'list'

        // 取播放地址（TVBox 约定：ac=play）—— 第 02 集故意走这条路，验证 App 的 ac=play 分支
        if (ac === 'play') {
          const id = url.searchParams.get('id') || ''
          console.log('[stub] ac=play id=' + id + ' flag=' + (url.searchParams.get('flag') || ''))
          return sendJson(res, {
            parse: 0,
            url: DEMO_STREAM,
            header: { 'User-Agent': 'okhttp/3.15.0' },
          })
        }

        if (ac === 'detail') {
          return sendJson(res, {
            list: [{
              vod_id: '1',
              vod_name: '打桩测试片',
              vod_pic: '',
              vod_remarks: '打桩源',
              vod_content: '这是打桩 bundle 返回的假数据，用来验证 App 的数据通路。'
                + '第 01 集是直链（直接播），第 02 集是标识（要先问 ac=play）—— 两条路都能测。',
              vod_play_from: '打桩线路$$$备用线路',
              vod_play_url: '第01集$' + DEMO_STREAM + '#第02集$stub-episode-2'
                + '$$$第02集$stub-episode-2b',
            }],
          })
        }

        if (ac === 'search') {
          const wd = url.searchParams.get('wd') || ''
          return sendJson(res, {
            list: [{ vod_id: '1', vod_name: '打桩测试片（搜索：' + wd + '）', vod_pic: '', vod_remarks: '打桩源' }],
          })
        }

        return sendJson(res, {
          class: [
            { type_id: '1', type_name: '打桩分类A' },
            { type_id: '2', type_name: '打桩分类B' },
          ],
          page: 1, pagecount: 1, limit: 20, total: 1,
          list: [{ vod_id: '1', vod_name: '打桩测试片', vod_pic: '', vod_remarks: '打桩源', type_name: '打桩分类A' }],
        })
      }

      sendJson(res, { error: 'not_found', path }, 404)
    })

    // 宿主会把 listen 强制成 { host: '127.0.0.1', port: 0 }
    server.listen(() => {
      console.log('[stub] 本地服务已监听（宿主会回报 serverStarted）')
    })
  },
}
