// Counts what is actually inside an OpenFreeMap tile, per source-layer.
//
//   node count-pois.mjs <lat> <lng> <zoom>
//
// Written because the only honest way to answer "why can't I see the restaurants"
// is to count the restaurants in the tile. The style can only draw what the tile
// carries, and OpenFreeMap's TileJSON advertises maxzoom 14 -- so at street level
// the app is overzooming a z14 tile and no style change can invent a POI that was
// never published.
//
// A minimal Mapbox Vector Tile decoder: no protobuf dependency, just enough of the
// spec to walk the layer/feature/tag structure. Geometry is skipped on purpose --
// the question here is how many features of each class exist, not where they are.

const [, , latArg, lngArg, zoomArg] = process.argv;
const lat = Number(latArg ?? 5.5639);
const lng = Number(lngArg ?? -0.195);
const zoom = Number(zoomArg ?? 14);

/** Reads a varint from `buf` at `pos`; returns [value, nextPos]. */
function varint(buf, pos) {
  let result = 0;
  let shift = 0;
  for (;;) {
    const byte = buf[pos++];
    result += (byte & 0x7f) * Math.pow(2, shift);
    if ((byte & 0x80) === 0) break;
    shift += 7;
  }
  return [result, pos];
}

/** Reads a length-delimited field; returns [bytes, nextPos]. */
function bytesField(buf, pos) {
  const [len, afterLen] = varint(buf, pos);
  return [buf.subarray(afterLen, afterLen + len), afterLen + len];
}

function readString(buf, pos) {
  const [bytes, next] = bytesField(buf, pos);
  return [bytes.toString('utf8'), next];
}

function readValue(buf) {
  let pos = 0;
  let out = null;
  while (pos < buf.length) {
    let key;
    [key, pos] = varint(buf, pos);
    const field = key >> 3;
    const wire = key & 7;
    if (wire === 2) {
      const [b, next] = bytesField(buf, pos);
      pos = next;
      // 1 string, 2 float, 3 double, 4 int, 5 uint, 6 sint, 7 bool
      if (field === 1) out = b.toString('utf8');
      else if (field === 2) out = b.readFloatBE(0);
      else if (field === 3) out = b.readDoubleBE(0);
      else if (field === 4) out = b.readInt32BE(0);
      else if (field === 5) out = b.readUInt32BE(0);
      else if (field === 6) {
        let v = 0;
        let shift = 0;
        for (let i = b.length - 1; i >= 0; i--) {
          v += (b[i] & 0x7f) * Math.pow(2, shift);
          shift += 7;
        }
        out = v;
      } else if (field === 7) out = b[0] !== 0;
    } else if (wire === 0) {
      const [v, next] = varint(buf, pos);
      pos = next;
      if (field === 4) out = v | 0;
      else if (field === 5) out = v;
    } else if (wire === 5) {
      pos += 4;
      if (field === 2) out = buf.readFloatBE(pos - 4);
    } else if (wire === 1) {
      pos += 8;
      if (field === 3) out = buf.readDoubleBE(pos - 8);
    } else break;
  }
  return out;
}

function countLayers(tile, wanted) {
  const counts = new Map();
  const byClass = new Map();
  let pos = 0;
  while (pos < tile.length) {
    let key;
    [key, pos] = varint(tile, pos);
    const field = key >> 3;
    const wire = key & 7;
    if (wire === 2) {
      const [b, next] = bytesField(tile, pos);
      pos = next;
      if (field !== 3) continue; // only TileLayer
      countLayer(b, wanted, counts, byClass);
    } else if (wire === 0) {
      const [, next] = varint(tile, pos);
      pos = next;
    } else break;
  }
  return { counts, byClass };
}

function countLayer(layer, wanted, counts, byClass) {
  const keys = [];
  const values = [];
  const featureBuffers = [];
  let name = '';
  let features = 0;
  let pos = 0;
  while (pos < layer.length) {
    let key;
    [key, pos] = varint(layer, pos);
    const field = key >> 3;
    const wire = key & 7;
    if (wire !== 2) {
      if (wire === 0) {
        const [, next] = varint(layer, pos);
        pos = next;
      } else if (wire === 5) pos += 4;
      else if (wire === 1) pos += 8;
      else break;
      continue;
    }
    const [b, next] = bytesField(layer, pos);
    pos = next;
    if (field === 1) name = b.toString('utf8');
    else if (field === 2) {
      features++;
      featureBuffers.push(b);
    } else if (field === 3) keys.push(b.toString('utf8'));
    else if (field === 4) values.push(readValue(b));
  }
  counts.set(name, (counts.get(name) ?? 0) + features);
  // Two passes, and the second one has to happen here. MVT writes features *before*
  // the layer's `keys` and `values`, so tallying on the way past the feature field
  // looks every tag up in two empty arrays and reports that 1315 POIs have no class
  // and no name -- which is what the first run of this script said, and it was the
  // decoder lying rather than the tile.
  if (wanted === name || wanted === '*') {
    for (const f of featureBuffers) tally(f, keys, values, name, byClass);
  }
}

/** Reads a Feature's packed tag pairs and counts the ones worth counting. */
function tally(feature, keys, values, layerName, byClass) {
  let pos = 0;
  let tags = [];
  while (pos < feature.length) {
    let key;
    [key, pos] = varint(feature, pos);
    const field = key >> 3;
    const wire = key & 7;
    if (wire === 2) {
      const [b, next] = bytesField(feature, pos);
      pos = next;
      if (field === 2) {
        tags = [];
        let p = 0;
        while (p < b.length) {
          let v;
          [v, p] = varint(b, p);
          tags.push(v);
        }
      }
    } else if (wire === 0) {
      const [, next] = varint(feature, pos);
      pos = next;
    } else if (wire === 5) pos += 4;
    else if (wire === 1) pos += 8;
    else break;
  }
  const get = (name) => {
    for (let i = 0; i + 1 < tags.length; i += 2) {
      if (keys[tags[i]] === name) return values[tags[i + 1]];
    }
    return undefined;
  };
  const cls = get('class');
  const name2 = get('name');
  const bucket = byClass.get(cls ?? '(no class)') ?? { total: 0, named: 0 };
  bucket.total++;
  if (name2) bucket.named++;
  byClass.set(cls ?? '(no class)', bucket);
}

const n = Math.pow(2, zoom);
const x = Math.floor(((lng + 180) / 360) * n);
const y = Math.floor(((1 - Math.asinh(Math.tan((lat * Math.PI) / 180)) / Math.PI) / 2) * n);

const tj = await (await fetch('https://tiles.openfreemap.org/planet')).json();
const url = tj.tiles[0].replace('{z}/{x}/{y}.pbf', `${zoom}/${x}/${y}.pbf`);
console.log(`tile ${zoom}/${x}/${y} for ${lat},${lng}`);
console.log(url);

const res = await fetch(url);
if (!res.ok) {
  console.error(`HTTP ${res.status} -- no tile at this zoom`);
  process.exit(1);
}
const tile = Buffer.from(await res.arrayBuffer());
console.log(`\n${(tile.length / 1024).toFixed(0)} KB of vector tile\n`);

const { counts, byClass } = countLayers(tile, 'poi');
console.log('features per source-layer:');
for (const [k, v] of [...counts].sort((a, b) => b[1] - a[1])) {
  console.log('  ' + k.padEnd(24) + v);
}

console.log('\npoi classes present (total / with a name):');
const rows = [...byClass].sort((a, b) => b[1].total - a[1].total);
for (const [cls, b] of rows) {
  console.log('  ' + String(cls).padEnd(22) + String(b.total).padStart(5) + ' / ' + b.named);
}
const named = rows.reduce((n, [, b]) => n + b.named, 0);
const total = rows.reduce((n, [, b]) => n + b.total, 0);
console.log(`\n  ${total} POIs in this tile, ${named} of them named.`);