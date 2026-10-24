// Glass solids drawn in the Channels app icon's style (kiwi-init/channels, desktop/build/icon.svg):
// clear faces crossed by a thin dispersion band, a dark under-edge, white edges and a highlight
// line. Shapes are flat polygons extruded into 3D and projected orthographically.

export const V = {
  add: (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]],
  sub: (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]],
  mul: (a, s) => [a[0] * s, a[1] * s, a[2] * s],
  dot: (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2],
  cross: (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]],
  norm: a => { const l = Math.hypot(...a); return [a[0] / l, a[1] / l, a[2] / l]; },
};

const rad = d => (d * Math.PI) / 180;

// A rotation by these degrees about x, then y, then z. Camera space: x right, y up, z towards you.
export function rot(ax, ay, az) {
  const [a, b, c] = [rad(ax), rad(ay), rad(az)];
  return ([x, y, z]) => {
    [y, z] = [y * Math.cos(a) - z * Math.sin(a), y * Math.sin(a) + z * Math.cos(a)];
    [x, z] = [x * Math.cos(b) + z * Math.sin(b), -x * Math.sin(b) + z * Math.cos(b)];
    [x, y] = [x * Math.cos(c) - y * Math.sin(c), x * Math.sin(c) + y * Math.cos(c)];
    return [x, y, z];
  };
}

// A rotation by these degrees about an axis through a point.
export function rotAbout(axis, origin, degrees) {
  const k = V.norm(axis), c = Math.cos(rad(degrees)), s = Math.sin(rad(degrees));
  return p => {
    const v = V.sub(p, origin);
    return V.add(V.add(V.add(V.mul(v, c), V.mul(V.cross(k, v), s)), V.mul(k, V.dot(k, v) * (1 - c))), origin);
  };
}

const area = loop => loop.reduce((s, p, i) => {
  const q = loop[(i + 1) % loop.length];
  return s + p[0] * q[1] - q[0] * p[1];
}, 0) / 2;

// A flat polygon (an outer loop, then holes) extruded `t` deep, centred on its plane.
// `place` maps local [x, y, z] to the world. `skip` names outer-loop edges (edge i runs from point i
// to i + 1) that are cuts: they get no side face and no outline, so two pieces meet without a seam.
// `highlight` is a local 2D segment drawn on the +z cap.
export function slab({ loops, t, place = p => p, skip = [], highlight = null }) {
  const n = loops[0].length;
  if (area(loops[0]) < 0) skip = skip.map(i => (((n - 2 - i) % n) + n) % n);
  loops = loops.map((l, i) => ((i === 0) === area(l) > 0 ? l : [...l].reverse()));
  const at = (p, z) => place([p[0], p[1], z]);
  const capNormal = sign => V.norm(V.sub(place([0, 0, sign]), place([0, 0, 0])));
  const faces = [
    { loops: loops.map(l => l.map(p => at(p, t / 2))), normal: capNormal(1), open: skip, highlight: highlight?.map(p => at(p, t / 2)) },
    { loops: loops.map(l => [...l].reverse().map(p => at(p, -t / 2))), normal: capNormal(-1), open: skip.map(i => (((n - 2 - i) % n) + n) % n) },
  ];
  loops.forEach((l, li) => l.forEach((p, i) => {
    if (li === 0 && skip.includes(i)) return;
    const q = l[(i + 1) % l.length];
    const quad = [at(p, -t / 2), at(q, -t / 2), at(q, t / 2), at(p, t / 2)];
    faces.push({ loops: [quad], normal: V.norm(V.cross(V.sub(quad[1], quad[0]), V.sub(quad[3], quad[0]))) });
  }));
  return { faces };
}

// A square frame: size s, bars b wide.
export const ringLoops = (s, b) => [
  [[-s / 2, -s / 2], [s / 2, -s / 2], [s / 2, s / 2], [-s / 2, s / 2]],
  [[-s / 2 + b, -s / 2 + b], [-s / 2 + b, s / 2 - b], [s / 2 - b, s / 2 - b], [s / 2 - b, -s / 2 + b]],
];

// The band's colours after its pink lead, and where it starts on each face, in turn.
const PALETTES = [
  ["#ff3d6e", "#ffa53d", "#fff27a", "#5cffb0", "#45c9ff", "#ffffff"],
  ["#ffa53d", "#fff27a", "#5cffb0", "#45c9ff", "#7b61ff", "#ffffff"],
  ["#fff27a", "#5cffb0", "#45c9ff", "#7b61ff", "#ff5ad8", "#ffffff"],
];
const OFFSETS = [0.12, 0.27, 0.42, 0.16, 0.31, 0.46, 0.21];
const LEAD = "#ff5fbf";

// Draws the objects in order, each one's far faces before its near ones, fitted to a 96×96 box
// with `margin` around it. `view` turns the world to the camera. Returns an SVG fragment.
export function render(objects, { view = p => p, margin = 6 } = {}) {
  const proj = p => { const q = view(p); return [q[0], -q[1], q[2]]; };
  const all = objects.flatMap(o => o.faces.flatMap(f => f.loops.flat().map(proj)));
  const xs = all.map(p => p[0]), ys = all.map(p => p[1]);
  const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
  const k = (96 - 2 * margin) / Math.max(maxX - minX, maxY - minY);
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  const S = p => { const q = proj(p); return [48 + (q[0] - cx) * k, 48 + (q[1] - cy) * k, q[2]]; };
  const f2 = n => n.toFixed(2);
  const d = loops => loops.map(l => l.map((p, i) => `${i ? "L" : "M"}${f2(p[0])} ${f2(p[1])}`).join("") + "Z").join("");
  const outline = (loops, open = []) => !open.length ? d(loops) : loops.map((l, li) => l.map((p, i) => {
    if (li === 0 && open.includes(i)) return "";
    const q = l[(i + 1) % l.length];
    return `M${f2(p[0])} ${f2(p[1])}L${f2(q[0])} ${f2(q[1])}`;
  }).join("")).join("");

  const defs = [], paths = [];
  let g = 0;
  // A band across the face, along its longest diagonal from its first point.
  const band = (pts, peak, base) => {
    const a = pts[0], far = p => Math.hypot(p[0] - a[0], p[1] - a[1]);
    const b = pts.reduce((m, p) => (far(p) > far(m) ? p : m), a);
    const o = OFFSETS[g % OFFSETS.length], pal = PALETTES[g % PALETTES.length], id = `s${g++}`;
    const stops = [[0, "#ffffff", base], [o, LEAD, 0], [o + 0.03, LEAD, peak]];
    pal.forEach((c, i) => stops.push([o + 0.09 + i * 0.06, c, peak]));
    stops.push([o + 0.1 + pal.length * 0.06, "#ffffff", 0], [1, "#ffffff", base * 1.5]);
    defs.push(`<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="${f2(a[0])}" y1="${f2(a[1])}" x2="${f2(b[0])}" y2="${f2(b[1])}">` +
      stops.map(([off, c, op]) => `<stop offset="${f2(Math.min(off, 1))}" stop-color="${c}" stop-opacity="${f2(op)}"/>`).join("") + "</linearGradient>");
    return id;
  };

  for (const o of objects) {
    const faces = o.faces.map(f => {
      const n = view(f.normal).map((x, i) => (i === 1 ? -x : x));
      const loops = f.loops.map(l => l.map(S));
      const z = loops[0].reduce((s, p) => s + p[2], 0) / loops[0].length;
      return { ...f, n, loops, z, near: n[2] > 1e-6 };
    });
    const byDepth = (a, b) => a.z - b.z;
    for (const f of faces.filter(f => !f.near).sort(byDepth)) {
      const p = d(f.loops), e = outline(f.loops, f.open), id = band(f.loops.flat(), 0.35, 0.04);
      paths.push(`<path d="${e}" fill="none" stroke="#14161f" stroke-opacity="0.22" stroke-width="1.2" stroke-linejoin="round" stroke-linecap="round"/>`);
      paths.push(`<path d="${p}" fill="url(#${id})" fill-rule="evenodd"/>`);
      paths.push(`<path d="${e}" fill="none" stroke="#ffffff" stroke-opacity="0.3" stroke-width="0.6" stroke-linejoin="round" stroke-linecap="round"/>`);
    }
    for (const f of faces.filter(f => f.near).sort(byDepth)) {
      const p = d(f.loops), e = outline(f.loops, f.open), nz = f.n[2], down = Math.max(0, f.n[1]);
      const id = band(f.loops.flat(), 0.45 + 0.23 * nz, 0.04 + 0.04 * nz);
      paths.push(`<path d="${p}" fill="#0b0d14" fill-opacity="${f2(0.34 + 0.16 * down)}" fill-rule="evenodd"/>`);
      paths.push(`<path d="${e}" fill="none" stroke="#14161f" stroke-opacity="0.6" stroke-width="${f2(2.1 + 0.3 * nz)}" stroke-linejoin="round" stroke-linecap="round"/>`);
      paths.push(`<path d="${p}" fill="url(#${id})" fill-rule="evenodd"/>`);
      paths.push(`<path d="${e}" fill="none" stroke="#ffffff" stroke-opacity="${f2(0.7 + 0.18 * nz)}" stroke-width="${f2(0.88 + 0.25 * nz)}" stroke-linejoin="round" stroke-linecap="round"/>`);
      if (f.highlight) {
        const [a, b] = f.highlight.map(S);
        paths.push(`<path d="M${f2(a[0])} ${f2(a[1])}L${f2(b[0])} ${f2(b[1])}" stroke="#ffffff" stroke-width="0.9" stroke-linecap="round" opacity="0.55"/>`);
      }
    }
  }
  return `<defs>\n${defs.join("\n")}\n</defs>\n${paths.join("\n")}`;
}

// The art on the black rounded square of the macOS icon grid, as Channels has it.
export const icon = art => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <rect x="100" y="100" width="824" height="824" rx="185" fill="#000"/>
  <svg x="212" y="212" width="600" height="600" viewBox="0 0 96 96">
${art}
  </svg>
</svg>
`;
