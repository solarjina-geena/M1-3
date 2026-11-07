// 관리 화면 '비전 불량' 탭 — 권선 비전 가성불량 조치 엑셀(1블록 = 날짜·모델·1차/2차 재검사)을 올려 저장. 2026-11-07 팀장 요청(위치도 입력과 같은 방식)
// 검사 수량 = 비전이 걸러낸 것을 사람이 다시 본 수량, 불량 = 진성(유형별), 양품 = 가성. 같은 날·모델 권선 일보가 1건이면 FK 연결(추정 안 함).
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  let prev = null;
  const pct = (a, b) => b ? Math.round(a * 1000 / b) / 10 + '%' : '—';

  function render() {
    const box = $('#vc_out'); if (!prev) { box.innerHTML = ''; return }
    const bs = prev.blocks;
    box.innerHTML = `<div class="muted">${e(prev.file)} · 연도 ${prev.year} · 재검사 ${bs.length}건 (검사 수량이 빈 칸·빈 양식은 건너뜀) · <b>이미 저장됨</b>은 기본 해제</div>
      <table><tr><th><input type="checkbox" id="vc_all" style="width:auto"></th><th>날짜</th><th>모델</th><th>차수</th><th>다시 본 수량</th><th>진성</th><th>가성</th><th>가성률</th><th>진성 유형</th><th>엑셀 위치</th><th>상태</th></tr>
      ${bs.map(b => b.problem ? `<tr><td></td><td>${e(b.date)}</td><td colspan="8">${e(b.label)}</td><td class="err">${e(b.problem)}</td></tr>` : `<tr>
        <td><input type="checkbox" class="vc_blk" value="${e(b.key)}" ${b.exists ? '' : 'checked'} style="width:auto"></td>
        <td>${e(b.date)}</td><td><b>${e(b.model)}</b></td><td>비전 ${b.round}차</td><td>${b.inspected}</td><td class="err">${b.true || ''}</td><td>${b.false}</td><td>${pct(b.false, b.true + b.false)}</td>
        <td style="white-space:nowrap">${b.types.length ? b.types.map(t => e(t[0] + ' ' + t[1])).join('<br>') : (b.true ? '<span class="warn">유형 미기재</span>' : '<span class="muted">—</span>')}</td>
        <td class="muted">${e(b.cell)}</td>
        <td>${b.exists ? '<span class="warn">이미 저장됨</span>' : b.check ? `<span class="warn">${e(b.check)}</span>` : '<span class="ok">새 기록</span>'}</td></tr>`).join('')}</table>`;
    $('#vc_all').onchange = ev => document.querySelectorAll('.vc_blk').forEach(c => c.checked = ev.target.checked);
  }
  const done = () => { render(); const m = {}; prev.blocks.forEach(b => { if (!b.problem) m[b.model] = (m[b.model] || 0) + 1 });
    return prev.blocks.length ? `미리보기 · 재검사 ${prev.blocks.length}건 (${Object.entries(m).map(([k, v]) => k + ' ' + v).join(' · ')}) — 확인 후 'DB에 저장'` : '읽을 수 있는 블록이 없습니다 — "날짜: 10/1" 줄부터 복사하세요' };

  function preview() {
    const f = $('#vc_file').files[0];
    if (!f) { setStatus('vision', '엑셀 파일을 먼저 고르세요', 'warn'); return }
    job('vision', '비전 불량 엑셀 읽기', async signal => {
      const fd = new FormData(); fd.append('file', f);
      prev = await api('/api/vision-check/preview?year=' + ($('#vc_year').value || 2026), { method: 'POST', authed: true, body: fd, signal });
      return done();
    }, { limit: 120 }).catch(() => { });
  }
  function previewText() {
    const text = $('#vc_text').value;
    if (!text.trim()) { setStatus('vision', '엑셀에서 블록을 복사해 붙여넣으세요', 'warn'); return }
    job('vision', '붙여넣기 읽기', async signal => {
      prev = await api('/api/vision-check/preview-text', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text, year: +($('#vc_year').value || 2026) }) });
      return done();
    }, { limit: 60 }).catch(() => { });
  }
  function save() {
    if (!prev) { setStatus('vision', '먼저 미리보기를 하세요', 'warn'); return }
    const keys = [...document.querySelectorAll('.vc_blk:checked')].map(c => c.value);
    if (!keys.length) { setStatus('vision', '저장할 줄을 고르세요', 'warn'); return }
    if (!confirm(`비전 재검사 ${keys.length}건을 저장할까요?`)) return;
    job('vision', 'DB 저장', async signal => {
      const r = await api('/api/vision-check', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ sha256: prev.sha256, keys, replace: $('#vc_replace').checked }) });
      const nm = k => { const b = prev.blocks.find(x => x.key === k); return b ? `${b.date} ${b.model} 비전 ${b.round}차` : k };
      $('#vc_res').innerHTML = `<ul>${r.results.map(x => x.ok ? `<li class="ok">${e(nm(x.key))} 저장 · ${x.linked_to_journal ? '권선 일보 연결' : '<span class="muted">권선 일보 미연결(그날 일보 없음·여러 건)</span>'}</li>` : x.exists ? `<li class="warn">${e(nm(x.key))} 이미 저장됨 — 바꾸려면 '기존 기록 바꾸기'</li>` : `<li class="err">${e(nm(x.key))} 실패 · ${e(x.error)}</li>`).join('')}</ul>
        <a class="primary small" href="index.html?proc=BA&view=vision" target="m13dash" style="display:inline-block;margin-top:4px;padding:6px 12px;border-radius:8px;text-decoration:none">대시보드 비전 불량 보기 ↗</a>`;
      prev.blocks.forEach(b => { if (r.results.some(x => (x.ok || x.exists) && x.key === b.key)) b.exists = true }); render(); loadList();
      return `저장 ${r.saved}건${r.results.length - r.saved ? ` · 저장 안 됨 ${r.results.length - r.saved}건(아래 사유)` : ''}`;
    }, { limit: 180 }).catch(() => { });
  }
  async function loadList() {
    let rows = [];
    try { rows = await api('/api/vision-check-entries', { authed: true }) } catch (err) { $('#vc_list').innerHTML = `<div class="err">${e(err.message)} (로그인이 필요할 수 있습니다)</div>`; return }
    m13List.show('vision', $('#vc_list'), rows, {
      dateKey: 'check_date', timeKey: 'recorded_at', dateLabel: '날짜', empty: '입력된 비전 재검사가 없습니다.',
      head: '<th>날짜</th><th>모델</th><th>차수</th><th>다시 본 수량</th><th>진성</th><th>가성</th><th>가성률</th><th>진성 유형</th><th>권선 일보</th><th>출처</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.check_date)}${Number(r.same_count) > 1 ? ' <span class="m13-badge" style="background:#c62828">중복 ' + r.same_count + '</span>' : ''}</td><td>${e(r.model_code)}</td><td>비전 ${r.round}차</td><td>${r.inspected_qty_ea}</td><td class="err">${r.true_qty || ''}</td><td>${r.false_qty}</td><td>${pct(r.false_qty, r.true_qty + r.false_qty)}</td>
        <td style="white-space:nowrap">${e(r.true_types || '—')}${r.check_note ? `<br><small class="warn">${e(r.check_note)}</small>` : ''}</td><td>${r.linked_to_journal ? '연결' : '<span class="muted">미연결</span>'}</td><td class="muted"><small>${e(r.file || '')}${r.cell ? ' · ' + e(r.cell) : ''}</small></td><td class="muted">${e(m13Time(r.recorded_at))}</td>
        <td><button class="ghost small" type="button" data-vcv="${e(r.run_id)}" data-vcl="${e(r.check_date + ' ' + r.model_code + ' 비전 ' + r.round + '차')}">삭제</button></td></tr>`,
      after: box => box.querySelectorAll('[data-vcv]').forEach(b => b.onclick = () => {
        const note = prompt(b.dataset.vcl + ' 재검사를 삭제(VOID)할까요?\n사유를 5자 이상 적어 주세요'); if (note === null) return;
        job('vision', '삭제', async () => { await api('/api/vision-check/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run_id: b.dataset.vcv, note }) }); loadList(); return `삭제(VOID) · ${b.dataset.vcl}` }).catch(() => { });
      }),
    });
  }
  function init() {
    if (!$('#v-vision')) return;
    $('#vc_go').onclick = preview; $('#vc_goText').onclick = previewText; $('#vc_save').onclick = save; $('#vc_listGo').onclick = loadList;
    $('#vc_file').onchange = () => { prev = null; render(); $('#vc_res').innerHTML = ''; const f = $('#vc_file').files[0]; if (f) setStatus('vision', `파일 선택됨 · ${f.name} · '파일 미리보기'를 누르세요`, 'info') };
    document.querySelector('#tabs [data-v="vision"]')?.addEventListener('click', loadList);
    if (document.querySelector('#tabs [data-v="vision"].on')) loadList();
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
