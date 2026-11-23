#!/usr/bin/env node
// Downloads spelunkr.tv's Star4000/Star3000 WOFF2 fonts and converts them to TTF
// inside SpelunkrTV/Fonts/ (gitignored, never committed).
//
// Usage: node tools/fetch-fonts.mjs
// Requires either npm package `wawoff2` (e.g. `npm install --no-save wawoff2`)
// or Python `fontTools` + `brotli` (`pip3 install fonttools brotli`).
import { execFileSync } from "node:child_process";
import { mkdirSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(here, "..", "SpelunkrTV", "Fonts");
const BASE = "https://spelunkr.tv/fonts/star4000/";
const NAMES = [
  "star4000",
  "star4000-large",
  "star4000-extended",
  "star4000-large-compressed",
  "star3000",
  "star3000-heavy",
];

async function loadWawoff2() {
  try {
    const mod = await import("wawoff2");
    return mod.default || mod;
  } catch {
    return null;
  }
}

function convertWithPython(woff2Path, ttfPath) {
  execFileSync("python3", [
    "-c",
    "import sys; from fontTools.ttLib import TTFont; f = TTFont(sys.argv[1]); f.flavor = None; f.save(sys.argv[2])",
    woff2Path,
    ttfPath,
  ], { stdio: "pipe" });
}

const wawoff2 = await loadWawoff2();
mkdirSync(OUT_DIR, { recursive: true });

for (const name of NAMES) {
  const url = `${BASE}${name}.woff2?v=2`;
  const res = await fetch(url, { headers: { "User-Agent": "SpelunkrTV/0.1" } });
  if (!res.ok) {
    console.error(`fetch-fonts: ${url} -> HTTP ${res.status}`);
    process.exit(1);
  }
  const woff2Bytes = Buffer.from(await res.arrayBuffer());
  const outPath = join(OUT_DIR, `${name}.ttf`);

  if (wawoff2 && typeof wawoff2.decompress === "function") {
    const ttf = Buffer.from(await wawoff2.decompress(woff2Bytes));
    writeFileSync(outPath, ttf);
    console.log(`  wrote ${name}.ttf (${(ttf.length / 1024).toFixed(1)} KB via wawoff2)`);
  } else {
    const tmp = join(tmpdir(), `spelunkr-${name}.woff2`);
    writeFileSync(tmp, woff2Bytes);
    try {
      convertWithPython(tmp, outPath);
      console.log(`  wrote ${name}.ttf (via Python fontTools)`);
    } catch {
      unlinkSync(tmp);
      console.error(
        "fetch-fonts: could not convert WOFF2 to TTF.\n" +
        "Install either:\n" +
        "  npm install --no-save wawoff2\n" +
        "or:\n" +
        "  pip3 install fonttools brotli"
      );
      process.exit(1);
    }
    unlinkSync(tmp);
  }
}

console.log(`Done. Fonts written to ${OUT_DIR}`);
