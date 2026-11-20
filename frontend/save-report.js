// 작업일보 판독 저장 뒤 '저장 안 된 줄과 이유, 먼저 해 볼 일' 정리 + '판독 결과 파일로 받기' — 2026-11-20 사용자 의견 반영
// - 저장이 끝나면 표 아래에 실패·건너뜀·뺀 줄·판독 오류 줄을 모아 보여 주고, 이유마다 먼저 해 볼 일을 쉬운 말로 붙인다.
// - 저장 전/후 언제든 판독 결과(고친 값 포함)를 파일로 받아 둘 수 있다 → 빠진 줄이 생겨도 무엇을 읽었는지 나중에 확인 가능.
(() => {
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])));
  const P = () => (typeof PROC === 'object' ? PROC : {});

  function tip(msg) {
    const m = String(msg || '');
    if (/로그인|401|인증|token|만료|권한|403/i.test(m)) return '로그인이 끊겼거나 권한이 없습니다 → 화면 위에서 다시 로그인한 뒤 아래 \'남은 건 저장\'을 누르세요.';
    if (/이미|중복|exists|409|duplicate/i.test(m)) return '같은 일보가 이미 저장돼 있습니다 → 줄의 \'기존 기록 바꾸기\'를 켜고 다시 저장하거나, 정말 다른 기록이면 \'고치기\'에서 순번·LOT 을 확인하세요.';
    if (/Failed to fetch|NetworkError|network|시간|timeout|502|503|504|Bad Gateway|Service Unavailable/i.test(m)) return '인터넷이나 서버 응답 문제입니다 → 1분쯤 뒤 \'남은 건 저장\'을 다시 누르세요(서버가 깨어나는 데 시간이 걸릴 수 있음).';
    if (/422|필수|required|숫자|형식|invalid|null|날짜|date|model|모델/i.test(m)) return '빈칸이나 숫자·날짜 형식이 맞지 않습니다 → 그 줄의 \'고치기\'에서 노란 칸·빈칸을 채운 뒤 다시 저장하세요.';
    if (/Abort|중단/i.test(m)) return '저장을 중단해서 남은 줄입니다 → \'남은 건 저장\'을 누르면 이어서 저장합니다.';
    return '원인을 바로 알기 어렵습니다 → 아래 \'판독 결과 파일로 받기\'로 파일을 받아 관리자에게 보내 주세요. 급하면 줄의 \'폼에 넣기\'로 직접 입력할 수 있습니다.';
  }

  function label(it, k) {
    const p = it && it.payload;
    if (!p) return `${k + 1}번째 줄`;
    return `${k + 1}번째 줄 · ${p.work_date || '날짜 없음'} ${p.shift || ''} · ${p.model || ''} · ${P()[p.process] || p.process || ''}${p.source?.page ? ' · 원본 ' + p.source.page + '쪽' : ''}${p.inspector_raw ? ' · 검사자 ' + p.inspector_raw : ''}`;
  }

  function collect() {
    const its = window.pendingItems || [], out = [];
    its.forEach((it, k) => {
      if (!it) return;
      if (!it.ok) { out.push({ k, kind: '판독 오류', why: it.error || '판독 단계에서 항목을 만들지 못함', it }); return }
      if (it._skip) { out.push({ k, kind: '뺀 줄', why: '\'빼기\'를 눌러 저장하지 않음', it }); return }
      const cell = document.querySelector(`tr[data-i="${k}"] .st-cell`); if (!cell) return;
      const txt = cell.textContent.trim();
      if (cell.classList.contains('err')) out.push({ k, kind: '실패', why: txt.replace(/^실패:\s*/, ''), it });
      else if (/건너뜀/.test(txt)) out.push({ k, kind: '건너뜀', why: '이미 저장된 일보라 건너뜀(\'기존 기록 바꾸기\'가 꺼져 있음)', it });
      else if (!/저장됨/.test(txt)) out.push({ k, kind: '저장 안 됨', why: '아직 저장하지 않음', it });
    });
    return out;
  }

  function report() {
    const dock = document.querySelector('.save-dock'); if (!dock) return;
    let box = document.getElementById('saveReport');
    if (!box) { box = document.createElement('div'); box.id = 'saveReport'; dock.after(box) }
    const list = collect(), total = (window.pendingItems || []).length;
    if (!list.length) { box.innerHTML = `<div class="sr ok-box">✔ ${total}줄 모두 저장됐습니다.</div>`; return }
    const tag = { '실패': 'err', '판독 오류': 'err', '건너뜀': 'warn', '뺀 줄': 'muted', '저장 안 됨': 'warn' };
    box.innerHTML = `<div class="sr"><b>저장 안 된 줄 ${list.length}건</b> <span class="muted">(전체 ${total}줄) — 줄 이름을 누르면 표의 그 줄로 이동합니다</span>`
      + `<table><tr><th>줄</th><th>상태</th><th>이유</th><th>먼저 해 볼 일</th></tr>`
      + list.map(x => `<tr><td style="text-align:left"><a href="#" data-sr-go="${x.k}">${e(label(x.it, x.k))}</a></td><td class="${tag[x.kind] || ''}">${e(x.kind)}</td><td style="text-align:left">${e(x.why)}</td><td style="text-align:left">${e(x.kind === '뺀 줄' ? '일부러 뺀 줄이면 그대로 두세요. 다시 넣으려면 \'되살리기\'.' : x.kind === '건너뜀' ? tip('이미') : x.kind === '판독 오류' ? '판독 단계에서 못 읽은 줄입니다 → 그 쪽만 사진(캡처)으로 다시 올려 판독하거나, 원본을 보고 위쪽 입력 폼으로 직접 넣으세요.' : tip(x.why))}</td></tr>`).join('')
      + `</table><div class="muted" style="margin-top:4px">그래도 안 되면 '판독 결과 파일로 받기'로 받아 두세요 — 판독한 값과 고친 값이 모두 들어 있어 나중에 그대로 다시 넣거나 원인을 찾을 수 있습니다.</div></div>`;
  }

  function download() {
    const its = window.pendingItems || [];
    if (!its.length) { alert('받을 판독 결과가 없습니다.'); return }
    const f = document.getElementById('imgIn')?.files?.[0] || document.getElementById('fileIn')?.files?.[0];
    const rows = its.map((it, k) => {
      const cell = document.querySelector(`tr[data-i="${k}"] .st-cell`);
      return { 줄: k + 1, 상태: !it ? '' : !it.ok ? '판독 오류' : it._skip ? '뺀 줄' : (cell ? cell.textContent.trim() : ''), 오류: it?.error || null, 고친_칸수: it?.edited || 0, 내용: it?.payload || null };
    });
    const data = { 받은_시각: new Date().toLocaleString('ko-KR'), 일보_종류: window.journalKind || null, 원본_파일: f ? f.name : null, 줄_수: its.length, 줄: rows };
    const z = n => String(n).padStart(2, '0'), d = new Date();
    const name = `판독결과_${d.getFullYear()}${z(d.getMonth() + 1)}${z(d.getDate())}_${z(d.getHours())}${z(d.getMinutes())}${f ? '_' + f.name.replace(/\.[^.]+$/, '') : ''}.json`;
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
    a.download = name; document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove() }, 500);
  }
  window.m13SaveReport = report;
  window.m13DownloadReading = download;

  // 미리보기 표 아래 저장 줄에 '판독 결과 파일로 받기' 단추
  const origTable = window.itemsTable;
  if (typeof origTable === 'function') window.itemsTable = (...a) => {
    setTimeout(() => document.getElementById('saveReport')?.remove(), 0);
    return origTable(...a).replace('<span id="st-save"', '<button class="ghost" type="button" onclick="m13DownloadReading()" title="판독한 값과 고친 값을 내 컴퓨터에 파일로 저장(나중에 확인·다시 넣기용)">판독 결과 파일로 받기</button><span id="st-save"');
  };
  // 저장이 끝나면 정리 표
  const origSave = window.saveAll;
  if (typeof origSave === 'function') window.saveAll = async (...a) => { const r = await origSave(...a); try { const ran = [...document.querySelectorAll('tr[data-i] .st-cell')].some(c => c.classList.contains('err') || /저장됨|건너뜀/.test(c.textContent)); if (ran) report() } catch (err) { console.warn('[save report]', err) } return r };

  document.addEventListener('click', ev => {
    const a = ev.target.closest && ev.target.closest('[data-sr-go]'); if (!a) return; ev.preventDefault();
    const tr = document.querySelector(`tr[data-i="${a.dataset.srGo}"]`); if (!tr) return;
    tr.scrollIntoView({ block: 'center', behavior: 'smooth' }); tr.style.outline = '3px solid #1e6fd9'; setTimeout(() => tr.style.outline = '', 2000);
  });
  const css = document.createElement('style');
  css.textContent = '.sr{margin-top:8px;padding:8px 10px;border:2px solid #e7ad00;border-radius:10px;background:var(--surface);font-size:12px}.sr table{margin-top:6px}.sr td,.sr th{font-size:12px}.sr.ok-box{border-color:#5cb85c}';
  document.head.appendChild(css);
})();
