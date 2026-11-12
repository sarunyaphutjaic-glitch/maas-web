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
      description: 'ค้นหาเที่ยวบินที่ยังจองได้ (ยังไม่ออก) ตามเมืองหรือรหัสสนามบิน และวันที่',
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
          passengers: { type: 'ARRAY', items: { type: 'STRING' }, description: 'ชื่อผู้เดินทาง 1–4 คน' },
          travel_class: { type: 'STRING', enum: ['ECONOMY', 'BUSINESS'] },
          payment_method: { type: 'STRING', enum: ['CREDIT_CARD', 'QR', 'MOBILE_BANKING'] },
        },
        required: ['flight_id', 'passengers', 'travel_class', 'payment_method'],
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

function systemPrompt(name: string) {
  const now = new Date().toLocaleString('th-TH', { timeZone: 'Asia/Bangkok', dateStyle: 'full', timeStyle: 'short' });
  return `คุณคือ "MaaS Agent" ผู้ช่วยจองตั๋วเครื่องบินของระบบ MaaS พูดภาษาไทย สุภาพ กระชับ
ผู้ใช้ชื่อ ${name} · เวลาปัจจุบัน (เวลาไทย UTC+07): ${now}

ขั้นตอนการทำงาน
1. ถามข้อมูลที่ขาด: ปลายทาง วันที่ จำนวนและชื่อผู้เดินทาง ชั้นโดยสาร (ECONOMY / BUSINESS) ช่องทางชำระ
2. ใช้ search_flights หาเที่ยวบิน แล้วแสดงเป็นรายการ: เลขเที่ยวบิน เส้นทาง วันเวลา (เวลาไทย) ราคา
3. เมื่อได้ข้อมูลครบ เรียก propose_booking เพื่อสร้างร่างการจอง แล้วบอกผู้ใช้สั้นๆ ให้ตรวจรายละเอียดในการ์ด
   และกดปุ่ม "ยืนยันการจอง" (คุณจองเองไม่ได้ การจองจริงเกิดเมื่อผู้ใช้กดปุ่มเท่านั้น)
4. ถ้าระบบแจ้งว่าจองสำเร็จแล้ว และเที่ยวบินลงสุวรรณภูมิหรือดอนเมือง เสนอวางแผนต่อ BTS / รถเมล์ด้วย plan_connection

กติกา
- ใช้เฉพาะข้อมูลจากเครื่องมือ ห้ามแต่งเที่ยวบิน ราคา หรือรหัสการจองขึ้นเอง
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
  if (!MAIL_URL) return { sent: false, reason: 'ยังไม่ได้ตั้งค่า APPS_SCRIPT_URL' };
  const passengers = (b.passengers as string[]).map((p, i) => `<li>${p} — ที่นั่ง ${(b.seats as string[])[i]}</li>`).join('');
  const html = `
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
  try {
    const res = await fetch(MAIL_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: MAIL_TOKEN, to: b.email, subject: `ยืนยันการจอง ${b.booking_ref} · ${b.flight_no}`, html }),
      redirect: 'follow',
    });
    const text = await res.text();
    let ok = res.ok;
    try { ok = ok && JSON.parse(text).ok === true; } catch { /* Apps Script อาจตอบเป็นหน้า HTML */ }
    return ok ? { sent: true, to: b.email } : { sent: false, reason: text.slice(0, 200) };
  } catch (e) {
    return { sent: false, reason: e instanceof Error ? e.message : String(e) };
  }
}

// ---------- ทำงานตามเครื่องมือที่ LLM เรียก ----------
// deno-lint-ignore no-explicit-any
async function runTool(supabase: any, name: string, args: Record<string, any>) {
  if (name === 'search_flights') {
    let q = supabase.from('v_flight_schedule').select('*')
      .eq('flight_status', 'SCHEDULED').gt('departure_time', new Date().toISOString())
      .order('departure_time').limit(10);
    const dest = String(args.destination ?? '').trim();
    if (/^[A-Za-z]{3}$/.test(dest)) q = q.eq('destination_code', dest.toUpperCase());
    else if (dest) q = q.ilike('destination_city', `%${dest}%`);
    const org = String(args.origin ?? '').trim();
    if (/^[A-Za-z]{3}$/.test(org)) q = q.eq('origin_code', org.toUpperCase());
    else if (org) q = q.ilike('origin_city', `%${org}%`);
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
  const { data: me } = await supabase.from('users').select('user_id, full_name').eq('auth_id', user.id).single();

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

  const message = String(body.message ?? '').slice(0, 500);
  // deno-lint-ignore no-explicit-any
  const history: any[] = trimHistory(Array.isArray(body.history) ? body.history : []);
  if (!message) return reply({ error: 'กรุณาพิมพ์ข้อความ' }, 400);

  const contents = [...history, { role: 'user', parts: [{ text: message }] }];
  const system = systemPrompt(me?.full_name ?? 'ผู้ใช้');
  const events: { tool: string; args: unknown; ok: boolean; summary: string }[] = [];
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
            : `รวม ${r.total_fare} บาท`,
        });
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
