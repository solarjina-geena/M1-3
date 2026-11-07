// 관리 화면 '리워크 작업일보' 탭 — CA 공정 리워크 작업일보(재마킹 · 비전 가성 양품 CA 투입) 사진·PDF → Claude 판독 → 칸마다 고치기 → 저장. 2026-11-07 팀장 요청
// 칸 하나(모델 × 용접부/조립부) = 리워크 1건: rework_record(S/N 범위·마킹 LOT) + CA 공정 리워크 작업 실행(REWORK) + 진성 불량. 가성은 다시 투입한 양품 수량.
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const PART = { WELD: '용접부(비전 가성 양품 투입)', ASSEMBLY: '조립부(재마킹 등)' };
  let prev = null;
  const num = v => v == null || v === '' ? '' : v;
  // (2026-11-07 팀장) 최종검사 일보처럼: 표는 읽기 전용 요약 + 줄마다 [고치기 · 빼기] 세로 단추, 고치기 = 줄 아래 편집 칸
  const fmt = v => v == null || v === '' ? '—' : Number(v).toLocaleString();
  const sumCells = b => `<td>${e(b.work_date || '?')}</td><td><b>${e(b.model)}</b></td><td>${e(PART[b.part] || b.part)}</td>
        <td>${fmt(b.total_qty)}</td><td class="err">${b.true_qty || ''}</td>
        <td style="white-space:nowrap">${b.part === 'WELD' ? ((b.true_types || []).map(t => e((t.name || '?') + (t.qty != null ? ' ' + t.qty : ''))).join('<br>') || '—')
          : ((b.rows || []).map(r => e(`${r.type || '?'} ${r.qty ?? '—'} · 진 ${r.true ?? 0} · 가 ${r.false ?? 0}`)).join('<br>') || '—')}</td>
        <td>${fmt(b.false_qty)}</td><td>${b.part === 'WELD' ? fmt(b.input_qty) : '—'}</td>
        <td style="white-space:nowrap">${e(b.mark || '')} ${e(b.serial_start || '')}${b.serial_end ? ' ~ ' + e(b.serial_end) : ''}${b.serial_count ? `<br><small class="muted">${b.serial_count.toLocaleString()}개 번호</small>` : ''}</td>
        <td>${b.ca_lot_code ? e(b.ca_lot_code) : '<small class="warn">미연결</small>'}${b.workers_masked?.length ? `<br><small class="muted">작업자 ${b.workers_masked.map(e).join('·')}</small>` : ''}</td>`;
  const stCell = b => (b.skip ? '<b class="warn">빼기(저장 안 함)</b>' : b.exists ? '<span class="warn">이미 저장됨</span>' : b.check ? `<span class="warn">${e(b.check)}</span>` : '<span class="ok">OK</span>')
    + (b.edited ? '<br><small class="warn">수정됨(저장 전)</small>' : '');
  function editor(b) {
    const I = (f, label, v, w = '80px', t = 'text') => `<label>${label} <input data-rk="${e(b.key)}" data-rf="${f}" type="${t}" value="${e(num(v))}" style="width:${w}"></label>`;
    const rowsHtml = (b.rows || []).map((r, i) => `<div class="je-row">${e(r.type || '?')} 수량 <input data-rk="${e(b.key)}" data-rf="rows.${i}.qty" value="${e(num(r.qty))}" style="width:55px"> 진성 <input data-rk="${e(b.key)}" data-rf="rows.${i}.true" value="${e(num(r.true))}" style="width:50px"> 가성 <input data-rk="${e(b.key)}" data-rf="rows.${i}.false" value="${e(num(r.false))}" style="width:50px"></div>`).join('') || '<div class="muted">없음</div>';
    const typesTxt = (b.true_types || []).map(t => (t.name || '') + (t.qty != null ? ' ' + t.qty : '')).join(', ');
    return `<div class="je"><div class="je-grid">
      ${I('work_date', '날짜', b.work_date, '140px', 'date')}
      <label>모델 <select data-rk="${e(b.key)}" data-rf="model">${['IV', 'OV', 'HSV'].map(m => `<option ${m === b.model ? 'selected' : ''}>${m}</option>`).join('')}</select></label>
      <label>구분 <select data-rk="${e(b.key)}" data-rf="part">${Object.entries(PART).map(([v, t]) => `<option value="${v}" ${v === b.part ? 'selected' : ''}>${t}</option>`).join('')}</select></label>
      ${I('total_qty', '총 수량', b.total_qty, '70px')} ${I('true_qty', '진성', b.true_qty, '60px')} ${I('false_qty', '가성', b.false_qty, '60px')}
      ${b.part === 'WELD' ? I('input_qty', '투입', b.input_qty, '60px') : ''}
      ${I('mark', '마킹', b.mark, '60px')} ${I('serial_start', 'S/N 시작', b.serial_start, '90px')} ${I('serial_end', 'S/N 끝', b.serial_end, '90px')}</div>
      ${b.part === 'WELD' ? `<label class="je-wide">진성 유형 (예: 권선불량 4, 핀찍힘 9) <input data-rk="${e(b.key)}" data-rf="true_types_txt" value="${e(typesTxt)}"></label>`
        : `<div class="je-list"><b>유형별 (저항·깊이·내경·마킹)</b>${rowsHtml}</div>`}
      <label class="je-wide">메모 <input data-rk="${e(b.key)}" data-rf="note" value="${e(b.note || '')}"></label>
      ${b.check ? `<div class="warn" style="margin:4px 0">확인: ${e(b.check)}</div>` : ''}
      <button class="ghost small" type="button" data-rk-close="${e(b.key)}">고치기 닫기</button></div>`;
  }
  function render() {
    const box = $('#rk_out'); if (!prev) { box.innerHTML = ''; return }
    const bs = prev.blocks;
    box.innerHTML = `<div class="muted">${e(prev.file || '')} · 리워크 날짜 ${e(prev.work_date || '?')} (${prev.date_source === 'FILE' ? '파일명' : 'AI 판독'}) · 칸 ${bs.length}개 · <b>고치기</b>로 값을 고치고, 저장하지 않을 칸은 <b>빼기</b></div>
      ${(prev.uncertain_notes || []).length ? `<div class="muted" style="margin:4px 0">메모: ${prev.uncertain_notes.map(e).join(' / ')}</div>` : ''}
      <div class="tbl-wrap"><table><tr><th>상태</th><th>날짜</th><th>모델</th><th>구분</th><th>총 수량</th><th>진성</th><th>진성 유형 · 유형별</th><th>가성</th><th>투입</th><th>마킹 · S/N 범위</th><th>CA LOT</th><th></th></tr>
      ${bs.map(b => `<tr data-rk-row="${e(b.key)}"${b.skip ? ' style="opacity:.5"' : ''}><td class="st-cell">${stCell(b)}</td>${sumCells(b)}
        <td><div class="act-col"><button class="ghost small" type="button" data-rk-ed="${e(b.key)}">고치기</button><button class="ghost small" type="button" data-rk-skip="${e(b.key)}">${b.skip ? '빼기 취소' : '빼기'}</button></div></td></tr>
        ${b.open ? `<tr class="je-tr"><td colspan="12" style="background:var(--edit-bg,#f4f8fd);text-align:left">${editor(b)}</td></tr>` : ''}`).join('')}</table></div>`;
    const n = bs.filter(b => !b.skip && !b.exists).length;
    $('#rk_save').textContent = `리워크 ${n}건 DB에 저장`;
  }
  document.addEventListener('click', ev => {
    const t = ev.target; if (!t.dataset || !prev) return;
    const k = t.dataset.rkEd || t.dataset.rkSkip || t.dataset.rkClose; if (!k) return;
    const b = prev.blocks.find(x => x.key === k); if (!b) return;
    if (t.dataset.rkEd) b.open = !b.open; else if (t.dataset.rkSkip) b.skip = !b.skip; else b.open = false;
    render();
  });
  // 고친 값 반영(고친 칸은 human_edits 로 기록). 입력 중에는 표 요약 칸만 바꿔 커서를 잃지 않게
  document.addEventListener('input', ev => {
    const t = ev.target; if (!t.dataset || !t.dataset.rk || !prev) return;
    const b = prev.blocks.find(x => x.key === t.dataset.rk); if (!b) return;
    const f = t.dataset.rf, old = f === 'true_types_txt' ? (b.true_types || []).map(x => (x.name || '') + ' ' + (x.qty ?? '')).join(', ') : f.split('.').reduce((o, k) => o?.[k], b);
    if (f === 'true_types_txt') b.true_types = t.value.split(',').map(s => s.trim()).filter(Boolean).map(s => { const m = s.match(/^(.*?)\s*(\d+)\s*(EA|개)?$/i); return m ? { name: m[1].trim(), qty: +m[2] } : { name: s, qty: null } });
    else if (f.startsWith('rows.')) { const [, i, k] = f.split('.'); b.rows[+i][k] = t.value === '' ? null : +t.value }
    else b[f] = t.value === '' ? null : t.value;
    if (f === 'serial_start' || f === 'serial_end') {
      const a = +b.serial_start, z = +b.serial_end; b.serial_count = a && z && z >= a ? z - a + 1 : null;
      if (a && z && z >= a && b.check) b.check = b.check.split(' · ').filter(x => !/S\/N 끝/.test(x)).join(' · ') || null;
    }
    (b.human_edits = b.human_edits || []).push({ path: f, ai: old == null ? null : String(old), value: t.value }); b.edited = true;
    t.style.background = 'var(--ok-bg,#eaf7ea)';
    if (f === 'part' || f === 'model') { render(); return }
    const row = document.querySelector(`tr[data-rk-row="${CSS.escape(b.key)}"]`); if (!row) return;
    const tmp = document.createElement('tbody'); tmp.innerHTML = `<tr><td></td>${sumCells(b)}</tr>`;
    const cells = [...tmp.querySelectorAll('tr > td')].slice(1);
    [...row.children].slice(1, 1 + cells.length).forEach((c, i) => c.replaceWith(cells[i]));
    const st = row.querySelector('.st-cell'); if (st) st.innerHTML = stCell(b);
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
    const rep = $('#rk_replace').checked;
    const blocks = prev.blocks.filter(b => !b.skip && (rep || !b.exists)).map(({ open, edited, skip, ...b }) => b);
    if (!blocks.length) { setStatus('rework', '저장할 칸이 없습니다(모두 빼기 또는 이미 저장됨 — 바꾸려면 기존 기록 바꾸기)', 'warn'); return }
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
