// สร้าง public/js/config.js จาก Environment Variables ตอน build บน Vercel
// ทำให้ไม่มีค่า key อยู่ใน GitHub repo
const fs = require('fs');
const path = require('path');

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_ANON_KEY;

if (!url || !key) {
  console.error('ไม่พบ SUPABASE_URL หรือ SUPABASE_ANON_KEY ใน Environment Variables');
  process.exit(1);
}

const out = `// ไฟล์นี้สร้างอัตโนมัติตอน build ห้ามแก้และห้าม commit
export const SUPABASE_URL = ${JSON.stringify(url)};
export const SUPABASE_ANON_KEY = ${JSON.stringify(key)};
`;
fs.writeFileSync(path.join(__dirname, '..', 'public', 'js', 'config.js'), out);
console.log('สร้าง public/js/config.js เรียบร้อย');
