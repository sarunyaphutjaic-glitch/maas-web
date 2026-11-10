import { supabase } from './supabaseClient.js';

// =========================================================
// บัตรโดยสารของฉัน: เติมเงิน + แตะบัตรเข้า/ออก
// การคำนวณค่าโดยสารและการหักเงินทำโดย Trigger ในฐานข้อมูล (09_triggers_trip_planner.sql)
// =========================================================
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const baht = (n) => Number(n).toLocaleString('th-TH', { minimumFractionDigits: 2 }) + ' บาท';
const STATUS_TH = { ACTIVE: 'ใช้งานได้', BLOCKED: 'ถูกระงับ', EXPIRED: 'หมดอายุ' };

let stations = [];
let box;
let userId;

export async function renderWallet(uid, container) {
  userId = uid;
  box = container;
  if (!stations.length) {
    const { data } = await supabase.from('stations').select('station_id, station_code, station_name').order('station_code');
    stations = data || [];
  }
  const { data: cards, error } = await supabase
    .from('cards')
    .select('card_id, card_number, balance, status, card_types(type_name, discount_rate)')
    .eq('user_id', userId).order('card_id');
  if (error) { box.innerHTML = `<p class="notice error">โหลดข้อมูลบัตรไม่สำเร็จ: ${esc(error.message)}</p>`; return; }
  if (!cards.length) { box.innerHTML = '<p class="empty">ยังไม่มีบัตรโดยสาร</p>'; return; }

  const ids = cards.map((c) => c.card_id);
  const { data: open } = await supabase.from('gate_logs')
    .select('log_id, card_id, entry_time, stations!fk_gate_entry(station_name)')
    .in('card_id', ids).eq('status', 'IN_JOURNEY');

  const stationOpts = stations.map((s) => `<option value="${s.station_id}">${esc(s.station_name)} (${esc(s.station_code)})</option>`).join('');
  box.innerHTML = `<div class="wallet-msg notice hidden" role="status" aria-live="polite"></div>` + cards.map((c) => {
    const trip = (open || []).find((t) => t.card_id === c.card_id);
    const active = c.status === 'ACTIVE';
    return `
      <div class="wallet-card" data-card="${c.card_id}">
        <div class="wallet-face">
          <span class="wallet-type">${esc(c.card_types?.type_name)} · ลด ${Number(c.card_types?.discount_rate) * 100}%</span>
          <span class="wallet-balance">${baht(c.balance)}</span>
          <span class="wallet-number">${esc(c.card_number.replace(/(\d{4})(?=\d)/g, '$1 '))}</span>
          <span class="wallet-status" data-status="${c.status}">${STATUS_TH[c.status]}</span>
        </div>
        <div class="wallet-actions">
          <div class="wallet-row">
            <strong>เติมเงิน</strong>
            <select data-amount aria-label="จำนวนเงิน">${[100, 200, 300, 500, 1000].map((a) => `<option>${a}</option>`).join('')}</select>
            <select data-method aria-label="ช่องทางชำระ"><option value="QR">QR</option><option value="MOBILE_BANKING">Mobile Banking</option><option value="CREDIT_CARD">บัตรเครดิต</option></select>
            <button class="btn" type="button" data-topup ${active ? '' : 'disabled'}>เติมเงิน</button>
          </div>
          <div class="wallet-row">
            ${trip ? `
              <strong>กำลังเดินทาง</strong><span class="wallet-trip">จาก ${esc(trip.stations?.station_name)}</span>
              <select data-exit aria-label="สถานีที่แตะออก">${stationOpts}</select>
              <button class="btn" type="button" data-tapout="${trip.log_id}">แตะบัตรออก</button>` : `
              <strong>แตะบัตรเข้า</strong>
              <select data-entry aria-label="สถานีที่แตะเข้า">${stationOpts}</select>
              <button class="btn btn-ghost" type="button" data-tapin ${active ? '' : 'disabled'}>แตะบัตรเข้า</button>`}
          </div>
        </div>
      </div>`;
  }).join('');

  box.querySelectorAll('.wallet-card').forEach((el) => {
    const cardId = Number(el.dataset.card);
    el.querySelector('[data-topup]').addEventListener('click', () => topUp(el, cardId));
    el.querySelector('[data-tapin]')?.addEventListener('click', () => tapIn(el, cardId));
    el.querySelector('[data-tapout]')?.addEventListener('click', (e) => tapOut(el, Number(e.target.dataset.tapout)));
  });
}

function say(text, isError = false) {
  const m = box.querySelector('.wallet-msg');
  m.textContent = text;
  m.classList.toggle('error', isError);
  m.classList.remove('hidden');
}

async function topUp(el, cardId) {
  const amount = Number(el.querySelector('[data-amount]').value);
  const { data, error } = await supabase.rpc('top_up_card',
    { p_card_id: cardId, p_amount: amount, p_method: el.querySelector('[data-method]').value });
  if (error) return say(error.message, true);
  await renderWallet(userId, box);
  say(`เติมเงิน ${baht(amount)} สำเร็จ ยอดคงเหลือ ${baht(data)} (บันทึกใน payments + card_topups, Trigger เพิ่มยอดในบัตร)`);
}

async function tapIn(el, cardId) {
  const sel = el.querySelector('[data-entry]');
  const { error } = await supabase.rpc('tap_in', { p_card_id: cardId, p_station_id: Number(sel.value) });
  if (error) return say(error.message, true);
  const name = sel.options[sel.selectedIndex].text;
  await renderWallet(userId, box);
  say(`แตะบัตรเข้าที่ ${name} แล้ว`);
}

async function tapOut(el, logId) {
  const sel = el.querySelector('[data-exit]');
  const { data, error } = await supabase.rpc('tap_out', { p_log_id: logId, p_station_id: Number(sel.value) });
  if (error) return say(error.message, true);
  const name = sel.options[sel.selectedIndex].text;
  await renderWallet(userId, box);
  say(data.status === 'CANCELLED'
    ? `แตะออกที่สถานีเดิม ไม่คิดค่าโดยสาร`
    : `แตะบัตรออกที่ ${name} · Trigger คิดค่าโดยสาร ${baht(data.fare_charged)} · คงเหลือ ${baht(data.balance)}`);
}
