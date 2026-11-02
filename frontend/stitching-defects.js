/* Display-only, process-scoped names. Original database names and quantities stay intact. */
(function (root) {
  'use strict';
  const normalize = name => String(name).toLowerCase().replace(/[\s_-]/g, '');
  const map = groups => new Map(groups.flatMap(([label, aliases]) => aliases.map(name => [normalize(name), label])));
  const names = new Map([
    ...['위치도', 'location', 'position', '위치', '위치도불량', 'OV 위치도'].map(n => [n, '위치도 불량']),
    ...['전장', 'electrical', '단자', 'length', '전장불량', 'terminal'].map(n => [n, '전장 불량'])
  ]);
  const processNames = {
    // Injection keeps original names while sharing NULL counts and source details.
    IMEB3_INJECTION: new Map(),
    IMEB3_STITCHING: new Map([...names].map(([name, label]) => [normalize(name), label])),
    IMEB3_WINDING: map([
      ['용접 불량', ['용접', '용접불량', 'weld', 'welding', 'weld_ng']],
      ['비전 1차 불량', ['비전1차', '비전1차(미용접,이탈,여선)', 'vision1', 'vision1_ng', 'BA_vision1']],
      ['비전 2차 불량', ['비전2차', '비전2차(권선정열,Post파손)', 'vision2', 'vision2_ng', 'BA_vision2']],
      ['비전 3차 불량', ['비전3차', '비전3차(와이어데미지)', 'vision3', 'vision3_ng']],
      ['셋업 불량', ['setup', 'setup불량', 'Set Up 불량', 'setup_ng', 'SET_UP', 'SET-UP']],
      ['와이어 끊어짐', ['Wire 끊어짐', 'wire_break', 'wire_break_ng']]
    ]),
    IMEB3_CA_PRESS: map([
      ['깊이 불량', ['깊이', '깊이불량', 'depth']],
      ['저항 불량', ['저항', '저항불량', 'resistance', 'CA_resistance']],
      ['내전압 불량', ['내전압', '내전압불량', 'voltage', 'dielectric', 'withstand_voltage']],
      ['내경 불량', ['내경불량', 'CA_inner_diameter']],
      ['하부 케이스 혼입 불량', ['lower_case_mix']]
      // Candidate labels and BA_* records in CA are deliberately not assigned a new meaning.
    ]),
    IMEB3_FINAL_INSPECTION: map([
      ['마킹 불량', ['marking', 'Marking 불량']],
      ['보빈 파손', ['Bobbin 파손', 'bobbin_break', 'bobbin_파손']],
      ['포스트 파손', ['Post 파손', 'post_break', 'post_파손']],
      ['와이어 손상', ['Wire Damage', 'wire_damage']],
      ['와이어 늘어짐', ['Wire 늘어짐', 'wire_stretch', '와이어늘어짐']],
      ['와이어 이탈', ['Wire 이탈', '와이어 이탈']],
      // Printed source forms say Lead Pin 휨; some OCR keys incorrectly say 뜸.
      ['리드핀 휨', ['Lead Pin 뜸', 'LeadPin뜸', 'lead_pin_뜸', 'lead_pin_bend', 'lead_pin_bent', 'Lead Pin 휨']],
      ['리드핀 찍힘', ['Lead Pin 찍힘', 'lead_pin_dent']],
      ['리드핀 도금 불량', ['Lead Pin 도금']],
      ['핀 찍힘', ['Pin 찍힘', 'pin_nick', 'pin_press']],
      ['핀 도금 불량', ['Pin 도금']],
      ['상부 케이스 찍힘', ['U/C 찍힘', 'u_c_찍힘', 'upper_case_nick', 'upper_case_dent', 'upper_case_press']],
      ['하부 케이스 찍힘', ['L/C 찍힘', 'l_c_찍힘', 'lower_case_nick', 'lower_case_dent', 'lower_case_press']],
      ['상부 케이스 도금 불량', ['U/C 도금', 'upper_case_plating']],
      ['하부 케이스 도금 불량', ['L/C 도금', 'lower_case_plating']],
      ['내경 파손', ['내경파손', 'inner_bore_break']],
      ['미압입 불량', ['미압입', 'not_inserted', 'missing_press', 'misinsert']],
      ['보빈 미성형', ['Bobbin 미성형', '보빈 미성형', 'bobbin_unformed']],
      ['포스트 미성형', ['Post 미성형', '포스트미성형', 'post_unformed', 'post_immature']],
      ['여선 불량', ['여선불량', '여선', 'yeseon']],
      ['보빈 이물', ['보빈 이물', 'bobbin_foreign_matter']],
      ['보빈 가스', ['bobbin_gas']],
      ['포스트 가스', ['Post 가스']]
    ])
  };
  function supported(process) { return Object.hasOwn(processNames, process); }
  function displayName(process, name) { return processNames[process]?.get(normalize(name)) || name; }
  function group(process, rows, quantityStatus) {
    if (!supported(process)) return rows;
    const nulls = quantityStatus == null ? null : new Map(quantityStatus.map(r => [r.defect_name, r.null_findings]));
    const groups = new Map();
    for (const row of rows) {
      const name = displayName(process, row.defect_name);
      if (!groups.has(name)) groups.set(name, {defect_name: name, qty: 0, findings: 0, null_findings: nulls ? 0 : null, originals: []});
      const g = groups.get(name);
      const original = {...row, null_findings: nulls ? (nulls.get(row.defect_name) || 0) : null};
      g.qty += row.qty;
      g.findings += row.findings;
      if (nulls) g.null_findings += original.null_findings;
      g.originals.push(original);
    }
    return [...groups.values()].sort((a, b) => b.qty - a.qty || a.defect_name.localeCompare(b.defect_name, 'ko'));
  }
  const exports = {group, supported, displayName};
  root.StitchingDefects = exports;
  if (typeof module !== 'undefined' && module.exports) module.exports = exports;
})(globalThis);
