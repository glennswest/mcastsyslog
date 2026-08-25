import Foundation

/// A small browser console served at `/`.
///
/// It is not a second copy of the app — the window is the viewer. This exists so
/// the REST API is usable without writing a client first: type a filter, see the
/// rows and the rollup, and read the URL it built so the next question can be
/// asked with `curl`.
enum APIConsole {
    static let page = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>mcastsyslog</title>
    <style>
      :root {
        color-scheme: light dark;
        --bg: #ffffff; --fg: #1c1c1e; --dim: #6c6c70; --line: #d8d8dc;
        --panel: #f5f5f7; --field: #ffffff;
        --err: #c0392b; --warn: #b35309; --note: #8a6d00; --info: #6c6c70;
        --crit: #7d3c98; --debug: #98989d; --ok: #1e8e3e;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #1c1c1e; --fg: #f2f2f7; --dim: #98989d; --line: #38383a;
          --panel: #2c2c2e; --field: #1c1c1e;
          --err: #ff6b5e; --warn: #ff9f0a; --note: #ffd60a; --info: #98989d;
          --crit: #d98cff; --debug: #6c6c70; --ok: #30d158;
        }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--fg);
        font: 13px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      }
      header {
        display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap;
        padding: 10px 14px; border-bottom: 1px solid var(--line); background: var(--panel);
        position: sticky; top: 0; z-index: 2;
      }
      h1 { font-size: 14px; font-weight: 600; margin: 0; }
      .sub { color: var(--dim); font-size: 12px; }
      .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; background: var(--dim); }
      .dot.on { background: var(--ok); }
      form { display: flex; gap: 6px; flex-wrap: wrap; padding: 10px 14px;
             border-bottom: 1px solid var(--line); align-items: center; }
      input, select, button {
        font: inherit; padding: 4px 7px; border: 1px solid var(--line);
        border-radius: 5px; background: var(--field); color: var(--fg);
      }
      input[type=text] { min-width: 130px; }
      button { background: var(--panel); cursor: pointer; }
      button.primary { background: var(--fg); color: var(--bg); border-color: var(--fg); }
      label { color: var(--dim); font-size: 11px; display: flex; flex-direction: column; gap: 2px; }
      main { display: grid; grid-template-columns: 1fr 260px; gap: 0; align-items: start; }
      @media (max-width: 860px) { main { grid-template-columns: 1fr; } }
      #rows { font: 11.5px/1.5 "SF Mono", ui-monospace, Menlo, monospace; padding: 6px 0; }
      .row { display: grid; grid-template-columns: 92px 46px 130px 96px 1fr;
             gap: 8px; padding: 1px 14px; align-items: start; }
      .row:hover { background: var(--panel); }
      .sev { font-weight: 600; font-size: 10px; padding: 0 4px; border-radius: 3px; text-align: center; }
      .s0,.s1,.s2 { color: var(--crit); } .s3 { color: var(--err); }
      .s4 { color: var(--warn); } .s5 { color: var(--note); }
      .s6 { color: var(--info); } .s7 { color: var(--debug); }
      .t, .tag { color: var(--dim); }
      .msg { white-space: pre-wrap; word-break: break-word; }
      .chip { font-size: 9.5px; padding: 0 4px; border-radius: 3px; margin-left: 6px;
              border: 1px solid currentColor; }
      aside { border-left: 1px solid var(--line); padding: 10px 14px; position: sticky; top: 57px; }
      @media (max-width: 860px) { aside { border-left: none; border-top: 1px solid var(--line); position: static; } }
      aside h2 { font-size: 10px; text-transform: uppercase; letter-spacing: .04em;
                 color: var(--dim); margin: 12px 0 4px; }
      aside .kv { display: flex; justify-content: space-between; gap: 8px; font-size: 12px; padding: 1px 0; }
      aside .kv span:last-child { font-family: "SF Mono", ui-monospace, monospace; }
      .bar { padding: 6px 14px; border-bottom: 1px solid var(--line); color: var(--dim);
             font-size: 11.5px; display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }
      code { font-family: "SF Mono", ui-monospace, monospace; font-size: 11px;
             background: var(--panel); padding: 1px 5px; border-radius: 4px; }
      .empty { padding: 40px 14px; text-align: center; color: var(--dim); }
    </style>
    </head>
    <body>
    <header>
      <h1>mcastsyslog</h1>
      <span class="sub"><span class="dot" id="dot"></span> <span id="status">…</span></span>
      <span class="sub" style="margin-left:auto" id="storeline"></span>
    </header>

    <form id="f" onsubmit="event.preventDefault(); load();">
      <label>host <input type="text" id="host" placeholder="any" autocomplete="off"></label>
      <label>tag <input type="text" id="tag" placeholder="any" autocomplete="off"></label>
      <label>at least
        <select id="min_severity">
          <option value="">any</option>
          <option value="error">error</option>
          <option value="warning">warning</option>
          <option value="notice">notice</option>
          <option value="info">info</option>
        </select>
      </label>
      <label>search <input type="text" id="q" placeholder="message text" autocomplete="off"></label>
      <label>mode
        <select id="mode"><option value="tokens">words</option><option value="substring">substring</option></select>
      </label>
      <label>last
        <select id="last">
          <option value="">everything</option>
          <option value="5m">5m</option><option value="15m">15m</option>
          <option value="1h">1h</option><option value="6h">6h</option><option value="1d">1d</option>
        </select>
      </label>
      <label>limit <input type="text" id="limit" value="200" style="width:60px"></label>
      <button class="primary" type="submit">Search</button>
      <button type="button" id="livebtn" onclick="toggleLive()">Follow</button>
    </form>

    <div class="bar">
      <span id="result">—</span>
      <span id="scan"></span>
      <span style="margin-left:auto">GET <code id="url">/api/v1/events</code></span>
    </div>

    <main>
      <div id="rows"><div class="empty">Search to load events.</div></div>
      <aside>
        <h2>Summary</h2>
        <div id="summary" class="sub">—</div>
        <h2>Nodes</h2>
        <div id="fleet" class="sub">—</div>
        <h2>API</h2>
        <div class="sub">
          <a href="/api/v1">endpoints</a> ·
          <a href="/api/v1/types">types</a> ·
          <a href="/api/v1/stats">stats</a>
        </div>
      </aside>
    </main>

    <script>
    const $ = id => document.getElementById(id);
    const esc = s => String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
    let source = null;

    function params() {
      const p = new URLSearchParams();
      for (const k of ['host','tag','min_severity','q','mode','last','limit']) {
        const v = $(k).value.trim();
        if (v && !(k === 'mode' && !$('q').value.trim())) p.set(k, v);
      }
      return p;
    }

    function severityClass(n) { return 's' + n; }

    function rowHTML(e) {
      const time = (e.sent || e.recv).slice(11, 23);
      const flags = (e.flags || []).map(f => `<span class="chip">${esc(f)}</span>`).join('');
      return `<div class="row">
        <span class="t">${esc(time)}</span>
        <span class="sev ${severityClass(e.severity)}">${esc((e.severity_name||'').slice(0,4).toUpperCase())}</span>
        <span>${esc(e.host)}</span>
        <span class="tag">${esc(e.tag)}</span>
        <span class="msg ${severityClass(e.severity)}">${esc(e.message)}${flags}</span>
      </div>`;
    }

    async function load() {
      const p = params();
      $('url').textContent = '/api/v1/events?' + p;
      const r = await fetch('/api/v1/events?' + p);
      const d = await r.json();
      if (d.error) { $('rows').innerHTML = `<div class="empty">${esc(d.error)}</div>`; return; }
      $('rows').innerHTML = d.events.length
        ? d.events.map(rowHTML).join('')
        : '<div class="empty">Nothing matches.</div>';
      const exact = d.matched_exact ? '' : 'more than ';
      $('result').textContent = `${d.returned} shown of ${exact}${d.matched} matched · ${d.elapsed_ms.toFixed(1)}ms`;
      $('scan').textContent = d.scanned ? 'substring search — this read messages rather than an index' : '';
      window.scrollTo(0, document.body.scrollHeight);
      loadSummary(p);
    }

    async function loadSummary(p) {
      const d = await (await fetch('/api/v1/summary?' + p)).json();
      if (d.error) return;
      const rows = [];
      for (const s of d.by_severity) rows.push([s.name, s.count]);
      let html = rows.map(([k, v]) => `<div class="kv"><span>${esc(k)}</span><span>${v}</span></div>`).join('');
      const f = d.flags || {};
      for (const [k, v] of Object.entries(f)) {
        if (v > 0) html += `<div class="kv"><span>${esc(k)}</span><span>${v}</span></div>`;
      }
      if (d.lines_the_nodes_held_back > 0) {
        html += `<div class="kv"><span>held back by nodes</span><span>${d.lines_the_nodes_held_back}</span></div>`;
      }
      html += `<div class="kv"><span>rate</span><span>${d.rate_per_second.toFixed(1)}/s</span></div>`;
      $('summary').innerHTML = html || '—';
    }

    async function loadFleet() {
      const d = await (await fetch('/api/v1/fleet?window=5m')).json();
      if (d.error || !d.nodes) return;
      $('fleet').innerHTML = d.nodes.length ? d.nodes.map(n =>
        `<div class="kv"><span class="${severityClass(n.worst_severity)}">${esc(n.host)}</span>` +
        `<span>${n.rate_per_second.toFixed(1)}/s</span></div>`).join('')
        : '<div class="kv"><span>nothing heard</span><span></span></div>';
    }

    async function loadStatus() {
      const h = await (await fetch('/api/v1/health')).json();
      $('dot').className = 'dot' + (h.listening ? ' on' : '');
      const ifs = (h.interfaces || []).map(i => i.name).join(', ');
      $('status').textContent = h.listening
        ? `${h.endpoint}${ifs ? ' via ' + ifs : ' — no interface joined'}`
        : 'not listening';
      const s = await (await fetch('/api/v1/stats')).json();
      if (s.store) $('storeline').textContent =
        `${s.store.events.toLocaleString()} events · ${s.store.hosts} nodes · ${s.store.bytes_human}`;
    }

    function toggleLive() {
      if (source) { source.close(); source = null; $('livebtn').textContent = 'Follow'; return; }
      const p = params();
      p.delete('limit'); p.delete('last');
      source = new EventSource('/api/v1/stream?' + p);
      source.addEventListener('log', ev => {
        const e = JSON.parse(ev.data);
        $('rows').insertAdjacentHTML('beforeend', rowHTML(e));
        const rows = $('rows').children;
        while (rows.length > 2000) rows[0].remove();
        window.scrollTo(0, document.body.scrollHeight);
      });
      source.onerror = () => { $('livebtn').textContent = 'Follow'; };
      $('livebtn').textContent = 'Following — stop';
      if ($('rows').querySelector('.empty')) $('rows').innerHTML = '';
    }

    loadStatus(); loadFleet(); load();
    setInterval(() => { loadStatus(); loadFleet(); }, 5000);
    </script>
    </body>
    </html>
    """
}
