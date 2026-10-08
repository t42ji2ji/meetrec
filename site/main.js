(function () {
  var root = document.documentElement;

  // Language switch
  var titles = {
    en: "MeetRec — the meeting recorder that knows who said what",
    zh: "MeetRec — 知道誰說了什麼的會議錄音"
  };
  function setLang(lang, remember) {
    root.setAttribute("data-lang", lang);
    root.lang = lang === "zh" ? "zh-Hant-TW" : "en";
    document.title = titles[lang];
    document.querySelectorAll("[data-set-lang]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-set-lang") === lang));
    });
    if (remember) { try { localStorage.setItem("meetrec-lang", lang); } catch (e) {} }
  }
  setLang(root.getAttribute("data-lang") || "en", false);
  document.querySelectorAll("[data-set-lang]").forEach(function (b) {
    b.addEventListener("click", function () { setLang(b.getAttribute("data-set-lang"), true); });
  });

  // Hairline under the bar once the page scrolls
  var bar = document.querySelector(".bar");
  function onScroll() { bar.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Hide the film until its file exists
  var film = document.querySelector("[data-film]");
  var video = film && film.querySelector("video");
  if (video) video.addEventListener("error", function () { film.hidden = true; });

  // Play the example transcript: lines light up as the playhead passes their turn
  var live = document.querySelector(".live");
  var lines = Array.prototype.slice.call(document.querySelectorAll("[data-lines] li"));
  var head = document.querySelector("[data-playhead]");
  var clock = document.querySelector("[data-clock]");
  var length = 56, speed = 4, hold = 2.5;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  live.classList.add("playing");
  var start = null;
  function frame(now) {
    if (start === null) start = now;
    var elapsed = (now - start) / 1000 * speed;
    if (elapsed > length + hold * speed) { start = now; elapsed = 0; }
    var t = Math.min(elapsed, length);
    head.style.left = (t / length * 100) + "%";
    var s = Math.floor(t);
    clock.textContent = "00:" + (s < 10 ? "0" : "") + s;
    var current = -1;
    lines.forEach(function (li, i) {
      var said = t >= Number(li.getAttribute("data-t"));
      li.classList.toggle("said", said);
      if (said) current = i;
    });
    lines.forEach(function (li, i) { li.classList.toggle("now", i === current); });
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
