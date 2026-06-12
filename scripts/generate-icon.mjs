import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const root = process.cwd();
const buildDir = path.join(root, 'build');
const iconsetDir = path.join(buildDir, 'icon.iconset');
const sourcePng = path.join(buildDir, 'icon.png');
const size = 1024;

mkdirSync(buildDir, { recursive: true });
rmSync(iconsetDir, { recursive: true, force: true });
mkdirSync(iconsetDir, { recursive: true });

writeFileSync(sourcePng, createIconPng(size, size));

const iconSizes = [
  ['icon_16x16.png', 16],
  ['icon_16x16@2x.png', 32],
  ['icon_32x32.png', 32],
  ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128],
  ['icon_128x128@2x.png', 256],
  ['icon_256x256.png', 256],
  ['icon_256x256@2x.png', 512],
  ['icon_512x512.png', 512],
  ['icon_512x512@2x.png', 1024]
];

for (const [filename, targetSize] of iconSizes) {
  execFileSync('sips', ['-z', String(targetSize), String(targetSize), sourcePng, '--out', path.join(iconsetDir, filename)], {
    stdio: 'ignore'
  });
}

writeFileSync(path.join(buildDir, 'icon.icns'), createIcns([
  ['icp4', path.join(iconsetDir, 'icon_16x16.png')],
  ['icp5', path.join(iconsetDir, 'icon_32x32.png')],
  ['icp6', path.join(iconsetDir, 'icon_32x32@2x.png')],
  ['ic07', path.join(iconsetDir, 'icon_128x128.png')],
  ['ic08', path.join(iconsetDir, 'icon_256x256.png')],
  ['ic09', path.join(iconsetDir, 'icon_512x512.png')],
  ['ic10', path.join(iconsetDir, 'icon_512x512@2x.png')]
]));
rmSync(iconsetDir, { recursive: true, force: true });

function createIconPng(width, height) {
  const data = Buffer.alloc(width * height * 4);
  const radius = 190;
  const rect = { x: 88, y: 72, w: 848, h: 848 };
  const pulsePoints = [
    [172, 512],
    [350, 512],
    [405, 462],
    [438, 364],
    [530, 361],
    [607, 648],
    [651, 651],
    [692, 560],
    [755, 516],
    [852, 516]
  ];
  const branchA = [[738, 516], [738, 430], [796, 372]];
  const branchB = [[738, 516], [738, 612], [796, 670]];

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const idx = (y * width + x) * 4;
      let pixel = [0, 0, 0, 0];
      const mask = roundedRectCoverage(x, y, rect.x, rect.y, rect.w, rect.h, radius);

      if (mask > 0) {
        const bg = mixGradient(x, y);
        pixel = [bg[0], bg[1], bg[2], Math.round(255 * mask)];

        const glass = glassAlpha(x, y) * mask;
        if (glass > 0) {
          pixel = blend(pixel, [255, 255, 255, Math.round(255 * glass)]);
        }

        const rim = roundedRectStrokeCoverage(x, y, rect.x + 2, rect.y + 2, rect.w - 4, rect.h - 4, radius - 2, 5);
        if (rim > 0) {
          pixel = blend(pixel, [255, 255, 255, Math.round(44 * rim)]);
        }
      }

      const glow = Math.max(
        polylineCoverage(x, y, pulsePoints, 86),
        polylineCoverage(x, y, branchA, 86),
        polylineCoverage(x, y, branchB, 86)
      );
      if (glow > 0) {
        pixel = blend(pixel, [39, 241, 244, Math.round(82 * glow)]);
      }

      const stroke = Math.max(
        polylineCoverage(x, y, pulsePoints, 44),
        polylineCoverage(x, y, branchA, 44),
        polylineCoverage(x, y, branchB, 44)
      );
      if (stroke > 0) {
        pixel = blend(pixel, [...pulseColor(x), Math.round(255 * stroke)]);
      }

      for (const [cx, cy] of [[796, 372], [852, 516], [796, 670]]) {
        const outer = circleCoverage(x, y, cx, cy, 59);
        if (outer > 0) {
          pixel = blend(pixel, [...pulseColor(cx), Math.round(255 * outer)]);
        }
        const inner = circleCoverage(x, y, cx, cy, 26);
        if (inner > 0) {
          pixel = blend(pixel, [18, 33, 38, Math.round(255 * inner)]);
        }
      }

      data[idx] = pixel[0];
      data[idx + 1] = pixel[1];
      data[idx + 2] = pixel[2];
      data[idx + 3] = pixel[3];
    }
  }

  return encodePng(width, height, data);
}

function mixGradient(x, y) {
  const t = clamp((x * 0.55 + y * 0.7 - 180) / 850, 0, 1);
  const a = [59, 65, 77];
  const b = t < 0.55 ? [20, 26, 34] : [5, 8, 13];
  const local = t < 0.55 ? t / 0.55 : (t - 0.55) / 0.45;
  return [
    lerp(a[0], b[0], local),
    lerp(a[1], b[1], local),
    lerp(a[2], b[2], local)
  ].map(Math.round);
}

function glassAlpha(x, y) {
  const line = y - (0.58 * x + 190);
  if (line > 0 || y > 740) {
    return 0;
  }
  return clamp((1 - y / 720) * 0.25, 0, 0.28);
}

function pulseColor(x) {
  const t = clamp((x - 172) / (852 - 172), 0, 1);
  const start = [57, 214, 255];
  const mid = [39, 241, 244];
  const end = [137, 255, 213];
  const a = t < 0.52 ? start : mid;
  const b = t < 0.52 ? mid : end;
  const local = t < 0.52 ? t / 0.52 : (t - 0.52) / 0.48;
  return [
    Math.round(lerp(a[0], b[0], local)),
    Math.round(lerp(a[1], b[1], local)),
    Math.round(lerp(a[2], b[2], local))
  ];
}

function roundedRectCoverage(px, py, x, y, w, h, r) {
  const qx = Math.abs(px - (x + w / 2)) - (w / 2 - r);
  const qy = Math.abs(py - (y + h / 2)) - (h / 2 - r);
  const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
  const inside = Math.min(Math.max(qx, qy), 0);
  const d = outside + inside - r;
  return clamp(0.5 - d, 0, 1);
}

function roundedRectStrokeCoverage(px, py, x, y, w, h, r, strokeWidth) {
  const outer = roundedRectCoverage(px, py, x, y, w, h, r);
  const inner = roundedRectCoverage(px, py, x + strokeWidth, y + strokeWidth, w - strokeWidth * 2, h - strokeWidth * 2, r - strokeWidth);
  return clamp(outer - inner, 0, 1);
}

function polylineCoverage(x, y, points, width) {
  let d = Infinity;
  for (let i = 0; i < points.length - 1; i += 1) {
    d = Math.min(d, segmentDistance(x, y, points[i], points[i + 1]));
  }
  return clamp((width / 2 + 1 - d) / 2, 0, 1);
}

function segmentDistance(x, y, a, b) {
  const vx = b[0] - a[0];
  const vy = b[1] - a[1];
  const wx = x - a[0];
  const wy = y - a[1];
  const c = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy), 0, 1);
  const dx = x - (a[0] + c * vx);
  const dy = y - (a[1] + c * vy);
  return Math.hypot(dx, dy);
}

function circleCoverage(x, y, cx, cy, r) {
  return clamp(0.5 - (Math.hypot(x - cx, y - cy) - r), 0, 1);
}

function blend(base, top) {
  const ta = top[3] / 255;
  const ba = base[3] / 255;
  const outA = ta + ba * (1 - ta);
  if (outA === 0) {
    return [0, 0, 0, 0];
  }

  return [
    Math.round((top[0] * ta + base[0] * ba * (1 - ta)) / outA),
    Math.round((top[1] * ta + base[1] * ba * (1 - ta)) / outA),
    Math.round((top[2] * ta + base[2] * ba * (1 - ta)) / outA),
    Math.round(outA * 255)
  ];
}

function encodePng(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y += 1) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }

  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk('IHDR', ihdr(width, height)),
    pngChunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    pngChunk('IEND', Buffer.alloc(0))
  ]);
}

function createIcns(entries) {
  const chunks = entries.map(([type, filePath]) => {
    const data = readFileSync(filePath);
    const header = Buffer.alloc(8);
    header.write(type, 0, 4, 'ascii');
    header.writeUInt32BE(data.length + 8, 4);
    return Buffer.concat([header, data]);
  });
  const totalLength = 8 + chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const header = Buffer.alloc(8);
  header.write('icns', 0, 4, 'ascii');
  header.writeUInt32BE(totalLength, 4);
  return Buffer.concat([header, ...chunks]);
}

function ihdr(width, height) {
  const buffer = Buffer.alloc(13);
  buffer.writeUInt32BE(width, 0);
  buffer.writeUInt32BE(height, 4);
  buffer[8] = 8;
  buffer[9] = 6;
  buffer[10] = 0;
  buffer[11] = 0;
  buffer[12] = 0;
  return buffer;
}

function pngChunk(type, data) {
  const typeBuffer = Buffer.from(type);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuffer, data])), 0);
  return Buffer.concat([length, typeBuffer, data, crc]);
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let i = 0; i < 8; i += 1) {
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}
