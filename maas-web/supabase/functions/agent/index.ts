// =====================================================================
// Supabase Edge Function: agent (AI Agent จองตั๋วเครื่องบิน)
//
// Gemini Function Calling: LLM เลือกเรียก "เครื่องมือ" เอง แล้ว Edge Function ทำงานจริงกับฐานข้อมูล
//   search_flights   → ค้นหาเที่ยวบินจาก v_flight_schedule
//   propose_booking  → สร้าง "ร่างการจอง" ให้ผู้ใช้ตรวจ (AI จองเองไม่ได้)
// การจองจริง: ผู้ใช้กดปุ่ม "ยืนยันการจอง" → action 'confirm' → ฟังก์ชัน SQL book_flight
//   (payments + bookings + tickets ใน Transaction เดียว) → ส่งอีเมล (Human-in-the-loop)
//   my_bookings      → ดูการจองของตัวเอง (RLS)
//   plan_connection  → วางแผนต่อ BTS / รถเมล์ หลังลงเครื่อง (plan_trip)
//   query_data       → ถามข้อมูลด้วยภาษาธรรมชาติ (Text-to-SQL ผ่าน run_chat_query) แสดง SQL + ตารางเป็นหลักฐาน
// หลังจองสำเร็จ ส่งอีเมลยืนยันผ่าน Google Apps Script (Web App)
//
// Secrets: GEMINI_API_KEY, GEMINI_MODEL, GEMINI_FALLBACK_MODELS, APPS_SCRIPT_URL, APPS_SCRIPT_TOKEN
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-3.5-flash-lite';
const FALLBACK_MODELS = (Deno.env.get('GEMINI_FALLBACK_MODELS') || '').split(',').map((m) => m.trim()).filter(Boolean);
const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY');
const MAIL_URL = Deno.env.get('APPS_SCRIPT_URL');
const MAIL_TOKEN = Deno.env.get('APPS_SCRIPT_TOKEN');
const MAX_STEPS = 6;   // จำนวนรอบเรียกเครื่องมือสูงสุดต่อ 1 ข้อความ

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// ---------- เครื่องมือที่ให้ LLM เรียก ----------
const TOOLS = [{
  functionDeclarations: [
    {
      name: 'search_flights',
      description: 'ค้นหาเที่ยวบินที่ยังจองได้ (ยังไม่ออก) ระหว่างสนามบินในระบบ 8 แห่งเท่านั้น ตามที่ผู้ใช้ระบุ',
      parameters: {
        type: 'OBJECT',
        properties: {
          destination: { type: 'STRING', description: 'เมืองหรือรหัสสนามบินปลายทาง เช่น เชียงใหม่, CNX, ภูเก็ต' },
          origin: { type: 'STRING', description: 'เมืองหรือรหัสสนามบินต้นทาง (ไม่บังคับ) เช่น BKK, DMK' },
          date: { type: 'STRING', description: 'วันที่ YYYY-MM-DD ตามเวลาไทย (ไม่บังคับ)' },
        },
        required: ['destination'],
      },
    },
    {
      name: 'propose_booking',
      description: 'สร้าง "ร่างการจอง" ให้ผู้ใช้ตรวจและกดปุ่มยืนยันเอง (ยังไม่จองจริง ยังไม่ตัดเงิน) เรียกเมื่อได้ข้อมูลครบแล้ว',
      parameters: {
        type: 'OBJECT',
        properties: {
          flight_id: { type: 'INTEGER', description: 'flight_id จากผล search_flights' },
          origin: { type: 'STRING', description: 'สนามบินต้นทางที่ผู้ใช้ขอ (รหัสหรือชื่อเมือง) ใช้ตรวจว่าเที่ยวบินตรงตามที่ขอ' },
          destination: { type: 'STRING', description: 'สนามบินปลายทางที่ผู้ใช้ขอ (รหัสหรือชื่อเมือง)' },
          passengers: { type: 'ARRAY', items: { type: 'STRING' }, description: 'ชื่อผู้เดินทาง 1–4 คน' },
          travel_class: { type: 'STRING', enum: ['ECONOMY', 'BUSINESS'] },
          payment_method: { type: 'STRING', enum: ['CREDIT_CARD', 'QR', 'MOBILE_BANKING'] },
        },
        required: ['flight_id', 'destination', 'passengers', 'travel_class', 'payment_method'],
      },
    },
    {
      name: 'query_data',
      description: 'ตอบคำถามข้อมูลด้วย SQL SELECT คำสั่งเดียว บน View ที่อนุญาตเท่านั้น เช่น ค่าโดยสาร BTS สายรถเมล์ สถิติ ประวัติของผู้ใช้',
      parameters: {
        type: 'OBJECT',
        properties: { sql: { type: 'STRING', description: 'PostgreSQL SELECT คำสั่งเดียว ไม่มี ; ท้าย ใส่ LIMIT ไม่เกิน 50' } },
        required: ['sql'],
      },
    },
    {
      name: 'my_bookings',
      description: 'ดูรายการตั๋วเครื่องบินที่ผู้ใช้จองไว้ (เฉพาะของตัวเอง)',
      parameters: { type: 'OBJECT', properties: {} },
    },
    {
      name: 'plan_connection',
      description: 'วางแผนเดินทางต่อหลังลงเครื่องที่สุวรรณภูมิหรือดอนเมือง ไปยังสถานี BTS หรือป้ายรถเมล์',
      parameters: {
        type: 'OBJECT',
        properties: {
          flight_id: { type: 'INTEGER' },
          destination_name: { type: 'STRING', description: 'ชื่อสถานี BTS หรือป้ายรถเมล์ เช่น อโศก, สยาม' },
          card_type: { type: 'STRING', enum: ['Adult', 'Student', 'Senior'] },
        },
        required: ['flight_id', 'destination_name'],
      },
    },
  ],
}];

const VIEWS: { name: string; who: 'public' | 'admin'; desc: string }[] = [
  { name: 'v_fare_lookup', who: 'public', desc: `ค่าโดยสาร BTS ระหว่างสถานี
  origin_station, origin_code, destination_station, destination_code (ชื่อสถานีภาษาไทย เช่น 'สยาม', 'อโศก'),
  adult_fare, student_fare, senior_fare (บาท)` },
  { name: 'v_flight_schedule', who: 'public', desc: `ตารางเที่ยวบิน
  flight_no, origin_code, origin_city, destination_code, destination_city (เช่น 'เชียงใหม่', 'ภูเก็ต'),
  departure_time, arrival_time, flight_date, base_price, flight_status ('SCHEDULED' | 'ARRIVED' | 'CANCELLED')
  (รหัส: BKK สุวรรณภูมิ, DMK ดอนเมือง, CNX เชียงใหม่, HKT ภูเก็ต, HDY หาดใหญ่, KBV กระบี่, USM สมุย, UTH อุดรธานี)` },
  { name: 'v_bus_route_stops', who: 'public', desc: `ป้ายของรถเมล์แต่ละสาย (1 แถว = 1 ป้ายในสาย) ใช้ตอบว่าสายไหนผ่านป้ายไหน
  route_no ('2','4','15','25','29','76','77','365'), route_name, fare, sequence_no, stop_code,
  stop_name (เช่น 'ป้ายสวนจตุจักร', 'ป้ายอโศก (เทอร์มินอล 21)'), district, near_bts_station (สถานี BTS ข้างป้าย)` },
  { name: 'v_bus_stops_near_bts', who: 'public', desc: `ป้ายรถเมล์ใกล้สถานี BTS (ใช้ตอบเรื่องการต่อรถ)
  bts_station, station_code, bus_stop, bus_routes (เช่น '2, 25'), distance_m` },
  { name: 'v_trip_details', who: 'public', desc: `การเดินทาง BTS แต่ละเที่ยว (ผู้โดยสารเห็นเฉพาะของตัวเอง)
  log_id, user_id, passenger_name, card_number, card_type ('Adult' | 'Student' | 'Senior'),
  entry_station, exit_station, trip_date, entry_hour, entry_time, exit_time, duration_min, fare_charged,
  status ('COMPLETED' | 'IN_JOURNEY' = ลืมแตะออก | 'CANCELLED')` },
  { name: 'v_problem_trips', who: 'public', desc: `เที่ยว BTS ที่ลืมแตะออกหรือยกเลิก
  log_id, passenger_name, card_number, card_type, entry_station, entry_time, status` },
  { name: 'v_flight_bookings', who: 'public', desc: `ตั๋วเครื่องบินที่จอง (ผู้โดยสารเห็นเฉพาะของตัวเอง)
  ticket_id, booking_ref, user_id, booker_name, passenger_name, flight_no, origin_code, origin_city,
  destination_code, destination_city, departure_time, flight_date, travel_class ('ECONOMY' | 'BUSINESS'),
  seat_no, price, booking_status ('CONFIRMED' | 'PENDING' | 'CANCELLED'), payment_method, flight_status` },
  { name: 'v_bus_ride_details', who: 'public', desc: `การขึ้นรถเมล์แต่ละครั้ง (ผู้โดยสารเห็นเฉพาะของตัวเอง)
  ride_id, user_id, passenger_name, route_no, route_name, board_stop, alight_stop, boarded_at, ride_date,
  ride_hour, fare_paid, payment_method, bus_type ('NORMAL' | 'AIRCON' | 'EV')` },
  { name: 'v_user_spending', who: 'public', desc: `ค่าใช้จ่ายรวมแยกโหมด (ผู้โดยสารเห็นเฉพาะของตัวเอง)
  user_id, full_name, rail_topup, flight, bus, total_spent, modes_used` },
  { name: 'v_station_ridership', who: 'admin', desc: `สรุปรายสถานี BTS
  station_id, station_code, station_name, lines, entries, exits, revenue_from_entries` },
  { name: 'v_daily_rail_revenue', who: 'admin', desc: `รายได้ BTS รายวัน
  trip_date, total_trips, completed_trips, unique_cards, revenue, avg_fare` },
  { name: 'v_card_type_stats', who: 'admin', desc: `สถิติตามประเภทบัตร
  card_type, discount_rate, total_cards, avg_balance, total_trips, total_fare, avg_fare` },
  { name: 'v_route_revenue', who: 'admin', desc: `รายได้ต่อเส้นทางบิน
  route (เช่น 'BKK-CNX'), origin_city, destination_city, flights, tickets_sold, revenue, avg_ticket_price` },
  { name: 'v_flight_occupancy', who: 'admin', desc: `อัตราที่นั่งเต็มต่อเที่ยวบิน
  flight_id, flight_no, route, departure_time, flight_date, aircraft_model, total_seats, seats_sold, occupancy_pct, flight_status` },
  { name: 'v_route_ridership', who: 'admin', desc: `สรุปรายสายรถเมล์
  route_no, route_name, fare, scheduled_trips, completed_trips, passengers, revenue, avg_delay_min` },
  { name: 'v_driver_workload', who: 'admin', desc: `ภาระงานพนักงานขับรถ
  driver_id, driver_name, completed_trips, driving_hours, avg_delay_min, routes_driven` },
  { name: 'v_payment_summary', who: 'admin', desc: `สรุปการชำระเงินรายเดือน
  month, service_type ('RAIL_TOPUP' | 'FLIGHT' | 'BUS'), method, transactions, total_amount` },
];

function systemPrompt(name: string, role: string, airports: string) {
  const isPassenger = role !== 'admin' && role !== 'staff';
  const schema = VIEWS.filter((v) => !isPassenger || v.who === 'public').map((v) => `${v.name} — ${v.desc}`).join('\n\n');
  const now = new Date().toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'full', timeStyle: 'short' });
  return `คุณคือ "MaaS Agent" ผู้ช่วยของระบบ MaaS (รถไฟฟ้า BTS, สายการบิน, รถเมล์) พูดภาษาไทย สุภาพ กระชับ
ผู้ใช้ชื่อ ${name} (สิทธิ์ ${isPassenger ? 'ผู้โดยสาร' : 'ผู้ดูแลระบบ'}) · เวลาปัจจุบัน (เวลาไทย UTC+07): ${now}

งานที่ทำได้ 2 อย่าง
A) จองตั๋วเครื่องบิน (จองได้เฉพาะเที่ยวบิน ไม่มีการจองรถไฟฟ้าหรือรถเมล์)
B) ตอบคำถามข้อมูลด้วยเครื่องมือ query_data เขียน SQL บน View ที่อนุญาต แล้วสรุปคำตอบจากผลลัพธ์จริง

สนามบินในระบบมีเพียง 8 แห่ง: ${airports}

ขั้นตอนการทำงาน
1. ถามข้อมูลที่ขาด: ปลายทาง วันที่ จำนวนและชื่อผู้เดินทาง ชั้นโดยสาร (ECONOMY / BUSINESS) ช่องทางชำระ
2. ใช้ search_flights หาเที่ยวบิน แล้วแสดงเป็นรายการ: เลขเที่ยวบิน เส้นทาง วันเวลา (เวลาไทย) ราคา
3. เมื่อได้ข้อมูลครบ เรียก propose_booking เพื่อสร้างร่างการจอง แล้วบอกผู้ใช้สั้นๆ ให้ตรวจรายละเอียดในการ์ด
   และกดปุ่ม "ยืนยันการจอง" (คุณจองเองไม่ได้ การจองจริงเกิดเมื่อผู้ใช้กดปุ่มเท่านั้น)
4. ถ้าระบบแจ้งว่าจองสำเร็จแล้ว และเที่ยวบินลงสุวรรณภูมิหรือดอนเมือง เสนอวางแผนต่อ BTS / รถเมล์ด้วย plan_connection

กติกาการจอง (สำคัญ)
- ใช้สนามบินตามที่ผู้ใช้ระบุเท่านั้น ถ้าเมืองที่ผู้ใช้ขอไม่มีสนามบินในรายการ ให้บอกว่าไม่มีและแสดงรายการสนามบินที่มี
- ห้ามเปลี่ยนไปเสนอสนามบินอื่นแทนเอง ถ้าไม่มีเที่ยวบินตรงตามที่ขอ ให้บอกว่าไม่มี แล้วถามผู้ใช้ก่อนว่าจะดูวันอื่นหรือสนามบินอื่นไหม
- "กรุงเทพ" มี 2 สนามบิน (BKK สุวรรณภูมิ, DMK ดอนเมือง) ถ้าผู้ใช้ไม่ระบุ ให้แสดงทั้งสองแบบแยกให้ชัด
- ตอนเรียก propose_booking ต้องส่ง origin / destination ตามที่ผู้ใช้ขอ ระบบจะตรวจว่าเที่ยวบินตรงจริง

กติกาการตอบคำถามข้อมูล (query_data)
- ใช้ได้เฉพาะ View ด้านล่าง SELECT คำสั่งเดียว ค้นข้อความด้วย ILIKE '%คำ%'
- ผู้โดยสารถามได้เฉพาะข้อมูลสาธารณะและข้อมูลของตัวเอง ถ้าถามรายได้หรือข้อมูลคนอื่นให้ปฏิเสธ
- ปฏิเสธคำขอแก้ไข ลบ หรือเปลี่ยนแปลงข้อมูลทุกกรณี

View ที่ใช้ได้
${schema}

กติกาทั่วไป
- ใช้เฉพาะข้อมูลจากเครื่องมือ ห้ามแต่งเที่ยวบิน ราคา ตัวเลข หรือรหัสการจองขึ้นเอง
- ปฏิเสธเรื่องที่ไม่เกี่ยวกับการเดินทางอย่างสุภาพ
- ห้ามบอกว่าจองสำเร็จแล้ว จนกว่าระบบจะแจ้งผลหลังผู้ใช้กดยืนยัน
- จองได้ครั้งละ 1–4 คน และจองได้เฉพาะในชื่อบัญชีของผู้ใช้ที่ login อยู่`;
}

// ---------- เรียก Gemini (ลองซ้ำ + รุ่นสำรองเมื่อคนใช้เยอะ) ----------
async function callGemini(contents: unknown[], system: string) {
  let last = '';
  for (const model of [MODEL, ...FALLBACK_MODELS]) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_KEY ?? '' },
        signal: AbortSignal.timeout(40_000),
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents,
          tools: TOOLS,
          generationConfig: { temperature: 0.2 },
        }),
      });
      const data = await res.json();
      if (res.ok) return { model, content: data?.candidates?.[0]?.content ?? { role: 'model', parts: [] } };
      last = data?.error?.message || `Gemini HTTP ${res.status}`;
      if (![429, 500, 503].includes(res.status)) throw new Error(last);
      if (attempt === 1) await new Promise((r) => setTimeout(r, 1500));
    }
  }
  throw new Error(last + ' (ลองใหม่อีกครั้งในอีกสักครู่)');
}

// ---------- อีเมลยืนยันผ่าน Google Apps Script ----------
const th = (ts: string) => new Date(ts).toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'long', timeStyle: 'short' });
async function sendEmail(b: Record<string, unknown>) {
  return postMail(b.email as string, `ยืนยันการจอง ${b.booking_ref} · ${b.flight_no}`, bookingHtml(b));
}

function bookingHtml(b: Record<string, unknown>) {
  const passengers = (b.passengers as string[]).map((p, i) => `<li>${p} — ที่นั่ง ${(b.seats as string[])[i]}</li>`).join('');
  return `
    <div style="font-family:sans-serif;max-width:560px">
      <h2 style="margin:0 0 8px">ยืนยันการจองตั๋วเครื่องบิน ✈️</h2>
      <p>เรียนคุณ ${b.name}<br>ระบบ MaaS ได้รับการจองของคุณเรียบร้อยแล้ว</p>
      <table cellpadding="6" style="border-collapse:collapse;border:1px solid #ddd">
        <tr><td><b>รหัสการจอง</b></td><td><b style="font-size:18px">${b.booking_ref}</b></td></tr>
        <tr><td>เที่ยวบิน</td><td>${b.flight_no} · ${b.origin} (${b.origin_city}) → ${b.destination} (${b.destination_city})</td></tr>
        <tr><td>ออกเดินทาง</td><td>${th(b.departure_time as string)} (เวลาไทย)</td></tr>
        <tr><td>ถึงปลายทาง</td><td>${th(b.arrival_time as string)} (เวลาไทย)</td></tr>
        <tr><td>ชั้นโดยสาร</td><td>${b.travel_class}</td></tr>
        <tr><td>ยอดชำระ</td><td>${Number(b.total).toLocaleString('th-TH')} บาท (${b.payment_method})</td></tr>
      </table>
      <p><b>ผู้เดินทาง</b></p><ul>${passengers}</ul>
      <p style="color:#777;font-size:12px">อีเมลนี้ส่งอัตโนมัติจาก MaaS Agent · AIE313 Database System</p>
    </div>`;
}

function cancelHtml(c: Record<string, unknown>) {
  return `
    <div style="font-family:sans-serif;max-width:560px">
      <h2 style="margin:0 0 8px;color:#c2412d">แจ้งยกเลิกการจอง</h2>
      <p>เรียนคุณ ${c.name}<br>การจองของคุณถูกยกเลิกแล้ว${c.cancelled_by_admin ? ' โดยผู้ดูแลระบบ' : ''}</p>
      <table cellpadding="6" style="border-collapse:collapse;border:1px solid #ddd">
        <tr><td><b>รหัสการจอง</b></td><td><b style="font-size:18px">${c.booking_ref}</b></td></tr>
        <tr><td>เที่ยวบิน</td><td>${c.flight_no} · ${c.origin} (${c.origin_city}) → ${c.destination} (${c.destination_city})</td></tr>
        <tr><td>กำหนดออกเดิม</td><td>${th(c.departure_time as string)} (เวลาไทย)</td></tr>
        <tr><td>ผู้เดินทาง</td><td>${(c.passengers as string[]).join('<br>')}</td></tr>
        <tr><td>เหตุผล</td><td>${c.reason}</td></tr>
        <tr><td>ยอดคืนเงิน</td><td><b>${Number(c.refund).toLocaleString('th-TH')} บาท</b> (คืนช่องทางเดิม)</td></tr>
      </table>
      <p style="color:#777;font-size:12px">อีเมลนี้ส่งอัตโนมัติจาก MaaS Agent · AIE313 Database System</p>
    </div>`;
}

async function postMail(to: string, subject: string, html: string) {
  if (!MAIL_URL) return { sent: false, reason: 'ยังไม่ได้ตั้งค่า APPS_SCRIPT_URL' };
  try {
    const res = await fetch(MAIL_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: MAIL_TOKEN, to, subject, html }),
      redirect: 'follow',
    });
    const text = await res.text();
    let ok = res.ok;
    try { ok = ok && JSON.parse(text).ok === true; } catch { /* Apps Script อาจตอบเป็นหน้า HTML */ }
    return ok ? { sent: true, to } : { sent: false, reason: text.slice(0, 200) };
  } catch (e) {
    return { sent: false, reason: e instanceof Error ? e.message : String(e) };
  }
}

// ---------- สนามบิน: แปลงคำที่ผู้ใช้พิมพ์ → รหัสสนามบินในระบบ ----------
type Airport = { iata_code: string; airport_name: string; city: string };
let AIRPORTS: Airport[] = [];
const ALIAS: Record<string, string[]> = {
  'กรุงเทพ': ['BKK', 'DMK'], 'bangkok': ['BKK', 'DMK'], 'สุวรรณภูมิ': ['BKK'], 'ดอนเมือง': ['DMK'],
  'เชียงใหม่': ['CNX'], 'ภูเก็ต': ['HKT'], 'หาดใหญ่': ['HDY'], 'สงขลา': ['HDY'], 'กระบี่': ['KBV'],
  'สมุย': ['USM'], 'เกาะสมุย': ['USM'], 'สุราษฎร์': ['USM'], 'อุดร': ['UTH'], 'อุดรธานี': ['UTH'],
};
function resolveAirport(term: string): string[] {
  const t = String(term ?? '').trim().toLowerCase().replace(/^(สนามบิน|ท่าอากาศยาน)/, '').trim();
  if (!t) return [];
  const byCode = AIRPORTS.filter((a) => a.iata_code.toLowerCase() === t).map((a) => a.iata_code);
  if (byCode.length) return byCode;
  for (const [k, v] of Object.entries(ALIAS)) if (t.includes(k.toLowerCase())) return v;
  return AIRPORTS.filter((a) => a.city.toLowerCase().includes(t) || a.airport_name.toLowerCase().includes(t)).map((a) => a.iata_code);
}
const airportList = () => AIRPORTS.map((a) => `${a.iata_code} ${a.airport_name.replace('ท่าอากาศยาน', '')}`).join(', ');

// ---------- ทำงานตามเครื่องมือที่ LLM เรียก ----------
// deno-lint-ignore no-explicit-any
async function runTool(supabase: any, name: string, args: Record<string, any>) {
  if (name === 'search_flights') {
    let q = supabase.from('v_flight_schedule').select('*')
      .eq('flight_status', 'SCHEDULED').gt('departure_time', new Date().toISOString())
      .order('departure_time').limit(10);
    const destCodes = resolveAirport(args.destination);
    if (!destCodes.length) return { error: `ไม่มีสนามบิน "${args.destination}" ในระบบ สนามบินที่มี: ${airportList()}` };
    q = q.in('destination_code', destCodes);
    if (args.origin) {
      const orgCodes = resolveAirport(args.origin);
      if (!orgCodes.length) return { error: `ไม่มีสนามบิน "${args.origin}" ในระบบ สนามบินที่มี: ${airportList()}` };
      q = q.in('origin_code', orgCodes);
    }
    if (args.date) q = q.eq('flight_date', args.date);
    const { data, error } = await q;
    if (error) return { error: error.message };
    return {
      flights: (data ?? []).map((f: Record<string, string>) => ({
        flight_id: f.flight_id, flight_no: f.flight_no,
        from: `${f.origin_code} ${f.origin_city}`, to: `${f.destination_code} ${f.destination_city}`,
        departure_th: th(f.departure_time), arrival_th: th(f.arrival_time), economy_price: f.base_price,
      })),
    };
  }
  if (name === 'propose_booking') {
    const passengers = (args.passengers ?? []).map((p: string) => String(p).trim()).filter(Boolean);
    if (passengers.length < 1 || passengers.length > 4) return { error: 'จองได้ครั้งละ 1–4 คน' };
    const { data: f, error } = await supabase.from('v_flight_schedule').select('*').eq('flight_id', args.flight_id).single();
    if (error || !f) return { error: 'ไม่พบเที่ยวบิน' };
    if (f.flight_status !== 'SCHEDULED' || new Date(f.departure_time) <= new Date()) return { error: `เที่ยวบิน ${f.flight_no} จองไม่ได้แล้ว` };
    // ตรวจว่าเที่ยวบินตรงกับสนามบินที่ผู้ใช้ขอจริง (กันการจองผิดสนามบิน)
    const wantDest = resolveAirport(args.destination);
    if (!wantDest.includes(f.destination_code)) {
      return { error: `เที่ยวบิน ${f.flight_no} ไปลง ${f.destination_code} ไม่ตรงกับปลายทางที่ขอ (${args.destination})` };
    }
    if (args.origin && !resolveAirport(args.origin).includes(f.origin_code)) {
      return { error: `เที่ยวบิน ${f.flight_no} ออกจาก ${f.origin_code} ไม่ตรงกับต้นทางที่ขอ (${args.origin})` };
    }
    const each = Number(f.base_price) * (args.travel_class === 'BUSINESS' ? 2.5 : 1);
    return {
      draft: {
        flight_id: f.flight_id, flight_no: f.flight_no,
        origin: f.origin_code, origin_city: f.origin_city, destination: f.destination_code, destination_city: f.destination_city,
        departure_time: f.departure_time, arrival_time: f.arrival_time,
        passengers, travel_class: args.travel_class, payment_method: args.payment_method,
        price_each: each, total: each * passengers.length,
      },
      note: 'ร่างการจองยังไม่ถูกบันทึก รอผู้ใช้กดปุ่มยืนยัน',
    };
  }
  if (name === 'query_data') {
    const { data, error } = await supabase.rpc('run_chat_query', { p_sql: String(args.sql ?? '') });
    if (error) return { error: error.message, sql: args.sql };
    const rows = data?.rows ?? [];
    return { sql: args.sql, row_count: rows.length, rows: rows.slice(0, 30) };
  }
  if (name === 'my_bookings') {
    const { data, error } = await supabase.from('v_flight_bookings')
      .select('booking_ref, flight_no, origin_code, destination_code, departure_time, passenger_name, seat_no, travel_class, price, booking_status')
      .order('departure_time', { ascending: false }).limit(15);
    if (error) return { error: error.message };
    return { bookings: (data ?? []).map((b: Record<string, string>) => ({ ...b, departure_time: th(b.departure_time) })) };
  }
  if (name === 'plan_connection') {
    const term = `%${String(args.destination_name ?? '').replace(/^(สถานี|ป้าย)/, '').trim()}%`;
    const { data: st } = await supabase.from('stations').select('station_id, station_name').ilike('station_name', term).limit(1);
    const { data: bs } = st?.length ? { data: [] } : await supabase.from('bus_stops').select('stop_id, stop_name').ilike('stop_name', term).limit(1);
    const dest = st?.[0] ? { type: 'STATION', id: st[0].station_id } : bs?.[0] ? { type: 'BUS_STOP', id: bs[0].stop_id } : null;
    if (!dest) return { error: 'ไม่พบสถานีหรือป้ายรถเมล์ชื่อนี้' };
    const { data, error } = await supabase.rpc('plan_trip', {
      p_flight_id: args.flight_id, p_dest_type: dest.type, p_dest_id: dest.id, p_card_type: args.card_type || 'Adult',
    });
    if (error) return { error: error.message };
    return data;
  }
  return { error: 'ไม่รู้จักเครื่องมือนี้' };
}

// เก็บประวัติไม่เกิน 30 ส่วน และต้องเริ่มที่ข้อความของผู้ใช้ (ไม่ตัดคู่ functionCall / functionResponse ขาด)
// deno-lint-ignore no-explicit-any
function trimHistory(h: any[]) {
  const out = h.slice(-30);
  while (out.length && !(out[0]?.role === 'user' && out[0]?.parts?.some((p: { text?: string }) => p.text))) out.shift();
  return out;
}

// ---------- จุดรับคำขอ ----------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (!GEMINI_KEY) return reply({ error: 'ยังไม่ได้ตั้งค่า GEMINI_API_KEY' }, 500);

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '',
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
  );
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return reply({ error: 'กรุณาเข้าสู่ระบบก่อนใช้งาน' }, 401);
  const { data: me } = await supabase.from('users').select('user_id, full_name, role').eq('auth_id', user.id).single();
  if (!AIRPORTS.length) {
    const { data: ap } = await supabase.from('airports').select('iata_code, airport_name, city').order('iata_code');
    AIRPORTS = ap ?? [];
  }

  const body = await req.json().catch(() => ({}));

  // ---------- ผู้ใช้กดปุ่ม "ยืนยันการจอง" → จองจริง (ไม่ผ่าน LLM) ----------
  if (body.action === 'confirm') {
    const d = body.draft ?? {};
    // ราคาและที่นั่งคำนวณใหม่ในฐานข้อมูลเสมอ ไม่เชื่อตัวเลขที่ส่งมาจากหน้าเว็บ
    const { data, error } = await supabase.rpc('book_flight', {
      p_flight_id: d.flight_id, p_passengers: d.passengers, p_class: d.travel_class, p_method: d.payment_method,
    });
    if (error) return reply({ error: error.message });
    const email = await sendEmail(data);
    await supabase.from('chat_logs').insert({
      user_id: me?.user_id ?? null, question: '[agent] ยืนยันการจอง ' + data.flight_no,
      generated_sql: `book_flight(${d.flight_id}, ${JSON.stringify(d.passengers)}, ${d.travel_class}, ${d.payment_method})`,
      answer: `จองสำเร็จ ${data.booking_ref}` + (email.sent ? ' · ส่งอีเมลแล้ว' : ''), row_count: d.passengers?.length ?? 0,
      status: 'SUCCESS', llm_model: null, latency_ms: null,
    });
    return reply({ booking: data, email });
  }

  // ---------- ยกเลิกการจอง (กฎ 24 ชั่วโมง / สิทธิ์ผู้ดูแล ตรวจในฟังก์ชัน cancel_booking) ----------
  if (body.action === 'cancel') {
    const { data, error } = await supabase.rpc('cancel_booking', { p_booking_ref: body.booking_ref, p_reason: body.reason ?? null });
    if (error) return reply({ error: error.message });
    const email = await postMail(data.email, `ยกเลิกการจอง ${data.booking_ref} · ${data.flight_no}`, cancelHtml(data));
    await supabase.from('chat_logs').insert({
      user_id: me?.user_id ?? null, question: '[agent] ยกเลิกการจอง ' + data.booking_ref,
      generated_sql: `cancel_booking('${data.booking_ref}')`, answer: `ยกเลิกแล้ว คืนเงิน ${data.refund} บาท`,
      row_count: 1, status: 'SUCCESS', llm_model: null, latency_ms: null,
    });
    return reply({ cancelled: data, email });
  }

  const message = String(body.message ?? '').slice(0, 500);
  // deno-lint-ignore no-explicit-any
  const history: any[] = trimHistory(Array.isArray(body.history) ? body.history : []);
  if (!message) return reply({ error: 'กรุณาพิมพ์ข้อความ' }, 400);

  const contents = [...history, { role: 'user', parts: [{ text: message }] }];
  const system = systemPrompt(me?.full_name ?? 'ผู้ใช้', me?.role ?? 'passenger', airportList());
  const events: { tool: string; args: unknown; ok: boolean; summary: string; sql?: string; rows?: unknown[] }[] = [];
  let proposal = null, model = MODEL, text = '';

  try {
    for (let step = 0; step < MAX_STEPS; step++) {
      const out = await callGemini(contents, system);
      model = out.model;
      contents.push(out.content);                                    // เก็บทั้ง content (รวม thought signature)
      const calls = (out.content.parts ?? []).filter((p: { functionCall?: unknown }) => p.functionCall);
      if (!calls.length) {
        text = (out.content.parts ?? []).filter((p: { thought?: boolean }) => !p.thought)
          .map((p: { text?: string }) => p.text ?? '').join('').trim();
        break;
      }
      const responses = [];
      for (const c of calls) {
        const { name, args } = c.functionCall;
        const result = await runTool(supabase, name, args ?? {});
        // deno-lint-ignore no-explicit-any
        const r = result as any;
        if (name === 'propose_booking' && r.draft) proposal = r.draft;
        events.push({
          tool: name, args, ok: !r.error,
          summary: r.error ? r.error
            : name === 'search_flights' ? `พบ ${r.flights.length} เที่ยวบิน`
            : name === 'propose_booking' ? `ร่างการจอง ${r.draft.flight_no} · รอยืนยัน`
            : name === 'my_bookings' ? `พบ ${r.bookings.length} ตั๋ว`
            : name === 'query_data' ? `ได้ ${r.row_count} แถว`
            : `รวม ${r.total_fare} บาท`,
        });
        if (name === 'query_data') Object.assign(events[events.length - 1], { sql: r.sql, rows: r.rows ?? [] });
        responses.push({ functionResponse: { name, response: { result } } });
      }
      contents.push({ role: 'user', parts: responses });
    }
  } catch (e) {
    return reply({ error: 'เชื่อมต่อ LLM ไม่สำเร็จ: ' + (e instanceof Error ? e.message : String(e)), events }, 200);
  }

  // บันทึกลง chat_logs (ใช้ตารางเดียวกับระบบ Chat)
  await supabase.from('chat_logs').insert({
    user_id: me?.user_id ?? null, question: '[agent] ' + message,
    generated_sql: events.length ? events.map((e) => `${e.tool}(${JSON.stringify(e.args)})`).join('\n') : null,
    answer: text, row_count: events.length, status: 'SUCCESS', llm_model: model, latency_ms: null,
  });

  return reply({ text, events, proposal, model, history: trimHistory(contents) });
});
