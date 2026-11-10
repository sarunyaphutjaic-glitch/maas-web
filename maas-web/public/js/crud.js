import { supabase } from './supabaseClient.js';

// =========================================================
// CRUD ที่ใช้ซ้ำได้: กำหนดตาราง คอลัมน์ และฟอร์มผ่าน config
// ใช้กับ "เที่ยวบิน" (สมาชิกคนที่ 1) และ "ตารางเดินรถ" (สมาชิกคนที่ 3)
// =========================================================
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const thTime = (ts) => (ts ? new Date(ts).toLocaleString('th-TH', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Bangkok' }) : '–');
// timestamptz ↔ ช่อง datetime-local (เวลาไทย)
const toLocalInput = (ts) => (ts ? new Date(ts).toLocaleString('sv-SE', { timeZone: 'Asia/Bangkok' }).replace(' ', 'T').slice(0, 16) : '');
const fromLocalInput = (v) => (v ? `${v}:00+07:00` : null);

function thaiDbError(err) {
  switch (err?.code) {
    case '23503': return 'ทำรายการไม่ได้ เพราะมีข้อมูลอื่นอ้างถึงอยู่ (เช่น ตั๋วหรือการขึ้นรถ)';
    case '23505': return 'ข้อมูลซ้ำกับที่มีอยู่แล้ว: ' + (err.details || err.message);
    case '23514': return 'ค่าที่กรอกไม่ผ่านเงื่อนไขของฐานข้อมูล: ' + err.message;
    case '42501': return 'คุณไม่มีสิทธิ์ทำรายการนี้';
    default: return 'เกิดข้อผิดพลาด: ' + (err?.message || 'ไม่ทราบสาเหตุ');
  }
}

export function createCrud(cfg, role, notify) {
  const root = document.getElementById(cfg.mount);
  const canEdit = role === 'admin';
  let rows = [];
  let options = {};

  root.innerHTML = `
    <div class="panel-head">
      <div><h2>${esc(cfg.title)}</h2><p class="empty" data-count></p></div>
      ${canEdit ? `<button class="btn" type="button" data-add>${esc(cfg.addLabel)}</button>` : ''}
    </div>
    <div class="field"><label>ค้นหา</label><input type="search" data-search placeholder="${esc(cfg.searchHint)}"></div>
    <div data-table><p class="empty">กำลังโหลด…</p></div>
    <dialog data-dialog><form data-form novalidate>
      <h2 data-dtitle></h2>
      <div data-fields></div>
      <div class="dialog-actions">
        <button type="button" class="btn btn-ghost" data-close>ยกเลิก</button>
        <button type="submit" class="btn" data-submit>บันทึก</button>
      </div>
    </form></dialog>`;
  const q = (sel) => root.querySelector(sel);

  q('[data-search]').addEventListener('input', render);
  q('[data-close]').addEventListener('click', () => q('[data-dialog]').close());
  q('[data-form]').addEventListener('submit', save);
  q('[data-add]')?.addEventListener('click', () => open(null));
  q('[data-table]').addEventListener('click', (e) => {
    const id = e.target.dataset.edit ?? e.target.dataset.delete;
    if (!id) return;
    const row = rows.find((r) => String(r[cfg.pk]) === id);
    if (e.target.dataset.edit) open(row); else remove(row);
  });

  async function load() {
    const { data, error } = await supabase.from(cfg.table).select(cfg.select).order(cfg.order.col, { ascending: cfg.order.asc });
    if (error) { q('[data-table]').innerHTML = `<p class="notice error">${esc(thaiDbError(error))}</p>`; return; }
    rows = data;
    render();
  }

  function render() {
    const term = q('[data-search]').value.trim().toLowerCase();
    const shown = term ? rows.filter((r) => cfg.columns.some((c) => String(c.value(r) ?? '').toLowerCase().includes(term))) : rows;
    q('[data-count]').textContent = `${shown.length} จาก ${rows.length} รายการ`;
    q('[data-table]').innerHTML = shown.length ? `
      <div class="table-wrap crud-scroll"><table>
        <thead><tr>${cfg.columns.map((c) => `<th${c.num ? ' class="num"' : ''}>${esc(c.label)}</th>`).join('')}${canEdit ? '<th></th>' : ''}</tr></thead>
        <tbody>${shown.map((r) => `<tr>${cfg.columns.map((c) => `<td${c.num ? ' class="num"' : ''}>${c.html ? c.html(r) : esc(c.value(r))}</td>`).join('')}
          ${canEdit ? `<td class="row-actions"><button class="btn-small" data-edit="${r[cfg.pk]}">แก้ไข</button><button class="btn-small danger" data-delete="${r[cfg.pk]}">ลบ</button></td>` : ''}</tr>`).join('')}
        </tbody></table></div>` : '<p class="empty">ไม่พบรายการ</p>';
  }

  async function loadOptions() {
    for (const f of cfg.fields.filter((x) => x.type === 'select' && x.source)) {
      const { data } = await supabase.from(f.source.table).select(f.source.select).order(f.source.order);
      options[f.name] = (data || []).map((d) => ({ value: d[f.source.value], label: f.source.label(d) }));
    }
  }

  async function open(row) {
    if (!Object.keys(options).length) await loadOptions();
    q('[data-dtitle]').textContent = row ? `แก้ไข ${cfg.rowName(row)}` : cfg.addLabel;
    q('[data-fields]').innerHTML = cfg.fields.map((f) => {
      const v = row ? row[f.name] : f.default ?? '';
      const id = `${cfg.mount}-${f.name}`;
      let input;
      if (f.type === 'select') {
        const opts = f.source ? options[f.name] : f.options;
        input = `<select id="${id}" name="${f.name}">${opts.map((o) =>
          `<option value="${esc(o.value)}"${String(o.value) === String(v) ? ' selected' : ''}>${esc(o.label)}</option>`).join('')}</select>`;
      } else if (f.type === 'datetime') {
        input = `<input id="${id}" name="${f.name}" type="datetime-local" value="${toLocalInput(v)}" required>`;
      } else {
        input = `<input id="${id}" name="${f.name}" type="${f.type || 'text'}" value="${esc(v)}" ${f.attrs || ''} required>`;
      }
      return `<div class="field"><label for="${id}">${esc(f.label)}</label>${input}</div>`;
    }).join('');
    q('[data-form]').dataset.id = row ? row[cfg.pk] : '';
    q('[data-dialog]').showModal();
  }

  async function save(e) {
    e.preventDefault();
    const form = q('[data-form]');
    const values = {};
    for (const f of cfg.fields) {
      const raw = form.elements[f.name].value;
      if (raw === '') return alert(`กรอก ${f.label}`);
      values[f.name] = f.type === 'datetime' ? fromLocalInput(raw)
        : f.type === 'number' || (f.type === 'select' && f.source) ? Number(raw) : raw.trim();
    }
    const id = form.dataset.id;
    const res = id
      ? await supabase.from(cfg.table).update(values).eq(cfg.pk, id).select()
      : await supabase.from(cfg.table).insert(values).select();
    if (res.error) return notify(thaiDbError(res.error), true);
    if (!res.data?.length) return notify('คุณไม่มีสิทธิ์ทำรายการนี้', true);
    q('[data-dialog]').close();
    notify(`${id ? 'บันทึก' : 'เพิ่ม'} ${cfg.rowName(res.data[0])} แล้ว`);
    load();
  }

  async function remove(row) {
    if (!confirm(`ลบ ${cfg.rowName(row)}?`)) return;
    const { data, error } = await supabase.from(cfg.table).delete().eq(cfg.pk, row[cfg.pk]).select();
    if (error) return notify(thaiDbError(error), true);
    if (!data?.length) return notify('คุณไม่มีสิทธิ์ลบรายการนี้', true);
    notify(`ลบ ${cfg.rowName(row)} แล้ว`);
    load();
  }

  load();
}

// ---------------------------------------------------------
// ตั้งค่า: เที่ยวบิน (สมาชิกคนที่ 1)
// ---------------------------------------------------------
const FLIGHT_STATUS = { SCHEDULED: 'ตามกำหนด', DEPARTED: 'ออกแล้ว', ARRIVED: 'ถึงแล้ว', CANCELLED: 'ยกเลิก' };
export const FLIGHTS = {
  mount: 'crud-flights', table: 'flights', pk: 'flight_id',
  title: 'เที่ยวบิน', addLabel: 'เพิ่มเที่ยวบิน', searchHint: 'เช่น MA101, BKK, CNX',
  select: 'flight_id, flight_no, origin_airport_id, destination_airport_id, aircraft_id, departure_time, arrival_time, base_price, status, origin:airports!fk_flights_origin(iata_code), dest:airports!fk_flights_destination(iata_code), aircrafts(registration_no, model)',
  order: { col: 'departure_time', asc: false },
  rowName: (r) => `เที่ยวบิน ${r.flight_no}`,
  columns: [
    { label: 'เที่ยวบิน', value: (r) => r.flight_no },
    { label: 'เส้นทาง', value: (r) => `${r.origin?.iata_code ?? ''} → ${r.dest?.iata_code ?? ''}` },
    { label: 'ออกเดินทาง', value: (r) => thTime(r.departure_time) },
    { label: 'เครื่องบิน', value: (r) => `${r.aircrafts?.registration_no ?? ''} ${r.aircrafts?.model ?? ''}` },
    { label: 'ราคา', num: true, value: (r) => Number(r.base_price).toLocaleString('th-TH') },
    { label: 'สถานะ', value: (r) => FLIGHT_STATUS[r.status], html: (r) => `<span class="status" data-status="${r.status === 'CANCELLED' ? 'BLOCKED' : 'ACTIVE'}">${FLIGHT_STATUS[r.status]}</span>` },
  ],
  fields: [
    { name: 'flight_no', label: 'เลขเที่ยวบิน', attrs: 'maxlength="10" placeholder="MA701"' },
    { name: 'origin_airport_id', label: 'สนามบินต้นทาง', type: 'select', source: { table: 'airports', select: 'airport_id, iata_code, city', order: 'iata_code', value: 'airport_id', label: (a) => `${a.iata_code} · ${a.city}` } },
    { name: 'destination_airport_id', label: 'สนามบินปลายทาง', type: 'select', source: { table: 'airports', select: 'airport_id, iata_code, city', order: 'iata_code', value: 'airport_id', label: (a) => `${a.iata_code} · ${a.city}` } },
    { name: 'aircraft_id', label: 'เครื่องบิน', type: 'select', source: { table: 'aircrafts', select: 'aircraft_id, registration_no, model, total_seats', order: 'registration_no', value: 'aircraft_id', label: (a) => `${a.registration_no} · ${a.model} (${a.total_seats} ที่นั่ง)` } },
    { name: 'departure_time', label: 'เวลาออก (เวลาไทย)', type: 'datetime' },
    { name: 'arrival_time', label: 'เวลาถึง (เวลาไทย)', type: 'datetime' },
    { name: 'base_price', label: 'ราคาชั้นประหยัด (บาท)', type: 'number', attrs: 'min="1" step="1"' },
    { name: 'status', label: 'สถานะ', type: 'select', default: 'SCHEDULED', options: Object.entries(FLIGHT_STATUS).map(([value, label]) => ({ value, label })) },
  ],
};

// ---------------------------------------------------------
// ตั้งค่า: ตารางเดินรถ (สมาชิกคนที่ 3)
// ---------------------------------------------------------
export const SCHEDULES = {
  mount: 'crud-schedules', table: 'bus_schedules', pk: 'schedule_id',
  title: 'ตารางเดินรถ', addLabel: 'เพิ่มรอบวิ่ง', searchHint: 'เช่น สาย 29, ชื่อคนขับ, ทะเบียนรถ',
  select: 'schedule_id, route_id, bus_id, driver_id, departure_time, bus_routes(route_no, route_name), buses(plate_no, bus_type), drivers(full_name), trip_logs(actual_departure)',
  order: { col: 'departure_time', asc: false },
  rowName: (r) => `รอบสาย ${r.bus_routes?.route_no ?? ''} เวลา ${thTime(r.departure_time)}`,
  columns: [
    { label: 'สาย', value: (r) => `${r.bus_routes?.route_no} · ${r.bus_routes?.route_name}` },
    { label: 'เวลาออก', value: (r) => thTime(r.departure_time) },
    { label: 'รถ', value: (r) => `${r.buses?.plate_no} (${r.buses?.bus_type})` },
    { label: 'คนขับ', value: (r) => r.drivers?.full_name },
    { label: 'ออกช้า', num: true, value: (r) => {
      const t = Array.isArray(r.trip_logs) ? r.trip_logs[0] : r.trip_logs;
      return t ? `${Math.round((new Date(t.actual_departure) - new Date(r.departure_time)) / 60000)} นาที` : 'ยังไม่วิ่ง';
    } },
  ],
  fields: [
    { name: 'route_id', label: 'สายรถเมล์', type: 'select', source: { table: 'bus_routes', select: 'route_id, route_no, route_name', order: 'route_no', value: 'route_id', label: (r) => `สาย ${r.route_no} · ${r.route_name}` } },
    { name: 'bus_id', label: 'รถ', type: 'select', source: { table: 'buses', select: 'bus_id, plate_no, bus_type', order: 'plate_no', value: 'bus_id', label: (b) => `${b.plate_no} (${b.bus_type})` } },
    { name: 'driver_id', label: 'พนักงานขับรถ', type: 'select', source: { table: 'drivers', select: 'driver_id, full_name', order: 'full_name', value: 'driver_id', label: (d) => d.full_name } },
    { name: 'departure_time', label: 'เวลาออก (เวลาไทย)', type: 'datetime' },
  ],
};
