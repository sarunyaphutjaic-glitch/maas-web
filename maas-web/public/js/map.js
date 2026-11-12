import { supabase } from './supabaseClient.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// สีตามโหมด (ตรงกับ css)
const COLOR = { SUK: '#7cc242', SIL: '#1d7a46', air: '#2f67d8', bus: '#e0a116', busLine: '#c98a00' };
const BANGKOK_CENTER = [13.738, 100.552];

let map;
let stats = '';
let trackSource = 'กำลังโหลดแนวรางจาก OpenStreetMap…';
const updateNote = () => { $('map-note').textContent = `${stats} — จุดทั้งหมดมาจากตาราง locations · เส้น BTS: ${trackSource}`; };

// ---------- แนวราง BTS จริงจาก OpenStreetMap (Overpass API) ----------
// ดึง route relation ของรถไฟฟ้า BTS ในกรอบกรุงเทพฯ แล้วแยกเป็นสายสุขุมวิท / สีลม · เก็บ cache ในเบราว์เซอร์ 30 วัน
const TRACK_CACHE = 'maas-bts-tracks-v1';
const OVERPASS = ['https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter'];
const OVERPASS_QUERY = `[out:json][timeout:25];
relation["route"~"^(train|subway|light_rail|monorail)$"](13.50,100.40,13.98,100.70);
out geom;`;

function lineOf(tags = {}) {
  const t = [tags.name, tags['name:en'], tags['name:th'], tags.ref, tags.network, tags.operator].join(' ').toLowerCase();
  if (!/bts|บีทีเอส/.test(t) && !/sukhumvit|สุขุมวิท|silom|สีลม/.test(t)) return null;
  if (/sukhumvit|สุขุมวิท/.test(t)) return 'SUK';
  if (/silom|สีลม/.test(t)) return 'SIL';
  return null;
}

// ---------- ตำแหน่งสถานีจริงจาก OpenStreetMap (ผู้ดูแลกดปรับพิกัดในฐานข้อมูล) ----------
const OVERPASS_STATIONS = `[out:json][timeout:25];
(node["railway"="station"](13.50,100.40,13.98,100.70);
 node["public_transport"="station"](13.50,100.40,13.98,100.70););
out;`;
const norm = (s) => String(s || '').replace(/^สถานี/, '').replace(/[\s.ฯ()\-–]/g, '').toLowerCase();

// จับคู่สถานีของเรากับ node ใน OSM: ชื่อตรงกัน > ชื่อขึ้นต้นเหมือนกัน · มีคำว่า BTS ได้คะแนนเพิ่ม · ห่างจากพิกัดเดิมไม่เกิน 3 กม.
function matchStations(ours, nodes) {
  const result = [], missing = [];
  ours.forEach((st) => {
    const want = norm(st.station_name);
    let best = null;
    nodes.forEach((n) => {
      const t = n.tags || {};
      const names = [t.name, t['name:th']].map(norm).filter(Boolean);
      let score = 0;
      if (names.includes(want)) score = 3;
      else if (names.some((x) => x.startsWith(want) || want.startsWith(x))) score = 2;
      if (!score) return;
      if (/bts/i.test([t.network, t.operator, t['name:en'], t.name].join(' '))) score += 1;
      const d = Math.hypot(n.lat - st.lat, (n.lon - st.lon) * Math.cos(st.lat * Math.PI / 180)) * 111320;
      if (d > 3000) return;
      if (!best || score > best.score || (score === best.score && d < best.d)) best = { score, d, n };
    });
    if (best) result.push({ code: st.station_code, lat: best.n.lat, lon: best.n.lon, moved_m: Math.round(best.d) });
    else missing.push(st.station_name);
  });
  return { result, missing };
}

async function syncStationsFromOSM(stationsData) {
  const btn = $('map-sync');
  const status = $('map-sync-status');
  btn.disabled = true;
  status.textContent = 'กำลังค้นหาตำแหน่งสถานีจาก OpenStreetMap…';
  let nodes = null;
  for (const url of OVERPASS) {
    try {
      const res = await fetch(url, { method: 'POST', body: 'data=' + encodeURIComponent(OVERPASS_STATIONS), signal: AbortSignal.timeout(25000) });
      if (res.ok) { nodes = (await res.json()).elements || []; break; }
    } catch { /* ลองเซิร์ฟเวอร์ถัดไป */ }
  }
  if (!nodes) { status.textContent = 'เชื่อมต่อ OpenStreetMap ไม่สำเร็จ ลองใหม่อีกครั้ง'; btn.disabled = false; return; }

  const ours = stationsData.map((s) => ({ station_code: s.station_code, station_name: s.station_name, lat: Number(s.locations.latitude), lon: Number(s.locations.longitude) }));
  const { result, missing } = matchStations(ours, nodes);
  const avg = result.length ? Math.round(result.reduce((a, r) => a + r.moved_m, 0) / result.length) : 0;
  const ok = confirm(`พบตำแหน่งจริง ${result.length} จาก ${ours.length} สถานี (คลาดเคลื่อนเดิมเฉลี่ย ${avg} เมตร)` +
    (missing.length ? `\nไม่พบ: ${missing.join(', ')} (คงพิกัดเดิม)` : '') + '\n\nบันทึกพิกัดใหม่ลงฐานข้อมูลไหม');
  if (!ok) { status.textContent = 'ยกเลิกการปรับพิกัด'; btn.disabled = false; return; }

  const { data, error } = await supabase.rpc('sync_station_locations', { p_points: result.map(({ code, lat, lon }) => ({ code, lat, lon })) });
  if (error) { status.textContent = 'บันทึกไม่สำเร็จ: ' + error.message; btn.disabled = false; return; }
  status.textContent = `ปรับพิกัดแล้ว ${data.stations_updated} สถานี · ย้ายป้ายรถเมล์ ${data.bus_stops_moved} ป้าย · กำลังโหลดแผนที่ใหม่…`;
  setTimeout(() => location.reload(), 1200);
}

async function loadRealTracks() {
  try {
    const cached = JSON.parse(localStorage.getItem(TRACK_CACHE) || 'null');
    if (cached && Date.now() - cached.at < 30 * 86400000) return cached.lines;
  } catch { /* ไม่มี cache */ }

  for (const url of OVERPASS) {
    try {
      const res = await fetch(url, { method: 'POST', body: 'data=' + encodeURIComponent(OVERPASS_QUERY), signal: AbortSignal.timeout(25000) });
      if (!res.ok) continue;
      const json = await res.json();
      const lines = { SUK: [], SIL: [] };
      const seen = new Set();
      (json.elements || []).forEach((rel) => {
        const code = lineOf(rel.tags);
        if (!code) return;
        (rel.members || []).forEach((m) => {
          if (m.type !== 'way' || !m.geometry || /platform|stop/.test(m.role || '') || seen.has(m.ref)) return;
          seen.add(m.ref);
          lines[code].push(m.geometry.map((p) => [p.lat, p.lon]));
        });
      });
      if (!lines.SUK.length && !lines.SIL.length) continue;
      try { localStorage.setItem(TRACK_CACHE, JSON.stringify({ at: Date.now(), lines })); } catch { /* เก็บไม่ได้ก็ใช้ต่อได้ */ }
      return lines;
    } catch { /* ลองเซิร์ฟเวอร์ถัดไป */ }
  }
  return null;
}
const layers = {};

export async function initMap() {
  if (map) { map.invalidateSize(); return; }

  map = L.map('map', { zoomControl: true, scrollWheelZoom: true }).setView(BANGKOK_CENTER, 13);
  // แสดงชื่อตามระดับซูม: ใกล้มากขึ้น = ชื่อมากขึ้น (กันชื่อซ้อนกันตอนซูมออก)
  const zoomClass = () => {
    const z = map.getZoom(), el = map.getContainer();
    el.classList.toggle('z12', z >= 12);
    el.classList.toggle('z13', z >= 13);
    el.classList.toggle('z14', z >= 14);
    el.classList.toggle('z15', z >= 15);
  };
  map.on('zoomend', zoomClass);
  zoomClass();
  // ภาพแผนที่พื้นหลัง (Tile Layer) ของ Leaflet: OpenStreetMap ใช้ฟรี ไม่ต้องมี API key
  const osm = L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  });
  const osmHot = L.tileLayer('https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png', {
    maxZoom: 19, subdomains: 'abc',
    attribution: '&copy; OpenStreetMap contributors, Tiles style by Humanitarian OpenStreetMap Team',
  });
  osm.addTo(map);
  L.control.layers({ 'OpenStreetMap (มาตรฐาน)': osm, 'OpenStreetMap (HOT)': osmHot }, null, { position: 'topright' }).addTo(map);

  const [stations, seqs, stops, routeStops, airports] = await Promise.all([
    supabase.from('stations').select('station_id, station_code, station_name, locations(latitude, longitude, district)'),
    supabase.from('station_sequences').select('sequence_no, station_id, lines(code, line_name)').order('sequence_no'),
    supabase.from('bus_stops').select('stop_id, stop_code, stop_name, locations(latitude, longitude)'),
    supabase.from('route_stops').select('sequence_no, stop_id, bus_routes(route_no, route_name)').order('sequence_no'),
    supabase.from('airports').select('iata_code, airport_name, city, locations(latitude, longitude)'),
  ]);
  const err = [stations, seqs, stops, routeStops, airports].find((r) => r.error);
  if (err) { $('map-note').textContent = 'โหลดข้อมูลแผนที่ไม่สำเร็จ: ' + err.error.message; return; }

  const stPos = Object.fromEntries(stations.data.map((s) => [s.station_id, [s.locations.latitude, s.locations.longitude]]));
  const stopPos = Object.fromEntries(stops.data.map((s) => [s.stop_id, [s.locations.latitude, s.locations.longitude]]));

  // ---------- เส้นและสถานี BTS ----------
  layers.rail = L.layerGroup();
  // เส้นราง: ใช้แนวรางจริงจาก OpenStreetMap ถ้าโหลดไม่ได้จะใช้เส้นตรงต่อสถานีตามลำดับใน station_sequences
  const byLine = {};
  seqs.data.forEach((r) => { (byLine[r.lines.code] ||= { name: r.lines.line_name, pts: [] }).pts.push(stPos[r.station_id]); });
  const tracks = L.layerGroup().addTo(layers.rail);
  const drawStraight = () => {
    tracks.clearLayers();
    Object.entries(byLine).forEach(([code, line]) => {
      L.polyline(line.pts, { color: COLOR[code] || COLOR.SIL, weight: 7, opacity: 0.95, lineCap: 'round' })
        .bindTooltip(line.name, { sticky: true, className: 'lbl-line' }).addTo(tracks);
    });
  };
  drawStraight();
  loadRealTracks().then((real) => {
    if (!real) { trackSource = 'เส้นตรงระหว่างสถานี (โหลดแนวรางจาก OpenStreetMap ไม่สำเร็จ)'; updateNote(); return; }
    tracks.clearLayers();
    Object.entries(real).forEach(([code, segs]) => {
      L.polyline(segs, { color: COLOR[code], weight: 6, opacity: 0.95, lineCap: 'round', lineJoin: 'round' })
        .bindTooltip(byLine[code]?.name || code, { sticky: true, className: 'lbl-line' }).addTo(tracks);
    });
    layers.rail.eachLayer((l) => l !== tracks && l.bringToFront?.());   // สถานีอยู่บนเส้น
    trackSource = 'แนวรางจริงจาก OpenStreetMap';
    updateNote();
  });
  // สายรถเมล์ที่จอดป้ายข้างสถานี (ป้ายรหัส B-<รหัสสถานี>)
  const routesOf = (stopId) => routeStops.data.filter((r) => r.stop_id === stopId)
    .map((r) => r.bus_routes.route_no).sort((a, b) => Number(a) - Number(b)).join(', ');
  const busAt = {};
  stops.data.forEach((b) => { if (b.stop_code.startsWith('B-')) busAt[b.stop_code.slice(2)] = routesOf(b.stop_id); });

  const linesOf = {};
  seqs.data.forEach((r) => { (linesOf[r.station_id] ||= []).push(r.lines.code); });
  stations.data.forEach((s) => {
    const codes = linesOf[s.station_id] || [];
    const hub = codes.length > 1;                      // สถานีร่วม (สยาม)
    L.circleMarker(stPos[s.station_id], {
      radius: hub ? 9 : 6, color: hub ? '#17221f' : (COLOR[codes[0]] || COLOR.SIL),
      weight: hub ? 3.5 : 3, fillColor: '#fff', fillOpacity: 1,
    })
      .bindTooltip(`${esc(s.station_name)}<small>${esc(s.station_code)}</small>${busAt[s.station_code]
        ? `<span class="lbl-busno">🚌 ${esc(busAt[s.station_code])}</span>` : ''}`, {
        // ตำแหน่งชื่อ: สายสีลมไว้ซ้าย, สถานีร่วมไว้บน, สายสุขุมวิทไว้ขวา (กันชื่อทับกันแถวสยาม)
        permanent: true,
        direction: hub ? 'top' : (codes.includes('SIL') ? 'left' : 'right'),
        offset: hub ? [0, -12] : (codes.includes('SIL') ? [-10, 0] : [10, 0]),
        className: `lbl lbl-rail${hub ? ' lbl-hub' : ''}${codes.includes('SIL') && !hub ? ' lbl-sil' : ''}`,
      })
      .bindPopup(`<div class="pop"><span class="pop-kind pop-rail">🚆 สถานี BTS</span><strong>${esc(s.station_name)}</strong>
        <span>${esc(s.station_code)} · เขต${esc(s.locations.district)}</span>
        <span>${codes.map((c) => (c === 'SUK' ? 'สายสุขุมวิท' : 'สายสีลม')).join(' · ')}</span>
        ${busAt[s.station_code] ? `<span>🚌 ต่อรถเมล์สาย ${esc(busAt[s.station_code])}</span>` : ''}</div>`)
      .addTo(layers.rail);
  });

  // ---------- สายและป้ายรถเมล์ ----------
  layers.bus = L.layerGroup();
  const byRoute = {};
  routeStops.data.forEach((r) => { (byRoute[r.bus_routes.route_no] ||= { name: r.bus_routes.route_name, pts: [] }).pts.push(stopPos[r.stop_id]); });
  Object.entries(byRoute).forEach(([no, route]) => {
    L.polyline(route.pts, { color: COLOR.busLine, weight: 3, opacity: 0.6, dashArray: '2 7', lineCap: 'round' })
      .bindTooltip(`รถเมล์สาย ${no} · ${route.name}`, { sticky: true, className: 'lbl-line' }).addTo(layers.bus);
  });
  const silom = new Set(seqs.data.filter((r) => r.lines.code === 'SIL').map((r) => r.station_id));
  const stationOfCode = Object.fromEntries(stations.data.map((x) => [x.station_code, x.station_id]));
  stops.data.forEach((s) => {
    const major = s.stop_code.startsWith('H');         // ป้ายหลัก/ปลายสาย ที่ไม่อยู่ติด BTS
    const onSilom = silom.has(stationOfCode[s.stop_code.slice(2)]);
    const side = onSilom ? 'right' : 'left';          // สถานีสีลมชื่ออยู่ซ้าย → ชื่อป้ายไว้ขวา
    L.marker(stopPos[s.stop_id], {
      icon: L.divIcon({ className: `bus-pin${major ? ' bus-pin-major' : ''}`, html: major ? '🚌' : '', iconSize: major ? [26, 26] : [12, 12] }),
      zIndexOffset: major ? 500 : -100,
    })
      .bindTooltip(`${esc(s.stop_name.replace(/^ป้าย/, ''))}<small>สาย ${esc(routesOf(s.stop_id))}</small>`, {
        // ป้ายอยู่ทางเหนือของสถานีเล็กน้อย → ชื่อป้ายไว้ด้านบน ห่างจากชื่อสถานี
        permanent: true, direction: 'top', offset: [0, -8],
        className: `lbl lbl-bus${major ? ' lbl-bus-major' : ''}${side === 'right' ? ' lbl-bus-right' : ''}`,
      })
      .bindPopup(`<div class="pop"><span class="pop-kind pop-bus">🚌 ป้ายรถเมล์</span><strong>${esc(s.stop_name)}</strong>
        <span>รถเมล์สาย ${esc(routesOf(s.stop_id)) || '–'}</span></div>`)
      .addTo(layers.bus);
  });

  // ---------- สนามบิน ----------
  layers.air = L.layerGroup();
  airports.data.forEach((a) => {
    L.marker([a.locations.latitude, a.locations.longitude], {
      icon: L.divIcon({ className: 'air-pin', html: '✈️', iconSize: [34, 34] }), zIndexOffset: 1000,
    })
      .bindTooltip(`${esc(a.iata_code)}<small>${esc(a.airport_name.replace('ท่าอากาศยาน', ''))}</small>`, {
        permanent: true, direction: 'top', offset: [0, -18], className: 'lbl lbl-air',
      })
      .bindPopup(`<div class="pop"><span class="pop-kind pop-air">✈️ สนามบิน</span><strong>${esc(a.airport_name)}</strong>
        <span>${esc(a.iata_code)} · ${esc(a.city)}</span></div>`)
      .addTo(layers.air);
  });

  // ---------- ติกเลือกชั้นข้อมูล ----------
  document.querySelectorAll('#map-layers input').forEach((cb) => {
    const sync = () => (cb.checked ? layers[cb.value].addTo(map) : layers[cb.value].remove());
    cb.addEventListener('change', sync);
    sync();
  });
  if (map.hasLayer(layers.rail)) layers.rail.eachLayer((l) => l.bringToFront?.());

  $('map-sync')?.addEventListener('click', () => syncStationsFromOSM(stations.data));
  const railBounds = L.latLngBounds(Object.values(stPos)).pad(0.05);
  map.fitBounds(railBounds);
  $('map-bkk').addEventListener('click', () => map.fitBounds(railBounds));

  // คำอธิบายสัญลักษณ์
  const legend = L.control({ position: 'bottomleft' });
  legend.onAdd = () => {
    const div = L.DomUtil.create('div', 'map-legend');
    div.innerHTML = `
      <strong>สัญลักษณ์</strong>
      <span><i class="lg-line" style="background:${COLOR.SUK}"></i>BTS สายสุขุมวิท</span>
      <span><i class="lg-line" style="background:${COLOR.SIL}"></i>BTS สายสีลม</span>
      <span><i class="lg-dot"></i>สถานี · <i class="lg-dot lg-hub"></i>สถานีร่วม</span>
      <span><i class="lg-line lg-dash"></i>สายรถเมล์</span>
      <span><i class="lg-bus"></i>ป้ายรถเมล์ · ✈️ สนามบิน</span>
      <span><span class="lbl-busno">🚌 2, 25</span> สายรถเมล์ที่ต่อได้จากสถานี</span>
      <em>ซูมเข้า 2 ระดับเพื่อดูชื่อป้ายรถเมล์</em>`;
    return div;
  };
  legend.addTo(map);
  $('map-all').addEventListener('click', () => map.fitBounds(L.featureGroup([...layers.air.getLayers()]).getBounds().pad(0.15)));
  // คลิกบนแผนที่ → ฟังก์ชัน nearest_points ในฐานข้อมูล (Haversine) หาจุดที่ใกล้ที่สุดของแต่ละประเภท
  const KIND = { RAIL_STATION: '🚆 สถานี BTS', BUS_STOP: '🚌 ป้ายรถเมล์', AIRPORT: '✈️ สนามบิน' };
  let probe = L.layerGroup().addTo(map);
  map.on('click', async (e) => {
    probe.clearLayers();
    const { lat, lng } = e.latlng;
    L.circleMarker([lat, lng], { radius: 7, color: '#7b5cd6', weight: 3, fillColor: '#fff', fillOpacity: 1 }).addTo(probe);
    const { data, error } = await supabase.rpc('nearest_points', { p_lat: lat, p_lon: lng, p_per_type: 1 });
    if (error) { L.popup().setLatLng(e.latlng).setContent(esc(error.message)).openOn(map); return; }
    data.forEach((p) => {
      L.polyline([[lat, lng], [p.latitude, p.longitude]], { color: '#7b5cd6', weight: 2, dashArray: '4 6' }).addTo(probe);
    });
    const fmtDist = (m) => (m >= 1000 ? `${(m / 1000).toFixed(1)} กม.` : `${Math.round(m)} ม.`);
    L.popup({ maxWidth: 300 }).setLatLng(e.latlng).setContent(`
      <div class="pop"><span class="pop-kind" style="background:#7b5cd6">📍 จุดที่ใกล้ที่สุด</span>
        <span>${lat.toFixed(5)}, ${lng.toFixed(5)}</span>
        ${data.map((p) => `<span class="near-row"><b>${KIND[p.kind]}</b> ${esc(p.name)} <em>${fmtDist(Number(p.distance_m))}</em><br><small>${esc(p.extra || '')}</small></span>`).join('')}
      </div>`).openOn(map);
  });

  stats = `สถานี BTS ${stations.data.length} · ป้ายรถเมล์ ${stops.data.length} · สนามบิน ${airports.data.length}`;
  updateNote();
}
