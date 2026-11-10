import { supabase } from './supabaseClient.js';

// สีประจำโหมด (ตรงกับ css/style.css)
const C = {
  ink: '#17221f', muted: '#5b6b66', rule: '#e3e9e6',
  rail: '#2f9a52', air: '#2f67d8', bus: '#e0a116',
  railSoft: 'rgba(47,154,82,0.14)', airSoft: 'rgba(47,103,216,0.14)', busSoft: 'rgba(224,161,22,0.18)',
};
const MODES = ['rail', 'air', 'bus'];
const STORE_KEY = 'maas-dashboard-modes';

const $ = (id) => document.getElementById(id);
const fmt = (n, d = 0) => Number(n ?? 0).toLocaleString('th-TH', { minimumFractionDigits: d, maximumFractionDigits: d });
const sum = (rows, k) => rows.reduce((s, r) => s + Number(r[k] ?? 0), 0);

Chart.defaults.font.family = getComputedStyle(document.body).fontFamily;
Chart.defaults.color = C.muted;
Chart.defaults.plugins.legend.labels.usePointStyle = true;
Chart.defaults.plugins.tooltip.padding = 10;
Chart.defaults.plugins.tooltip.cornerRadius = 8;

const charts = { rail: [], air: [], bus: [] };   // เก็บกราฟไว้ resize ตอนเปิดกลับมา
const loaded = { rail: false, air: false, bus: false };
let started = false;

// ---------- เริ่มต้นหน้า ----------
export async function initDashboard(profile) {
  if (started) return;
  started = true;

  if (profile?.role === 'passenger') {
    $('dash-scope').textContent = 'แสดงเฉพาะข้อมูลการเดินทางของคุณ · เลือกโหมดการเดินทางที่ต้องการดู';
  }

  // คืนค่าที่ผู้ใช้เลือกไว้ครั้งก่อน
  let saved = null;
  try { saved = JSON.parse(localStorage.getItem(STORE_KEY)); } catch { /* ไม่มีค่าเดิม */ }
  document.querySelectorAll('.mode-card input').forEach((cb) => {
    if (Array.isArray(saved)) cb.checked = saved.includes(cb.value);
    cb.addEventListener('change', applySelection);
  });

  loadTotals();
  applySelection();
}

// ---------- แสดง/ซ่อนตามการติกเลือก ----------
function applySelection() {
  const chosen = [...document.querySelectorAll('.mode-card input:checked')].map((cb) => cb.value);
  try { localStorage.setItem(STORE_KEY, JSON.stringify(chosen)); } catch { /* ไม่บันทึกก็ได้ */ }

  MODES.forEach((m) => {
    const on = chosen.includes(m);
    $('dash-' + m).classList.toggle('hidden', !on);
    if (on && !loaded[m]) { loaded[m] = true; LOADERS[m](); }
    if (on) charts[m].forEach((c) => c.resize());
  });
  $('dash-empty').classList.toggle('hidden', chosen.length > 0);
}

// ---------- ยอดรวมบนการ์ดเลือกโหมด ----------
async function loadTotals() {
  const { data, error } = await supabase.from('v_payment_summary').select('service_type, transactions, total_amount');
  if (error) return;
  const map = { RAIL_TOPUP: 'rail', FLIGHT: 'air', BUS: 'bus' };
  const label = { rail: 'ครั้งเติมเงิน', air: 'การจอง', bus: 'ครั้งขึ้นรถ' };
  MODES.forEach((m) => {
    const rows = data.filter((r) => map[r.service_type] === m);
    $('total-' + m).textContent = fmt(sum(rows, 'total_amount')) + ' ฿';
    $('sub-' + m).textContent = `ชำระแล้ว ${fmt(sum(rows, 'transactions'))} ${label[m]}`;
  });
}

// ---------- ส่วนช่วย ----------
function kpis(id, items) {
  $(id).innerHTML = items.map((k) => `
    <div class="kpi">
      <span class="kpi-label">${k.label}</span>
      <span class="kpi-value">${k.value}</span>
      ${k.note ? `<span class="kpi-note">${k.note}</span>` : ''}
    </div>`).join('');
}

function showError(canvasId, error) {
  $(canvasId).closest('.chart-box').innerHTML = `<p class="notice error">โหลดข้อมูลไม่สำเร็จ: ${error.message}</p>`;
}

function make(mode, canvasId, config) {
  const chart = new Chart($(canvasId), config);
  charts[mode].push(chart);
  return chart;
}

const axisY = { beginAtZero: true, grid: { color: C.rule }, border: { display: false } };
const axisX = { grid: { display: false }, border: { display: false } };

// =========================================================
// รถไฟฟ้า BTS
// =========================================================
async function loadRail() {
  const [daily, stations, types] = await Promise.all([
    supabase.from('v_daily_rail_revenue').select('trip_date, total_trips, unique_cards, revenue, avg_fare').order('trip_date'),
    supabase.from('v_station_ridership').select('station_name, entries, exits').order('entries', { ascending: false }).limit(10),
    supabase.from('v_card_type_stats').select('*').order('total_fare', { ascending: false }),
  ]);

  if (!daily.error) {
    const d = daily.data;
    const trips = sum(d, 'total_trips'), revenue = sum(d, 'revenue');
    const best = d.reduce((a, b) => (Number(b.revenue) > Number(a?.revenue ?? -1) ? b : a), null);
    kpis('kpi-rail', [
      { label: 'จำนวนเที่ยว', value: fmt(trips), note: `${d.length} วัน` },
      { label: 'รายได้ค่าโดยสาร', value: fmt(revenue) + ' ฿' },
      { label: 'ค่าโดยสารเฉลี่ย', value: fmt(trips ? revenue / trips : 0, 2) + ' ฿', note: 'ต่อเที่ยว' },
      { label: 'วันรายได้สูงสุด', value: best ? new Date(best.trip_date).toLocaleDateString('th-TH', { day: 'numeric', month: 'short' }) : '–', note: best ? fmt(best.revenue) + ' ฿' : '' },
    ]);
    make('rail', 'chart-daily', {
      type: 'line',
      data: {
        labels: d.map((r) => new Date(r.trip_date).toLocaleDateString('th-TH', { day: 'numeric', month: 'short' })),
        datasets: [{ label: 'รายได้ (บาท)', data: d.map((r) => Number(r.revenue)), borderColor: C.rail,
          backgroundColor: C.railSoft, fill: true, tension: 0.3, pointRadius: 0, pointHoverRadius: 5, borderWidth: 2 }],
      },
      options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
        plugins: { legend: { display: false } }, scales: { y: axisY, x: { ...axisX, ticks: { maxTicksLimit: 10 } } } },
    });
  } else showError('chart-daily', daily.error);

  if (!stations.error) {
    make('rail', 'chart-stations', {
      type: 'bar',
      data: {
        labels: stations.data.map((r) => r.station_name),
        datasets: [
          { label: 'แตะเข้า', data: stations.data.map((r) => r.entries), backgroundColor: C.rail, borderRadius: 6 },
          { label: 'แตะออก', data: stations.data.map((r) => r.exits), backgroundColor: C.railSoft, borderRadius: 6 },
        ],
      },
      options: { indexAxis: 'y', maintainAspectRatio: false, plugins: { legend: { position: 'bottom' } },
        scales: { x: axisY, y: axisX } },
    });
  } else showError('chart-stations', stations.error);

  if (!types.error) {
    const t = types.data;
    make('rail', 'chart-cardtypes', {
      type: 'bar',
      data: { labels: t.map((r) => r.card_type),
        datasets: [{ label: 'ค่าโดยสารรวม (บาท)', data: t.map((r) => Number(r.total_fare)),
          backgroundColor: [C.rail, '#5fb97b', '#9fd5b0'], borderRadius: 8 }] },
      options: { maintainAspectRatio: false, plugins: { legend: { display: false } }, scales: { y: axisY, x: axisX } },
    });
    $('cardtype-table').innerHTML = `<table>
      <thead><tr><th>ประเภทบัตร</th><th class="num">ส่วนลด</th><th class="num">บัตร</th><th class="num">เที่ยว</th><th class="num">เฉลี่ย/เที่ยว</th></tr></thead>
      <tbody>${t.map((r) => `<tr><td>${r.card_type}</td><td class="num">${fmt(r.discount_rate * 100)}%</td>
        <td class="num">${fmt(r.total_cards)}</td><td class="num">${fmt(r.total_trips)}</td><td class="num">${fmt(r.avg_fare, 2)} ฿</td></tr>`).join('')}</tbody>
    </table>`;
  } else showError('chart-cardtypes', types.error);
}

// =========================================================
// สายการบิน
// =========================================================
async function loadAir() {
  const [routes, flights, tickets] = await Promise.all([
    supabase.from('v_route_revenue').select('*').order('revenue', { ascending: false }),
    supabase.from('v_flight_occupancy').select('flight_status, seats_sold'),
    supabase.from('v_flight_bookings').select('travel_class, price, booking_status').eq('booking_status', 'CONFIRMED'),
  ]);

  if (!routes.error && !flights.error) {
    const r = routes.data, f = flights.data;
    const sold = sum(r, 'tickets_sold'), revenue = sum(r, 'revenue');
    const cancelled = f.filter((x) => x.flight_status === 'CANCELLED').length;
    kpis('kpi-air', [
      { label: 'เที่ยวบิน', value: fmt(f.length), note: `ยกเลิก ${cancelled} เที่ยว` },
      { label: 'ตั๋วที่ขายได้', value: fmt(sold), note: 'เฉพาะการจองที่ยืนยัน' },
      { label: 'รายได้', value: fmt(revenue) + ' ฿' },
      { label: 'ราคาตั๋วเฉลี่ย', value: fmt(sold ? revenue / sold : 0) + ' ฿' },
    ]);
    make('air', 'chart-routes', {
      type: 'bar',
      data: { labels: r.map((x) => x.route.replace('-', ' → ')),
        datasets: [{ label: 'รายได้ (บาท)', data: r.map((x) => Number(x.revenue)), backgroundColor: C.air, borderRadius: 6 }] },
      options: { indexAxis: 'y', maintainAspectRatio: false, plugins: { legend: { display: false } },
        scales: { x: axisY, y: axisX } },
    });
  } else showError('chart-routes', routes.error || flights.error);

  if (!tickets.error) {
    const byClass = (c) => tickets.data.filter((t) => t.travel_class === c);
    make('air', 'chart-class', {
      type: 'doughnut',
      data: { labels: ['ชั้นประหยัด', 'ชั้นธุรกิจ'],
        datasets: [{ data: [sum(byClass('ECONOMY'), 'price'), sum(byClass('BUSINESS'), 'price')],
          backgroundColor: [C.air, '#9bb8ef'], borderWidth: 0, hoverOffset: 6 }] },
      options: { maintainAspectRatio: false, cutout: '62%',
        plugins: { legend: { position: 'bottom' },
          tooltip: { callbacks: { label: (ctx) => {
            const all = ctx.dataset.data.reduce((a, b) => a + b, 0);
            return ` ${ctx.label}: ${fmt(ctx.raw)} ฿ (${fmt(all ? (100 * ctx.raw) / all : 0, 1)}%)`;
          } } } } },
    });
  } else showError('chart-class', tickets.error);
}

// =========================================================
// รถเมล์
// =========================================================
async function loadBus() {
  const [routes, rides] = await Promise.all([
    supabase.from('v_route_ridership').select('*'),
    supabase.from('v_bus_ride_details').select('ride_hour'),
  ]);

  if (!routes.error) {
    const r = [...routes.data].sort((a, b) => Number(a.route_no) - Number(b.route_no));   // เรียงเลขสาย 2, 15, 29, ...
    const planned = sum(r, 'scheduled_trips'), done = sum(r, 'completed_trips');
    const delayRows = r.filter((x) => x.avg_delay_min !== null);
    kpis('kpi-bus', [
      { label: 'รอบวิ่ง', value: fmt(done), note: `จากแผน ${fmt(planned)} รอบ` },
      { label: 'ผู้โดยสาร', value: fmt(sum(r, 'passengers')) },
      { label: 'รายได้', value: fmt(sum(r, 'revenue')) + ' ฿' },
      { label: 'ออกช้าเฉลี่ย', value: fmt(delayRows.length ? sum(delayRows, 'avg_delay_min') / delayRows.length : 0, 1) + ' นาที' },
    ]);
    make('bus', 'chart-busroutes', {
      data: { labels: r.map((x) => `สาย ${x.route_no}`),
        datasets: [
          { type: 'bar', label: 'ผู้โดยสาร (คน)', data: r.map((x) => x.passengers), backgroundColor: C.bus, borderRadius: 6, yAxisID: 'y' },
          { type: 'line', label: 'ออกช้าเฉลี่ย (นาที)', data: r.map((x) => Number(x.avg_delay_min)), borderColor: C.ink,
            backgroundColor: C.ink, pointRadius: 4, tension: 0.3, yAxisID: 'y2' },
        ] },
      options: { maintainAspectRatio: false, interaction: { mode: 'index', intersect: false },
        plugins: { legend: { position: 'bottom' } },
        scales: { y: axisY, y2: { ...axisY, position: 'right', grid: { display: false } }, x: axisX } },
    });
  } else showError('chart-busroutes', routes.error);

  if (!rides.error) {
    const counts = Array.from({ length: 24 }, (_, h) => rides.data.filter((x) => x.ride_hour === h).length);
    const first = counts.findIndex((c) => c > 0), last = 23 - [...counts].reverse().findIndex((c) => c > 0);
    const hours = first < 0 ? [] : counts.slice(first, last + 1).map((c, i) => ({ h: first + i, c }));
    const peak = Math.max(...hours.map((x) => x.c), 0);
    make('bus', 'chart-bushours', {
      type: 'bar',
      data: { labels: hours.map((x) => `${String(x.h).padStart(2, '0')}:00`),
        datasets: [{ label: 'ครั้งที่ขึ้นรถ', data: hours.map((x) => x.c),
          backgroundColor: hours.map((x) => (x.c === peak ? C.bus : C.busSoft)), borderRadius: 6 }] },
      options: { maintainAspectRatio: false, plugins: { legend: { display: false } }, scales: { y: axisY, x: axisX } },
    });
  } else showError('chart-bushours', rides.error);
}

const LOADERS = { rail: loadRail, air: loadAir, bus: loadBus };
