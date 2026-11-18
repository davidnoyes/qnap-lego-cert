// LegoCert run progress: a ball moving along a line of stages. The server renders the
// current state; while a run is in progress (or just after a button started one) this
// polls ?status=1 and redraws. Built with createElement/textContent only, never
// innerHTML, so nothing from the server can become markup.
(function () {
  "use strict";
  var box = document.getElementById("prog");
  if (!box) return;
  var src = box.getAttribute("data-src");
  // Set right after a button click: the click time. Runs that started earlier are the
  // previous run, not this one. Same "YYYY-MM-DD HH:MM:SS" format, so strings compare.
  var since = box.getAttribute("data-since") || "";
  var startedAt = Date.now();

  function parse(text) {
    var s = {};
    text.split("\n").forEach(function (line) {
      var i = line.indexOf("=");
      if (i > 0) s[line.slice(0, i)] = line.slice(i + 1);
    });
    return s;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  }

  function render(s) {
    if (!s.state || s.state === "idle") { box.hidden = true; return; }
    box.hidden = false;
    var stages = (s.stages || "").split("|");
    var n = stages.length;
    var idx = Math.max(0, Math.min(n - 1, parseInt(s.idx, 10) || 0));
    var pct = n > 1 ? (idx / (n - 1)) * 100 : 0;

    var head = el("div", "prog-head");
    head.appendChild(el("b", null, s.run || ""));
    head.appendChild(el("span", "muted", s.when ? "  " + s.when : ""));

    var track = el("div", "track");
    track.appendChild(el("div", "line"));
    var fill = el("div", "fill " + s.state);
    fill.style.width = pct + "%";
    track.appendChild(fill);
    stages.forEach(function (name, i) {
      var cls = i < idx ? "done" : i === idx ? "cur" : "todo";
      var stop = el("div", "stop " + cls);
      stop.style.left = (n > 1 ? (i / (n - 1)) * 100 : 0) + "%";
      if (i === 0) stop.className += " first";
      if (i === n - 1) stop.className += " last";
      stop.appendChild(el("span", "lbl", name));
      track.appendChild(stop);
    });
    var ball = el("div", "ball " + s.state);
    ball.style.left = pct + "%";
    track.appendChild(ball);

    var msg = el("div", "prog-msg " + s.state, s.msg || "");

    while (box.firstChild) box.removeChild(box.firstChild);
    box.appendChild(head);
    box.appendChild(track);
    box.appendChild(msg);
  }

  function tick() {
    fetch(src, { credentials: "same-origin", cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.text();
      })
      .then(function (text) {
        var s = parse(text);
        var isNew = !since || (s.start || "") >= since;
        if (isNew) {
          render(s);
          since = ""; // found it; from now on just follow the latest run
          if (s.state === "running") setTimeout(tick, 2000);
        } else if (Date.now() - startedAt < 20000) {
          setTimeout(tick, 1000); // the new run hasn't logged its start yet
        } else {
          render(s);
        }
      })
      .catch(function () {
        // e.g. the NAS web server restarting while a certificate is installed
        var msg = box.querySelector(".prog-msg");
        if (msg) msg.textContent = "Waiting for the NAS to respond…";
        setTimeout(tick, 4000);
      });
  }

  if (box.getAttribute("data-state") === "running" || since) setTimeout(tick, 1000);
})();
