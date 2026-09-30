// Every "Las Palmas" Nominatim knows in Accra, routed from 37 Military Hospital.
//
//   node toolchain/las-palmas.mjs
//
// There are at least four places called Las Palmas in Accra and they are
// several kilometres apart -- North Legon, Nii Boi Town/Lapaz, Abofu and
// Dansoman. "Las Palmas, Lapaz" names one of them and "Lapaz" is a
// neighbourhood as well as a place, so a geocoder asked for "Las Palmas,
// Lapaz" and handed back a restaurant in North Legon, and this has now been
// wrong twice. This lists them all, routed, so the choice is the user's rather
// than a guess buried in a test fixture.

const HOSPITAL = { lat: 5.5868922, lng: -0.1850474 };
const HOSPITAL_LABEL = '37 Military Hospital';

async function geocode(q) {
  const url = 'https://nominatim.openstreetmap.org/search?q=' + encodeURIComponent(q)
    + '&format=json&limit=10&countrycodes=gh';
  const res = await fetch(url, { headers: { 'User-Agent': 'MeetNGo/1.0 (place disambiguation)' } });
  if (!res.ok) return [];
  return await res.json();
}

async function osrm(from, to) {
  const url = `https://router.project-osrm.org/route/v1/driving/`
    + `${from.lng},${from.lat};${to.lng},${to.lat}?overview=false`;
  try {
    const res = await fetch(url, { headers: { 'User-Agent': 'MeetNGo/1.0 (routing proxy)' } });
    if (!res.ok) return null;
    const body = await res.json();
    const r = body?.routes?.[0];
    return r ? { km: r.distance / 1000, min: r.duration / 60 } : null;
  } catch { return null; }
}

const seen = new Map();
for (const q of ['Las Palmas, Ghana', 'Las Palmas, Lapaz, Accra', 'Las Palmas, Lapaz, Ghana']) {
  for (const c of await geocode(q)) {
    const key = c.lat + ',' + c.lon;
    if (seen.has(key)) continue;
    seen.set(key, c);
  }
  await new Promise((r) => setTimeout(r, 1100)); // Nominatim's 1 req/s policy
}

const rows = [];
for (const c of seen.values()) {
  const r = await osrm({ lat: +c.lat, lng: +c.lon }, HOSPITAL);
  if (!r) continue;
  rows.push({
    km: r.km,
    min: r.min * 1.9, // the same city factor the route function applies
    name: c.display_name,
    lat: +c.lat,
    lon: +c.lon,
  });
}
rows.sort((a, b) => a.km - b.km);

console.log(`\nEvery "Las Palmas" Nominatim knows, driven from ${HOSPITAL_LABEL}:\n`);
console.log('  ' + 'road km'.padStart(8) + '  ' + 'drive'.padStart(7) + '   address Nominatim returned');
console.log('  ' + '-'.repeat(78));
for (const r of rows) {
  console.log('  ' + r.km.toFixed(2).padStart(8) + '  ' + (r.min.toFixed(0) + 'm').padStart(7) + '   ' + r.name);
}
console.log('\n  times are the route function\'s own figure: OSRM free-flow x 1.9 for Accra traffic');
console.log('  pick the row that matches where you actually start from\n');

export { rows, HOSPITAL };
