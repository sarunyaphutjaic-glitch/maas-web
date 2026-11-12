import { supabase } from './supabaseClient.js';

// =========================================================
// การจองของฉัน: ประวัติการจองตั๋วเครื่องบิน (รวมตั๋วเป็นรายการจอง)
// ข้อมูลจาก v_flight_bookings · RLS ให้ผู้โดยสารเห็นเฉพาะของตัวเอง ผู้ดูแลเห็นทั้งหมด
// =========================================================
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const th = (ts, opt) => new Date(ts).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', ...opt });
const baht = (n) => Number(n).toLocaleString('th-TH') + ' ฿';
const CLASS_TH = { ECONOMY: 'ชั้นประหยัด', BUSINESS: 'ชั้นธุรกิจ' };
const PAY_TH = { CREDIT_CARD: 'บัตรเครดิต', QR: 'QR พร้อมเพย์', MOBILE_BANKING: 'Mobile Banking' };

let bookings = [];
let filter = 'upcoming';
let scope = 'mine';
let me = null;
let started = false;

export async function initBookings(profile) {
  me = profile;
  if (!started) {
    started = true;
    document.querySelectorAll('#bk-filter button').forEach((b) => b.addEventListener('click', () => {
      filter = b.dataset.filter;
      document.querySelectorAll('#bk-filter button').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
      render();
    }));
    $('bk-search').addEventListener('input', render);
    if (me?.role === 'admin' || me?.role === 'staff') {
      $('bk-scope').classList.remove('hidden');
      $('bk-scope').addEventListener('change', (e) => { scope = e.target.value; render(); });
    }
  }
  await load();
}

// เรียกจากหน้าอื่นหลังจองสำเร็จ เพื่อให้เห็นรายการล่าสุด
export function refreshBookings() { if (started) load(); }

async function load() {
  $('bk-list').innerHTML = '<p class="empty">กำลังโหลด…</p>';
  const { data, error } = await supabase.from('v_flight_bookings').select('*').order('departure_time', { ascending: false });
  if (error) { $('bk-list').innerHTML = `<p class="notice error">${esc(error.message)}</p>`; return; }

  // รวมตั๋วหลายใบเป็น 1 การจอง
  const map = new Map();
  data.forEach((t) => {
    if (!map.has(t.booking_ref)) {
      map.set(t.booking_ref, {
        ref: t.booking_ref, user_id: t.user_id, booker: t.booker_name, flight_no: t.flight_no,
        origin: t.origin_code, origin_city: t.origin_city, destination: t.destination_code, destination_city: t.destination_city,
        departure: t.departure_time, status: t.booking_status, flight_status: t.flight_status,
        payment: t.payment_method, tickets: [],
      });
    }
    map.get(t.booking_ref).tickets.push(t);
  });
  bookings = [...map.values()];
  render();
}

function state(b) {
  if (b.status === 'CANCELLED') return 'cancelled';
  if (b.flight_status === 'CANCELLED') return 'cancelled';
  return new Date(b.departure) > new Date() ? 'upcoming' : 'past';
}

function render() {
  const q = $('bk-search').value.trim().toLowerCase();
  const mine = bookings.filter((b) => scope === 'all' || b.user_id === me?.user_id);
  const counts = { upcoming: 0, past: 0, cancelled: 0 };
  mine.forEach((b) => { counts[state(b)]++; });
  const spent = mine.filter((b) => b.status === 'CONFIRMED').reduce((s, b) => s + b.tickets.reduce((x, t) => x + Number(t.price), 0), 0);

  $('bk-kpis').innerHTML = `
    <div class="kpi"><span class="kpi-label">การจองทั้งหมด</span><span class="kpi-value">${mine.length}</span></div>
    <div class="kpi"><span class="kpi-label">กำลังจะเดินทาง</span><span class="kpi-value">${counts.upcoming}</span></div>
    <div class="kpi"><span class="kpi-label">เดินทางแล้ว</span><span class="kpi-value">${counts.past}</span></div>
    <div class="kpi"><span class="kpi-label">ยอดชำระรวม</span><span class="kpi-value">${baht(spent)}</span></div>`;
  document.querySelectorAll('#bk-filter button').forEach((b) => {
    const n = b.dataset.filter === 'all' ? mine.length : counts[b.dataset.filter];
    b.querySelector('span').textContent = n;
  });

  let list = mine.filter((b) => filter === 'all' || state(b) === filter);
  if (q) list = list.filter((b) => [b.ref, b.flight_no, b.origin, b.destination, b.origin_city, b.destination_city, b.booker,
    ...b.tickets.map((t) => t.passenger_name)].some((v) => String(v ?? '').toLowerCase().includes(q)));
  if (filter === 'upcoming') list.sort((a, b) => new Date(a.departure) - new Date(b.departure));

  $('bk-list').innerHTML = list.length ? list.map(card).join('') : `
    <div class="bk-empty">
      <p>ยังไม่มีการจองในหมวดนี้</p>
      <a class="btn" href="#agent">🤖 จองตั๋วกับผู้ช่วย</a>
    </div>`;
}

function card(b) {
  const st = state(b);
  const label = { upcoming: 'กำลังจะเดินทาง', past: 'เดินทางแล้ว', cancelled: 'ยกเลิก' }[st];
  const total = b.tickets.reduce((s, t) => s + Number(t.price), 0);
  return `
    <article class="bk-card bk-${st}">
      <div class="bk-left">
        <div class="bk-top"><span class="bk-flight">✈️ ${esc(b.flight_no)}</span><span class="bk-badge">${label}</span></div>
        <div class="bk-route"><strong>${esc(b.origin)}</strong><span>→</span><strong>${esc(b.destination)}</strong></div>
        <div class="bk-city">${esc(b.origin_city)} → ${esc(b.destination_city)}</div>
        <div class="bk-date">${th(b.departure, { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' })} · ${th(b.departure, { hour: '2-digit', minute: '2-digit' })} น.</div>
      </div>
      <div class="bk-right">
        <div class="bk-ref"><small>รหัสการจอง</small>${esc(b.ref)}</div>
        ${scope === 'all' ? `<div class="bk-booker">ผู้จอง: ${esc(b.booker)}</div>` : ''}
        <ul class="bk-pax">${b.tickets.map((t) => `<li>${esc(t.passenger_name)} <b>${esc(t.seat_no)}</b> <em>${CLASS_TH[t.travel_class] || esc(t.travel_class)}</em></li>`).join('')}</ul>
        <div class="bk-total"><span>${PAY_TH[b.payment] || esc(b.payment || '')}</span><strong>${baht(total)}</strong></div>
      </div>
    </article>`;
}
