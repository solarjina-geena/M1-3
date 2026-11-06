// 로그인 세션 저장소 — 대시보드(index)·관리 화면(manage)·표 화면(tables)이 모든 탭에서 같은 로그인을 쓰도록 localStorage 'm13auth' 에 둔다.
// (이전에는 sessionStorage 라 새 탭을 열 때마다 다시 로그인해야 했다. 2026-11-06 사용자 보고)
// - 예전 탭 저장소(sessionStorage)에 남은 로그인은 처음 읽을 때 옮겨 온다.
// - 로그인 후 12시간이 지나면 자동으로 풀린다(공용 PC 대비). 로그아웃하면 모든 탭에서 풀린다.
// - Storage 와 같은 모양(getItem/setItem/removeItem)이라 기존 코드는 sessionStorage 대신 이것을 부르면 된다.
(function () {
  const K = 'm13auth', MAX_MS = 12 * 3600 * 1000;
  const ls = () => { try { return window.localStorage } catch (e) { return null } };
  const ss = () => { try { return window.sessionStorage } catch (e) { return null } };
  function read() {
    let v = null;
    try { v = ls()?.getItem(K) || null } catch (e) { }
    if (!v) {
      try { const s = ss()?.getItem(K); if (s) { v = s; ls()?.setItem(K, s) } } catch (e) { }
    }
    if (!v) return null;
    try {
      const o = JSON.parse(v);
      if (o && o.login_at && Date.now() - o.login_at > MAX_MS) { remove(); return null }
    } catch (e) { }
    return v;
  }
  function remove() {
    try { ls()?.removeItem(K) } catch (e) { }
    try { ss()?.removeItem(K) } catch (e) { }
  }
  function write(v) {
    try {
      const o = JSON.parse(v), prev = JSON.parse(read() || 'null');
      // 토큰 갱신(같은 사람)이면 처음 로그인 시각을 유지, 새 로그인이면 지금 시각
      o.login_at = (prev && prev.login_at && prev.email && prev.email === o.email) ? prev.login_at : Date.now();
      v = JSON.stringify(o);
    } catch (e) { }
    try { ls()?.setItem(K, v) } catch (e) { try { ss()?.setItem(K, v) } catch (_) { } }
    try { ss()?.removeItem(K) } catch (e) { }
  }
  window.m13AuthStore = { getItem: () => read(), setItem: (_k, v) => write(v), removeItem: () => remove() };
})();
