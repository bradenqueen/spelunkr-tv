
// ---- Spelunkr TV glue (written for the Apple TV app, not part of spelunkr.tv) ----
// SPK_RB / SPK_ZO / SPK_FN are set by update-engine.mjs to the site's own
// "new channel", "add version" and "what's on at time t" functions.
function spkPresenceConfig() {
  return JSON.stringify({
    url: typeof SPK_SB_URL === "string" ? SPK_SB_URL : null,
    key: typeof SPK_SB_KEY === "string" ? SPK_SB_KEY : null
  });
}
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
    if (r.item.type === "video") return { title: r.item.displayTitle || r.item.title || r.item.id, year: r.item.year || null, startMs: r.startMs };
    if (r.endMs <= t) break;
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
    out.id = it.id; out.file = it.file || it.mp4 || null; out.title = it.displayTitle || it.title || it.id;
    out.year = it.year || null; out.duration = it.duration;
    if (Number.isInteger(it.videoIndex)) out.videoIndex = it.videoIndex;
    if (Number.isFinite(it.moov)) out.moov = it.moov;
    if (it.ambient != null) out.ambient = it.ambient;
  } else if (it.type === "ad") {
    out.id = (it.slice && it.slice.tape) || null; out.file = (it.slice && it.slice.file) || null;
    out.title = "Commercial break";
    if (it.slice && Number.isFinite(Number(it.slice.gainDb))) out.gainDb = Number(it.slice.gainDb);
    if (it.slice && Number.isFinite(it.slice.moov)) out.moov = it.slice.moov;
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
    if (r.item.type === "video") {
      out.push({
        title: r.item.displayTitle || r.item.title || r.item.id,
        year: r.item.year || null,
        startMs: r.startMs,
        endMs: r.endMs,
        videoIndex: Number.isInteger(r.item.videoIndex) ? r.item.videoIndex : null,
        version: r.version
      });
    }
    if (r.endMs <= t) break;
    t = r.endMs;
  }
  return JSON.stringify(out);
}

// ---- Time-grid schedule and marathon block grouping (ported from spelunkr.tv) ----
var SPK_SHORT_THRESHOLD_S = 900; // 15 minutes

function spkVersionByNumber(ch, v) {
  for (var i = 0; i < ch.versions.length; i++) {
    if (ch.versions[i].v === v) return ch.versions[i];
  }
  return null;
}

function spkVideoRecord(r) {
  var it = r.item;
  var dur = Number.isFinite(it.duration) && it.duration > 0 ? it.duration : Math.max(0, (r.endMs - r.startMs) / 1000);
  return {
    title: it.displayTitle || it.title || it.id,
    year: it.year || null,
    startMs: r.startMs,
    endMs: r.endMs,
    durationS: dur,
    videoIndex: Number.isInteger(it.videoIndex) ? it.videoIndex : null,
    version: r.version,
    show: it.show || null
  };
}

// All video entries overlapping [fromMs, toMs], skipping bump-breaks, ads, and up-next cards.
function spkRange(channelId, fromMs, toMs) {
  var ch = spkChannels[channelId];
  if (!ch || !ch.versions.length || toMs <= fromMs) return "[]";
  var out = [], t = fromMs;
  for (var i = 0; i < 2000 && t < toMs; i++) {
    var r = SPK_FN(ch, t);
    if (r.item.type === "video") out.push(spkVideoRecord(r));
    if (r.endMs <= t) break;
    t = r.endMs;
  }
  return JSON.stringify(out);
}

function spkShortShowsSet(items) {
  var counts = {};
  if (!Array.isArray(items)) return counts;
  for (var i = 0; i < items.length; i++) {
    var it = items[i];
    if (!it || !it.show) continue;
    var c = counts[it.show] || (counts[it.show] = { short: 0, all: 0 });
    c.all++;
    if (it.duration < SPK_SHORT_THRESHOLD_S) c.short++;
  }
  var result = {};
  for (var k in counts) {
    if (counts[k].short * 2 > counts[k].all) result[k] = true;
  }
  return result;
}

function spkGroupBlocks(containers, fromMs, toMs, shortShows) {
  var cells = [];
  for (var ci = 0; ci < containers.length; ci++) {
    var entries = containers[ci];
    var runs = [];
    for (var ei = 0; ei < entries.length; ei++) {
      var e = entries[ei];
      var kind = (e.show && shortShows[e.show]) ? ("sitting:" + e.show) : (e.durationS < SPK_SHORT_THRESHOLD_S ? "short" : null);
      var prev = runs.length ? runs[runs.length - 1] : null;
      if (kind && prev && prev.of === kind) prev.entries.push(e);
      else runs.push({ of: kind, entries: [e] });
    }
    var merged = [];
    for (var ri = 0; ri < runs.length; ri++) {
      var run = runs[ri];
      if (run.of && run.of !== "short" && run.entries.length === 1 && run.entries[0].durationS < SPK_SHORT_THRESHOLD_S) {
        run.of = "short";
      }
      var last = merged.length ? merged[merged.length - 1] : null;
      if (run.of === "short" && last && last.of === "short") {
        for (var j = 0; j < run.entries.length; j++) last.entries.push(run.entries[j]);
      } else {
        merged.push(run);
      }
    }
    for (var mi = 0; mi < merged.length; mi++) {
      var list = merged[mi].entries;
      if (!list.length) continue;
      var first = list[0], endEntry = list[list.length - 1];
      var startMs = first.startMs, endMs = endEntry.endMs;
      if (endMs <= fromMs || startMs >= toMs) continue;
      if (list.length === 1) {
        cells.push({
          title: first.title,
          year: first.year,
          startMs: startMs,
          endMs: endMs,
          durationS: first.durationS,
          videoIndex: first.videoIndex,
          version: first.version,
          isMarathon: false,
          series: null,
          showCount: 1,
          shows: []
        });
      } else {
        var firstShow = first.show;
        var sameSeries = !!firstShow;
        for (var si = 1; si < list.length && sameSeries; si++) {
          if (list[si].show !== firstShow) sameSeries = false;
        }
        cells.push({
          title: sameSeries ? firstShow : first.title,
          year: null,
          startMs: startMs,
          endMs: endMs,
          durationS: Math.max(0, (endMs - startMs) / 1000),
          videoIndex: first.videoIndex,
          version: first.version,
          isMarathon: true,
          series: sameSeries ? firstShow : null,
          showCount: list.length,
          shows: list.map(function (s) {
            return {
              title: s.title,
              year: s.year,
              startMs: s.startMs,
              endMs: s.endMs,
              durationS: s.durationS,
              videoIndex: s.videoIndex,
              version: s.version
            };
          })
        });
      }
    }
  }
  return cells;
}

// Grid cells (with marathon block grouping) overlapping [fromMs, toMs], matching spelunkr.tv's guide.
function spkBlocks(channelId, fromMs, toMs) {
  var ch = spkChannels[channelId];
  if (!ch || !ch.versions.length || toMs <= fromMs) return "[]";
  var version, shortShows;
  function selectVersion(number) {
    version = spkVersionByNumber(ch, number);
    shortShows = spkShortShowsSet(version.items);
  }
  function standalone(r) {
    return r.item.type === "video" && r.item.duration >= SPK_SHORT_THRESHOLD_S
      && !(r.item.show && shortShows[r.item.show]);
  }
  function boundary(prev, next) {
    if (prev.version !== next.version) return true;
    if (standalone(prev) || standalone(next)) return true;
    if (version.block && (prev.item.type === "bump-break" || next.item.type === "bump-break")) return true;
    // An all-short lineup can repeat forever. Each scheduled cycle starts a new run.
    return prev.cycle !== next.cycle;
  }

  var current = SPK_FN(ch, fromMs);
  selectVersion(current.version);
  // A new version can take effect in the middle of its first visible item.
  function visibleStart(r) {
    return version === ch.versions[0] ? r.startMs : Math.max(r.startMs, version.effectiveAtMs);
  }
  var t = visibleStart(current);
  while (!standalone(current)) {
    var prev = SPK_FN(ch, t - 1);
    if (boundary(prev, current) || visibleStart(prev) >= t) break;
    current = prev;
    t = visibleStart(current);
  }

  var entries = [], cells = [];
  function flush() {
    if (entries.length) cells = cells.concat(spkGroupBlocks([entries], fromMs, toMs, shortShows));
    entries = [];
  }
  while (true) {
    if (current.item.type === "video") {
      var entry = spkVideoRecord(current);
      entry.startMs = t;
      entries.push(entry);
    }
    if (current.endMs <= t) break;
    t = current.endMs;
    var next = SPK_FN(ch, t);
    if (boundary(current, next)) {
      flush();
      if (t >= toMs) break;
      if (current.version !== next.version) selectVersion(next.version);
    }
    current = next;
  }
  flush();
  return JSON.stringify(cells);
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
