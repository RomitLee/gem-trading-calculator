// 自毁 Service Worker：一次性用品
// 作用：旧版本浏览器的 SW 更新检查会拿到本文件 → 激活后清空全部 gem-calculator-* 缓存并注销自己，
// 然后通知页面刷新。此后本应用不再使用任何离线缓存，每次打开都是网络最新版本。
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.filter(k => String(k).startsWith('gem-calculator-')).map(k => caches.delete(k)));
    } catch (e) { /* ignore */ }
    try { await self.registration.unregister(); } catch (e) { /* ignore */ }
    try {
      const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      clients.forEach(c => c.postMessage({ type: 'SW_REMOVED' }));
    } catch (e) { /* ignore */ }
  })());
});
// 不监听 fetch：不拦截任何网络请求
