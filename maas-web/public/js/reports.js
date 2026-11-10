import { supabase } from './supabaseClient.js';

// รายการ View ที่แสดงในหน้ารายงาน (เพื่อนเพิ่ม View ของตัวเองต่อท้ายได้)
const VIEWS = [
  { name: 'v_trip_details',       label: 'รายละเอียดการเดินทาง',        order: 'entry_time', asc: false },
  { name: 'v_station_ridership',  label: 'ผู้โดยสารแต่ละสถานี',          order: 'entries',    asc: false },
  { name: 'v_daily_rail_revenue', label: 'รายได้รถไฟฟ้ารายวัน',          order: 'trip_date',  asc: false },
  { name: 'v_card_type_stats',    label: 'สถิติตามประเภทบัตร',           order: 'total_fare', asc: false },
  { name: 'v_problem_trips',      label: 'เที่ยวที่มีปัญหา',              order: 'entry_time', asc: false },
];
const MAX_ROWS = 500;

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

let rows = [];
let loaded = false;

export function initReports() {
  if (loaded) return;
  loaded = true;

  $('report-view').innerHTML = VIEWS
    .map((v) => `<option value="${v.name}">${v.label} (${v.name})</option>`)
    .join('');
  $('report-view').addEventListener('change', loadView);
  $('report-search').addEventListener('input', render);
  loadView();
}

async function loadView() {
  const v = VIEWS.find((x) => x.name === $('report-view').value);
  $('report-search').value = '';
  $('report-table').innerHTML = '<p class="empty">กำลังโหลด…</p>';

  const { data, error } = await supabase
    .from(v.name)
    .select('*')
    .order(v.order, { ascending: v.asc })
    .limit(MAX_ROWS);

  if (error) {
    $('report-table').innerHTML = `<p class="notice error">โหลด ${esc(v.name)} ไม่สำเร็จ: ${esc(error.message)}</p>`;
    $('report-count').textContent = '';
    return;
  }
  rows = data;
  render();
}

// แปลงค่าให้อ่านง่าย: เวลาเป็นเวลาไทย, ตัวเลขใส่จุลภาค
function show(val) {
  if (val === null || val === undefined) return '<span class="empty">–</span>';
  if (typeof val === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(val)) {
    return esc(new Date(val).toLocaleString('th-TH', { dateStyle: 'short', timeStyle: 'short', timeZone: 'Asia/Bangkok' }));
  }
  return esc(val);
}

function render() {
  const q = $('report-search').value.trim().toLowerCase();
  const shown = q
    ? rows.filter((r) => Object.values(r).some((v) => String(v ?? '').toLowerCase().includes(q)))
    : rows;

  $('report-count').textContent =
    `${shown.length.toLocaleString('th-TH')} จาก ${rows.length.toLocaleString('th-TH')} แถว` +
    (rows.length === MAX_ROWS ? ` (แสดงสูงสุด ${MAX_ROWS} แถว)` : '');

  if (!shown.length) {
    $('report-table').innerHTML = `<p class="empty">${rows.length ? 'ไม่พบข้อมูลที่ตรงกับคำค้น' : 'View นี้ยังไม่มีข้อมูลที่คุณมีสิทธิ์เห็น'}</p>`;
    return;
  }
  const cols = Object.keys(shown[0]);
  $('report-table').innerHTML = `
    <div class="table-wrap"><table>
      <thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
      <tbody>${shown.map((r) =>
        `<tr>${cols.map((c) => `<td${typeof r[c] === 'number' ? ' class="num"' : ''}>${show(r[c])}</td>`).join('')}</tr>`
      ).join('')}</tbody>
    </table></div>`;
}
