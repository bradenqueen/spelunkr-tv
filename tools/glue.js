
// ---- Spelunkr TV glue (written for the Apple TV app, not part of spelunkr.tv) ----
// SPK_RB / SPK_ZO / SPK_FN are set by update-engine.mjs to the site's own
// "new channel", "add version" and "what's on at time t" functions.
function spkBuildVersion(manifest, platform, meta) {
  var r = manifest.bumps || [], s = (platform && platform.bumps) || [];
  return {
    v: meta.v, epochMs: meta.epochMs,
    effectiveAtMs: meta.effectiveAtMs != null ? meta.effectiveAtMs : meta.epochMs,
    startIndex: meta.startIndex || 0,
    items: manifest.items,
    bumps: r.length && s.length ? {
      channelBumps: r, platformBumps: s,
      channelAudio: manifest.audioOverlay ? Object.values(manifest.audioPools || {}).flat() : (manifest.audio || []),
      platformAudio: platform.audio || []
    } : null,
    audioPools: manifest.audioPools || null,
    audioOverlay: !!manifest.audioOverlay,
    block: manifest.block || null,
    ads: manifest.ads || null,
    engine: manifest.engine
  };
}
var spkChannels = {};
function spkAddVersion(channelId, manifestJSON, platformJSON, metaJSON) {
  var ch = spkChannels[channelId] || (spkChannels[channelId] = SPK_RB(channelId, []));
  var meta = JSON.parse(metaJSON);
  if (ch.versions.some(function (x) { return x.v === meta.v; })) return true;
  SPK_ZO(ch, spkBuildVersion(JSON.parse(manifestJSON), platformJSON ? JSON.parse(platformJSON) : null, meta));
  return true;
}
function spkHasVersion(channelId, v) {
  var ch = spkChannels[channelId];
  return !!ch && ch.versions.some(function (x) { return x.v === v; });
}
function spkSeekBase(item) {
  if (item && item.type === "ad") return (item.slice && Number.isInteger(item.slice.inMs) && item.slice.inMs > 0) ? item.slice.inMs / 1e3 : 0;
  return (item && Number.isInteger(item.inS) && item.inS > 0) ? item.inS : 0;
}
function spkNextVideo(ch, fromMs) {
  var t = fromMs;
  for (var i = 0; i < 60; i++) {
    var r = SPK_FN(ch, t);
    if (r.item.type === "video") return { title: r.item.title || r.item.id, year: r.item.year || null, startMs: r.startMs };
    t = r.endMs;
  }
  return null;
}
// What is on air on a channel at nowMs, as JSON.
function spkNow(channelId, nowMs) {
  var ch = spkChannels[channelId];
  if (!ch || !ch.versions.length) return null;
  var r = SPK_FN(ch, nowMs);
  var it = r.item;
  var out = {
    type: it.type, key: r.key, offset: r.offsetExact, remaining: r.remaining,
    startMs: r.startMs, endMs: r.endMs, version: r.version,
    seekBase: spkSeekBase(it), next: spkNextVideo(ch, r.endMs)
  };
  if (it.type === "video") {
    out.id = it.id; out.file = it.file || it.mp4 || null; out.title = it.title || it.id;
    out.year = it.year || null; out.duration = it.duration;
    if (it.ambient != null) out.ambient = it.ambient;
  } else if (it.type === "ad") {
    out.id = (it.slice && it.slice.tape) || null; out.file = (it.slice && it.slice.file) || null;
    out.title = "Commercial break";
    if (it.slice && Number.isFinite(Number(it.slice.gainDb))) out.gainDb = Number(it.slice.gainDb);
  } else {
    var text = function (b) { return b && b.slides ? b.slides.map(function (x) { return x.text; }) : []; };
    out.channelSlides = text(it.channelBump);
    out.platformSlides = text(it.platformBump);
    out.half = it.half || null;
    var au = it.channelAudio || it.platformAudio || null;
    out.audio = au && au.filename ? { filename: au.filename, title: au.title || null, artist: au.artist || null, startOffset: au.startOffset || 0 } : null;
  }
  return JSON.stringify(out);
}
// The next n shows (videos only) from nowMs, for the guide.
function spkUpcoming(channelId, nowMs, n) {
  var ch = spkChannels[channelId];
  if (!ch || !ch.versions.length) return "[]";
  var out = [], t = nowMs;
  for (var i = 0; i < 400 && out.length < n; i++) {
    var r = SPK_FN(ch, t);
    if (r.item.type === "video") out.push({ title: r.item.title || r.item.id, year: r.item.year || null, startMs: r.startMs, endMs: r.endMs });
    t = r.endMs;
  }
  return JSON.stringify(out);
}

// ---- Overlay music (channels with audioOverlay: true, e.g. VACATION SLIDES) ----
// Silent footage plays under a playlist of public-domain tracks. The playlist for each tape is
// shuffled with a seeded RNG, so every viewer hears the same track at the same moment.
// These helpers are copies of the site's own seeded RNG, string hash and playlist builder
// (written under our own names so this file does not depend on the minified ones).
// update-engine.mjs cross-checks spkOverlayPlan against the site's copy on every run.
function spkHash(s) {
  var h = 0;
  for (var i = 0; i < s.length; i++) h = (h << 5) - h + s.charCodeAt(i) | 0;
  return h;
}
function spkRng(seed) {
  var t = seed | 0;
  return function () {
    t = t + 1831565813 | 0;
    var n = Math.imul(t ^ t >>> 15, 1 | t);
    n ^= n + Math.imul(n ^ n >>> 7, 61 | n);
    return ((n ^ n >>> 14) >>> 0) / 4294967296;
  };
}
// The tracks that play under one tape: [{ track, startAt }], startAt in seconds from the tape's start.
function spkOverlayPlan(pools, item, videoIndex, channelId, durationS, seed) {
  if (!pools) return [];
  var pool = null;
  if (item.year) pool = pools[Math.floor(parseInt(item.year) / 10) * 10 + "s"];
  if (!pool || pool.length === 0) pool = pools["default"];
  if (!pool || pool.length === 0) return [];
  var rng = spkRng(spkHash(channelId + "-audio-" + videoIndex + "-" + seed));
  var order = pool.slice();
  for (var p = order.length - 1; p > 0; p--) {
    var g = Math.floor(rng() * (p + 1));
    var tmp = order[p]; order[p] = order[g]; order[g] = tmp;
  }
  var plan = [], at = 0, n = 0;
  while (at < durationS && n < order.length * 3) {
    var track = order[n % order.length];
    plan.push({ track: track, startAt: at });
    at += track.duration;
    n++;
  }
  return plan;
}
// Same address the site plays overlay tracks from (null when the pool entry has no file name).
function spkOverlayURL(track) {
  if (!track || !track.id || !track.file) return null;
  return "https://archive.org/download/" + track.id + "/" + track.file.split("/").map(encodeURIComponent).join("/");
}
function spkOverlayTrack(track) {
  return { id: track.id, file: track.file || null, title: track.title || null, artist: track.artist || null,
           duration: track.duration || null, url: spkOverlayURL(track) };
}
// The overlay music that goes with what is on air at nowMs, as JSON (null if the channel has no
// overlay, or something other than a tape is on). startMs - the tape's start - and startAt give
// the position in the track at any moment: (now - startMs) / 1000 - startAt.
//   ambient: volume (0.05 to 0.3) for the tape's own sound, 0 when it is muted under the music.
//   nextAtMs: when the next track takes over (null if this is the last one on this tape).
//   fallbacks: stand-ins, in order, if the track will not play (the site plays them from 0).
function spkOverlay(channelId, nowMs) {
  var ch = spkChannels[channelId];
  if (!ch || !ch.versions.length) return null;
  var r = SPK_FN(ch, nowMs), it = r.item;
  if (it.type !== "video") return null;
  var ver = ch.versions.filter(function (x) { return x.v === r.version; })[0];
  if (!ver || !ver.audioOverlay) return null;
  var ambient = Number(it.ambient);
  ambient = Number.isFinite(ambient) && ambient > 0 && ambient <= 0.3 ? ambient : 0;
  var out = { key: r.key, startMs: r.startMs, endMs: r.endMs, ambient: ambient,
              index: 0, startAt: 0, nextAtMs: null, track: null, fallbacks: [] };
  var plan = spkOverlayPlan(ver.audioPools, it, it.videoIndex, channelId, it.duration, r.seed);
  if (!plan.length) return JSON.stringify(out);
  var elapsed = Math.min((nowMs - r.startMs) / 1000, it.duration);
  var k = 0;
  for (var i = plan.length - 1; i >= 0; i--) if (elapsed >= plan[i].startAt) { k = i; break; }
  out.index = k; out.startAt = plan[k].startAt; out.track = spkOverlayTrack(plan[k].track);
  if (k + 1 < plan.length) {
    var nextMs = r.startMs + plan[k + 1].startAt * 1e3;
    if (nextMs < r.endMs) out.nextAtMs = nextMs;
  }
  for (var j = 1; j < plan.length && out.fallbacks.length < 3; j++) out.fallbacks.push(spkOverlayTrack(plan[(k + j) % plan.length].track));
  return JSON.stringify(out);
}
