import { supabase } from './supabaseClient.js';

// สีประจำระบบ (ตรงกับ css/style.css)
const C = { ink: '#17221f', muted: '#5b6b66', rule: '#d6deda', air: '#2f67d8', rail: '#2f9a52', bus: '#e0a116' };
const fmt = (n, d = 0) => Number(n ?? 0).toLocaleString('th-TH', { minimumFractionDigits: d, maximumFractionDigits: d });

Chart.defaults.font.family = getComputedStyle(document.body).fontFamily;
Chart.defaults.color = C.muted;

let loaded = false;

export async function initDashboard(profile) {
  if (loaded) return;
  loaded = true;

  if (profile?.role === 'passenger') {
    document.getElementById('dash-scope').textContent =
      'แสดงเฉพาะข้อมูลการเดินทางจากบัตรของคุณ';
  }

  await Promise.all([loadDaily(), loadStations(), loadCardTypes()]);
}

function errorBox(id, error) {
  document.getElementById(id).outerHTML =
    `<p class="notice error">โหลดข้อมูลไม่สำเร็จ: ${error.message}</p>`;
}

// ---------- 1. รายได้รายวัน (v_daily_rail_revenue) ----------
async function loadDaily() {
  const { data, error } = await supabase
    .from('v_daily_rail_revenue')
    .select('trip_date, total_trips, revenue')
    .order('trip_date');
  if (error) return errorBox('chart-daily', error);

  const total = data.reduce((s, r) => s + Number(r.revenue), 0);
  const trips = data.reduce((s, r) => s + Number(r.total_trips), 0);
  document.getElementById('daily-summary').textContent =
    `รวม ${fmt(total)} บาท จาก ${fmt(trips)} เที่ยว ใน ${data.length} วัน`;

  new Chart(document.getElementById('chart-daily'), {
    type: 'line',
    data: {
      labels: data.map((r) => new Date(r.trip_date).toLocaleDateString('th-TH', { day: 'numeric', month: 'short' })),
      datasets: [{
        label: 'รายได้ (บาท)',
        data: data.map((r) => Number(r.revenue)),
        borderColor: C.rail,
        backgroundColor: 'rgba(47,154,82,0.12)',
        fill: true,
        tension: 0.15,
        pointRadius: 2,
      }],
    },
    options: {
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: { y: { beginAtZero: true, grid: { color: C.rule } }, x: { grid: { display: false } } },
    },
  });
}

// ---------- 2. 10 สถานีที่มีผู้แตะบัตรเข้ามากที่สุด (v_station_ridership) ----------
async function loadStations() {
  const { data, error } = await supabase
    .from('v_station_ridership')
    .select('station_name, entries, exits')
    .order('entries', { ascending: false })
    .limit(10);
  if (error) return errorBox('chart-stations', error);

  new Chart(document.getElementById('chart-stations'), {
    type: 'bar',
    data: {
      labels: data.map((r) => r.station_name),
      datasets: [
        { label: 'แตะเข้า', data: data.map((r) => r.entries), backgroundColor: C.rail },
        { label: 'แตะออก', data: data.map((r) => r.exits), backgroundColor: C.air },
      ],
    },
    options: {
      indexAxis: 'y',
      maintainAspectRatio: false,
      plugins: { legend: { position: 'bottom' } },
      scales: { x: { beginAtZero: true, grid: { color: C.rule } }, y: { grid: { display: false } } },
    },
  });
}

// ---------- 3. สถิติตามประเภทบัตร (v_card_type_stats) ----------
async function loadCardTypes() {
  const { data, error } = await supabase
    .from('v_card_type_stats')
    .select('*')
    .order('total_fare', { ascending: false });
  if (error) return errorBox('chart-cardtypes', error);

  new Chart(document.getElementById('chart-cardtypes'), {
    type: 'bar',
    data: {
      labels: data.map((r) => r.card_type),
      datasets: [{
        label: 'ค่าโดยสารรวม (บาท)',
        data: data.map((r) => Number(r.total_fare)),
        backgroundColor: [C.rail, C.air, C.bus],
      }],
    },
    options: {
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: { y: { beginAtZero: true, grid: { color: C.rule } }, x: { grid: { display: false } } },
    },
  });

  document.getElementById('cardtype-table').innerHTML = `
    <table>
      <thead><tr>
        <th>ประเภทบัตร</th><th class="num">ส่วนลด</th><th class="num">จำนวนบัตร</th>
        <th class="num">เที่ยว</th><th class="num">ค่าโดยสารเฉลี่ย</th><th class="num">ยอดคงเหลือเฉลี่ย</th>
      </tr></thead>
      <tbody>${data.map((r) => `
        <tr>
          <td>${r.card_type}</td>
          <td class="num">${fmt(r.discount_rate * 100)}%</td>
          <td class="num">${fmt(r.total_cards)}</td>
          <td class="num">${fmt(r.total_trips)}</td>
          <td class="num">${fmt(r.avg_fare, 2)}</td>
          <td class="num">${fmt(r.avg_balance, 2)}</td>
        </tr>`).join('')}
      </tbody>
    </table>`;
}
