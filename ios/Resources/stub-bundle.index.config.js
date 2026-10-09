// 打桩配置：与发布配置同构的最小占位（docs/00 §4.2 的兜底模板）
// 走的是和真源完全一样的加载路径：require() → module.exports

var stub_config_default = {
  sites: { list: [] },
  pans: { list: [] },
  danmu: { urls: [], autoPush: false },
  color: [],
}

module.exports = stub_config_default
