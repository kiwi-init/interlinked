// The hero's two linked glass frames, the app icon's mark in 3D: they drift in from apart, link
// as they do in the icon while a band of spectral light crosses them, and settle. After that the
// page only redraws to lean them towards the pointer. Without WebGL the icon's SVG stays; with
// reduced motion they're drawn once, linked. A file of its own, so the CSP stays script-src 'self'.

const VERT = `
attribute vec2 a;
void main() { gl_Position = vec4(a, 0.0, 1.0); }
`;

const FRAG = `
precision highp float;
uniform vec2 uRes;
uniform float uPx;
uniform float uBand;
uniform float uFlash;
uniform float uFade;
uniform vec3 uCa;
uniform vec3 uCb;
uniform mat3 uRa;
uniform mat3 uRb;
uniform mat3 uView;

const float HALF = 0.5;
const float HOLE = 0.3;
const float T = 0.05;
const float R = 0.01;
const float EYE = 9.0;
const float SPAN = 2.25;

vec3 bump3y(vec3 x, vec3 y) { return clamp(1.0 - x * x - y, 0.0, 1.0); }
vec3 spectral(float x) {
  const vec3 c1 = vec3(3.54585104, 2.93225262, 2.41593945);
  const vec3 x1 = vec3(0.69549072, 0.49228336, 0.27699880);
  const vec3 y1 = vec3(0.02312639, 0.15225084, 0.52607955);
  const vec3 c2 = vec3(3.90307140, 3.21182957, 3.96587128);
  const vec3 x2 = vec3(0.11748627, 0.86755042, 0.66077860);
  const vec3 y2 = vec3(0.84897130, 0.88445281, 0.73949448);
  return bump3y(c1 * (x - x1), y1) + bump3y(c2 * (x - x2), y2);
}

float box2(vec2 q, float h) { vec2 d = abs(q) - h; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }
float ring(vec3 p) {
  float d = max(box2(p.xy, HALF), -box2(p.xy, HOLE));
  vec2 w = vec2(d + R, abs(p.z) - T + R);
  return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - R;
}
vec3 local(vec3 p, int k) { return k == 0 ? uRa * (p - uCa) : uRb * (p - uCb); }
float one(vec3 p, int k) { return ring(local(p, k)); }
float map(vec3 p, out int id) {
  float a = one(p, 0), b = one(p, 1);
  id = a < b ? 0 : 1;
  return min(a, b);
}
vec3 normalOf(vec3 p, int k) {
  vec2 e = vec2(0.0004, -0.0004);
  return normalize(e.xyy * one(p + e.xyy, k) + e.yyx * one(p + e.yyx, k) + e.yxy * one(p + e.yxy, k) + e.xxx * one(p + e.xxx, k));
}

const vec3 NB = normalize(vec3(0.9, -0.35, 0.25));
vec3 band(vec3 p, float spread, out float mask) {
  float x = (dot(p, NB) - uBand) / (0.24 * (1.0 + spread));
  mask = exp(-x * x * 1.6) * step(abs(x), 1.6);
  vec3 c = spectral(clamp(0.5 - 0.42 * x, 0.0, 1.0)) * mask;
  float sheen = exp(-pow((x - 1.15) * 7.0, 2.0));
  return (c * 0.7 + vec3(sheen) * 0.5) * (0.3 + 0.9 * uFlash);
}

void main() {
  vec2 q = (gl_FragCoord.xy - 0.5 * uRes) / min(uRes.x, uRes.y) * SPAN;
  vec3 ro = uView * vec3(0.0, 0.0, EYE);
  vec3 rd = uView * normalize(vec3(q, -EYE));
  float px = SPAN / min(uRes.x, uRes.y);
  float css = px * uPx;
  vec3 col = vec3(0.0);
  float trans = 1.0;
  float t = EYE - 2.0;
  bool any = false;
  for (int layer = 0; layer < 4; layer++) {
    int id = 0;
    bool hit = false;
    for (int i = 0; i < 120; i++) {
      float d = map(ro + rd * t, id);
      if (d < 0.00015) { hit = true; break; }
      t += d * 0.9;
      if (t > EYE + 2.0) break;
    }
    if (!hit) break;
    any = true;
    vec3 pp = ro + rd * t;
    vec3 n = normalOf(pp, id);
    vec3 lp = local(pp, id);
    vec2 sq = abs(lp.xy);
    float m = max(sq.x, sq.y);
    float ez = T - abs(lp.z);
    float eo = HALF - m;
    float ei = m - HOLE;
    float edge = min(min(max(ez, eo), max(ez, ei)), min(max(HALF - sq.x, HALF - sq.y), max(abs(sq.x - HOLE), abs(sq.y - HOLE))));
    float t0 = t;
    for (int i = 0; i < 40; i++) { float d = one(ro + rd * t, id); if (d > 0.0) break; t += max(-d, 0.003); }
    float L = t - t0;
    vec3 mid = ro + rd * (t0 + 0.5 * L);
    float cosi = abs(dot(n, -rd));
    float fres = 0.04 + 0.96 * pow(1.0 - cosi, 5.0);
    float onFace = 1.0 - smoothstep(0.004, 0.012, ez);
    float rimLine = 1.0 - smoothstep(0.004 + 0.25 * css, 0.004 + 1.15 * css, edge);
    float rimGlow = exp(-max(edge - 0.004, 0.0) / (3.0 * css)) * 0.1;
    float corner = length(vec2(min(ez, min(eo, ei)), edge));
    float glint = exp(-corner / (2.2 * css)) * 0.5;
    float bm;
    vec3 light = band(mid, L * 1.5, bm);
    vec3 rimCol = mix(vec3(0.93, 0.94, 0.96), light * 1.6 + 0.3, clamp(bm, 0.0, 1.0) * 0.8);
    vec3 rf = reflect(rd, n);
    float sheen = smoothstep(0.72, 0.98, dot(rf, normalize(vec3(-0.4, 0.8, 0.45)))) * onFace * 0.06;
    float body = 0.045 + 0.05 * onFace;
    vec3 c = light * (0.38 + 0.8 * fres + 1.6 * L) + rimCol * (rimLine * 1.15 + rimGlow + glint) + vec3(fres) * 0.08 + vec3(sheen) + vec3(body);
    col += trans * c;
    trans *= 0.42;
    t += 0.004;
  }
  if (!any) { gl_FragColor = vec4(0.0); return; }
  col = col / (1.0 + 0.3 * col);
  gl_FragColor = vec4(col, 1.0 - trans * 0.75) * uFade;
}
`;

const INTRO = 2.6;
const LEAN = 7;
const TILT = 38;
const REST = 0.12;
const rad = (d) => (d * Math.PI) / 180;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
const ease = (x) => 1 - Math.pow(1 - clamp(x, 0, 1), 3);
const smooth = (a, b, v) => {
  const x = clamp((v - a) / (b - a), 0, 1);
  return x * x * (3 - 2 * x);
};

// Column-major 3x3 matrices, as uniformMatrix3fv takes them.
const mul = (a, b) => {
  const out = new Array(9);
  for (let c = 0; c < 3; c++) for (let r = 0; r < 3; r++) out[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
  return out;
};
const transpose = (m) => [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
const rotX = (d) => [1, 0, 0, 0, Math.cos(rad(d)), Math.sin(rad(d)), 0, -Math.sin(rad(d)), Math.cos(rad(d))];
const rotY = (d) => [Math.cos(rad(d)), 0, -Math.sin(rad(d)), 0, 1, 0, Math.sin(rad(d)), 0, Math.cos(rad(d))];
const rotZ = (d) => [Math.cos(rad(d)), Math.sin(rad(d)), 0, -Math.sin(rad(d)), Math.cos(rad(d)), 0, 0, 0, 1];
// A rotation by these degrees about an axis (Rodrigues).
function about([x, y, z], d) {
  const l = Math.hypot(x, y, z);
  [x, y, z] = [x / l, y / l, z / l];
  const c = Math.cos(rad(d)), s = Math.sin(rad(d)), k = 1 - c;
  return [c + x * x * k, y * x * k + z * s, z * x * k - y * s, x * y * k - z * s, c + y * y * k, z * y * k + x * s, x * z * k + y * s, y * z * k - x * s, c + z * z * k];
}

// Where the frames are at a moment of the intro (0 apart, 1 linked), with the pointer's lean.
function pose(at, lean) {
  const e = ease(at);
  const apart = 1 - e;
  return {
    ca: [-0.24 - 1.1 * apart, 0.24 + 0.55 * apart, 0.35 * apart],
    cb: [0.24 + 1.1 * apart, -0.24 - 0.55 * apart, -0.35 * apart],
    ra: transpose(rotZ(-24 * apart)),
    rb: transpose(about([1, -1, 0], TILT + 62 * apart)),
    view: transpose(mul(rotY(22 + lean[0]), rotX(-28 + lean[1]))),
    band: -1.4 + (1.4 + REST + 0.18 * (lean[0] / LEAN)) * smooth(0.35, 1.0, at),
    flash: smooth(0.4, 0.75, at) * (1 - smooth(0.85, 1.0, at)) * 0.6 + 0.55,
    fade: smooth(0, 0.3, at),
  };
}

function start(box) {
  const canvas = box.querySelector("canvas");
  const gl = canvas && canvas.getContext("webgl", { premultipliedAlpha: false, antialias: false, alpha: true });
  if (!gl) return;
  const shader = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
  };
  const vs = shader(gl.VERTEX_SHADER, VERT), fs = shader(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) return;
  const prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
  gl.useProgram(prog);
  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const a = gl.getAttribLocation(prog, "a");
  gl.enableVertexAttribArray(a);
  gl.vertexAttribPointer(a, 2, gl.FLOAT, false, 0, 0);
  const u = Object.fromEntries(["uRes", "uPx", "uBand", "uFlash", "uFade", "uCa", "uCb", "uRa", "uRb", "uView"].map((n) => [n, gl.getUniformLocation(prog, n)]));

  const still = matchMedia("(prefers-reduced-motion: reduce)");
  const hover = matchMedia("(hover: hover) and (pointer: fine)");
  let at = still.matches ? 1 : 0;
  let lean = [0, 0];
  let want = [0, 0];
  let seen = true;
  let frame = 0;
  let last = 0;

  function draw() {
    const p = pose(at, lean);
    gl.uniform2f(u.uRes, canvas.width, canvas.height);
    gl.uniform1f(u.uPx, canvas.width / Math.max(1, canvas.clientWidth));
    gl.uniform1f(u.uBand, p.band);
    gl.uniform1f(u.uFlash, p.flash);
    gl.uniform1f(u.uFade, p.fade);
    gl.uniform3fv(u.uCa, p.ca);
    gl.uniform3fv(u.uCb, p.cb);
    gl.uniformMatrix3fv(u.uRa, false, p.ra);
    gl.uniformMatrix3fv(u.uRb, false, p.rb);
    gl.uniformMatrix3fv(u.uView, false, p.view);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  const moving = () => at < 1 || Math.abs(want[0] - lean[0]) > 0.02 || Math.abs(want[1] - lean[1]) > 0.02;
  function tick(now) {
    frame = 0;
    const dt = last ? Math.min((now - last) / 1000, 0.05) : 0;
    last = now;
    if (!still.matches) at = Math.min(1, at + dt / INTRO);
    const k = 1 - Math.exp(-dt * 4);
    lean = [lean[0] + (want[0] - lean[0]) * k, lean[1] + (want[1] - lean[1]) * k];
    draw();
    if (moving()) wake();
    else last = 0;
  }
  function wake() {
    if (!frame && seen && !document.hidden) frame = requestAnimationFrame(tick);
  }

  function size() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
    if (!w || !h) return;
    if (canvas.width !== w || canvas.height !== h) [canvas.width, canvas.height] = [w, h];
    draw();
    wake();
  }

  new ResizeObserver(size).observe(canvas);
  new IntersectionObserver(([entry]) => {
    seen = entry.isIntersecting;
    if (seen) return wake();
    cancelAnimationFrame(frame);
    frame = 0;
    last = 0;
  }).observe(box);
  document.addEventListener("visibilitychange", () => {
    last = 0;
    wake();
  });
  addEventListener(
    "pointermove",
    (e) => {
      if (still.matches || !hover.matches) return;
      const r = box.getBoundingClientRect();
      const x = clamp((e.clientX - (r.left + r.width / 2)) / innerWidth, -1, 1);
      const y = clamp((e.clientY - (r.top + r.height / 2)) / innerHeight, -1, 1);
      want = [x * LEAN, y * LEAN];
      wake();
    },
    { passive: true },
  );
  still.addEventListener("change", () => {
    at = 1;
    want = [0, 0];
    lean = [0, 0];
    draw();
  });

  size();
  box.classList.add("gl");
}

const box = document.querySelector(".linked");
if (box) start(box);
