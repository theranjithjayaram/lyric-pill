// LyricPill site. No dependencies. Everything below degrades to the static page.
(function () {
  "use strict";
  document.documentElement.classList.add("js");
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---- entrances: reveal sections as they arrive -------------------------
  const revealed = document.querySelectorAll("[data-reveal]");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (e.isIntersecting) { e.target.classList.add("is-in"); io.unobserve(e.target); }
      }
    }, { rootMargin: "0px 0px -10% 0px", threshold: 0.1 });
    revealed.forEach((el) => io.observe(el));
  } else {
    revealed.forEach((el) => el.classList.add("is-in"));
  }

  // ---- the live thing: the pill keeps LRC time -----------------------------
  // Invented lines; the Hindi verse arrives as its translation, as the app shows it.
  const lrc = [
    { ms: 0, text: "Morning light across the floor" },
    { ms: 3000, text: "the kettle hums, the window glows" },
    { ms: 6000, text: "we left the maps, we kept the roads" },
    { ms: 9000, text: "⇄ Today the sky is absolutely clear", note: "आज आसमान बिल्कुल साफ है · translated on this Mac" },
    { ms: 12000, text: "and the chorus comes around again" },
    { ms: 15000, text: "one line at a time, until the end" },
  ];
  const loopMs = 18000;
  const pill = document.getElementById("pill");
  const pillText = document.getElementById("pill-text");
  const timecode = document.getElementById("timecode");
  const timenote = document.getElementById("timenote");
  if (pill && pillText && timecode) {
    let playing = !reduceMotion;
    let base = performance.now();
    let paused = 0;
    let shown = -1;
    let timer = null;

    const pos = () => (playing ? (performance.now() - base) : paused) % loopMs;
    const indexAt = (ms) => { let i = 0; while (i + 1 < lrc.length && lrc[i + 1].ms <= ms) i++; return i; };
    const fmt = (ms) => {
      const s = Math.floor(ms / 1000), h = Math.floor((ms % 1000) / 10);
      return "00:" + String(s).padStart(2, "0") + "." + String(h).padStart(2, "0");
    };
    const render = () => {
      const ms = pos();
      const i = indexAt(ms);
      if (i !== shown) {
        shown = i;
        pillText.textContent = lrc[i].text;
        if (timenote) timenote.textContent = lrc[i].note || "";
      }
      timecode.textContent = fmt(ms);
    };
    // Like the app: one timeout armed for the next line boundary, plus the
    // timecode, which is only decoration and ticks ten times a second.
    const arm = () => {
      clearTimeout(timer);
      if (!playing) return;
      const ms = pos();
      const i = indexAt(ms);
      const next = i + 1 < lrc.length ? lrc[i + 1].ms : loopMs;
      timer = setTimeout(() => { render(); arm(); }, Math.max(20, next - ms + 10));
    };
    let ticker = null;
    const tick = () => { render(); ticker = playing ? setTimeout(tick, 100) : null; };
    const setPlaying = (on) => {
      if (on === playing) return;
      if (on) { base = performance.now() - paused; } else { paused = pos(); }
      playing = on;
      pill.setAttribute("aria-label", on ? "Lyric line; press to pause the demo" : "Lyric line; press to resume the demo");
      render(); arm(); if (on && !ticker) tick();
    };
    pill.addEventListener("click", () => setPlaying(!playing));
    render(); arm(); if (playing) tick();
    document.addEventListener("visibilitychange", () => { if (document.hidden) setPlaying(false); });
  }

  // ---- the carousel: the centred panel is lit, the caption follows it -----
  const carousel = document.getElementById("carousel");
  const name = document.getElementById("carousel-name");
  const line = document.getElementById("carousel-line");
  if (carousel && name && line) {
    const panels = Array.from(carousel.querySelectorAll(".panel"));
    let raf = 0;
    const update = () => {
      raf = 0;
      const mid = carousel.getBoundingClientRect().left + carousel.clientWidth / 2;
      let best = null, bestD = Infinity;
      for (const p of panels) {
        const r = p.getBoundingClientRect();
        const d = Math.abs(r.left + r.width / 2 - mid);
        if (d < bestD) { bestD = d; best = p; }
      }
      if (!best || best.classList.contains("is-lit")) return;
      panels.forEach((p) => p.classList.toggle("is-lit", p === best));
      name.textContent = best.dataset.name;
      line.textContent = best.dataset.text;
    };
    carousel.addEventListener("scroll", () => { if (!raf) raf = requestAnimationFrame(update); }, { passive: true });
    // drag to scroll with a mouse
    let dragging = false, startX = 0, startLeft = 0;
    carousel.addEventListener("pointerdown", (e) => { if (e.pointerType !== "mouse") return; dragging = true; startX = e.clientX; startLeft = carousel.scrollLeft; carousel.setPointerCapture(e.pointerId); });
    carousel.addEventListener("pointermove", (e) => { if (dragging) carousel.scrollLeft = startLeft - (e.clientX - startX); });
    carousel.addEventListener("pointerup", () => { dragging = false; });
    carousel.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
        e.preventDefault();
        const lit = panels.findIndex((p) => p.classList.contains("is-lit"));
        const next = panels[Math.min(panels.length - 1, Math.max(0, lit + (e.key === "ArrowRight" ? 1 : -1)))];
        next.scrollIntoView({ behavior: reduceMotion ? "auto" : "smooth", inline: "center", block: "nearest" });
      }
    });
    update();
  }

  // ---- the switches: each band answers click, Space and Enter -------------
  document.querySelectorAll(".band .switch").forEach((sw) => {
    const band = sw.closest(".band");
    const toggle = () => {
      const on = !sw.classList.contains("is-on");
      sw.classList.toggle("is-on", on);
      band.classList.toggle("is-on", on);
      sw.setAttribute("aria-checked", String(on));
    };
    sw.addEventListener("click", toggle);
  });

  // ---- the download button: the latest release, when GitHub answers --------
  const meta = document.getElementById("download-meta");
  const versionTile = document.getElementById("version-tile");
  const buttons = [document.getElementById("download"), document.getElementById("download-footer")].filter(Boolean);
  if (meta && buttons.length && "fetch" in window) {
    fetch("https://api.github.com/repos/theranjithjayaram/lyric-pill/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : null))
      .then((rel) => {
        if (!rel || !rel.tag_name) return;
        const dmg = (rel.assets || []).find((a) => /\.dmg$/.test(a.name));
        const version = rel.tag_name.replace(/^v/, "");
        const date = rel.published_at ? new Date(rel.published_at).toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" }) : "";
        if (dmg) {
          buttons.forEach((b) => { b.href = dmg.browser_download_url; });
          const mb = (dmg.size / 1048576).toFixed(dmg.size >= 10485760 ? 0 : 1).replace(/\.0$/, "");
          meta.textContent = "Version " + version + " · " + mb + " MB · macOS 13 or later · Apple silicon and Intel";
        } else {
          meta.textContent = "Version " + version + " · macOS 13 or later · Apple silicon and Intel";
        }
        if (versionTile) versionTile.textContent = "Version " + version + (date ? ", " + date + "." : ".");
      })
      .catch(() => {});
  }
})();
