// =====================================================
// Supabase Edge Function: chat
// วิธี B: Text-to-SQL
//   คำถาม → Gemini สร้าง SQL → run_chat_query (อ่านอย่างเดียว + RLS)
//   → Gemini สรุปคำตอบจากผลลัพธ์จริง → บันทึก chat_logs
// Secret ที่ต้องตั้ง: GEMINI_API_KEY (และ GEMINI_MODEL ถ้าต้องการเปลี่ยนรุ่น)
// =====================================================
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-3.8-flash';
// ระดับการ "คิด" ของ Gemini: low = ตอบเร็ว เหมาะกับงานแปลงคำถามเป็น SQL
const THINKING = Deno.env.get('GEMINI_THINKING') || 'low';
const CALL_TIMEOUT_MS = 40_000;   // ตัดการเรียก Gemini ที่นานเกิน เพื่อให้ตอบ error ได้ทันก่อน function หมดเวลา
// รุ่นสำรองเมื่อรุ่นหลักคนใช้เยอะ (คั่นด้วย , ) เช่น ตั้ง Secret GEMINI_FALLBACK_MODELS
const FALLBACK_MODELS = (Deno.env.get('GEMINI_FALLBACK_MODELS') || '')
  .split(',').map((m) => m.trim()).filter(Boolean);
let usedModel = MODEL;   // รุ่นที่ตอบสำเร็จจริงในคำขอนี้
const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY');

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ---------- คำอธิบาย View ที่เปิดให้ LLM ใช้ ----------
// public = ผู้โดยสารใช้ได้ (ข้อมูลสาธารณะ หรือ RLS กรองเหลือของตัวเอง), admin = ผู้ดูแลเท่านั้น
const VIEWS: { name: string; who: 'public' | 'admin'; desc: string }[] = [
  { name: 'v_fare_lookup', who: 'public', desc: `ค่าโดยสาร BTS ระหว่างสถานี
  origin_station, origin_code, destination_station, destination_code (ชื่อสถานีภาษาไทย เช่น 'สยาม', 'อโศก'),
  adult_fare, student_fare, senior_fare (บาท)` },
  { name: 'v_flight_schedule', who: 'public', desc: `ตารางเที่ยวบิน
  flight_no, origin_code, origin_city, destination_code, destination_city (เช่น 'เชียงใหม่', 'ภูเก็ต'),
  departure_time, arrival_time, flight_date, base_price, flight_status ('SCHEDULED' | 'ARRIVED' | 'CANCELLED')
  (รหัส: BKK สุวรรณภูมิ, DMK ดอนเมือง, CNX เชียงใหม่, HKT ภูเก็ต, HDY หาดใหญ่, KBV กระบี่, USM สมุย, UTH อุดรธานี)` },
  { name: 'v_bus_route_stops', who: 'public', desc: `ป้ายของรถเมล์แต่ละสาย (1 แถว = 1 ป้ายในสาย) ใช้ตอบว่าสายไหนผ่านป้ายไหน
  route_no ('2','25','29','77','15','76'), route_name, fare, sequence_no, stop_code,
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

function sqlPrompt(role: string) {
  const isPassenger = role === 'passenger';
  const views = VIEWS.filter((v) => !isPassenger || v.who === 'public');
  const schema = views.map((v) => `${v.name} — ${v.desc}`).join('\n\n');
  const scope = isPassenger
    ? `ผู้ถามเป็น "ผู้โดยสาร" ตอบได้เฉพาะ
  1) ข้อมูลสาธารณะ: ค่าโดยสาร BTS, ตารางเที่ยวบิน, สายและป้ายรถเมล์, การต่อรถ
  2) ข้อมูลการเดินทาง ตั๋ว และค่าใช้จ่ายของตัวเอง (ระบบกรองให้เหลือของตัวเองอยู่แล้ว)
ห้ามตอบเรื่องรายได้ สถิติรวมของระบบ ข้อมูลของผู้ใช้คนอื่น พนักงาน หรือข้อมูลหลังบ้าน
และห้ามตอบเรื่องที่ไม่เกี่ยวกับการเดินทาง ให้ปฏิเสธ (sql = null) พร้อมบอกสั้นๆ ว่าถามเรื่องอะไรได้บ้าง`
    : `ผู้ถามเป็นผู้ดูแลระบบ ใช้ View ได้ทั้งหมดด้านล่าง`;

  return `คุณคือผู้ช่วยแปลงคำถาม (ภาษาไทยหรืออังกฤษ) ให้เป็นคำสั่ง SQL ของ PostgreSQL
สำหรับระบบขนส่ง MaaS (รถไฟฟ้า BTS, สายการบิน, รถเมล์) ข้อมูลส่วนใหญ่อยู่ในช่วง 1 ต.ค. – 9 พ.ย. 2026 (พ.ศ. 2569)
และมีเที่ยวบินล่วงหน้าถึง 20 พ.ย. 2026

${scope}

ใช้ได้เฉพาะ View ต่อไปนี้เท่านั้น ห้ามใช้ตารางหรือ View อื่น:
${schema}

กติกา
- เขียนเฉพาะ SELECT คำสั่งเดียว ไม่มีเครื่องหมาย ; ท้ายคำสั่ง
- ใส่ LIMIT ไม่เกิน 50 เมื่อผลลัพธ์อาจมีหลายแถว
- ถ้าคำถามเป็นปีพุทธศักราช ให้ลบ 543 เป็นคริสต์ศักราช
- ตั้งชื่อคอลัมน์ผลลัพธ์ให้อ่านเข้าใจ (ภาษาอังกฤษ snake_case)
- ค้นหาข้อความ (ชื่อสถานี ชื่อคน ชื่อป้าย ชื่อสาย) ด้วย ILIKE '%คำค้น%' แทนการเทียบเท่ากันตรงๆ
- พยายามตอบด้วยคอลัมน์ที่มีให้มากที่สุดก่อน ถ้าพอหาคำตอบได้จาก View ที่อนุญาต ให้เขียน SQL เสมอ
- ปฏิเสธ (sql เป็น null พร้อมเหตุผลสั้นๆ ภาษาไทยใน reason) เมื่อ
  1) คำถามขอให้เพิ่ม แก้ไข ลบ ข้อมูล หรือเปลี่ยนโครงสร้าง
  2) คำถามไม่เกี่ยวกับข้อมูลใน View ที่อนุญาต หรือขออ่านตารางอื่นโดยตรง

ตอบเป็น JSON เท่านั้น รูปแบบ {"sql": "..." หรือ null, "reason": "..."}`;
}

const ANSWER_PROMPT = `คุณคือผู้ช่วยตอบคำถามจากข้อมูลในฐานข้อมูล
จะได้รับ คำถาม, SQL ที่ใช้ และผลลัพธ์ (rows) ให้ตอบเป็นภาษาไทย 1–3 ประโยค กระชับ
ใช้เฉพาะตัวเลขและข้อมูลที่อยู่ใน rows เท่านั้น ห้ามเดาหรือเพิ่มข้อมูลเอง
ถ้า rows ว่าง ให้บอกว่าไม่พบข้อมูลที่ตรงกับคำถาม`;

// ---------- เรียก Gemini ----------
async function callGemini(model: string, system: string, user: string, json: boolean, thinking: boolean) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': GEMINI_KEY ?? '' },
      signal: AbortSignal.timeout(CALL_TIMEOUT_MS),
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: 'user', parts: [{ text: user }] }],
        generationConfig: {
          temperature: 0,
          ...(json ? { responseMimeType: 'application/json' } : {}),
          ...(thinking ? { thinkingConfig: { thinkingLevel: THINKING } } : {}),
        },
      }),
    },
  );
  const data = await res.json();
  return { ok: res.ok, status: res.status, data };
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// 429 = เกินโควตาชั่วคราว, 500/503 = เซิร์ฟเวอร์ Google คนใช้เยอะ → ลองใหม่ได้
const BUSY = (status: number) => status === 429 || status === 500 || status === 503;

async function gemini(system: string, user: string, json: boolean) {
  let lastError = '';
  for (const model of [MODEL, ...FALLBACK_MODELS]) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      let r;
      try {
        r = await callGemini(model, system, user, json, true);
        // รุ่นที่ไม่รองรับการตั้งค่า thinking → เรียกใหม่โดยไม่ส่งค่านี้
        if (!r.ok && /thinking/i.test(r.data?.error?.message ?? '')) {
          r = await callGemini(model, system, user, json, false);
        }
      } catch (e) {
        if (e instanceof DOMException && e.name === 'TimeoutError') {
          lastError = `${model} ตอบช้าเกิน ${CALL_TIMEOUT_MS / 1000} วินาที`;
          break;                                   // ช้าเกิน → ไปรุ่นถัดไปเลย
        }
        throw e;
      }

      if (r.ok) {
        usedModel = model;
        const text = r.data?.candidates?.[0]?.content?.parts
          ?.filter((p: { thought?: boolean }) => !p.thought)
          .map((p: { text?: string }) => p.text ?? '').join('') ?? '';
        if (!json) return text.trim();
        return JSON.parse(text.replace(/```json|```/g, '').trim());
      }

      lastError = r.data?.error?.message || `Gemini HTTP ${r.status}`;
      if (!BUSY(r.status)) throw new Error(lastError);   // error อื่น เช่น key ผิด → หยุดเลย
      if (attempt === 1) await sleep(1500);              // คนใช้เยอะ → รอแล้วลองอีกครั้ง
    }
  }
  throw new Error(lastError + ' (ลองใหม่อีกครั้งในอีกสักครู่)');
}

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// ---------- จุดรับคำขอ ----------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (!GEMINI_KEY) return reply({ error: 'ยังไม่ได้ตั้งค่า GEMINI_API_KEY ใน Secrets' }, 500);

  // ใช้ token ของผู้ใช้ที่ login อยู่ → ทุก query ผ่าน RLS ตามสิทธิ์ของคนถาม
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '',
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
  );
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return reply({ error: 'กรุณาเข้าสู่ระบบก่อนใช้งาน' }, 401);

  // สิทธิ์ของผู้ถาม (ใช้เลือกคำอธิบาย View ที่ส่งให้ LLM)
  const { data: me } = await supabase.from('users').select('user_id, role').eq('auth_id', user.id).single();
  const SQL_PROMPT = sqlPrompt(me?.role ?? 'passenger');

  const { question } = await req.json().catch(() => ({}));
  if (!question || typeof question !== 'string' || question.length > 500) {
    return reply({ error: 'กรุณาพิมพ์คำถาม (ไม่เกิน 500 ตัวอักษร)' }, 400);
  }

  usedModel = MODEL;
  const started = Date.now();
  let sql: string | null = null;
  let rows: unknown[] = [];
  let answer = '';
  let status: 'SUCCESS' | 'ERROR' | 'REJECTED' = 'SUCCESS';

  try {
    // 1) ให้ Gemini สร้าง SQL
    const gen = await gemini(SQL_PROMPT, question, true);
    if (!gen?.sql) {
      status = 'REJECTED';
      answer = gen?.reason || 'ไม่สามารถตอบคำถามนี้จากข้อมูลในระบบได้';
    } else {
      sql = String(gen.sql).trim();
      // 2) รัน SQL แบบอ่านอย่างเดียว
      let { data, error } = await supabase.rpc('run_chat_query', { p_sql: sql });

      // SQL ผิดไวยากรณ์ → ให้ Gemini แก้ 1 ครั้ง (ยกเว้นถูกบล็อกด้วยเหตุผลความปลอดภัย)
      if (error && error.code !== 'P0001') {
        const fix = await gemini(SQL_PROMPT,
          `${question}\n\nSQL เดิมผิดพลาด: ${sql}\nข้อความ error: ${error.message}\nช่วยแก้ SQL ให้ถูกต้อง`, true);
        if (fix?.sql) {
          sql = String(fix.sql).trim();
          ({ data, error } = await supabase.rpc('run_chat_query', { p_sql: sql }));
        }
      }

      if (error) {
        status = error.code === 'P0001' ? 'REJECTED' : 'ERROR';
        answer = (status === 'REJECTED' ? 'ระบบปฏิเสธคำสั่งนี้: ' : 'รันคำสั่งไม่สำเร็จ: ') + error.message;
      } else {
        rows = data?.rows ?? [];
        // 3) ให้ Gemini สรุปคำตอบจากผลลัพธ์จริง (ส่งไปไม่เกิน 30 แถว)
        answer = await gemini(ANSWER_PROMPT,
          JSON.stringify({ question, sql, total_rows: rows.length, rows: rows.slice(0, 30) }), false);
      }
    }
  } catch (e) {
    status = 'ERROR';
    answer = 'เชื่อมต่อ LLM ไม่สำเร็จ: ' + (e instanceof Error ? e.message : String(e));
  }

  const latency = Date.now() - started;

  // 4) บันทึกประวัติลง chat_logs (RLS อนุญาตให้บันทึกเฉพาะของตัวเอง)
  await supabase.from('chat_logs').insert({
    user_id: me?.user_id ?? null,
    question,
    generated_sql: sql,
    answer,
    row_count: rows.length,
    status,
    llm_model: usedModel,
    latency_ms: latency,
  });

  return reply({ answer, sql, rows, status, model: usedModel, latency_ms: latency });
});
