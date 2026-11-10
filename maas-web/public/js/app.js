import { supabase } from './supabaseClient.js';
import { initDashboard } from './dashboard.js';
import { initReports } from './reports.js';
import { initManage } from './manage.js';
import { initChat } from './chat.js';

const $ = (id) => document.getElementById(id);
const ROLE_TH = { admin: 'ผู้ดูแลระบบ', staff: 'เจ้าหน้าที่', passenger: 'ผู้โดยสาร' };
const STATUS_TH = { ACTIVE: 'ใช้งานได้', BLOCKED: 'ถูกระงับ', EXPIRED: 'หมดอายุ' };
const baht = (n) => Number(n).toLocaleString('th-TH', { minimumFractionDigits: 2 }) + ' บาท';
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------- 1. ตรวจว่า login แล้วหรือยัง ----------
const { data: { session } } = await supabase.auth.getSession();
if (!session) {
  location.replace('index.html');
  throw new Error('not logged in');
}

// ---------- 2. โหลดข้อมูลผู้ใช้จากตาราง users ----------
const { data: profile, error: profileErr } = await supabase
  .from('users')
  .select('user_id, full_name, email, role, created_at')
  .eq('auth_id', session.user.id)
  .single();

if (profileErr) {
  $('who-name').textContent = 'ไม่พบข้อมูลผู้ใช้ในตาราง users';
  console.error(profileErr);
} else {
  $('who-name').textContent = profile.full_name;
  $('who-role').textContent = ROLE_TH[profile.role];
  $('who-role').dataset.role = profile.role;
  $('p-name').textContent = profile.full_name;
  $('p-email').textContent = profile.email;
  $('p-role').textContent = ROLE_TH[profile.role];
  $('p-created').textContent = new Date(profile.created_at).toLocaleDateString('th-TH', { dateStyle: 'long' });
  loadMyCards(profile.user_id);
}

// เผยแพร่ข้อมูลผู้ใช้ให้หน้าอื่น (ที่จะเพิ่มทีหลัง) ใช้ได้
window.currentUser = profile;

// ---------- 3. บัตรของฉัน (ทดสอบ RLS: ผู้โดยสารเห็นเฉพาะบัตรตัวเอง) ----------
async function loadMyCards(userId) {
  const box = $('cards-box');
  const { data, error } = await supabase
    .from('cards')
    .select('card_number, balance, status, issued_at, card_types(type_name)')
    .eq('user_id', userId)
    .order('issued_at');

  if (error) {
    box.innerHTML = `<p class="notice error">โหลดข้อมูลบัตรไม่สำเร็จ: ${esc(error.message)}</p>`;
    return;
  }
  if (!data.length) {
    box.innerHTML = '<p class="empty">ยังไม่มีบัตรโดยสาร</p>';
    return;
  }
  box.innerHTML = `
    <div class="table-wrap"><table>
      <thead><tr><th>เลขบัตร</th><th>ประเภท</th><th>สถานะ</th><th class="num">ยอดคงเหลือ</th></tr></thead>
      <tbody>${data.map((c) => `
        <tr>
          <td>${esc(c.card_number)}</td>
          <td>${esc(c.card_types?.type_name)}</td>
          <td>${esc(STATUS_TH[c.status] || c.status)}</td>
          <td class="num">${baht(c.balance)}</td>
        </tr>`).join('')}
      </tbody>
    </table></div>`;
}

// ---------- 4. สลับหน้าตามเมนู (#home, #dashboard, ...) ----------
const PAGES = ['home', 'dashboard', 'manage', 'reports', 'chat'];
function route() {
  const name = PAGES.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'home';
  PAGES.forEach((p) => $('page-' + p).classList.toggle('hidden', p !== name));
  // โหลดข้อมูลของแต่ละหน้าครั้งแรกที่เปิด
  if (name === 'dashboard') initDashboard(profile);
  if (name === 'reports') initReports();
  if (name === 'manage') initManage(profile);
  if (name === 'chat') initChat();
  document.querySelectorAll('.sidenav a').forEach((a) => {
    if (a.getAttribute('href') === '#' + name) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  });
}
window.addEventListener('hashchange', route);
route();

// ---------- 5. ออกจากระบบ ----------
$('btn-logout').addEventListener('click', async () => {
  await supabase.auth.signOut();
  location.replace('index.html');
});
