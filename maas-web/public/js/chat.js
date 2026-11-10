import { supabase } from './supabaseClient.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const STATUS_TH = { SUCCESS: 'ตอบจากข้อมูลจริง', REJECTED: 'ถูกปฏิเสธ', ERROR: 'ผิดพลาด' };

let loaded = false;
let busy = false;

const SUGGEST = {
  passenger: [
    'จากสยามไปอโศกค่าโดยสารเท่าไร',
    'ฉันเดินทาง BTS ไปกี่เที่ยว จ่ายไปเท่าไร',
    'รถเมล์สายไหนผ่านป้ายอโศก',
    'ลงรถไฟฟ้าที่หมอชิต ต่อรถเมล์สายไหนได้บ้าง',
    'เที่ยวบินไปเชียงใหม่มีวันไหนบ้าง',
    'ฉันใช้จ่ายค่าเดินทางรวมเท่าไร',
  ],
  admin: [
    'สถานีไหนมีคนแตะบัตรเข้ามากที่สุด 5 อันดับ',
    'ผู้โดยสารคนไหนเดินทางบ่อยที่สุด และจ่ายค่าโดยสารรวมเท่าไร',
    'รายได้รวมและค่าโดยสารเฉลี่ยแยกตามประเภทบัตร',
    'มีเที่ยวที่ลืมแตะบัตรออกกี่เที่ยว',
    'เส้นทางบินไหนทำรายได้สูงสุด',
    'ลงรถไฟฟ้าที่อโศก ต่อรถเมล์สายไหนได้บ้าง',
    'ใครใช้จ่ายรวมทุกโหมดการเดินทางมากที่สุด',
  ],
};

export function initChat(profile) {
  if (loaded) return;
  loaded = true;

  const role = profile?.role === 'admin' || profile?.role === 'staff' ? 'admin' : 'passenger';
  $('chat-suggest').innerHTML = SUGGEST[role].map((q) => `<button type="button">${esc(q)}</button>`).join('');
  if (role === 'passenger') {
    $('chat-input').placeholder = 'เช่น จากหมอชิตไปสยามค่าโดยสารเท่าไร';
    $('chat-lead').textContent = 'ถามได้เรื่องค่าโดยสาร เที่ยวบิน สายรถเมล์ และข้อมูลการเดินทางของคุณเอง (ข้อมูลภาพรวมของระบบดูได้เฉพาะผู้ดูแล)';
  }

  $('chat-form').addEventListener('submit', (e) => {
    e.preventDefault();
    ask($('chat-input').value);
  });
  // Enter = ส่ง, Shift+Enter = ขึ้นบรรทัดใหม่
  $('chat-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      ask($('chat-input').value);
    }
  });
  document.querySelectorAll('.chat-suggest button').forEach((b) =>
    b.addEventListener('click', () => ask(b.textContent)));

  loadHistory();
}

// ---------- ประวัติเดิมจาก chat_logs ----------
async function loadHistory() {
  const { data, error } = await supabase
    .from('chat_logs')
    .select('question, generated_sql, answer, row_count, status, llm_model, latency_ms, created_at')
    .order('created_at', { ascending: false })
    .limit(10);
  if (error || !data?.length) return;
  data.reverse().forEach((log) => {
    addUser(log.question);
    addBot({
      answer: log.answer, sql: log.generated_sql, status: log.status,
      model: log.llm_model, latency_ms: log.latency_ms, rows: null, row_count: log.row_count,
    });
  });
  $('chat-log').insertAdjacentHTML('beforeend', '<p class="chat-divider">ประวัติก่อนหน้า (ไม่แสดงตารางผลลัพธ์)</p>');
  scrollDown();
}

// ---------- ส่งคำถาม ----------
async function ask(text) {
  const question = text.trim();
  if (!question || busy) return;
  busy = true;
  $('chat-input').value = '';
  $('chat-send').disabled = true;
  addUser(question);
  const thinking = addThinking();

  const { data, error } = await supabase.functions.invoke('chat', { body: { question } });
  thinking.remove();

  if (error) {
    let msg = error.message;
    const status = error.context?.status;
    try { msg = (await error.context.json()).error || msg; } catch {
      if (status === 546 || status === 504) msg = 'Edge Function ทำงานนานเกินเวลาที่กำหนด ให้ดูรายละเอียดที่ Edge Functions → chat → Logs';
      else if (status) msg += ` (HTTP ${status})`;
    }
    addBot({ answer: 'เรียกระบบ Chat ไม่สำเร็จ: ' + msg, status: 'ERROR', sql: null, rows: [] });
  } else {
    addBot(data);
  }
  busy = false;
  $('chat-send').disabled = false;
  $('chat-input').focus();
}

// ---------- แสดงข้อความ ----------
function addUser(text) {
  $('chat-log').insertAdjacentHTML('beforeend', `<div class="msg msg-user">${esc(text)}</div>`);
  scrollDown();
}

function addThinking() {
  $('chat-log').insertAdjacentHTML('beforeend',
    '<div class="msg msg-bot thinking" role="status">กำลังสร้าง SQL และดึงข้อมูล…</div>');
  scrollDown();
  return $('chat-log').lastElementChild;
}

function addBot(r) {
  const rows = r.rows;
  const count = rows ? rows.length : r.row_count;
  const meta = [
    `<span class="chat-status" data-status="${esc(r.status)}">${STATUS_TH[r.status] || esc(r.status)}</span>`,
    r.sql ? `${count ?? 0} แถว` : '',
    r.model ? esc(r.model) : '',
    r.latency_ms ? `${(r.latency_ms / 1000).toFixed(1)} วินาที` : '',
  ].filter(Boolean).join(' <span aria-hidden="true">|</span> ');

  $('chat-log').insertAdjacentHTML('beforeend', `
    <div class="msg msg-bot">
      <p class="chat-answer">${esc(r.answer)}</p>
      <p class="chat-meta">${meta}</p>
      ${r.sql ? `<details open><summary>SQL ที่ระบบสร้าง</summary><pre><code>${esc(r.sql)}</code></pre></details>` : ''}
      ${rows && rows.length ? `<details ${rows.length <= 10 ? 'open' : ''}><summary>ตารางผลลัพธ์ (raw data)</summary>${table(rows)}</details>` : ''}
    </div>`);
  scrollDown();
}

function table(rows) {
  const cols = Object.keys(rows[0]);
  return `<div class="table-wrap"><table>
    <thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${rows.slice(0, 50).map((r) =>
      `<tr>${cols.map((c) => `<td${typeof r[c] === 'number' ? ' class="num"' : ''}>${esc(r[c])}</td>`).join('')}</tr>`
    ).join('')}</tbody>
  </table></div>`;
}

function scrollDown() {
  const log = $('chat-log');
  log.scrollTop = log.scrollHeight;
}
