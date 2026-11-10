import { supabase } from './supabaseClient.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// สีตามโหมด (ตรงกับ css)
const COLOR = { SUK: '#7cc242', SIL: '#1d7a46', air: '#2f67d8', bus: '#e0a116', busLine: '#c98a00' };
const BANGKOK_CENTER = [13.738, 100.552];

let map;
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
  L.tileLayer('https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png', {
    maxZoom: 19, subdomains: 'abcd',
    attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
  }).addTo(map);

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
  const byLine = {};
  seqs.data.forEach((r) => { (byLine[r.lines.code] ||= { name: r.lines.line_name, pts: [] }).pts.push(stPos[r.station_id]); });
  Object.entries(byLine).forEach(([code, line]) => {
    L.polyline(line.pts, { color: COLOR[code] || COLOR.SIL, weight: 6, opacity: 0.9 })
      .bindTooltip(line.name, { sticky: true, className: 'lbl-line' }).addTo(layers.rail);
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

  $('map-bkk').addEventListener('click', () => map.setView(BANGKOK_CENTER, 13));

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
  $('map-note').textContent =
    `สถานี BTS ${stations.data.length} · ป้ายรถเมล์ ${stops.data.length} · สนามบิน ${airports.data.length} — ทุกจุดมาจากตาราง locations กลาง`;
}
