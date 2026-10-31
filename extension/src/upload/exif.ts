// The two things an upload needs from EXIF: when, and where. JPEG carries
// it in APP1; HEIC in an `Exif` item — both are a TIFF block after
// "Exif\0\0", so finding that marker in the first bytes covers both.

export interface Exif {
  takenAt?: number;
  lat?: number;
  lng?: number;
}

const marker = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

function findTiff(b: Uint8Array): number {
  outer: for (let i = 0; i < b.length - 14; i++) {
    for (let k = 0; k < marker.length; k++) if (b[i + k] !== marker[k]) continue outer;
    const t = i + 6;
    const order = String.fromCharCode(b[t]!, b[t + 1]!);
    if (order === 'II' || order === 'MM') return t;
  }
  return -1;
}

export function readExif(bytes: Uint8Array): Exif {
  const t = findTiff(bytes);
  if (t < 0) return {};
  const v = new DataView(bytes.buffer, bytes.byteOffset + t, bytes.length - t);
  const le = v.getUint8(0) === 0x49;
  const u16 = (o: number) => v.getUint16(o, le);
  const u32 = (o: number) => v.getUint32(o, le);
  const entries = (ifd: number) => {
    const out = new Map<number, { type: number; count: number; at: number }>();
    if (ifd <= 0 || ifd + 2 > v.byteLength) return out;
    const n = u16(ifd);
    for (let i = 0; i < n; i++) {
      const e = ifd + 2 + i * 12;
      if (e + 12 > v.byteLength) break;
      out.set(u16(e), { type: u16(e + 2), count: u32(e + 4), at: e + 8 });
    }
    return out;
  };
  const offset = (e: { at: number }) => u32(e.at);
  const ascii = (e: { count: number; at: number }) => {
    const o = e.count > 4 ? offset(e) : e.at;
    let s = '';
    for (let i = 0; i < e.count - 1 && o + i < v.byteLength; i++) s += String.fromCharCode(v.getUint8(o + i));
    return s;
  };
  const rationals = (e: { count: number; at: number }) => {
    const o = offset(e);
    const out: number[] = [];
    for (let i = 0; i < e.count && o + i * 8 + 8 <= v.byteLength; i++) out.push(u32(o + i * 8) / (u32(o + i * 8 + 4) || 1));
    return out;
  };
  const out: Exif = {};
  try {
    const ifd0 = entries(u32(4));
    const exifPtr = ifd0.get(0x8769);
    if (exifPtr) {
      const exif = entries(offset(exifPtr));
      const when = exif.get(0x9003) ?? exif.get(0x9004);
      const m = when && /^(\d{4}):(\d\d):(\d\d) (\d\d):(\d\d):(\d\d)/.exec(ascii(when));
      // Camera wall time, read as this computer's local time — as the phone does.
      if (m) out.takenAt = new Date(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!, +m[6]!).getTime();
    }
    const gpsPtr = ifd0.get(0x8825);
    if (gpsPtr) {
      const gps = entries(offset(gpsPtr));
      const deg = (r: number[]) => (r[0] ?? 0) + (r[1] ?? 0) / 60 + (r[2] ?? 0) / 3600;
      const lat = gps.get(2);
      const lng = gps.get(4);
      if (lat && lng) {
        const sLat = gps.get(1) ? ascii({ ...gps.get(1)!, count: 2 }) : 'N';
        const sLng = gps.get(3) ? ascii({ ...gps.get(3)!, count: 2 }) : 'E';
        out.lat = deg(rationals(lat)) * (sLat === 'S' ? -1 : 1);
        out.lng = deg(rationals(lng)) * (sLng === 'W' ? -1 : 1);
      }
    }
  } catch {
    // A damaged block: whatever was read before it stands.
  }
  return out;
}
