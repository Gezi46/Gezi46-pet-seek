#!/usr/bin/env node
/**
 * peekdeek.gltf -> peekdeek_opt.glb optimizer.
 *
 * The source is a Blockbench Minecraft-player export whose 6.83 MB binary buffer is
 * stored as a 9.12 M-char base64 data URI inside a 10.8 MB .gltf. ~6.07 MB of that
 * buffer is animation data, and two animations are pathologically stretched:
 *
 *   MainAnim                    282,882 keys / 4,312.000 s
 *   hold_mainhand$minecraft:mace 32,235 keys / 1,000.000 s
 *
 * Everything the desktop pet actually needs is a small set of short loops. This tool:
 *   1. rebuilds the asset as a single self-contained .glb (binary, 4-byte aligned),
 *   2. keeps a curated animation set and drops the rest,
 *   3. time-caps + resamples the two over-long animations so they stay usable,
 *   4. optionally drops animation channels that never change (Godot does this too,
 *      but removing them shrinks the file the editor has to chew through).
 *
 * The mesh hierarchy, node names and materials are preserved byte-for-byte so that
 * every retained animation still drives exactly the same nodes.
 *
 * Usage:
 *   node gltf_to_glb.mjs <in.gltf> <out.glb> [--report]
 */
import { readFileSync, writeFileSync } from "node:fs";

// ---------------------------------------------------------------- CLI

const argv = process.argv.slice(2);
const positional = [];
let extraFile = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--extra") { extraFile = argv[++i]; continue; }
  if (argv[i].startsWith("--")) continue;
  positional.push(argv[i]);
}
const [inFile, outFile] = positional;
if (!inFile || !outFile) {
  console.error("usage: node gltf_to_glb.mjs <in.gltf> <out.glb> [--extra <more.gltf>] [--report]");
  process.exit(2);
}

// ---------------------------------------------------------------- config

/**
 * Animations worth shipping in a desktop pet, with optional overrides.
 * `capSeconds` time-limits an animation; `resampleHz` then re-samples the curve at a
 * uniform rate, which is how the 4,312 s MainAnim becomes a sane 24 s sway.
 */
const KEEP = {
  // Core locomotion / pose set
  idle: {},
  walk: {},
  walkBack: {},
  run: {},
  jump: {},
  sneak: {},
  sneaking: {},
  sit: {},
  sleep: {},
  climb: {},
  climbing: {},
  swim: {},
  swim_stand: {},
  fly: { capSeconds: 0.75, resampleHz: 30 },
  death: {},
  attacked: {},

  // Desktop-pet interactions
  use_mainhand: {},
  "use_mainhand:eat": {},   // 吃东西（2026-10-01 加回：喂食要用）
  use_offhand: {},
  swing_hand: {},
  swing_offhand: {},
  riptide: {},              // 转圈（2026-10-01 加回：开心时的动作）
  BlinkEye: {},
  BlinkTwo: {},

  // Personality emotes (author-named "extra" set)
  extra0: {},
  extra1: { keepConstant: true },   // 蜷缩（2026-10-01：**静态姿势**动画，别丢"恒定"通道 —— 姿势全在里面）
  extra2: {},
  extra3: {},
  extra4: {},
  extra5: {},
  extra6: {},
  extra7: {},

  // Ladders double nicely as "climb a window edge" clips
  ladder_up: {},
  ladder_down: {},
  ladder_stillness: {},

  // The rig's default pose track, rescued from a 4,312 s export artefact.
  MainAnim: { capSeconds: 24, resampleHz: 8, minKeys: 64 },
};

const DROP_CONSTANT_CHANNELS = process.env.KEEP_CONSTANT === "1" ? false : true;

// ---------------------------------------------------------------- glTF load

const srcText = readFileSync(inFile, "utf8");
const src = JSON.parse(srcText);
const bytesBefore = Buffer.byteLength(srcText, "utf8");

function loadSourceBuffer(obj, file) {
  const buf = obj.buffers[0];
  if (buf.uri?.startsWith("data:")) {
    return Buffer.from(buf.uri.slice(buf.uri.indexOf(",") + 1), "base64");
  }
  if (buf.uri) return readFileSync(new URL(buf.uri, `file://${file}`));
  return readFileSync(file.replace(/\.gltf$/, ".bin"));
}
const srcBin = loadSourceBuffer(src, inFile);
// 额外动画源（补主源缺的动作，比如 main.gltf 的 extra1）。两文件网格一致、只动画集不同
let extraSrc = null, extraBin = null;
if (extraFile) {
  extraSrc = JSON.parse(readFileSync(extraFile, "utf8"));
  extraBin = loadSourceBuffer(extraSrc, extraFile);
}

const COMP_SIZE = { 5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4 };
const TYPE_COUNT = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT2: 4, MAT3: 9, MAT4: 16 };
const ARRAY_CTOR = { 5120: Int8Array, 5121: Uint8Array, 5122: Int16Array, 5123: Uint16Array, 5125: Uint32Array, 5126: Float32Array };

/** Read an accessor into a flat JS array of numbers ("a b c a b c ...").
 *  S/B = 源 gltf 对象 + 它的 bin（默认主源，--extra 时传额外源） */
function readAccessor(index, S = src, B = srcBin) {
  const acc = S.accessors[index];
  const comps = TYPE_COUNT[acc.type];
  const total = acc.count * comps;
  const bv = acc.bufferView != null ? S.bufferViews[acc.bufferView] : null;
  const out = new Array(total);

  if (!bv) {
    // No bufferView: glTF allows a zero-filled accessor (often all-zero weights).
    for (let i = 0; i < total; i++) out[i] = 0;
    return out;
  }

  const compSize = COMP_SIZE[acc.componentType];
  const elemSize = comps * compSize;
  const stride = bv.byteStride ?? elemSize;
  const base = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0);
  const Ctor = ARRAY_CTOR[acc.componentType];
  const littleEndian = !S.extensionsRequired?.includes("KHR_mesh_quantization");

  for (let i = 0; i < acc.count; i++) {
    const off = base + i * stride;
    for (let c = 0; c < comps; c++) {
      const at = off + c * compSize;
      let v;
      switch (acc.componentType) {
        case 5126: v = B.readFloatLE(at); break;
        case 5125: v = B.readUInt32LE(at); break;
        case 5123: v = B.readUInt16LE(at); break;
        case 5122: v = B.readInt16LE(at); break;
        case 5121: v = B.readUInt8(at); break;
        default: v = B.readInt8(at); break;
      }
      out[i * comps + c] = v;
    }
  }
  return out;
}

// ---------------------------------------------------------------- glb builder

class GlbBuilder {
  constructor() {
    this.bin = [];       // list of Buffers
    this.binLength = 0;
    this.bufferViews = [];
    this.accessors = [];
  }

  /** Append a typed array as a new bufferView and return its index. */
  addView(typedArray, { target, byteStride } = {}) {
    const buf = Buffer.from(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
    // glTF requires each bufferView to start 4-byte aligned.
    const pad = (4 - (this.binLength % 4)) % 4;
    if (pad) { this.bin.push(Buffer.alloc(pad)); this.binLength += pad; }

    const view = {
      buffer: 0,
      byteOffset: this.binLength,
      byteLength: buf.length,
    };
    if (target != null) view.target = target;
    if (byteStride != null) view.byteStride = byteStride;

    this.bin.push(buf);
    this.binLength += buf.length;
    this.bufferViews.push(view);
    return this.bufferViews.length - 1;
  }

  /** Copy an accessor (values already extracted) into a fresh bufferView. */
  addAccessorFromValues(values, { componentType, type, min, max, target }) {
    const comps = TYPE_COUNT[type];
    const Ctor = ARRAY_CTOR[componentType];
    const arr = new Ctor(values.length);
    for (let i = 0; i < values.length; i++) arr[i] = values[i];
    const bufferView = this.addView(arr, { target });

    const accessor = { bufferView, componentType, count: values.length / comps, type };
    if (min) accessor.min = min;
    if (max) accessor.max = max;
    this.accessors.push(accessor);
    return this.accessors.length - 1;
  }

  finish({ json }) {
    const binChunk = Buffer.concat(this.bin, this.binLength);
    // The BIN chunk must be padded to 4 bytes with zeros.
    const binPad = (4 - (binChunk.length % 4)) % 4;
    const binPadded = binPad ? Buffer.concat([binChunk, Buffer.alloc(binPad)]) : binChunk;

    json.buffers = [{ byteLength: binPadded.length }];

    let jsonText = JSON.stringify(json);
    // JSON chunk is padded with spaces to 4 bytes.
    const jsonPad = (4 - (Buffer.byteLength(jsonText, "utf8") % 4)) % 4;
    if (jsonPad) jsonText += " ".repeat(jsonPad);
    const jsonBuf = Buffer.from(jsonText, "utf8");

    const total = 12 + 8 + jsonBuf.length + 8 + binPadded.length;
    const out = Buffer.alloc(total);
    let o = 0;
    out.writeUInt32LE(0x46546c67, o); o += 4;      // "glTF"
    out.writeUInt32LE(2, o); o += 4;               // version
    out.writeUInt32LE(total, o); o += 4;           // length
    out.writeUInt32LE(jsonBuf.length, o); o += 4;
    out.writeUInt32LE(0x4e4f534a, o); o += 4;      // "JSON"
    jsonBuf.copy(out, o); o += jsonBuf.length;
    out.writeUInt32LE(binPadded.length, o); o += 4;
    out.writeUInt32LE(0x004e4942, o); o += 4;      // "BIN"
    binPadded.copy(out, o);

    return { out, jsonBytes: jsonBuf.length, binBytes: binPadded.length };
  }
}

// ---------------------------------------------------------------- resampling

function lerp(a, b, t) { return a + (b - a) * t; }

/**
 * Re-normalize quaternion rows in place. Resampling with plain component lerp
 * walks slightly off the unit sphere, and Godot expects normalized rotations.
 */
function normalizeQuatRows(values, count, comps) {
  if (comps !== 4) return values;
  for (let i = 0; i < count; i++) {
    const o = i * 4;
    const len = Math.hypot(values[o], values[o + 1], values[o + 2], values[o + 3]);
    if (len > 1e-12 && Math.abs(len - 1) > 1e-9) {
      values[o] /= len; values[o + 1] /= len; values[o + 2] /= len; values[o + 3] /= len;
    }
  }
  return values;
}

/**
 * Time-cap then uniformly resample a sampler's (input, output) pair.
 * Returns { times, values } with INTERPOLATION LINEAR preserved.
 */
function resampleSampler(times, values, comps, { capSeconds, resampleHz, minKeys }) {
  const t0 = times[0];
  let tEnd = times[times.length - 1];
  if (capSeconds != null) tEnd = Math.min(tEnd, t0 + capSeconds);

  const span = tEnd - t0;
  let count = Math.max(Math.ceil(span * resampleHz) + 1, minKeys ?? 2);

  const outTimes = new Float32Array(count);
  const outVals = new Float32Array(count * comps);

  let src = 0;
  for (let i = 0; i < count; i++) {
    const t = span <= 0 ? t0 : t0 + (span * i) / (count - 1);
    outTimes[i] = t;

    // Advance `src` until it brackets t.
    while (src < times.length - 2 && times[src + 1] < t) src++;

    const tA = times[src];
    const tB = times[src + 1] ?? tA;
    const f = tB > tA ? Math.min(1, Math.max(0, (t - tA) / (tB - tA))) : 0;
    for (let c = 0; c < comps; c++) {
      outVals[i * comps + c] = lerp(values[src * comps + c], values[(src + 1) * comps + c] ?? values[src * comps + c], f);
    }
  }

  return { times: outTimes, values: outVals, count };
}

/** True when every sample equals the first sample (within epsilon). */
function isConstant(values, count, comps, eps = 1e-7) {
  for (let i = 1; i < count; i++) {
    for (let c = 0; c < comps; c++) {
      if (Math.abs(values[i * comps + c] - values[c]) > eps) return false;
    }
  }
  return true;
}

// ---------------------------------------------------------------- build

const builder = new GlbBuilder();
const stats = { animations: [], droppedAnims: [], droppedChannels: 0, resampled: [] };

// 1. Copy every mesh: attributes in a stable order, then indices.
const seenAccessor = new Map();
function copyAccessor(index, target) {
  if (seenAccessor.has(index)) {
    // Accessors shared between meshes (rare here) are copied fresh so each
    // bufferView keeps a single `target`, which some importers prefer.
    seenAccessor.delete(index);
  }
  const acc = src.accessors[index];
  const values = readAccessor(index);
  const newIndex = builder.addAccessorFromValues(values, {
    componentType: acc.componentType,
    type: acc.type,
    min: acc.min,
    max: acc.max,
    target,
  });
  seenAccessor.set(index, newIndex);
  return newIndex;
}

const meshes = src.meshes.map((m) => ({
  name: m.name,
  primitives: m.primitives.map((p) => {
    const attributes = {};
    // Deterministic attribute order keeps diffs stable between runs.
    for (const key of ["POSITION", "NORMAL", "TANGENT", "TEXCOORD_0", "TEXCOORD_1", "COLOR_0", "JOINTS_0", "WEIGHTS_0"]) {
      if (p.attributes[key] != null) attributes[key] = copyAccessor(p.attributes[key], 34962);
    }
    for (const key of Object.keys(p.attributes)) {
      if (attributes[key] == null) attributes[key] = copyAccessor(p.attributes[key], 34962);
    }
    const prim = { attributes };
    if (p.indices != null) prim.indices = copyAccessor(p.indices, 34963);
    if (p.material != null) prim.material = p.material;
    if (p.mode != null) prim.mode = p.mode;
    return prim;
  }),
}));

// 2. Copy images (embedded PNG) and textures/samplers/materials by reference.
const images = (src.images ?? []).map((im) => {
  if (im.bufferView == null) return { ...im };
  const bv = src.bufferViews[im.bufferView];
  const slice = srcBin.subarray(bv.byteOffset ?? 0, (bv.byteOffset ?? 0) + bv.byteLength);
  const bufferView = builder.addView(Buffer.from(slice));
  return { name: im.name, mimeType: im.mimeType, bufferView };
});

// 3. Copy animations (filtered + optionally resampled).
//    主源优先；主源没有、而 --extra 源有的（比如 main.gltf 的 extra1）从 extra 补
const animations = [];
const keptNames = new Set();

/** 把一个动画（来自源 S/B）按 KEEP 配置拷进 builder。返回 true = 保留了 */
function buildAnim(anim, S, B) {
  const cfg = KEEP[anim.name];
  if (!cfg) return false;

  const channels = [];
  const samplers = [];
  let droppedConstant = 0;
  const resampling = cfg.resampleHz != null || cfg.capSeconds != null;

  for (const ch of anim.channels) {
    const s = anim.samplers[ch.sampler];
    const inAcc = S.accessors[s.input];
    const outAcc = S.accessors[s.output];
    const comps = TYPE_COUNT[outAcc.type];

    const timesIn = readAccessor(s.input, S, B);
    const valsIn = readAccessor(s.output, S, B);

    let times, values, count;

    if (resampling) {
      const r = resampleSampler(timesIn, valsIn, comps, cfg);
      times = Array.from(r.times);
      values = Array.from(r.values);
      count = r.count;
      if (ch.target.path === "rotation") normalizeQuatRows(values, count, comps);
    } else {
      times = timesIn;
      values = valsIn;
      count = inAcc.count;
      if (ch.target.path === "rotation") normalizeQuatRows(values, count, comps);
    }

    // Drop channels that never move - they carry no information.
    // 例外：静态姿势动画（cfg.keepConstant）——"恒定"通道承载的正是那个姿势
    if (!cfg.keepConstant && DROP_CONSTANT_CHANNELS && isConstant(values, count, comps)) {
      droppedConstant++;
      continue;
    }

    const tMin = times[0];
    const tMax = times[times.length - 1];

    const inputIdx = builder.addAccessorFromValues(times, {
      componentType: 5126, type: "SCALAR", min: [tMin], max: [tMax],
    });
    const outputIdx = builder.addAccessorFromValues(values, {
      componentType: 5126, type: outAcc.type,
    });

    // Channels and samplers are emitted in lockstep, so a channel always
    // references the sampler with the same index.
    channels.push({ sampler: samplers.length, target: { node: ch.target.node, path: ch.target.path } });
    samplers.push({ input: inputIdx, output: outputIdx, interpolation: s.interpolation ?? "LINEAR" });
  }

  stats.droppedChannels += droppedConstant;

  if (channels.length === 0) {
    // Every track was constant: the clip is a static pose. Keep a 1-frame
    // version so the state still exists for the state machine.
    const singleChannels = [];
    const singleSamplers = [];
    for (const ch of anim.channels.slice(0, 1)) {
      const outAcc = S.accessors[anim.samplers[ch.sampler].output];
      const comps = TYPE_COUNT[outAcc.type];
      const valsIn = readAccessor(anim.samplers[ch.sampler].output, S, B);
      const inputIdx = builder.addAccessorFromValues([0], { componentType: 5126, type: "SCALAR", min: [0], max: [0] });
      const outputIdx = builder.addAccessorFromValues(valsIn.slice(0, comps), { componentType: 5126, type: outAcc.type });
      singleChannels.push({ sampler: singleSamplers.length, target: { node: ch.target.node, path: ch.target.path } });
      singleSamplers.push({ input: inputIdx, output: outputIdx, interpolation: "LINEAR" });
    }
    if (singleChannels.length) {
      animations.push({ name: anim.name, channels: singleChannels, samplers: singleSamplers });
      stats.animations.push({ name: anim.name, channels: singleChannels.length, note: "static" });
    }
    return true;
  }

  animations.push({ name: anim.name, channels, samplers });
  const note = resampling ? `resampled(cap=${cfg.capSeconds ?? "-"}s @${cfg.resampleHz ?? "-"}Hz)` : "";
  stats.animations.push({ name: anim.name, channels: channels.length, note });
  return true;
}

for (const anim of src.animations ?? []) {
  if (!KEEP[anim.name]) { stats.droppedAnims.push(anim.name); continue; }
  if (buildAnim(anim, src, srcBin)) keptNames.add(anim.name);
}
if (extraSrc) {
  for (const anim of extraSrc.animations ?? []) {
    if (keptNames.has(anim.name) || !KEEP[anim.name]) continue;
    buildAnim(anim, extraSrc, extraBin);
  }
}

// ---------------------------------------------------------------- assemble json

const gltf = {
  asset: {
    version: "2.0",
    generator: "pet_tools/gltf_to_glb.mjs (optimized from Blockbench export)",
  },
  scene: src.scene ?? 0,
  scenes: src.scenes,
  nodes: src.nodes,
  meshes,
  materials: src.materials,
  animations,
  accessors: builder.accessors,
  bufferViews: builder.bufferViews,
  buffers: [],
};
if (src.samplers) gltf.samplers = src.samplers;
if (src.textures) gltf.textures = src.textures;
if (images.length) gltf.images = images;
if (src.skins) gltf.skins = src.skins;
if (src.extensionsUsed) gltf.extensionsUsed = src.extensionsUsed;

const { out, jsonBytes, binBytes } = builder.finish({ json: gltf });
writeFileSync(outFile, out);

// ---------------------------------------------------------------- report

const beforeMB = bytesBefore / 1048576;
const afterMB = out.length / 1048576;
console.log(`in : ${inFile}  ${beforeMB.toFixed(2)} MiB (text)`);
console.log(`out: ${outFile}  ${afterMB.toFixed(2)} MiB (glb)`);
console.log(`     json ${(jsonBytes / 1048576).toFixed(2)} MiB + bin ${(binBytes / 1048576).toFixed(2)} MiB`);
console.log(`reduction: ${(beforeMB / afterMB).toFixed(1)}x smaller (${(100 - (afterMB / beforeMB) * 100).toFixed(1)}% less)`);
console.log(`\nanimations kept: ${stats.animations.length}, dropped: ${stats.droppedAnims.length}`);
console.log(`constant channels removed: ${stats.droppedChannels}`);
console.log("\nkept:");
for (const a of stats.animations) {
  console.log(`  ${a.name.padEnd(24)} channels=${String(a.channels).padStart(3)} ${a.note}`);
}
if (process.argv.includes("--report")) {
  console.log("\ndropped: " + stats.droppedAnims.join(", "));
}
