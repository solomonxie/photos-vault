import { expect, test } from 'vitest';
import { readExif } from '../src/upload/exif';
import { baseName, objectStamp } from '../src/upload/uploader';

test("an upload is named the way the phone names its own (lib/vault/object_key.dart)", async () => {
  const at = new Date(2026, 9, 28, 16, 13, 5).getTime();
  expect(objectStamp(at)).toBe('20261028161305');
  // Same constant as test/sync/naming_test.dart: ordinaryNameHash('web:3f2b').
  expect(await baseName('web:3f2b', at)).toBe('20261028161305_05ac64381c79503f099ed7213dbdf29b');
});

/// A minimal little-endian TIFF after "Exif\0\0": DateTimeOriginal and GPS.
function exifBlock(): Uint8Array {
  const b = new Uint8Array(400);
  const v = new DataView(b.buffer);
  const prefix = [0xff, 0xd8, 0xff, 0xe1, 0, 0, 0x45, 0x78, 0x69, 0x66, 0, 0];
  b.set(prefix);
  const t = prefix.length;
  const w16 = (o: number, x: number) => v.setUint16(t + o, x, true);
  const w32 = (o: number, x: number) => v.setUint32(t + o, x, true);
  b.set([0x49, 0x49], t);
  w16(2, 42);
  w32(4, 8);
  // IFD0: ExifIFD at 38, GPS IFD at 80.
  w16(8, 2);
  w16(10, 0x8769), w16(12, 4), w32(14, 1), w32(18, 38);
  w16(22, 0x8825), w16(24, 4), w32(26, 1), w32(30, 80);
  w32(34, 0);
  // Exif IFD: DateTimeOriginal ascii(20) at 200.
  w16(38, 1);
  w16(40, 0x9003), w16(42, 2), w32(44, 20), w32(48, 200);
  b.set(new TextEncoder().encode('2026:10:28 16:13:05\0'), t + 200);
  // GPS IFD: N, 38/1 42/1 36/1 ; W, 9/1 8/1 24/1
  w16(80, 4);
  const e = (i: number, tag: number, type: number, count: number, val: number) => {
    w16(82 + i * 12, tag), w16(84 + i * 12, type), w32(86 + i * 12, count), w32(90 + i * 12, val);
  };
  e(0, 1, 2, 2, 0x4e); // 'N'
  e(1, 2, 5, 3, 240);
  e(2, 3, 2, 2, 0x57); // 'W'
  e(3, 4, 5, 3, 300);
  [38, 1, 42, 1, 36, 1].forEach((x, i) => w32(240 + i * 4, x));
  [9, 1, 8, 1, 24, 1].forEach((x, i) => w32(300 + i * 4, x));
  return b;
}

test('EXIF: the camera date as local time, GPS signed by its reference', () => {
  const got = readExif(exifBlock());
  expect(got.takenAt).toBe(new Date(2026, 9, 28, 16, 13, 5).getTime());
  expect(got.lat).toBeCloseTo(38.71, 2);
  expect(got.lng).toBeCloseTo(-9.14, 2);
  expect(readExif(new Uint8Array(64))).toEqual({});
});
