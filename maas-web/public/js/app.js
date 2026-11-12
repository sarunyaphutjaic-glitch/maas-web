import { supabase } from './supabaseClient.js';
import { initDashboard } from './dashboard.js';
import { initReports } from './reports.js';
import { initManage } from './manage.js';
import { initChat } from './chat.js';
import { initPlanner } from './planner.js';
import { initMap } from './map.js';
import { renderWallet } from './wallet.js';
import { initAgent } from './agent.js';

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
  renderWallet(profile.user_id, $('cards-box'));
}

// เผยแพร่ข้อมูลผู้ใช้ให้หน้าอื่น (ที่จะเพิ่มทีหลัง) ใช้ได้
window.currentUser = profile;

// ---------- 4. สลับหน้าตามเมนู (#home, #dashboard, ...) ----------
const PAGES = ['home', 'dashboard', 'planner', 'map', 'manage', 'reports', 'chat', 'agent'];
// หน้าที่จำกัดสิทธิ์ (หน้าที่ไม่อยู่ในนี้ทุกคนเข้าได้)
const ACCESS = { dashboard: ['admin'], reports: ['admin'], manage: ['admin', 'staff'] };
const myRole = profile?.role ?? 'passenger';
const canSee = (page) => !ACCESS[page] || ACCESS[page].includes(myRole);
document.querySelectorAll('[data-roles]').forEach((el) => {
  el.classList.toggle('hidden', !el.dataset.roles.split(' ').includes(myRole));
});
function route() {
  let name = PAGES.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'home';
  if (!canSee(name)) {            // ไม่มีสิทธิ์ → กลับหน้าบัญชีของฉัน
    name = 'home';
    history.replaceState(null, '', '#home');
  }
  PAGES.forEach((p) => $('page-' + p).classList.toggle('hidden', p !== name));
  // โหลดข้อมูลของแต่ละหน้าครั้งแรกที่เปิด
  if (name === 'dashboard') initDashboard(profile);
  if (name === 'reports') initReports();
  if (name === 'manage') initManage(profile);
  if (name === 'chat') initChat(profile);
  if (name === 'planner') initPlanner();
  if (name === 'map') initMap();
  if (name === 'agent') initAgent();
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
