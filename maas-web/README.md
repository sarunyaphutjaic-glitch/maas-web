# MaaS — AIE313 Database System Mini Project

ระบบรวมข้อมูลการเดินทาง เครื่องบิน / รถไฟฟ้า / รถเมล์ บน Supabase

## โครงสร้าง
```
public/            ไฟล์เว็บทั้งหมด (Vercel ใช้โฟลเดอร์นี้)
  index.html       หน้า Login / Register
  app.html         หน้าระบบหลัก
  css/style.css
  js/supabaseClient.js
  js/auth.js
  js/app.js
  js/config.example.js   ตัวอย่างค่าตั้งค่า (config.js จริงไม่อยู่ใน repo)
scripts/gen-config.js    สร้าง config.js จาก Environment Variables ตอน deploy
sql/                     สคริปต์ฐานข้อมูล (เรียงตามลำดับการรัน)
```

## รันบนเครื่องตัวเอง
1. คัดลอก `public/js/config.example.js` เป็น `public/js/config.js` แล้วใส่ URL และ anon key
2. เปิด terminal ที่โฟลเดอร์ `public` แล้วรัน `npx serve .` (หรือใช้ Live Server ใน VS Code)
3. เปิด http://localhost:3000

## Deploy บน Vercel
- Build Command: `npm run build`
- Output Directory: `public`
- Environment Variables: `SUPABASE_URL`, `SUPABASE_ANON_KEY`
