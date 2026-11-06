// 관리 화면 '최종검사 재검사' 탭 — 최종검사 일보 비고란의 재검(이미 검사한 LOT 에서 불량을 더 가려내는 작업) 입력·삭제.
// manage.html 의 공용 함수($, api, job, setStatus, esc)를 쓴다. 저장: POST /api/reinspection → RPC m13_reinspection_save
//   inspection_run(REINSPECTION) + inspection_lot(대상 LOT 마다, CA 제품 LOT FK) + inspection_run_link(본검사 FK) + quality_finding(불량 유형 FK)
// 재검 1건이 여러 LOT 을 대상으로 할 수 있다(예: 9/23 IV L/C 찍힘 재검 = 마킹 10개 합계 38,400EA, 불량 173EA는 재검 전체 합계).
// 비고란 캡처: 원본은 화면에서 SHA-256 만 계산, 'AI로 읽기' 때만 긴 변 1,568px JPEG 사본을 보낸다(원본·사본 보관 안 함).
(() => {
  if (!document.querySelector('#v-reinsp')) return;
  const METHOD = { VISUAL_MANUAL: '육안 재검', MICROSCOPE: '현미경 검사' };
  const EA_PER_BOX = 480;
  let targets = [], defects = [], img = null, aiEntries = [];

  const norm = s => String(s || '').toLowerCase().replace(/[\s_\-/]/g, '');
  function defectCode(name) {
    const n = norm(name); if (!n) return null;
    const hit = defects.find(d => norm(d.defect_name) === n || norm(d.defect_code) === n || norm(d.defect_code.replace(/^FIN:/, '')) === n);
    return hit ? hit.defect_code : null;
  }

  // ---- 대상 LOT 줄 (모델별 '최종검사 받은 CA 제품 LOT' 목록에서 고른다)
  async function loadTargets() {
    const m = $('#r_model').value; targets = [];
    if (m) { try { targets = await api('/api/reinspection/targets?model=' + m) } catch (e) { setStatus('reinsp', 'LOT 목록 실패 · ' + e.message, 'error') } }
    document.querySelectorAll('#r_lots tr').forEach(tr => fillLot(tr));
  }
  function lotOptions(q) {
    q = (q || '').trim().toUpperCase(); const seen = new Map();
    for (const t of targets) {
      if (q && !(t.ca_lot_code + ' ' + (t.marking_code || '') + ' ' + (t.inspection_lot_raw || '') + ' ' + t.lot_date).toUpperCase().includes(q)) continue;
      const o = seen.get(t.ca_lot_code) || { code: t.ca_lot_code, date: t.lot_date, marks: new Set(), n: 0 };
      if (t.marking_code) o.marks.add(t.marking_code); o.n++; seen.set(t.ca_lot_code, o);
    }
    return [...seen.values()];
  }
  function fillLot(tr, pick) {
    const sel = tr.querySelector('.r_lot'), keep = pick ?? sel.value, opts = lotOptions(tr.querySelector('.r_lotq').value);
    sel.innerHTML = `<option value="">${$('#r_model').value ? `고르세요 (${opts.length}개)` : '모델을 먼저 고르세요'}</option>` +
      opts.map(o => `<option value="${esc(o.code)}">${esc(o.code)} · CA ${esc(o.date)}${o.marks.size ? ' · 마킹 ' + esc([...o.marks].join('/')) : ''}</option>`).join('') +
      '<option value="__UNRESOLVED">LOT 없음 — 원문 마킹만 저장(미연결, 확인 필요 탭에서 나중에 연결)</option>';
    if (keep && (keep === '__UNRESOLVED' || opts.some(o => o.code === keep))) sel.value = keep;
    fillPrior(tr);
  }
  function fillPrior(tr) {
    const code = tr.querySelector('.r_lot').value, runs = targets.filter(t => t.ca_lot_code === code), sel = tr.querySelector('.r_prior');
    if (code === '__UNRESOLVED') { sel.innerHTML = '<option value="NONE">연결 안 함 (LOT 미연결)</option>'; return }
    sel.innerHTML = !code ? '<option value="">LOT 을 먼저 고르세요</option>'
      : `<option value="">고르세요 (본검사 ${runs.length}건)</option>` + (runs.length > 1 ? `<option value="ALL">이 LOT 본검사 전부 (${runs.length}건, 재검일 이전)</option>` : '') +
        runs.map(t => `<option value="${esc(t.inspection_run_id)}">${esc(t.inspection_date)} 최종검사${t.inspection_round_no ? ' ' + t.inspection_round_no + '차' : ''} · ${t.run_qty_ea ?? '?'}EA · ${esc(t.inspection_lot_raw || '')}</option>`).join('') +
        '<option value="NONE">본검사 기록 없음 (연결 안 함)</option>';
    if (runs.length === 1) sel.value = runs[0].inspection_run_id;   // 이 LOT 을 검사한 기록이 하나뿐이면 그것(사람이 확인 후 저장)
  }
  function addLot(v = {}) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input class="r_mark" placeholder="ZIO" value="${esc(v.mark || '')}" style="width:70px"></td>
      <td><input class="r_lotq" placeholder="찾기 260915" value="${esc(v.q || '')}" style="width:100px"></td>
      <td><select class="r_lot"></select><div class="r_how muted" style="font-size:11px">${esc(v.how || '')}</div></td>
      <td><select class="r_prior"></select></td>
      <td><input type="number" min="0" class="r_box" value="${v.box ?? ''}" style="width:60px"></td>
      <td><input type="number" min="0" class="r_ea" value="${v.ea ?? ''}" style="width:80px"></td>
      <td><button class="ghost small" type="button">빼기</button></td>`;
    tr.querySelector('.r_lotq').oninput = () => fillLot(tr);
    tr.querySelector('.r_lot').onchange = () => fillPrior(tr);
    tr.querySelector('.r_box').oninput = e => { if (e.target.value !== '') tr.querySelector('.r_ea').value = +e.target.value * EA_PER_BOX; sumQty() };
    tr.querySelector('.r_ea').oninput = sumQty;
    tr.querySelector('button').onclick = () => { tr.remove(); sumQty() };
    $('#r_lots').append(tr); fillLot(tr, v.pick); if (v.pick && $('#r_allPrior').dataset.on === '1') setAll(tr);
    return tr;
  }
  function setAll(tr) { const s = tr.querySelector('.r_prior'); if ([...s.options].some(o => o.value === 'ALL')) s.value = 'ALL' }
  function sumQty() {
    const eas = [...document.querySelectorAll('#r_lots .r_ea')].map(i => i.value);
    $('#r_lotSum').textContent = eas.length && eas.every(v => v !== '') ? `LOT 합계 ${eas.reduce((a, v) => a + +v, 0).toLocaleString()}EA` : '';
  }

  // ---- 불량 줄
  function addDefect(name = '', qty = '') {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td><input list="r_dlist" class="r_dname" placeholder="불량명 (목록에서 고르거나 원문 그대로)" value="${esc(name)}"></td><td><input type="number" min="0" class="r_dqty" value="${esc(qty)}" style="width:90px"></td><td class="r_dcode muted"></td><td><button class="ghost small" type="button">빼기</button></td>`;
    const upd = () => { const v = tr.querySelector('.r_dname').value; tr.querySelector('.r_dcode').textContent = defectCode(v) ? '불량 유형 연결' : (v ? '원문만(유형 없음)' : '') };
    tr.querySelector('.r_dname').oninput = upd; tr.querySelector('button').onclick = () => tr.remove();
    $('#r_defects').append(tr); upd();
  }

  // 파일명 날짜(서버 file_name_date 와 같은 규칙). 메신저·카메라가 붙인 저장 시각은 쓰지 않는다
  function fileDate(name) {
    const n = String(name || '');
    if (/^(kakaotalk|img|pxl|screenshot|스크린샷|photo|camera|scan)[_ -]/i.test(n)) return null;
    const pats = [[/(?<!\d)(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)/, 0], [/(?<!\d)(\d{2})\.(\d{1,2})\.(\d{1,2})(?!\d)/, 2000], [/^(\d{2})(\d{2})(\d{2})(?!\d)/, 2000]];
    for (const [re, add] of pats) {
      const m = re.exec(n); if (!m) continue;
      const y = +m[1] + add, mo = +m[2], d = +m[3], dt = new Date(Date.UTC(y, mo - 1, d));
      if (dt.getUTCFullYear() === y && dt.getUTCMonth() === mo - 1 && dt.getUTCDate() === d) return `${y}-${String(mo).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    }
    return null;
  }

  // ---- 비고란 캡처 → AI 읽기
  async function shrink(file) {
    const bmp = await createImageBitmap(file); const k = Math.min(1, 1568 / Math.max(bmp.width, bmp.height));
    const c = document.createElement('canvas'); c.width = Math.round(bmp.width * k); c.height = Math.round(bmp.height * k);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    return await new Promise(r => c.toBlob(r, 'image/jpeg', 0.85));
  }
  $('#r_img').onchange = async e => {
    const f = e.target.files[0]; img = null; $('#r_imgInfo').textContent = '';
    if (!f) return;
    if (!/^image\//.test(f.type)) { setStatus('reinsp', '이미지 파일만(jpg/png/webp)', 'warn'); return }
    if (f.size > 5 * 1024 * 1024) { setStatus('reinsp', '원본 이미지는 5MB 이하로 캡처해 주세요', 'warn'); e.target.value = ''; return }
    const sha = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await f.arrayBuffer()))].map(b => b.toString(16).padStart(2, '0')).join('');
    const small = await shrink(f);
    img = { sha256: sha, name: f.name.slice(0, 80), blob: small };
    const fd8 = fileDate(f.name);   // 파일명 날짜가 기준(폴더 정리 규칙), 없으면 직접 넣거나 비고 판독으로 보완
    if (fd8) { $('#r_base').value = fd8; if (!$('#r_date').value) $('#r_date').value = fd8 }
    $('#r_imgInfo').innerHTML = `<img src="${URL.createObjectURL(small)}" style="max-width:100%;max-height:220px;border:1px solid var(--border);border-radius:6px;margin-top:6px"><br>원본 해시 ${sha.slice(0, 12)}… · AI 에 보낼 사본 ${(small.size / 1024).toFixed(0)}KB (원본은 올리지 않음)`;
  };
  $('#r_read').onclick = () => job('reinsp', 'AI로 읽기', async () => {
    if (!img) throw new Error('비고란 캡처 이미지를 먼저 고르세요');
    const fd = new FormData(); fd.append('file', img.blob, img.name.replace(/\.[^.]+$/, '') + '.jpg');
    const base = $('#r_base').value;
    const out = await api('/api/reinspection/read-image' + (base ? '?base_date=' + base : ''), { method: 'POST', authed: true, body: fd });
    aiEntries = out.entries || [];
    $('#r_ai').innerHTML = `<div class="muted" style="margin-top:8px"><b>AI 판독값 — 사람 확인 전</b> (AI(Claude) 생성) · 재검 ${aiEntries.length}건${(out.uncertain_notes || []).length ? ' · 메모: ' + esc(out.uncertain_notes.join(' / ')) : ''}</div>` +
      (aiEntries.length ? `<table><tr><th>모델</th><th>날짜</th><th>방법</th><th>대상 LOT (BOX)</th><th>합계</th><th>불량</th><th>원문</th><th></th></tr>${aiEntries.map((e, i) => `<tr>
        <td>${esc(e.model)}</td><td>${esc(e.date || e.date_raw || '—')}</td><td>${esc(e.method)}</td>
        <td style="text-align:left">${(e.lots || []).map(l => `${esc(l.mark)}${l.box_count != null ? ' ' + l.box_count + 'BOX' : ''} <small class="muted">${esc(l.lot_date || '날짜 미정')}</small>`).join('<br>') || '—'}</td>
        <td>${esc(e.qty_raw || '')}${e.qty_ea != null ? '<br>' + e.qty_ea.toLocaleString() + 'EA' : ''}</td>
        <td>${(e.defects || []).map(d => esc(d.name_raw) + ' ' + (d.qty ?? '?')).join('<br>') || '—'}</td>
        <td style="text-align:left"><small>${esc(e.raw_text)}</small></td>
        <td><button class="ghost small" type="button" data-use="${i}">불러오기</button></td></tr>`).join('')}</table>` : '<div class="muted">재검 항목을 찾지 못했습니다. 아래에 직접 입력하세요.</div>');
    $('#r_ai').querySelectorAll('[data-use]').forEach(b => b.onclick = () => useEntry(aiEntries[+b.dataset.use]));
    return `AI 읽기 · 재검 ${aiEntries.length}건 — 불러온 뒤 모델·LOT·본검사를 확인하고 저장하세요`;
  }, { buttons: ['#r_read'] }).catch(() => {});

  async function useEntry(e) {
    const notes = [];
    if (e.model && e.model !== 'UNKNOWN') $('#r_model').value = e.model; else notes.push('모델이 비고에 없음 → 직접 고르세요');
    await loadTargets();
    if (e.date) $('#r_date').value = e.date; else if (!$('#r_date').value) { if ($('#r_base').value) $('#r_date').value = $('#r_base').value; notes.push('재검일이 비고에 없어 일보 검사일로 채움 — 확인하세요') }
    if (e.method === 'MICROSCOPE' || e.method === 'VISUAL') $('#r_method').value = e.method === 'MICROSCOPE' ? 'MICROSCOPE' : 'VISUAL_MANUAL';
    $('#r_qty').value = e.qty_ea ?? (e.box_count != null ? e.box_count * EA_PER_BOX : '');
    $('#r_note').value = e.raw_text || '';
    $('#r_defects').innerHTML = ''; (e.defects || []).forEach(d => addDefect(d.name_raw, d.qty ?? '')); if (!(e.defects || []).length) addDefect();
    // LOT: 코드가 그대로 있으면 그것, 마킹코드 날짜가 정해졌으면 그날 CA LOT 이 하나일 때만 선택. 나머지는 사람이 고른다(추정 금지).
    $('#r_lots').innerHTML = ''; let unsure = 0;
    for (const l of e.lots || []) {
      let pick = '', q = '', how = l.how;
      if (l.lot_code && targets.some(t => t.ca_lot_code === l.lot_code)) pick = l.lot_code;
      else if (l.lot_date) {
        const same = [...new Set(targets.filter(t => t.lot_date === l.lot_date).map(t => t.ca_lot_code))];
        if (same.length === 1) pick = same[0];
        else { unsure++; q = l.lot_date.slice(2).replace(/-/g, ''); how += same.length ? ` · 그날 CA LOT ${same.length}개 중 고르세요` : ' · 그날 최종검사 받은 CA LOT 없음 → 직접 고르세요' }
      } else unsure++;
      addLot({ mark: l.mark, pick, q, how, box: l.box_count, ea: l.qty_ea ?? (l.box_count != null ? l.box_count * EA_PER_BOX : '') });
    }
    if (!(e.lots || []).length) { addLot(); notes.push('비고에 LOT 표기 없음 → 모델·LOT 을 직접 고르세요') }
    if (unsure) notes.push(`LOT ${unsure}줄은 직접 골라야 합니다`);
    sumQty();
    setStatus('reinsp', 'AI 항목을 불러왔습니다 · ' + (notes.length ? notes.join(' · ') : '모델·LOT·본검사를 확인하고 저장하세요'), notes.length ? 'warn' : 'info');
  }

  // ---- 저장
  $('#r_save').onclick = () => {
    const lots = [...document.querySelectorAll('#r_lots tr')].map(tr => ({
      lot_code: tr.querySelector('.r_lot').value === '__UNRESOLVED' ? '' : tr.querySelector('.r_lot').value, lot_code_raw: tr.querySelector('.r_mark').value.trim().toUpperCase() || null,
      box_count: tr.querySelector('.r_box').value === '' ? null : +tr.querySelector('.r_box').value,
      qty_ea: tr.querySelector('.r_ea').value === '' ? null : +tr.querySelector('.r_ea').value, prior_run_id: tr.querySelector('.r_prior').value }));
    const findings = [...document.querySelectorAll('#r_defects tr')].map(tr => {
      const name = tr.querySelector('.r_dname').value.trim(), q = tr.querySelector('.r_dqty').value;
      return { defect_code: defectCode(name), name_raw: name || null, qty: q === '' ? null : +q };
    }).filter(f => f.name_raw || f.qty != null);
    const body = { model: $('#r_model').value, inspection_date: $('#r_date').value, method: $('#r_method').value,
      qty_ea: $('#r_qty').value === '' ? null : +$('#r_qty').value, raw_note: $('#r_note').value.trim(), lots, findings, replace: $('#r_replace').checked,
      source: img ? { image_sha256: img.sha256, ai_read: aiEntries.length > 0 } : { ai_read: false, typed: true } };
    const miss = [!body.model && '모델', !body.inspection_date && '재검일', !lots.length && '대상 LOT'].filter(Boolean);
    const badLot = lots.findIndex(l => (!l.lot_code && !l.lot_code_raw) || !l.prior_run_id || (!l.lot_code && [...document.querySelectorAll('#r_lots .r_lot')][lots.indexOf(l)].value !== '__UNRESOLVED'));
    if (miss.length) { setStatus('reinsp', miss.join('·') + ' 을(를) 넣으세요', 'warn'); return }
    if (badLot >= 0) { setStatus('reinsp', `대상 LOT ${badLot + 1}번째 줄: LOT 과 본검사를 고르세요(LOT 이 DB 에 없으면 'LOT 없음 — 원문 마킹만', 이때 원문 마킹 필수)`, 'warn'); return }
    if (findings.some(f => f.qty == null || !f.name_raw)) { setStatus('reinsp', '불량 줄은 이름과 수량을 모두 넣거나 빼 주세요', 'warn'); return }
    job('reinsp', '재검 저장', async () => {
      const r = await api('/api/reinspection', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      loadList();
      return `저장됨 · ${body.model} ${body.inspection_date} · 대상 LOT ${r.lots}개 · 본검사 연결 ${r.prior_links}건 · 불량 ${r.findings}줄${r.replaced ? ' · 이전 기록 VOID ' + r.replaced.length + '건' : ''}`;
    }, { buttons: ['#r_save'] }).catch(() => {});
  };

  // ---- 입력된 재검 목록 · 삭제(VOID)
  async function loadList() {
    const m = $('#r_listModel').value; let rows = [];
    try { rows = await api('/api/reinspections?limit=2000' + (m ? '&model=' + m : '')) } catch (e) { $('#r_list').innerHTML = '<div class="err">' + esc(e.message) + '</div>'; return }
    m13List.show('reinsp', $('#r_list'), rows, { dateKey: 'inspection_date', timeKey: 'recorded_at', dateLabel: '재검일', empty: '입력된 재검사가 없습니다.',
      head: `<th>재검일</th><th>모델</th><th>대상 LOT</th><th>본검사</th><th>방법</th><th>재검 수량</th><th>불량</th><th>비고 원문</th><th>입력</th><th></th>`, row: r => `<tr>
      <td>${esc(r.inspection_date)}</td><td>${esc(r.model_code)}</td>
      <td style="text-align:left">${(r.lots || []).map(l => `${esc(l.lot_code_raw || '')}${l.ca_lot_code ? ' → ' + esc(l.ca_lot_code) : ' (미연결)'}`).join('<br>') || '—'}</td>
      <td>${(r.prior_runs || []).map(p => `${esc(p.prior_date)} ${p.prior_qty_ea ?? ''}EA`).join('<br>') || '<span class="warn">연결 없음</span>'}</td>
      <td>${esc(METHOD[r.inspection_method] || r.inspection_method || '')}</td><td>${r.inspected_qty_ea != null ? r.inspected_qty_ea.toLocaleString() : '—'}</td>
      <td>${(r.findings || []).map(f => esc(f.defect) + ' ' + (f.qty ?? '?')).join('<br>') || '<span class="warn">없음</span>'}</td>
      <td style="text-align:left"><small>${esc(r.raw_note || '')}</small></td>
      <td><small class="muted">${r.dataset ? '판독 적재' : r.source?.ai_read ? '캡처+AI' : '화면 입력'}</small></td>
      <td><button class="ghost small" type="button" data-void="${esc(r.run_id)}">삭제</button></td></tr>`, after: box => bindVoid(box) });
    function bindVoid(box) {
    box.querySelectorAll('[data-void]').forEach(b => b.onclick = () => {
      const note = prompt('삭제(VOID) 사유를 5자 이상 적어 주세요 (예: 같은 재검 중복 입력, LOT 잘못 고름)\n행은 지우지 않고 무효 처리되어 CRUD 이력에 남습니다.');
      if (note === null) return;
      job('reinsp', '재검 삭제', async () => {
        const r = await api('/api/reinspection/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run_id: b.dataset.void, note }) });
        loadList(); return `삭제(VOID) 완료 · 함께 무효 처리된 행 ${r.voided_rows}개(재검·대상 LOT·본검사 연결·불량)`;
      }).catch(() => {});
    });
    }
  }

  // ---- 시작
  $('#r_model').onchange = loadTargets;
  $('#r_addLot').onclick = () => addLot();
  $('#r_allPrior').onclick = () => { document.querySelectorAll('#r_lots tr').forEach(setAll); setStatus('reinsp', '본검사가 여러 건인 LOT 은 "본검사 전부"로 바꿨습니다(재검일 이전 최종검사만 연결)', 'info') }; $('#r_addDefect').onclick = () => addDefect();
  $('#r_listGo').onclick = loadList; $('#r_listModel').onchange = loadList;
  addLot(); addDefect();
  // 재검사는 ⑦ 최종검사 탭 안에 있다(2026-11-07 사용자: 최종검사 작업일보와 재검사를 한 탭에서). 탭을 열면 불량 유형·목록을 불러온다.
  let opened = false;
  const onOpen = () => {
    if (!defects.length) api('/api/defect-types/final').then(d => { defects = d; $('#r_dlist').innerHTML = [...new Set(d.map(x => x.defect_name))].map(n => `<option value="${esc(n)}">`).join('');
      document.querySelectorAll('#r_defects .r_dname').forEach(i => i.dispatchEvent(new Event('input'))) }).catch(() => {});
    loadList(); opened = true;
  };
  document.querySelector('#tabs [data-kind="FINAL_INSPECTION"]')?.addEventListener('click', onOpen);
  setTimeout(() => { if (!opened && document.querySelector('#v-reinsp')?.classList.contains('on')) onOpen() }, 500);   // ?tab=final(또는 reinsp) 로 열린 경우
})();
