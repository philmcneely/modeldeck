// Renders the phone deck's full-bleed home-screen icons from the ModelDeck app
// icon's geometry (design/icon/modeldeck-icon-1024.png, measured): the slate
// gradient and the three brand bars (12/8/16 widths, #4C8DFF/#E0A94A/#EA5C50).
// iOS masks the corners itself, so the art fills the square. Run once:
//   node tools/phone-deck/make-icons.mjs
import { writeFileSync } from 'node:fs';
import { deflateSync } from 'node:zlib';

const CRC = new Uint32Array(256).map((_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
};
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

// Measured from the 1024 icon's 824 px content square, normalized to 0..1.
const TOP = hex('#515866'), BOTTOM = hex('#393f4c');
const BARS = [
  { y0: 0.2718, y1: 0.3762, w: 0.4187, c: hex('#4C8DFF') },
  { y0: 0.4478, y1: 0.5510, w: 0.2791, c: hex('#E0A94A') },
  { y0: 0.6226, y1: 0.7257, w: 0.5583, c: hex('#EA5C50') },
];
const X0 = 0.2209;

// Signed coverage of a pill (stadium) shape at a point, 1 inside.
function inPill(x, y, bar) {
  const r = (bar.y1 - bar.y0) / 2, cy = (bar.y0 + bar.y1) / 2;
  const cx = Math.min(Math.max(x, X0 + r), X0 + bar.w - r);
  return (x - cx) ** 2 + (y - cy) ** 2 <= r * r;
}

function render(size) {
  const SS = 4;
  const raw = Buffer.alloc(size * (size * 3 + 1));
  for (let py = 0; py < size; py++) {
    raw[py * (size * 3 + 1)] = 0;
    for (let px = 0; px < size; px++) {
      const acc = [0, 0, 0];
      for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
        const x = (px + (sx + 0.5) / SS) / size, y = (py + (sy + 0.5) / SS) / size;
        let col = TOP.map((t, i) => t + (BOTTOM[i] - t) * y);
        for (const bar of BARS) if (inPill(x, y, bar)) { col = bar.c; break; }
        for (let i = 0; i < 3; i++) acc[i] += col[i];
      }
      const o = py * (size * 3 + 1) + 1 + px * 3;
      for (let i = 0; i < 3; i++) raw[o + i] = Math.round(acc[i] / (SS * SS));
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)),
  ]);
}

const dir = new URL('./icons/', import.meta.url);
for (const [name, size] of [['apple-touch-icon.png', 180], ['icon-192.png', 192], ['icon-512.png', 512], ['favicon-32.png', 32]]) {
  writeFileSync(new URL(name, dir), render(size));
  console.log('wrote', name, size);
}
