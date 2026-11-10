import { supabase } from './supabaseClient.js';

const $ = (id) => document.getElementById(id);
const msg = $('message');

// แปลข้อความ error ที่พบบ่อยจาก Supabase เป็นภาษาไทย
function thaiError(err) {
  const m = (err?.message || '').toLowerCase();
  if (m.includes('invalid login credentials')) return 'อีเมลหรือรหัสผ่านไม่ถูกต้อง';
  if (m.includes('email not confirmed')) return 'ยังไม่ได้ยืนยันอีเมล ให้กดลิงก์ในอีเมลก่อนเข้าสู่ระบบ';
  if (m.includes('already registered')) return 'อีเมลนี้มีบัญชีอยู่แล้ว ให้เข้าสู่ระบบแทน';
  if (m.includes('password should be at least')) return 'รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร';
  if (m.includes('rate limit')) return 'ส่งคำขอบ่อยเกินไป รอสักครู่แล้วลองใหม่';
  if (m.includes('invalid') && m.includes('email')) return 'รูปแบบอีเมลไม่ถูกต้อง';
  return 'เกิดข้อผิดพลาด: ' + (err?.message || 'ไม่ทราบสาเหตุ');
}

function show(text, isError = false) {
  msg.textContent = text;
  msg.classList.toggle('error', isError);
  msg.classList.remove('hidden');
}

// ---------- สลับแท็บ ----------
function selectTab(which) {
  const isLogin = which === 'login';
  $('tab-login').setAttribute('aria-selected', String(isLogin));
  $('tab-register').setAttribute('aria-selected', String(!isLogin));
  $('form-login').classList.toggle('hidden', !isLogin);
  $('form-register').classList.toggle('hidden', isLogin);
  msg.classList.add('hidden');
}
$('tab-login').addEventListener('click', () => selectTab('login'));
$('tab-register').addEventListener('click', () => selectTab('register'));

// ถ้า login ค้างอยู่แล้ว ไปหน้าระบบเลย
const { data: { session } } = await supabase.auth.getSession();
if (session) location.replace('app.html');

// ---------- เข้าสู่ระบบ ----------
$('form-login').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = e.submitter;
  btn.disabled = true;
  const { error } = await supabase.auth.signInWithPassword({
    email: $('login-email').value.trim(),
    password: $('login-password').value,
  });
  btn.disabled = false;
  if (error) return show(thaiError(error), true);
  location.replace('app.html');
});

// ---------- สมัครสมาชิก ----------
$('form-register').addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = $('reg-name').value.trim();
  const password = $('reg-password').value;
  if (!name) return show('กรอกชื่อ-นามสกุล', true);
  if (password.length < 6) return show('รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร', true);

  const btn = e.submitter;
  btn.disabled = true;
  const { data, error } = await supabase.auth.signUp({
    email: $('reg-email').value.trim(),
    password,
    options: { data: { full_name: name } },   // trigger ใน DB จะนำไปใส่ users.full_name
  });
  btn.disabled = false;
  if (error) return show(thaiError(error), true);

  if (data.session) {
    location.replace('app.html');              // ปิดการยืนยันอีเมลไว้ → เข้าระบบได้ทันที
  } else {
    show('สมัครสำเร็จ ให้เปิดอีเมลแล้วกดลิงก์ยืนยันก่อนเข้าสู่ระบบ');
    selectTab('login');
    msg.classList.remove('hidden');
  }
});
