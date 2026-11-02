/* Display-only stitching names. Original database names and quantities are preserved. */
(function (root) {
  'use strict';
  const names = new Map([
    ...['위치도', 'location', 'position', '위치', '위치도불량', 'OV 위치도'].map(n => [n, '위치도 불량']),
    ...['전장', 'electrical', '단자', 'length', '전장불량', 'terminal'].map(n => [n, '전장 불량'])
  ]);
  function group(process, rows, quantityStatus) {
    if (process !== 'IMEB3_STITCHING') return rows;
    const nulls = quantityStatus == null ? null : new Map(quantityStatus.map(r => [r.defect_name, r.null_findings]));
    const groups = new Map();
    for (const row of rows) {
      const name = names.get(row.defect_name) || row.defect_name;
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
  const exports = {group};
  root.StitchingDefects = exports;
  if (typeof module !== 'undefined' && module.exports) module.exports = exports;
})(globalThis);
