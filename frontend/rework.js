// 관리 화면 '리워크 작업일보' 탭 — CA 공정 리워크 작업일보(재마킹 · 비전 가성 양품 CA 투입) 사진·PDF → Claude 판독 → 칸마다 고치기 → 저장. 2026-11-07 팀장 요청
// 칸 하나(모델 × 용접부/조립부) = 리워크 1건: rework_record(S/N 범위·마킹 LOT) + CA 공정 리워크 작업 실행(REWORK) + 진성 불량. 가성은 다시 투입한 양품 수량.
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const PART = { WELD: '용접부(비전 가성 양품 투입)', ASSEMBLY: '조립부(재마킹 등)' };
  let prev = null;
  const num = v => v == null || v === '' ? '' : v;
  const inp = (k, f, v, w = '70px', t = 'text') => `<input data-rk="${k}" data-rf="${f}" type="${t}" value="${e(num(v))}" style="width:${w}">`;

  function render() {
    const box = $('#rk_out'); if (!prev) { box.innerHTML = ''; return }
    const bs = prev.blocks;
    box.innerHTML = `<div class="muted">${e(prev.file || '')} · 리워크 날짜 ${e(prev.work_date || '?')} (${prev.date_source === 'FILE' ? '파일명' : 'AI 판독'}) · 칸 ${bs.length}개 — 값을 고친 뒤 저장하세요. 노란 글씨 = 확인 필요</div>
      ${(prev.uncertain_notes || []).length ? `<div class="muted" style="margin:4px 0">메모: ${prev.uncertain_notes.map(e).join(' / ')}</div>` : ''}
      <table><tr><th><input type="checkbox" id="rk_all" checked style="width:auto"></th><th>날짜</th><th>모델</th><th>구분</th><th>총 수량</th><th>진성</th><th>진성 유형</th><th>가성</th><th>투입</th><th>마킹 · S/N 범위</th><th>CA LOT</th><th>조립부 유형별</th><th>상태</th></tr>
      ${bs.map(b => `<tr data-rk-row="${e(b.key)}">
        <td><input type="checkbox" class="rk_blk" value="${e(b.key)}" ${b.exists ? '' : 'checked'} style="width:auto"></td>
        <td>${inp(b.key, 'work_date', b.work_date, '130px', 'date')}</td>
        <td><select data-rk="${e(b.key)}" data-rf="model">${['IV', 'OV', 'HSV'].map(m => `<option ${m === b.model ? 'selected' : ''}>${m}</option>`).join('')}</select></td>
        <td><select data-rk="${e(b.key)}" data-rf="part">${Object.entries(PART).map(([v, t]) => `<option value="${v}" ${v === b.part ? 'selected' : ''}>${t}</option>`).join('')}</select></td>
        <td>${inp(b.key, 'total_qty', b.total_qty, '60px')}</td><td>${inp(b.key, 'true_qty', b.true_qty, '55px')}</td>
        <td style="white-space:nowrap">${b.part === 'WELD' ? inp(b.key, 'true_types_txt', (b.true_types || []).map(t => (t.name || '') + (t.qty != null ? ' ' + t.qty : '')).join(', '), '170px') : '<small class="muted">유형별 칸에서</small>'}</td>
        <td>${inp(b.key, 'false_qty', b.false_qty, '55px')}</td><td>${b.part === 'WELD' ? inp(b.key, 'input_qty', b.input_qty, '55px') : '—'}</td>
        <td style="white-space:nowrap">${inp(b.key, 'mark', b.mark, '50px')} ${inp(b.key, 'serial_start', b.serial_start, '80px')} ~ ${inp(b.key, 'serial_end', b.serial_end, '80px')}${b.serial_count ? `<br><small class="muted">${b.serial_count.toLocaleString()}개 번호</small>` : ''}</td>
        <td>${b.ca_lot_code ? e(b.ca_lot_code) : '<small class="warn">미연결</small>'}${b.mark_how ? `<br><small class="muted">${e(b.mark_how)}</small>` : ''}</td>
        <td style="white-space:nowrap">${b.part === 'ASSEMBLY' ? (b.rows || []).map((r, i) => `${e(r.type || '?')} ${inp(b.key, 'rows.' + i + '.qty', r.qty, '42px')} 진 ${inp(b.key, 'rows.' + i + '.true', r.true, '38px')} 가 ${inp(b.key, 'rows.' + i + '.false', r.false, '38px')}`).join('<br>') + (b.workers_masked?.length ? `<br><small class="muted">작업자 ${b.workers_masked.map(e).join('·')}</small>` : '') : '—'}</td>
        <td>${b.exists ? '<span class="warn">이미 저장됨</span>' : b.check ? `<span class="warn">${e(b.check)}</span>` : '<span class="ok">새 기록</span>'}${b.note ? `<br><small class="muted">${e(b.note)}</small>` : ''}</td></tr>`).join('')}</table>`;
    $('#rk_all').onchange = ev => document.querySelectorAll('.rk_blk').forEach(c => c.checked = ev.target.checked);
  }
  // 고친 값 반영(고친 칸은 human_edits 로 기록)
  document.addEventListener('input', ev => {
    const t = ev.target; if (!t.dataset || !t.dataset.rk || !prev) return;
    const b = prev.blocks.find(x => x.key === t.dataset.rk); if (!b) return;
    const f = t.dataset.rf, old = f === 'true_types_txt' ? (b.true_types || []).map(x => (x.name || '') + ' ' + (x.qty ?? '')).join(', ') : f.split('.').reduce((o, k) => o?.[k], b);
    if (f === 'true_types_txt') b.true_types = t.value.split(',').map(s => s.trim()).filter(Boolean).map(s => { const m = s.match(/^(.*?)\s*(\d+)\s*(EA|개)?$/i); return m ? { name: m[1].trim(), qty: +m[2] } : { name: s, qty: null } });
    else if (f.startsWith('rows.')) { const [, i, k] = f.split('.'); b.rows[+i][k] = t.value === '' ? null : +t.value }
    else b[f] = t.value === '' ? null : t.value;
    (b.human_edits = b.human_edits || []).push({ path: f, ai: old == null ? null : String(old), value: t.value });
    t.style.background = 'var(--ok-bg,#eaf7ea)';
    if (f === 'part' || f === 'model') render();
  });

  async function preview() {
    const f = $('#rk_file').files[0];
    if (!f) { setStatus('rework', '리워크 작업일보 사진·PDF 를 먼저 고르세요', 'warn'); return }
    job('rework', '리워크 일보 판독', async signal => {
      const send = async pg => { const fd = new FormData(); fd.append('file', f); return api('/api/rework/preview-image' + (pg ? '?page=' + pg : ''), { method: 'POST', authed: true, body: fd, signal }) };
      let r = await send(null);
      if (r.need_pages) {
        const all = { file: r.file, blocks: [], uncertain_notes: [] };
        for (let pg = 1; pg <= r.pdf_pages; pg++) {
          const x = await send(pg); all.work_date = all.work_date || x.work_date; all.date_source = x.date_source;
          all.blocks.push(...x.blocks.map(b => ({ ...b, key: 'p' + pg + b.key }))); all.uncertain_notes.push(...(x.uncertain_notes || []).map(n => pg + '쪽: ' + n));
        }
        r = all;
      }
      prev = r; render();
      return r.blocks.length ? `판독 완료 · 리워크 칸 ${r.blocks.length}개 — 확인·고친 뒤 'DB에 저장'` : '값이 적힌 리워크 칸을 찾지 못했습니다';
    }, { limit: 200 }).catch(() => { });
  }
  function save() {
    if (!prev) { setStatus('rework', '먼저 판독하세요', 'warn'); return }
    const keys = new Set([...document.querySelectorAll('.rk_blk:checked')].map(c => c.value));
    const blocks = prev.blocks.filter(b => keys.has(b.key));
    if (!blocks.length) { setStatus('rework', '저장할 칸을 고르세요', 'warn'); return }
    if (!confirm(`리워크 ${blocks.length}건을 저장할까요?`)) return;
    job('rework', 'DB 저장', async signal => {
      const r = await api('/api/rework', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ blocks, replace: $('#rk_replace').checked }) });
      const nm = k => { const b = prev.blocks.find(x => x.key === k); return b ? `${b.work_date} ${b.model} ${b.part === 'WELD' ? '용접부' : '조립부'}` : k };
      $('#rk_res').innerHTML = `<ul>${r.results.map(x => x.ok ? `<li class="ok">${e(nm(x.key))} 저장 · CA LOT ${e(x.ca_lot || '미연결')} · 진성 불량 ${x.defects}줄</li>` : x.exists ? `<li class="warn">${e(nm(x.key))} 이미 저장됨 — 바꾸려면 '기존 기록 바꾸기'</li>` : `<li class="err">${e(nm(x.key))} 실패 · ${e(x.error)}</li>`).join('')}</ul>`;
      prev.blocks.forEach(b => { if (r.results.some(x => (x.ok || x.exists) && x.key === b.key)) b.exists = true }); render(); loadList();
      return `저장 ${r.saved}건${r.results.length - r.saved ? ` · 저장 안 됨 ${r.results.length - r.saved}건` : ''}`;
    }, { limit: 120 }).catch(() => { });
  }
  async function loadList() {
    let rows = [];
    try { rows = await api('/api/rework-entries', { authed: true }) } catch (err) { $('#rk_list').innerHTML = `<div class="err">${e(err.message)} (로그인이 필요할 수 있습니다)</div>`; return }
    const fmt = n => n == null ? '—' : Number(n).toLocaleString();
    m13List.show('rework', $('#rk_list'), rows, {
      dateKey: 'work_date', timeKey: 'recorded_at', dateLabel: '리워크일', empty: '저장된 리워크가 없습니다.',
      head: '<th>리워크일</th><th>모델</th><th>구분</th><th>마킹 · S/N 범위</th><th>번호 수</th><th>CA LOT</th><th>총</th><th>진성</th><th>진성 유형</th><th>가성</th><th>투입</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.work_date)}${Number(r.same_count) > 1 ? ' <span class="m13-badge" style="background:#c62828">중복 ' + r.same_count + '</span>' : ''}</td><td>${e(r.model_code)}</td><td>${e(r.part_ko || '리워크')}</td>
        <td style="white-space:nowrap">${e(r.mark || '')} ${e(r.serial_start_raw || '')}${r.serial_end_raw ? ' ~ ' + e(r.serial_end_raw) : ''}</td><td>${fmt(r.serial_count)}</td><td>${e(r.ca_lot_code || '—')}</td>
        <td>${fmt(r.total_qty)}</td><td class="err">${r.true_qty || ''}</td><td style="white-space:nowrap">${e(r.true_types || '—')}${r.check_note ? `<br><small class="warn">${e(r.check_note)}</small>` : ''}</td><td>${fmt(r.false_qty)}</td><td>${fmt(r.input_qty)}</td>
        <td class="muted">${e(m13Time(r.recorded_at))}</td><td><button class="ghost small" type="button" data-rkv="${e(r.rework_id)}" data-rkl="${e(r.work_date + ' ' + r.model_code + ' ' + (r.part_ko || ''))}">삭제</button></td></tr>`,
      after: box => box.querySelectorAll('[data-rkv]').forEach(b => b.onclick = () => {
        const note = prompt(b.dataset.rkl + ' 리워크를 삭제(VOID)할까요?\n사유를 5자 이상 적어 주세요'); if (note === null) return;
        job('rework', '삭제', async () => { await api('/api/rework/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ rework_id: b.dataset.rkv, note }) }); loadList(); return '삭제(VOID) · ' + b.dataset.rkl }).catch(() => { });
      }),
    });
  }
  function init() {
    if (!$('#v-rework')) return;
    $('#rk_go').onclick = preview; $('#rk_save').onclick = save; $('#rk_listGo').onclick = loadList;
    $('#rk_file').onchange = () => { prev = null; render(); $('#rk_res').innerHTML = ''; const f = $('#rk_file').files[0]; if (f) setStatus('rework', `파일 선택됨 · ${f.name} · 'OCR 시작'을 누르세요`, 'info') };
    document.querySelector('#tabs [data-v="rework"]')?.addEventListener('click', loadList);
    if (document.querySelector('#tabs [data-v="rework"].on')) loadList();
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
