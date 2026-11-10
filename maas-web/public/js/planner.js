import { supabase } from './supabaseClient.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const baht = (n) => Number(n).toLocaleString('th-TH', { maximumFractionDigits: 2 }) + ' ฿';
const time = (ts) => new Date(ts).toLocaleTimeString('th-TH', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Bangkok' });
const day = (ts) => new Date(ts).toLocaleDateString('th-TH', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Asia/Bangkok' });
const dur = (m) => (m >= 60 ? `${Math.floor(m / 60)} ชม. ${m % 60} นาที` : `${m} นาที`);

const LEG = {
  FLIGHT:   { icon: '✈️', cls: 'air',  name: 'เครื่องบิน' },
  TRANSFER: { icon: '🚄', cls: 'link', name: 'ต่อรถเข้าเมือง' },
  BTS:      { icon: '🚆', cls: 'rail', name: 'รถไฟฟ้า' },
  BUS:      { icon: '🚌', cls: 'bus',  name: 'รถเมล์' },
};

let loaded = false;

export async function initPlanner() {
  if (loaded) return;
  loaded = true;

  // เที่ยวบินที่ลงกรุงเทพ (สุวรรณภูมิ / ดอนเมือง) เท่านั้นที่ต่อ BTS / รถเมล์ได้
  const [flights, stations, stops] = await Promise.all([
    supabase.from('flights')
      .select('flight_id, flight_no, departure_time, status, origin:airports!fk_flights_origin(iata_code, city), dest:airports!fk_flights_destination(iata_code, city)')
      .neq('status', 'CANCELLED').order('departure_time'),
    supabase.from('stations').select('station_id, station_code, station_name').order('station_name'),
    supabase.from('bus_stops').select('stop_id, stop_code, stop_name').order('stop_name'),
  ]);
  if (flights.error || stations.error || stops.error) {
    $('plan-result').innerHTML = `<p class="notice error">โหลดข้อมูลไม่สำเร็จ: ${esc((flights.error || stations.error || stops.error).message)}</p>`;
    return;
  }

  const toBkk = flights.data.filter((f) => ['BKK', 'DMK'].includes(f.dest?.iata_code));
  $('plan-flight').innerHTML = toBkk.map((f) =>
    `<option value="${f.flight_id}">${esc(f.flight_no)} · ${esc(f.origin.city)} → ${esc(f.dest.iata_code === 'BKK' ? 'สุวรรณภูมิ' : 'ดอนเมือง')} · ${day(f.departure_time)} ${time(f.departure_time)}</option>`).join('');

  $('plan-dest').innerHTML = `
    <optgroup label="สถานีรถไฟฟ้า BTS">${stations.data.map((s) =>
      `<option value="STATION:${s.station_id}">${esc(s.station_name)} (${esc(s.station_code)})</option>`).join('')}</optgroup>
    <optgroup label="ป้ายรถเมล์ (ต่อ BTS + รถเมล์)">${stops.data.filter((s) => s.stop_code.startsWith('H')).map((s) =>
      `<option value="BUS_STOP:${s.stop_id}">${esc(s.stop_name)}</option>`).join('')}</optgroup>`;

  $('plan-form').addEventListener('submit', (e) => { e.preventDefault(); plan(); });
}

async function plan() {
  const [type, id] = $('plan-dest').value.split(':');
  const btn = $('plan-submit');
  btn.disabled = true;
  $('plan-result').innerHTML = '<p class="empty">กำลังคำนวณเส้นทาง…</p>';

  const { data, error } = await supabase.rpc('plan_trip', {
    p_flight_id: Number($('plan-flight').value),
    p_dest_type: type,
    p_dest_id: Number(id),
    p_card_type: $('plan-card').value,
  });
  btn.disabled = false;
  if (error) {
    $('plan-result').innerHTML = `<p class="notice error">${esc(error.message)}</p>`;
    return;
  }
  render(data);
}

function render(trip) {
  const legs = trip.legs;
  const ground = legs.filter((l) => l.mode !== 'FLIGHT').reduce((s, l) => s + Number(l.fare), 0);
  $('plan-result').innerHTML = `
    <div class="trip-summary">
      <div><span class="kpi-label">ค่าใช้จ่ายรวม</span><span class="trip-big">${baht(trip.total_fare)}</span>
        <span class="kpi-note">ตั๋วเครื่องบิน ${baht(legs[0].fare)} + เดินทางต่อ ${baht(ground)}</span></div>
      <div><span class="kpi-label">เวลาเดินทางรวม</span><span class="trip-big">${dur(trip.total_minutes)}</span>
        <span class="kpi-note">ออก ${day(trip.start)} ${time(trip.start)} · ถึง ${time(trip.arrive)}</span></div>
      <div><span class="kpi-label">จำนวนช่วง</span><span class="trip-big">${legs.length} ต่อ</span>
        <span class="kpi-note">${legs.map((l) => LEG[l.mode].icon).join(' → ')}</span></div>
    </div>
    <ol class="trip-legs">
      ${legs.map((l) => `
        <li class="leg leg-${LEG[l.mode].cls}">
          <div class="leg-time">${time(l.depart)}<span>${time(l.arrive)}</span></div>
          <div class="leg-dot" aria-hidden="true">${LEG[l.mode].icon}</div>
          <div class="leg-body">
            <div class="leg-head"><strong>${esc(l.title)}</strong><span class="leg-fare">${baht(l.fare)}</span></div>
            <div class="leg-route">${esc(l.from)} → ${esc(l.to)}</div>
            <div class="leg-meta">${LEG[l.mode].name} · ${dur(Math.round(l.minutes))}${l.note ? ' · ' + esc(l.note) : ''}</div>
          </div>
        </li>`).join('')}
      <li class="leg leg-end">
        <div class="leg-time">${time(trip.arrive)}</div>
        <div class="leg-dot" aria-hidden="true">📍</div>
        <div class="leg-body"><strong>ถึงปลายทาง ${esc(legs.at(-1).to)}</strong></div>
      </li>
    </ol>
    <p class="empty">คำนวณโดยฟังก์ชัน <code>plan_trip</code> ในฐานข้อมูล: ค่าโดยสาร BTS มาจาก <code>fare_tables</code> หักส่วนลดตาม <code>card_types</code> และรถเมล์เลือกสายที่ผ่านป้ายใกล้สถานี BTS ซึ่งใช้เวลารวมน้อยที่สุด</p>`;
}
