// Which "Las Palmas, Lapaz" is the pickup, and what does that trip cost?
//
//   node toolchain/las-palmas-fare.mjs
//
// Nominatim returns two entries with the byte-identical label "Las Palmas,
// George Walker Bush Highway, Lapaz, Nii Boi Town" -- 160 m apart on opposite
// sides of the same road, which is why their routed distances differ by nearly
// two kilometres. Guessing between them is how this fixture was wrong three
// times, so both are priced and the user picks.

const PINS = [
  ['pin A', 5.6068938, -0.2490504],
  ['pin B', 5.6070653, -0.2491380],
];
const HOSPITAL = { lat: 5.5868922, lng: -0.1850474 };
const USER_KM = 11.6;

const RATES = { lite: 0.28, standard: 0.35, premium: 0.46 };
const MIN_FARE = 0.15;
// 20 cedis/litre, 8 km/litre.
const FUEL_PER_KM = 0.20 / 8;
// The same factor the deployed `route` function applies.
const TRAFFIC = 1.9;

async function road(from) {
  const url = 'https://router.project-osrm.org/route/v1/driving/'
    + `${from.lon},${from.lat};${HOSPITAL.lng},${HOSPITAL.lat}?overview=false`;
  const res = await fetch(url, { headers: { 'User-Agent': 'MeetNGo/1.0 (routing proxy)' } });
  const body = await res.json();
  const r = body.routes[0];
  return { km: r.distance / 1000, freeMin: r.duration / 60 };
}

const money = (v) => 'GHS ' + v.toFixed(2).padStart(6);

console.log('Two pins, identical labels, 160 m apart on opposite sides of the road.\n');
for (const [name, lat, lon] of PINS) {
  const { km, freeMin } = await road({ lat, lon });
  const shownMin = freeMin * TRAFFIC;
  const fuel = km * FUEL_PER_KM;
  const match = Math.abs(km - USER_KM) < 1 ? 'MATCHES the ' + USER_KM + ' km you drive' : 'not the ' + USER_KM + ' km you drive';

  console.log(name + '  ' + km.toFixed(2) + ' km   ' + freeMin.toFixed(1) + ' min free-flow   ' + shownMin.toFixed(0) + ' min shown');
  console.log('       ' + match);
  console.log('       fuel ' + money(fuel) + ' over the trip');
  for (const [cat, rate] of Object.entries(RATES)) {
    const fare = Math.max(MIN_FARE, km * rate);
    const net = fare - fuel;
    console.log('       ' + cat.padEnd(9) + money(fare) + '   driver nets ' + money(net) + '   ' + money(net / (shownMin / 60)) + '/hr');
  }
  console.log('');
}
console.log('During the 5-month promo the fare column is entirely the driver\'s:');
console.log('the platform takes 0, so nothing is deducted from it.');
