// 관리 화면 '사출조건 체크시트' 탭 — IV·OV·HSV 체크시트 엑셀(같은 양식)을 올려 탭(= 보빈 사출 LOT)별로 저장. 2026-11-06
// 엑셀은 서버가 셀 값만 읽는다(사진은 읽지 않음). 미리보기 → 탭 고르기 → 저장(실측·출처·사출 실행 FK) → 대시보드 사출 그래프.
// 저장은 API(m13_injection_sheet_save)가 탭 이름 = LOT 규칙으로 같은 모델 사출 실행에 연결한다(실행이 없으면 미연결로 저장, 추정 안 함).
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  let prev = null;
  const NAME = { INJ_PRESS_S1: '사출1 압력', INJ_PRESS_HOLD1: '보압1 압력', MON_SWITCH_POS_START: '전환위치', INJ_CUSHION: '쿠션', INJ_TEMP_NZ: '노즐 온도', BOBBIN_WEIGHT: '보빈무게(g)' };

  function render() {
    const box = $('#is_out'); if (!prev) { box.innerHTML = ''; return }
    const ok = prev.tabs.filter(t => !t.problem), codes = Object.keys(NAME);
    const val = (t, c, row) => { const o = t.sample.find(x => x.code === c && x.row === row); return o ? e(o.value) : '' };
    box.innerHTML = `<div class="muted">${e(prev.file)} · ${(prev.size / 1048576).toFixed(1)}MB · 값 탭 ${prev.tabs.length}장(저장 가능 ${ok.length}) · 건너뛴 탭(사진·인벤토리 등) ${prev.skipped_tabs.length}장${prev.spec_diff.length ? ` · <span class="warn">탭마다 기준이 다른 칸 ${prev.spec_diff.length}개</span>` : ''}
      ${ok.length && !ok.some(t => Object.keys(t.specs || {}).length) ? '<br>기준 줄이 비어 있어 SPEC 밴드는 만들지 않습니다(보빈무게 SPEC 은 DB 기존 값).' : ''}</div>
      <table><tr><th><input type="checkbox" id="is_all" checked style="width:auto"></th><th>탭 = 보빈 LOT</th><th>주·야</th><th>실측 칸<br><small>주간 / 야간</small></th>${codes.map(c => `<th>${NAME[c]}<br><small>주간 / 야간</small></th>`).join('')}<th>상태</th></tr>
      ${prev.tabs.map(t => `<tr><td>${t.problem ? '' : `<input type="checkbox" class="is_tab" value="${e(t.tab)}" ${t.exists ? '' : 'checked'} style="width:auto">`}</td>
        <td><b>${e(t.lot)}</b><br><small class="muted">${e(t.tab)}</small></td><td>${t.shift === 'N' ? '야간 탭' : '주간 탭'}</td><td>${t.day_obs} / ${t.night_obs}</td>
        ${codes.map(c => `<td>${val(t, c, 'DAY')}${val(t, c, 'NIGHT') ? ' / ' + val(t, c, 'NIGHT') : ''}</td>`).join('')}
        <td>${t.problem ? `<span class="err">저장 안 함: ${e(t.problem)}</span>` : t.exists ? '<span class="warn">이미 저장됨</span>' : '<span class="ok">새 탭</span>'}${t.skipped_cells?.length ? `<br><small class="muted">숫자 아닌 칸 ${t.skipped_cells.length}개 건너뜀</small>` : ''}</td></tr>`).join('')}</table>
      <div class="muted" style="margin-top:4px">주간 행 = 탭 LOT, 야간 행 = 야간 탭이면 탭 LOT · 주간 탭이면 같은 날 N1 LOT(사람 확인 전). 같은 모델 사출 실행 중 그 LOT 이 있으면 FK 연결, 없으면 미연결로 저장합니다. '이미 저장됨' 탭은 '기존 기록 바꾸기'를 켜야 다시 저장됩니다.</div>`;
    $('#is_all').onchange = ev => document.querySelectorAll('.is_tab').forEach(c => c.checked = ev.target.checked);
  }

  function preview() {
    const f = $('#is_file').files[0], model = $('#is_model').value;
    if (!f) { setStatus('inj', '엑셀 파일을 먼저 고르세요', 'warn'); return }
    if (!model) { setStatus('inj', '모델을 고르세요(제목 칸 모델과 다르면 저장하지 않습니다)', 'warn'); return }
    job('inj', '체크시트 읽기', async signal => {
      const fd = new FormData(); fd.append('file', f);
      prev = await api('/api/injection-sheet/preview?model=' + model, { method: 'POST', authed: true, body: fd, signal });
      render();
      const ok = prev.tabs.filter(t => !t.problem);
      return `미리보기 · ${model} 탭 ${prev.tabs.length}장 (저장 가능 ${ok.length}, 이미 저장됨 ${ok.filter(t => t.exists).length}) — 저장할 탭을 고르고 'DB에 저장'`;
    }, { limit: 120 }).catch(() => { });
  }

  function save() {
    if (!prev) { setStatus('inj', '먼저 미리보기를 하세요', 'warn'); return }
    const tabs = [...document.querySelectorAll('.is_tab:checked')].map(c => c.value);
    if (!tabs.length) { setStatus('inj', '저장할 탭을 고르세요', 'warn'); return }
    if (!confirm(`${prev.model} 사출조건 ${tabs.length}장을 저장할까요?\n${tabs.join(', ')}`)) return;
    job('inj', 'DB 저장', async signal => {
      const r = await api('/api/injection-sheet', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sha256: prev.sha256, model: prev.model, tabs, replace: $('#is_replace').checked }) });
      $('#is_res').innerHTML = `<ul>${r.detail.map(d => `<li>${e(d.tab)} · 실측 ${d.obs}칸 · 사출 실행 연결 ${d.linked}칸${d.linked_lots.length ? ' (' + d.linked_lots.map(e).join(', ') + ')' : ''}${d.unlinked_lots.length ? ` · <span class="warn">실행 없음 → 미연결: ${d.unlinked_lots.map(e).join(', ')}</span>` : ''}</li>`).join('')}</ul>
        <a class="ghost small" href="index.html?proc=INJECTION&model=${prev.model}" target="m13dash">대시보드 사출 그래프 보기 ↗</a>`;
      prev.tabs.forEach(t => { if (tabs.includes(t.tab)) t.exists = true }); render(); loadList();
      return `저장 · ${r.tabs}장 · 실측 ${r.observations}칸 · 사출 실행 FK ${r.linked}칸${r.voided ? ` · 이전 기록 VOID ${r.voided}칸` : ''}${r.spec_items ? ` · 기준 ${r.spec_items}항목` : ''}`;
    }, { limit: 120 }).catch(() => { });
  }

  async function loadList() {
    const m = $('#is_listModel').value; let rows = [];
    try { rows = await api('/api/injection-sheets' + (m ? '?model=' + m : '')) } catch (err) { $('#is_list').innerHTML = `<div class="err">${e(err.message)}</div>`; return }
    rows.forEach(r => { const d = String(r.tab || '').match(/^(\d{4})(\d{2})(\d{2})/); r.lot_date = d ? `${d[1]}-${d[2]}-${d[3]}` : '' });
    m13List.show('inj', $('#is_list'), rows, {
      dateKey: 'lot_date', timeKey: 'recorded_at', dateLabel: 'LOT 날짜', empty: '입력된 사출조건 탭이 없습니다.',
      head: '<th>모델</th><th>탭 = LOT</th><th>실측</th><th>사출 실행 연결</th><th>연결 LOT</th><th>파일</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.model_code)}</td><td>${e(r.tab)}</td><td>${r.observations}</td><td>${r.linked}${r.observations && r.linked < r.observations ? ' <small class="warn">일부 미연결</small>' : ''}</td><td>${e(r.linked_lots || '—')}</td><td class="muted">${e(r.file || (r.ds === 'INJ_COND_XLSX_V1' ? '도구 적재(IV)' : ''))}</td><td class="muted">${e(m13Time(r.recorded_at))}</td><td>${r.ds === 'INJ_COND_UPLOAD_V1' ? `<button class="ghost small" data-isv="${e(r.document_id)}" data-isl="${e(r.model_code + ' ' + r.tab)}">삭제</button>` : ''}</td></tr>`,
      after: box => box.querySelectorAll('[data-isv]').forEach(b => b.onclick = () => {
        const note = prompt(b.dataset.isl + ' 사출조건 탭을 삭제(VOID)할까요?\n사유를 5자 이상 적어 주세요'); if (note === null) return;
        job('inj', '탭 삭제', async () => { const r = await api('/api/injection-sheet/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ document_id: b.dataset.isv, note }) }); loadList(); return `삭제(VOID) · ${b.dataset.isl} · 실측 ${r.voided_observations}칸` }).catch(() => { });
      }),
    });
  }

  function init() {
    if (!$('#v-inj')) return;
    $('#is_go').onclick = preview; $('#is_save').onclick = save; $('#is_listGo').onclick = loadList; $('#is_listModel').onchange = loadList;
    $('#is_file').onchange = () => { prev = null; render(); $('#is_res').innerHTML = ''; const f = $('#is_file').files[0]; if (f) { const m = f.name.toUpperCase().match(/(?:^|[_\s-])(IV|OV|HSV)(?:[_\s.-]|$)/); if (m) $('#is_model').value = m[1]; setStatus('inj', `파일 선택됨 · ${f.name} (${(f.size / 1048576).toFixed(1)}MB) · '미리보기'를 누르세요`, 'info') } };
    document.querySelector('#tabs [data-v="inj"]')?.addEventListener('click', loadList);
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
