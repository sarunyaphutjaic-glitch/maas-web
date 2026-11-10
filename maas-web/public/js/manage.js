import { supabase } from './supabaseClient.js';
import { createCrud, FLIGHTS, SCHEDULES } from './crud.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const baht = (n) => Number(n).toLocaleString('th-TH', { minimumFractionDigits: 2 });
const STATUS_TH = { ACTIVE: 'ใช้งานได้', BLOCKED: 'ถูกระงับ', EXPIRED: 'หมดอายุ' };

let role = 'passenger';
let stations = [];
let cards = [];
let loaded = false;
const crudStarted = { flights: false, schedules: false };

// ---------- แปล error จากฐานข้อมูลเป็นภาษาไทย ----------
function thaiDbError(err) {
  switch (err?.code) {
    case '23503': return 'ทำรายการไม่ได้ เพราะมีข้อมูลอื่นอ้างถึงอยู่ (เช่น ประวัติการเดินทางหรือการเติมเงิน)';
    case '23505': return 'ข้อมูลซ้ำกับที่มีอยู่แล้ว: ' + (err.details || err.message);
    case '23514': return 'ค่าที่กรอกไม่ผ่านเงื่อนไขของฐานข้อมูล: ' + err.message;
    case '42501': return 'คุณไม่มีสิทธิ์ทำรายการนี้';
    case 'P0001': return err.message;   // ข้อความจาก RAISE EXCEPTION ในฟังก์ชัน
    default: return 'เกิดข้อผิดพลาด: ' + (err?.message || 'ไม่ทราบสาเหตุ');
  }
}

function notify(text, isError = false) {
  const box = $('manage-msg');
  box.textContent = text;
  box.classList.toggle('error', isError);
  box.classList.remove('hidden');
  box.scrollIntoView({ block: 'nearest' });
}

// =========================================================
// เริ่มต้นหน้า
// =========================================================
export function initManage(profile) {
  if (loaded) return;
  loaded = true;
  role = profile?.role || 'passenger';

  $('manage-scope').textContent = {
    admin: 'ผู้ดูแลระบบ: เพิ่ม แก้ไข และลบข้อมูลได้ทั้งหมด',
    staff: 'เจ้าหน้าที่: ดูข้อมูลได้ทั้งหมด และเปลี่ยนสถานะบัตรได้',
    passenger: 'ผู้โดยสาร: ดูข้อมูลได้อย่างเดียว',
  }[role];
  document.querySelectorAll('.admin-only').forEach((el) => el.classList.toggle('hidden', role !== 'admin'));

  $('mtab-stations').addEventListener('click', () => selectTab('stations'));
  $('mtab-cards').addEventListener('click', () => selectTab('cards'));
  $('mtab-flights').addEventListener('click', () => selectTab('flights'));
  $('mtab-schedules').addEventListener('click', () => selectTab('schedules'));

  $('btn-add-station').addEventListener('click', () => openStationDialog());
  $('form-station').addEventListener('submit', saveStation);
  $('btn-add-card').addEventListener('click', () => openCardDialog());
  $('form-card').addEventListener('submit', saveCard);
  $('cards-search').addEventListener('input', renderCards);
  document.querySelectorAll('[data-close]').forEach((b) =>
    b.addEventListener('click', () => b.closest('dialog').close()));

  // ปุ่มแก้ไข/ลบในตาราง (ใช้ event delegation)
  $('stations-table').addEventListener('click', onStationAction);
  $('cards-table').addEventListener('click', onCardAction);

  loadStations();
  loadCards();
}

function selectTab(which) {
  if (which === 'flights' && !crudStarted.flights) { crudStarted.flights = true; createCrud(FLIGHTS, role, notify); }
  if (which === 'schedules' && !crudStarted.schedules) { crudStarted.schedules = true; createCrud(SCHEDULES, role, notify); }
  ['stations', 'cards', 'flights', 'schedules'].forEach((t) => {
    $('mtab-' + t).setAttribute('aria-selected', String(t === which));
    $('mpanel-' + t).classList.toggle('hidden', t !== which);
  });
  $('manage-msg').classList.add('hidden');
}

// =========================================================
// สถานี (stations + locations + station_sequences)
// =========================================================
async function loadStations() {
  const { data, error } = await supabase
    .from('stations')
    .select('station_id, station_code, station_name, location_id, locations(district, latitude, longitude), station_sequences(sequence_no, lines(code, line_name))')
    .order('station_id');
  if (error) {
    $('stations-table').innerHTML = `<p class="notice error">${esc(thaiDbError(error))}</p>`;
    return;
  }
  stations = data;
  renderStations();
}

function renderStations() {
  const canEdit = role === 'admin';
  $('stations-count').textContent = `${stations.length} สถานี`;
  $('stations-table').innerHTML = `
    <div class="table-wrap"><table>
      <thead><tr>
        <th>รหัส</th><th>ชื่อสถานี</th><th>สาย (ลำดับ)</th><th>เขต</th><th class="num">ละติจูด</th><th class="num">ลองจิจูด</th>
        ${canEdit ? '<th></th>' : ''}
      </tr></thead>
      <tbody>${stations.map((s) => `
        <tr>
          <td>${esc(s.station_code)}</td>
          <td>${esc(s.station_name)}</td>
          <td>${s.station_sequences.map((q) => `${esc(q.lines.line_name)} (${q.sequence_no})`).join(', ')}</td>
          <td>${esc(s.locations?.district)}</td>
          <td class="num">${esc(s.locations?.latitude)}</td>
          <td class="num">${esc(s.locations?.longitude)}</td>
          ${canEdit ? `<td class="row-actions">
            <button class="btn-small" data-edit="${s.station_id}">แก้ไข</button>
            <button class="btn-small danger" data-delete="${s.station_id}">ลบ</button>
          </td>` : ''}
        </tr>`).join('')}
      </tbody>
    </table></div>`;
}

function openStationDialog(station = null) {
  const isEdit = !!station;
  $('dlg-station-title').textContent = isEdit ? `แก้ไขสถานี ${station.station_code}` : 'เพิ่มสถานี';
  $('st-id').value = station?.station_id ?? '';
  $('st-code').value = station?.station_code ?? '';
  $('st-name').value = station?.station_name ?? '';
  $('st-district').value = station?.locations?.district ?? '';
  // ตอนแก้ไข: ซ่อนช่องที่เปลี่ยนไม่ได้ (สาย, พิกัด)
  document.querySelectorAll('.add-only-station').forEach((el) => el.classList.toggle('hidden', isEdit));
  $('st-submit').textContent = isEdit ? 'บันทึกการแก้ไข' : 'เพิ่มสถานี';
  $('dlg-station').showModal();
}

async function saveStation(e) {
  e.preventDefault();
  const id = $('st-id').value;
  const code = $('st-code').value.trim().toUpperCase();
  const name = $('st-name').value.trim();
  const district = $('st-district').value.trim() || null;
  if (!code || !name) return alert('กรอกรหัสและชื่อสถานี');

  let error;
  if (id) {
    // UPDATE: แก้ชื่อ/รหัสในตาราง stations และเขตในตาราง locations
    const st = stations.find((s) => String(s.station_id) === id);
    ({ error } = await supabase.from('stations')
      .update({ station_code: code, station_name: name })
      .eq('station_id', id));
    if (!error) {
      ({ error } = await supabase.from('locations')
        .update({ district, location_name: 'สถานี BTS ' + name })
        .eq('location_id', st.location_id));
    }
  } else {
    // CREATE: เรียกฟังก์ชัน add_station (เพิ่ม 4 ตารางพร้อมกัน)
    const lat = parseFloat($('st-lat').value);
    const lon = parseFloat($('st-lon').value);
    if (Number.isNaN(lat) || Number.isNaN(lon)) return alert('กรอกพิกัดเป็นตัวเลข');
    ({ error } = await supabase.rpc('add_station', {
      p_code: code, p_name: name, p_line_code: $('st-line').value,
      p_latitude: lat, p_longitude: lon, p_district: district,
    }));
  }

  if (error) return notify(thaiDbError(error), true);
  $('dlg-station').close();
  notify(id ? `บันทึกสถานี ${code} แล้ว` : `เพิ่มสถานี ${code} ${name} แล้ว`);
  loadStations();
}

async function onStationAction(e) {
  const editId = e.target.dataset.edit;
  const delId = e.target.dataset.delete;
  if (editId) openStationDialog(stations.find((s) => String(s.station_id) === editId));
  if (delId) {
    const s = stations.find((x) => String(x.station_id) === delId);
    if (!confirm(`ลบสถานี ${s.station_code} ${s.station_name}?\nค่าโดยสารที่เกี่ยวข้องจะถูกลบด้วย`)) return;
    // DELETE: เรียกฟังก์ชัน delete_station
    const { error } = await supabase.rpc('delete_station', { p_station_id: Number(delId) });
    if (error) return notify(thaiDbError(error), true);
    notify(`ลบสถานี ${s.station_code} แล้ว`);
    loadStations();
  }
}

// =========================================================
// บัตรโดยสาร (cards)
// =========================================================
async function loadCards() {
  const { data, error } = await supabase
    .from('cards')
    .select('card_id, card_number, balance, status, issued_at, card_type_id, user_id, users(full_name, email), card_types(type_name)')
    .order('card_id');
  if (error) {
    $('cards-table').innerHTML = `<p class="notice error">${esc(thaiDbError(error))}</p>`;
    return;
  }
  cards = data;
  renderCards();
}

function renderCards() {
  const q = $('cards-search').value.trim().toLowerCase();
  const shown = q
    ? cards.filter((c) => [c.card_number, c.users?.full_name, c.users?.email, c.card_types?.type_name, c.status]
        .some((v) => String(v ?? '').toLowerCase().includes(q)))
    : cards;
  const canEdit = role === 'admin' || role === 'staff';

  $('cards-count').textContent = `${shown.length} จาก ${cards.length} ใบ`;
  $('cards-table').innerHTML = shown.length ? `
    <div class="table-wrap"><table>
      <thead><tr>
        <th>เลขบัตร</th><th>เจ้าของ</th><th>ประเภท</th><th>สถานะ</th><th class="num">ยอดคงเหลือ</th>
        ${canEdit ? '<th></th>' : ''}
      </tr></thead>
      <tbody>${shown.map((c) => `
        <tr>
          <td>${esc(c.card_number)}</td>
          <td>${esc(c.users?.full_name)}</td>
          <td>${esc(c.card_types?.type_name)}</td>
          <td><span class="status" data-status="${esc(c.status)}">${esc(STATUS_TH[c.status] || c.status)}</span></td>
          <td class="num">${baht(c.balance)}</td>
          ${canEdit ? `<td class="row-actions">
            <button class="btn-small" data-edit="${c.card_id}">แก้ไข</button>
            ${role === 'admin' ? `<button class="btn-small danger" data-delete="${c.card_id}">ลบ</button>` : ''}
          </td>` : ''}
        </tr>`).join('')}
      </tbody>
    </table></div>` : '<p class="empty">ไม่พบบัตรที่ตรงกับคำค้น</p>';
}

async function openCardDialog(card = null) {
  const isEdit = !!card;
  $('dlg-card-title').textContent = isEdit ? `แก้ไขบัตร ${card.card_number}` : 'ออกบัตรใหม่';
  $('cd-id').value = card?.card_id ?? '';
  $('cd-number').value = card?.card_number ?? '7001' + String(Math.floor(Math.random() * 1e8)).padStart(8, '0');
  $('cd-number').readOnly = isEdit;
  $('cd-status').value = card?.status ?? 'ACTIVE';
  document.querySelectorAll('.add-only-card').forEach((el) => el.classList.toggle('hidden', isEdit));
  $('cd-type').disabled = role !== 'admin';     // staff เปลี่ยนได้แค่สถานะ
  $('cd-submit').textContent = isEdit ? 'บันทึกการแก้ไข' : 'ออกบัตร';

  // โหลดตัวเลือกประเภทบัตร และรายชื่อผู้ใช้ (ตอนเพิ่ม)
  const { data: types } = await supabase.from('card_types').select('card_type_id, type_name, discount_rate').order('card_type_id');
  $('cd-type').innerHTML = (types || []).map((t) =>
    `<option value="${t.card_type_id}">${esc(t.type_name)} (ลด ${t.discount_rate * 100}%)</option>`).join('');
  $('cd-type').value = card?.card_type_id ?? types?.[0]?.card_type_id;

  if (!isEdit) {
    const { data: users } = await supabase.from('users').select('user_id, full_name, email').order('full_name');
    $('cd-user').innerHTML = (users || []).map((u) =>
      `<option value="${u.user_id}">${esc(u.full_name)} (${esc(u.email)})</option>`).join('');
  }
  $('dlg-card').showModal();
}

async function saveCard(e) {
  e.preventDefault();
  const id = $('cd-id').value;
  let result;

  if (id) {
    // UPDATE
    const changes = { status: $('cd-status').value };
    if (role === 'admin') changes.card_type_id = Number($('cd-type').value);
    result = await supabase.from('cards').update(changes).eq('card_id', id).select();
  } else {
    // CREATE
    result = await supabase.from('cards').insert({
      user_id: Number($('cd-user').value),
      card_type_id: Number($('cd-type').value),
      card_number: $('cd-number').value.trim(),
      status: $('cd-status').value,
    }).select();
  }

  if (result.error) return notify(thaiDbError(result.error), true);
  // RLS ไม่ให้สิทธิ์ → ไม่มี error แต่ไม่มีแถวถูกเปลี่ยน
  if (!result.data?.length) return notify('คุณไม่มีสิทธิ์แก้ไขบัตรใบนี้', true);

  $('dlg-card').close();
  notify(id ? `บันทึกบัตร ${result.data[0].card_number} แล้ว` : `ออกบัตร ${result.data[0].card_number} แล้ว`);
  loadCards();
}

async function onCardAction(e) {
  const editId = e.target.dataset.edit;
  const delId = e.target.dataset.delete;
  if (editId) openCardDialog(cards.find((c) => String(c.card_id) === editId));
  if (delId) {
    const c = cards.find((x) => String(x.card_id) === delId);
    if (!confirm(`ลบบัตร ${c.card_number} ของ ${c.users?.full_name}?`)) return;
    // DELETE
    const { data, error } = await supabase.from('cards').delete().eq('card_id', delId).select();
    if (error) return notify(thaiDbError(error), true);
    if (!data?.length) return notify('คุณไม่มีสิทธิ์ลบบัตรใบนี้', true);
    notify(`ลบบัตร ${c.card_number} แล้ว`);
    loadCards();
  }
}
