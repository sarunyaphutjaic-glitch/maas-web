import { supabase } from './supabaseClient.js';
import { refreshBookings } from './bookings.js';

// =========================================================
// AI Agent จองตั๋วเครื่องบิน (คุยหลายรอบ + เรียกเครื่องมือจริง + ส่งอีเมล)
// ประวัติการคุยเก็บในหน้าเว็บ แล้วส่งไปกับทุกข้อความ (Edge Function ไม่จำสถานะเอง)
// =========================================================
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const TOOL = {
  search_flights: '🔍 ค้นหาเที่ยวบิน', propose_booking: '📝 ร่างการจอง', my_bookings: '🎫 ดูการจองของฉัน', plan_connection: '🧭 วางแผนต่อรถ', query_data: '📊 ถามข้อมูล (SQL)',
};
const th = (ts) => new Date(ts).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'medium', timeStyle: 'short' });

let history = [];
let busy = false;
let started = false;

export function initAgent() {
  if (started) return;
  started = true;
  $('agent-form').addEventListener('submit', (e) => { e.preventDefault(); send($('agent-input').value); });
  $('agent-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send($('agent-input').value); }
  });
  document.querySelectorAll('#agent-suggest button').forEach((b) => b.addEventListener('click', () => send(b.textContent)));
  $('agent-reset').addEventListener('click', () => {
    history = [];
    $('agent-log').innerHTML = '';
    bot('สวัสดีครับ ผมคือ MaaS Agent ช่วยจองตั๋วเครื่องบิน (8 สนามบินในระบบ) และตอบคำถามข้อมูลการเดินทาง เช่น ค่าโดยสาร BTS หรือสายรถเมล์ อยากให้ช่วยเรื่องอะไรครับ');
  });
  $('success-close').addEventListener('click', () => $('dlg-success').close());
  $('success-mine').addEventListener('click', () => $('dlg-success').close());
  $('agent-reset').click();
}

async function send(text) {
  const message = text.trim();
  if (!message || busy) return;
  busy = true;
  $('agent-input').value = '';
  $('agent-send').disabled = true;
  user(message);
  const wait = thinking();

  const { data, error } = await supabase.functions.invoke('agent', { body: { message, history } });
  wait.remove();
  if (error) {
    let msg = error.message;
    try { msg = (await error.context.json()).error || msg; } catch { /* ใช้ข้อความเดิม */ }
    bot('เรียก Agent ไม่สำเร็จ: ' + msg, [], true);
  } else if (data.error) {
    bot(data.error, data.events || [], true);
  } else {
    history = data.history || history;
    bot(data.text || '(ไม่มีข้อความตอบกลับ)', data.events);
    if (data.proposal) confirmCard(data.proposal);
  }
  busy = false;
  $('agent-send').disabled = false;
  $('agent-input').focus();
}

function user(text) {
  $('agent-log').insertAdjacentHTML('beforeend', `<div class="msg msg-user">${esc(text)}</div>`);
  scroll();
}

function thinking() {
  $('agent-log').insertAdjacentHTML('beforeend', '<div class="msg msg-bot thinking" role="status">Agent กำลังคิดและเรียกเครื่องมือ…</div>');
  scroll();
  return $('agent-log').lastElementChild;
}

function bot(text, events = [], isError = false) {
  const steps = (events || []).map((e) =>
    `<span class="agent-step ${e.ok ? '' : 'agent-step-err'}">${TOOL[e.tool] || e.tool} · ${esc(e.summary)}</span>`).join('');
  const evidence = (events || []).filter((e) => e.tool === 'query_data' && e.sql).map((e) => `
    <details class="evidence" open><summary>SQL ที่ระบบสร้าง</summary><pre><code>${esc(e.sql)}</code></pre></details>
    ${e.rows?.length ? `<details class="evidence" ${e.rows.length <= 10 ? 'open' : ''}><summary>ตารางผลลัพธ์ (${e.rows.length} แถว)</summary>${table(e.rows)}</details>` : ''}`).join('');
  $('agent-log').insertAdjacentHTML('beforeend', `
    <div class="msg msg-bot ${isError ? 'agent-error' : ''}">
      ${steps ? `<div class="agent-steps">${steps}</div>` : ''}
      <p class="chat-answer">${esc(text)}</p>
      ${evidence}
    </div>`);
  scroll();
}

function table(rows) {
  const cols = Object.keys(rows[0]);
  return `<div class="table-wrap"><table>
    <thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map((r) => `<tr>${cols.map((c) => `<td${typeof r[c] === 'number' ? ' class="num"' : ''}>${esc(r[c])}</td>`).join('')}</tr>`).join('')}</tbody>
  </table></div>`;
}

// ---------- การ์ดยืนยันการจอง (ยังไม่จองจริงจนกว่าจะกดปุ่ม) ----------
const CLASS_TH = { ECONOMY: 'ชั้นประหยัด', BUSINESS: 'ชั้นธุรกิจ' };
const PAY_TH = { CREDIT_CARD: 'บัตรเครดิต', QR: 'QR พร้อมเพย์', MOBILE_BANKING: 'Mobile Banking' };
const baht = (n) => Number(n).toLocaleString('th-TH') + ' ฿';

function confirmCard(d) {
  const id = 'cf-' + Date.now();
  $('agent-log').insertAdjacentHTML('beforeend', `
    <div class="msg msg-bot confirm-card" id="${id}">
      <div class="confirm-head">📝 ตรวจรายละเอียดก่อนยืนยันการจอง</div>
      <div class="confirm-route"><strong>${esc(d.origin)}</strong><span>✈</span><strong>${esc(d.destination)}</strong></div>
      <dl class="confirm-list">
        <dt>เที่ยวบิน</dt><dd>${esc(d.flight_no)} · ${esc(d.origin_city)} → ${esc(d.destination_city)}</dd>
        <dt>ออกเดินทาง</dt><dd>${th(d.departure_time)} (เวลาไทย)</dd>
        <dt>ถึงปลายทาง</dt><dd>${th(d.arrival_time)}</dd>
        <dt>ผู้เดินทาง</dt><dd>${d.passengers.map(esc).join('<br>')}</dd>
        <dt>ชั้นโดยสาร</dt><dd>${CLASS_TH[d.travel_class] || esc(d.travel_class)} · ${baht(d.price_each)} / คน</dd>
        <dt>ชำระด้วย</dt><dd>${PAY_TH[d.payment_method] || esc(d.payment_method)}</dd>
      </dl>
      <div class="confirm-total"><span>ยอดชำระรวม</span><strong>${baht(d.total)}</strong></div>
      <div class="confirm-actions">
        <button class="btn btn-ghost" type="button" data-cancel>ยกเลิก</button>
        <button class="btn btn-confirm" type="button" data-confirm>ยืนยันการจอง</button>
      </div>
      <p class="confirm-note">ยังไม่มีการตัดเงินจนกว่าจะกดยืนยัน · ราคาจะคำนวณใหม่ในฐานข้อมูลตอนจองจริง</p>
    </div>`);
  const card = $(id);
  card.querySelector('[data-confirm]').addEventListener('click', () => confirmBooking(card, d));
  card.querySelector('[data-cancel]').addEventListener('click', () => {
    lock(card, 'ยกเลิกการจองนี้แล้ว');
    remember(`[ระบบ] ผู้ใช้กดยกเลิกร่างการจองเที่ยวบิน ${d.flight_no}`, 'รับทราบ ยกเลิกร่างการจองแล้ว');
    bot('ยกเลิกร่างการจองแล้วครับ ต้องการค้นหาเที่ยวบินอื่นไหมครับ');
  });
  scroll();
}

function lock(card, text, ok = false) {
  card.querySelector('.confirm-actions').innerHTML = `<span class="confirm-status ${ok ? 'ok' : ''}">${esc(text)}</span>`;
}

// ให้ Agent รู้ผลของการกดปุ่มในรอบถัดไป (ประวัติต้องสลับ user / model)
function remember(userText, modelText) {
  history.push({ role: 'user', parts: [{ text: userText }] }, { role: 'model', parts: [{ text: modelText }] });
}

async function confirmBooking(card, d) {
  const btn = card.querySelector('[data-confirm]');
  btn.disabled = true;
  btn.textContent = 'กำลังจอง…';
  card.querySelector('[data-cancel]').disabled = true;

  const { data, error } = await supabase.functions.invoke('agent', { body: { action: 'confirm', draft: d } });
  let msg = data?.error;
  if (error) { msg = error.message; try { msg = (await error.context.json()).error || msg; } catch { /* ใช้ข้อความเดิม */ } }
  if (msg) {
    btn.disabled = false;
    btn.textContent = 'ลองยืนยันอีกครั้ง';
    card.querySelector('[data-cancel]').disabled = false;
    bot('จองไม่สำเร็จ: ' + msg, [], true);
    return;
  }
  const b = data.booking;
  lock(card, `✅ จองสำเร็จ · รหัส ${b.booking_ref}`, true);
  remember(`[ระบบ] ผู้ใช้กดยืนยันแล้ว จองสำเร็จ รหัส ${b.booking_ref} เที่ยวบิน ${b.flight_no} flight_id ${b.flight_id} ที่นั่ง ${b.seats.join(', ')} ยอด ${b.total} บาท`,
    `จองสำเร็จแล้ว รหัส ${b.booking_ref}`);
  showSuccess(b, data.email);
  refreshBookings();
  bot(`จองสำเร็จแล้วครับ รหัสการจอง ${b.booking_ref}` +
    (['BKK', 'DMK'].includes(b.destination) ? ' ลงเครื่องแล้วจะเดินทางต่อไปที่ไหนครับ ผมวางแผนต่อ BTS / รถเมล์ให้ได้' : ''));
}

// ---------- หน้าต่างจองสำเร็จ ----------
function showSuccess(b, email) {
  $('success-body').innerHTML = `
    <div class="success-check" aria-hidden="true">✓</div>
    <h2 id="success-title">จองสำเร็จ!</h2>
    <p class="success-sub">รหัสการจอง</p>
    <div class="success-ref">${esc(b.booking_ref)}</div>
    <div class="ticket">
      <div class="ticket-head"><span>✈️ ${esc(b.flight_no)}</span><span>${CLASS_TH[b.travel_class] || esc(b.travel_class)}</span></div>
      <div class="ticket-route"><strong>${esc(b.origin)}</strong><span>→</span><strong>${esc(b.destination)}</strong></div>
      <div class="ticket-meta">${esc(b.origin_city)} → ${esc(b.destination_city)}</div>
      <div class="ticket-times">
        <div><small>ออกเดินทาง</small>${th(b.departure_time)}</div>
        <div><small>ถึงปลายทาง</small>${th(b.arrival_time)}</div>
      </div>
    </div>
    <table class="success-table">
      <thead><tr><th>ผู้เดินทาง</th><th>ที่นั่ง</th><th class="num">ราคา</th></tr></thead>
      <tbody>${b.passengers.map((p, i) => `<tr><td>${esc(p)}</td><td><strong>${esc(b.seats[i])}</strong></td><td class="num">${baht(b.price_each)}</td></tr>`).join('')}</tbody>
      <tfoot><tr><td colspan="2">รวม · ${PAY_TH[b.payment_method] || esc(b.payment_method)}</td><td class="num"><strong>${baht(b.total)}</strong></td></tr></tfoot>
    </table>
    <p class="success-mail ${email?.sent ? '' : 'err'}">${email?.sent
      ? `📧 ส่งอีเมลยืนยันไปที่ <b>${esc(email.to)}</b> แล้ว`
      : `📧 ส่งอีเมลไม่สำเร็จ (${esc(email?.reason || '')}) แต่การจองบันทึกเรียบร้อยแล้ว`}</p>`;
  $('dlg-success').showModal();
}

function scroll() { const log = $('agent-log'); log.scrollTop = log.scrollHeight; }
