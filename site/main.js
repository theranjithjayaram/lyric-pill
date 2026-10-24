// LyricPill site. No dependencies; the page works without this script.
(function () {
  "use strict";

  // ---- the demo pill keeps time like the app: one timeout per line ----------
  const lines = [
    { ms: 0, text: "Morning light across the floor" },
    { ms: 3000, text: "the kettle hums, the window glows" },
    { ms: 6000, text: "we left the maps, we kept the roads" },
    { ms: 9000, text: "⇄ Today the sky is absolutely clear" },
    { ms: 12000, text: "and the chorus comes around again" },
    { ms: 15000, text: "one line at a time, until the end" },
  ];
  const loopMs = 18000;
  const pill = document.getElementById("pill");
  const pillText = document.getElementById("pill-text");
  if (pill && pillText && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
    let playing = true;
    let base = performance.now();
    let paused = 0;
    let timer = null;
    const pos = () => (playing ? performance.now() - base : paused) % loopMs;
    const indexAt = (ms) => { let i = 0; while (i + 1 < lines.length && lines[i + 1].ms <= ms) i++; return i; };
    const show = () => { pillText.textContent = lines[indexAt(pos())].text; };
    const arm = () => {
      clearTimeout(timer);
      if (!playing) return;
      const ms = pos();
      const i = indexAt(ms);
      const next = i + 1 < lines.length ? lines[i + 1].ms : loopMs;
      timer = setTimeout(() => { show(); arm(); }, Math.max(20, next - ms + 10));
    };
    pill.addEventListener("click", () => {
      if (playing) { paused = pos(); playing = false; clearTimeout(timer); }
      else { base = performance.now() - paused; playing = true; arm(); }
      pill.setAttribute("aria-label", playing ? "Lyric line; press to pause the demo" : "Lyric line; press to resume the demo");
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden && playing) { paused = pos(); playing = false; clearTimeout(timer); }
    });
    show(); arm();
  }

  // ---- the download button: the latest release, when GitHub answers --------
  const meta = document.getElementById("download-meta");
  const button = document.getElementById("download");
  const versionTile = document.getElementById("version-tile");
  if (meta && button && "fetch" in window) {
    fetch("https://api.github.com/repos/theranjithjayaram/lyric-pill/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        if (!rel || !rel.tag_name) return;
        const version = rel.tag_name.replace(/^v/, "");
        const dmg = (rel.assets || []).find((a) => /\.dmg$/.test(a.name));
        if (dmg) {
          button.href = dmg.browser_download_url;
          const mb = (dmg.size / 1048576).toFixed(dmg.size >= 10485760 ? 0 : 1).replace(/\.0$/, "");
          meta.textContent = "Version " + version + " · " + mb + " MB · macOS 13 or later · Apple silicon and Intel";
        } else {
          meta.textContent = "Version " + version + " · macOS 13 or later · Apple silicon and Intel";
        }
        if (versionTile) versionTile.textContent = "Version " + version;
      })
      .catch(() => {});
  }
})();
