#!/usr/bin/env node
// Re-extracts spelunkr.tv's schedule engine into the Apple TV app.
// Run when the site changes its schedule format:  node tools/update-engine.mjs
// Then rebuild the app in Xcode.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, "..", "SpelunkrTV", "Engine", "spelunkr-engine.js.txt");
const SITE = "https://spelunkr.tv/";

const fail = (m) => { console.error("update-engine: " + m); process.exit(1); };
const text = async (u) => { const r = await fetch(u); if (!r.ok) fail(`${u} -> HTTP ${r.status}`); return r.text(); };

// Index of the brace that closes the one at `open`, skipping strings, templates and regex-free code.
function matchBrace(src, open) {
  let depth = 0;
  const stack = []; // template nesting
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === '"' || c === "'") { const q = c; for (i++; i < src.length && src[i] !== q; i++) if (src[i] === "\\") i++; continue; }
    if (c === "`") { stack.push(depth); depth = 0; i = skipTemplate(src, i + 1, stack); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0 && !stack.length) return i; }
  }
  return -1;
  function skipTemplate(s, j, st) {
    for (; j < s.length; j++) {
      if (s[j] === "\\") { j++; continue; }
      if (s[j] === "`") { depth = st.pop(); return j; }
      if (s[j] === "$" && s[j + 1] === "{") {
        // scan the ${ ... } expression
        let d = 1; j += 2;
        for (; j < s.length && d > 0; j++) {
          const ch = s[j];
          if (ch === '"' || ch === "'") { const q = ch; for (j++; j < s.length && s[j] !== q; j++) if (s[j] === "\\") j++; }
          else if (ch === "`") { j = skipTemplate(s, j + 1, [...st, d]); st.length = st.length; }
          else if (ch === "{") d++;
          else if (ch === "}") d--;
        }
        j--;
      }
    }
    return j;
  }
}

const html = await text(SITE);
const asset = (html.match(/\/assets\/index-[\w-]+\.js/) || [])[0] || fail("could not find the site's script in its HTML");
const js = await text(new URL(asset, SITE).href);

const start = js.search(/const \w+=\["centre","lower"\]/);
if (start < 0) fail("start marker not found");
const npv = js.indexOf("no published version");
if (npv < 0) fail("schedule lookup function not found");
const fnStart = js.lastIndexOf("function ", npv);
const FN = (js.slice(fnStart).match(/^function (\w+)\(/) || [])[1] || fail("could not name the lookup function");
const end = matchBrace(js, js.indexOf("{", fnStart));
if (end < 0) fail("could not find the end of the lookup function");
const RB = (js.match(/function (\w+)\(e,t=\[\]\)\{const n=\{channelId:e,versions:\[\]\}/) || [])[1] || fail("channel constructor not found");
const zoAt = js.indexOf(": no items`");
const ZO = (js.slice(js.lastIndexOf("function ", zoAt)).match(/^function (\w+)\(/) || [])[1] || fail("version loader not found");

const body = js.slice(start, end + 1);
for (const name of [FN, RB, ZO]) if (!new RegExp(`function ${name}\\(`).test(body)) fail(`${name} is outside the extracted engine`);

const glue = readFileSync(join(here, "glue.js"), "utf8");
const header = `// spelunkr.tv schedule engine, extracted from ${asset} on ${new Date().toISOString()}\n// by tools/update-engine.mjs. Do not edit by hand.\n`;
const engine = `${header}${body}\nvar SPK_RB=${RB},SPK_ZO=${ZO},SPK_FN=${FN};\n${glue}`;

// Smoke test against the live lineup before writing anything.
const ctx = { console: { log() {}, warn() {}, error() {} } };
vm.createContext(ctx);
try { vm.runInContext(engine, ctx); } catch (e) { fail("extracted engine does not run: " + e.message); }
const base = "https://spelunkr.tv/broadcast/";
const lineup = JSON.parse(await text(base + "lineup.json"));
const platforms = {};
let ok = 0;
for (const ch of lineup.channels.slice(0, 6)) {
  for (const v of ch.versions) {
    const m = await text(base + v.manifest);
    const p = JSON.parse(m).platform;
    if (p && !platforms[p]) platforms[p] = await text(base + p);
    ctx.spkAddVersion(ch.id, m, p ? platforms[p] : null, JSON.stringify({ v: v.v, epochMs: v.epochMs, effectiveAtMs: v.effectiveAtMs, startIndex: v.startIndex }));
  }
  const now = JSON.parse(ctx.spkNow(ch.id, Date.now()));
  console.log(`  ${String(ch.dial).padStart(3)} ${ch.name.padEnd(22)} ${now.type.padEnd(10)} ${now.title || ""}`);
  ok++;
}
if (!ok) fail("smoke test found no channels");

// Overlay-music channels (silent footage with music on top): load them too, and check that our
// copy of the playlist builder in glue.js still agrees with the site's own.
const WB = (body.match(/function (\w+)\(e,t,n,r,s,i\)\{if\(!e\)return\[\];let o=null;if\(t\.year\)/) || [])[1];
if (!WB) console.warn("  warning: could not find the site's overlay playlist builder; skipping the cross-check");
else vm.runInContext(`var SPK_WB=${WB};`, ctx);
for (const ch of lineup.channels.filter((c) => c.audioOverlay && !c.debugOnly)) {
  for (const v of ch.versions) {
    if (ctx.spkHasVersion(ch.id, v.v)) continue;
    const m = await text(base + v.manifest);
    const p = JSON.parse(m).platform;
    if (p && !platforms[p]) platforms[p] = await text(base + p);
    ctx.spkAddVersion(ch.id, m, p ? platforms[p] : null, JSON.stringify({ v: v.v, epochMs: v.epochMs, effectiveAtMs: v.effectiveAtMs, startIndex: v.startIndex }));
  }
  const t0 = Date.now();
  let cues = 0, mismatches = 0;
  for (let i = 0; i < 40; i++) {
    const t = t0 + i * 37 * 60 * 1000 + 13_000;
    const cue = JSON.parse(ctx.spkOverlay(ch.id, t) || "null");
    if (!cue) continue; // a card or ad was on air
    cues++;
    if (!cue.track || !cue.track.url) fail(`${ch.id}: overlay has no playable track at ${new Date(t).toISOString()}`);
    if (WB) {
      ctx.__t = t; ctx.__id = ch.id;
      const same = vm.runInContext(`(function () {
        var ch = spkChannels[__id], r = SPK_FN(ch, __t), v = ch.versions.filter(function (x) { return x.v === r.version; })[0];
        var a = JSON.stringify(SPK_WB(v.audioPools, r.item, r.item.videoIndex, __id, r.item.duration, r.seed));
        var b = JSON.stringify(spkOverlayPlan(v.audioPools, r.item, r.item.videoIndex, __id, r.item.duration, r.seed));
        return a === b;
      })()`, ctx);
      if (!same) mismatches++;
    }
  }
  if (!cues) fail(`${ch.id}: overlay smoke test found no tapes on air`);
  if (mismatches) fail(`${ch.id}: glue.js's overlay playlist differs from the site's in ${mismatches} of ${cues} samples; copy the site's new algorithm into spkOverlayPlan`);
  console.log(`  ${String(ch.dial).padStart(3)} ${ch.name.padEnd(22)} overlay ok (${cues} tapes sampled${WB ? ", matches the site" : ""})`);
}
mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, engine);
console.log(`wrote ${OUT} (${(engine.length / 1024).toFixed(0)} KB; engine ${lineup.engine})`);
