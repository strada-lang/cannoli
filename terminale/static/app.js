/* Terminale - browser side.
 *
 * Every tab is one server-side session (a shell on a PTY that keeps running
 * when the tab, the browser or the connection goes away). On load the page
 * lists the live sessions and re-attaches to the ones not detached here.
 *
 * WebSocket messages are binary: one type byte + payload.
 *   send:    I input, R "cols rows", T title, K kill, P pause, p resume
 *   receive: S attach (reset, scrollback follows), O output, X exit code,
 *            Z "cols rows" (another browser resized the session)
 */
(function () {
  'use strict';

  var enc = new TextEncoder();
  var dec = new TextDecoder();
  var $ = function (id) { return document.getElementById(id); };
  var tabsEl = $('tabs');
  var panesEl = $('panes');
  var emptyEl = $('empty');
  var statusEl = $('status');
  var tabs = [];
  var slots = [null, null];       // what is on screen: left pane, right pane (split view)
  var focus = 0;                  // which slot has the keyboard
  var active = null;              // === slots[focus]
  var HIGH_WATER = 1024 * 1024;   // bytes handed to xterm but not yet rendered
  var LOW_WATER = 128 * 1024;
  var TOUCH = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;

  // ---- settings ---------------------------------------------------------------
  // Kept in localStorage (instant on load) and in a file on the server
  // (~/.terminale/settings.json) so they follow you to other browsers.

  var THEMES = window.TERMINALE_THEMES || [];
  var FONTS = [
    { id: 'system', name: 'System monospace', css: 'ui-monospace, "SF Mono", "Cascadia Mono", "JetBrains Mono", Menlo, Consolas, "DejaVu Sans Mono", monospace' },
    { id: 'jetbrains', name: 'JetBrains Mono', css: '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace' },
    { id: 'fira', name: 'Fira Code', css: '"Fira Code", "Fira Mono", ui-monospace, Menlo, Consolas, monospace' },
    { id: 'cascadia', name: 'Cascadia Mono', css: '"Cascadia Mono", "Cascadia Code", Consolas, monospace' },
    { id: 'sfmono', name: 'SF Mono / Menlo', css: '"SF Mono", Menlo, Monaco, monospace' },
    { id: 'consolas', name: 'Consolas', css: 'Consolas, "Lucida Console", monospace' },
    { id: 'dejavu', name: 'DejaVu Sans Mono', css: '"DejaVu Sans Mono", "Liberation Mono", monospace' },
    { id: 'ubuntu', name: 'Ubuntu Mono', css: '"Ubuntu Mono", monospace' },
    { id: 'courier', name: 'Courier New', css: '"Courier New", Courier, monospace' },
    { id: 'custom', name: 'Other (installed font)...', css: '' }
  ];
  var DEFAULTS = {
    theme: 'terminale', fontFamily: 'system', customFont: '', fontSize: 14, lineHeight: 1,
    cursorStyle: 'block', cursorBlink: true, scrollback: 10000, copyOnSelect: false,
    rightClickPaste: false, confirmClose: false, bell: 'visual', macOptionIsMeta: true, webgl: true,
    allowClipboard: true, warnOnLeave: false, keyBar: 'auto'
  };
  var settings = {};

  // Only known keys with sane values survive (the file may be old or edited)
  function cleanSettings(raw) {
    var out = {}, k;
    raw = raw && typeof raw === 'object' ? raw : {};
    for (k in DEFAULTS) {
      out[k] = (typeof raw[k] === typeof DEFAULTS[k]) ? raw[k] : DEFAULTS[k];
    }
    if (!THEMES.some(function (t) { return t.id === out.theme; })) { out.theme = DEFAULTS.theme; }
    if (!FONTS.some(function (f) { return f.id === out.fontFamily; })) { out.fontFamily = DEFAULTS.fontFamily; }
    out.fontSize = Math.min(32, Math.max(8, Math.round(out.fontSize) || DEFAULTS.fontSize));
    out.lineHeight = Math.min(2, Math.max(1, out.lineHeight || 1));
    out.scrollback = Math.min(100000, Math.max(100, Math.round(out.scrollback) || DEFAULTS.scrollback));
    if (['block', 'bar', 'underline'].indexOf(out.cursorStyle) < 0) { out.cursorStyle = 'block'; }
    if (['none', 'visual', 'sound', 'notify'].indexOf(out.bell) < 0) { out.bell = 'visual'; }
    if (['auto', 'on', 'off'].indexOf(out.keyBar) < 0) { out.keyBar = 'auto'; }
    out.customFont = String(out.customFont).replace(/["\\;{}<>]/g, '').slice(0, 60);
    return out;
  }

  function currentTheme() {
    return THEMES.filter(function (t) { return t.id === settings.theme; })[0] || THEMES[0];
  }

  function fontCss() {
    if (settings.fontFamily === 'custom' && settings.customFont) {
      return '"' + settings.customFont + '", ' + FONTS[0].css;
    }
    var f = FONTS.filter(function (x) { return x.id === settings.fontFamily; })[0] || FONTS[0];
    return f.css || FONTS[0].css;
  }

  function termOptions() {
    return {
      theme: currentTheme().term,
      fontFamily: fontCss(),
      fontSize: settings.fontSize,
      lineHeight: settings.lineHeight,
      cursorStyle: settings.cursorStyle,
      cursorBlink: settings.cursorBlink,
      scrollback: settings.scrollback,
      macOptionIsMeta: settings.macOptionIsMeta
    };
  }

  function applyChrome() {
    var ui = currentTheme().ui, root = document.documentElement.style;
    root.setProperty('--bg', ui.bg);
    root.setProperty('--bar', ui.bar);
    root.setProperty('--tab', ui.tab);
    root.setProperty('--tab-active', ui.bg);
    root.setProperty('--line', ui.line);
    root.setProperty('--text', ui.text);
    root.setProperty('--dim', ui.dim);
    root.setProperty('--accent', ui.accent);
    root.colorScheme = currentTheme().dark ? 'dark' : 'light';
    var show = settings.keyBar === 'on' || (settings.keyBar === 'auto' && TOUCH);
    if ($('keybar')) { $('keybar').hidden = !show; }
  }

  // Apply the settings to the page and every open terminal
  function applySettings() {
    applyChrome();
    var opts = termOptions();
    tabs.forEach(function (t) {
      for (var k in opts) { t.term.options[k] = opts[k]; }
      if (settings.webgl && isShown(t)) { t.enableWebgl(); } else { t.disableWebgl(); }
    });
    fitShown();
  }

  var saveTimer = null;
  function saveSettings() {
    store('settings', settings);
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      api('POST', 'api/settings', { settings: JSON.stringify(settings) })
        .then(function () { flashSaved('Saved'); })
        .catch(function (e) { if (e.message !== 'signed out') { flashSaved('Saved in this browser only'); } });
    }, 400);
  }

  function setSetting(key, value) {
    var next = {};
    for (var k in settings) { next[k] = settings[k]; }
    next[key] = value;
    settings = cleanSettings(next);
    applySettings();
    syncPanel();
    saveSettings();
    if (key === 'bell' && value === 'notify' && window.Notification && Notification.permission === 'default') {
      Notification.requestPermission();
    }
  }

  var audioCtx = null;
  function beep() {
    try {
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      var osc = audioCtx.createOscillator(), gain = audioCtx.createGain();
      osc.frequency.value = 880;
      gain.gain.setValueAtTime(0.08, audioCtx.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.0001, audioCtx.currentTime + 0.12);
      osc.connect(gain).connect(audioCtx.destination);
      osc.start();
      osc.stop(audioCtx.currentTime + 0.13);
    } catch (e) { /* no audio */ }
  }

  settings = cleanSettings(store('settings'));
  applyChrome();

  // ---- helpers ------------------------------------------------------------------

  function store(key, value) {
    try {
      if (value === undefined) { return JSON.parse(localStorage.getItem('terminale.' + key)); }
      localStorage.setItem('terminale.' + key, JSON.stringify(value));
    } catch (e) { /* private mode */ }
    return null;
  }

  function api(method, path, params) {
    var opt = { method: method, credentials: 'same-origin' };
    if (params instanceof FormData) { opt.body = params; }
    else if (params && method !== 'GET') { opt.body = new URLSearchParams(params); }
    else if (params) { path += '?' + new URLSearchParams(params).toString(); }
    return fetch(path, opt).then(function (r) {
      if (r.status === 401) { location.reload(); throw new Error('signed out'); }
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) { throw new Error(j.error || ('HTTP ' + r.status)); }
        return j;
      });
    });
  }

  function wsUrl(id) {
    var base = location.pathname.replace(/[^/]*$/, '');
    return (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + base + 'ws/' + id;
  }

  function frame(type, payload) {
    var body = typeof payload === 'string' ? enc.encode(payload) : (payload || new Uint8Array(0));
    var out = new Uint8Array(body.length + 1);
    out[0] = type.charCodeAt(0);
    out.set(body, 1);
    return out;
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text !== undefined) { e.textContent = text; }
    return e;
  }

  var toastTimer = null;
  function toast(text, isError) {
    var t = $('toast');
    t.textContent = text;
    t.className = 'toast' + (isError ? ' error' : '');
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, isError ? 6000 : 3000);
  }

  function ago(sec) {
    var d = Math.max(0, Math.floor(Date.now() / 1000 - sec));
    if (d < 90) { return 'just now'; }
    if (d < 5400) { return Math.round(d / 60) + ' min ago'; }
    if (d < 129600) { return Math.round(d / 3600) + ' h ago'; }
    return Math.round(d / 86400) + ' days ago';
  }

  function sizeText(n) {
    if (n < 1024) { return n + ' B'; }
    if (n < 1048576) { return (n / 1024).toFixed(n < 10240 ? 1 : 0) + ' K'; }
    if (n < 1073741824) { return (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' M'; }
    return (n / 1073741824).toFixed(1) + ' G';
  }

  function hiddenIds() { return store('hidden') || {}; }

  function isShown(tab) { return !!tab && (slots[0] === tab || slots[1] === tab); }

  function updateStatus() {
    var down = tabs.some(function (t) { return !t.connected && !t.ended; });
    statusEl.className = 'status ' + (tabs.length === 0 ? '' : down ? 'down' : 'ok');
    statusEl.title = down ? 'Reconnecting...' : 'Connected';
    emptyEl.hidden = tabs.length > 0;
    document.title = active ? active.title + ' - Terminale' : 'Terminale';
  }

  function saveOrder() {
    store('order', tabs.map(function (t) { return t.id; }));
    if (active) { store('active', active.id); }
  }

  // ---- a tab ---------------------------------------------------------------

  function Tab(info) {
    var self = this;
    this.id = info.id;
    this.title = info.title || 'shell';
    this.pinned = !!(store('pinned') || {})[info.id];   // renamed by hand: ignore program titles
    this.connected = false;
    this.ended = false;
    this.detached = false;
    this.pending = 0;
    this.paused = false;
    this.retry = 0;
    this.ws = null;
    this.gl = null;
    this.sized = false;
    this.following = false;      // resizing to match another browser: don't echo it back
    this.foreign = false;        // currently at another browser's size

    this.el = el('div', 'tab offline');
    this.el.setAttribute('role', 'tab');
    this.el.draggable = true;
    this.titleEl = el('span', 'tab-title', this.title);
    var close = el('button', 'tab-close', '\u00d7');
    close.title = 'Close terminal (ends its shell). Right-click the tab to detach instead.';
    close.setAttribute('aria-label', 'Close terminal');
    this.el.appendChild(this.titleEl);
    this.el.appendChild(close);
    this.el.addEventListener('mousedown', function (ev) {
      if (ev.button === 1) { ev.preventDefault(); self.kill(); return; }
      if (ev.button === 0 && ev.target !== close) { activate(self); }
    });
    this.el.addEventListener('dblclick', function (ev) { if (ev.target !== close) { self.rename(); } });
    this.el.addEventListener('contextmenu', function (ev) { ev.preventDefault(); tabMenu(self, ev.clientX, ev.clientY); });
    close.addEventListener('click', function (ev) { ev.stopPropagation(); self.kill(); });
    // drag to reorder
    this.el.addEventListener('dragstart', function (ev) {
      dragged = self;
      self.el.classList.add('dragging');
      ev.dataTransfer.effectAllowed = 'move';
      try { ev.dataTransfer.setData('text/plain', self.id); } catch (e) { /* old browsers */ }
    });
    this.el.addEventListener('dragend', function () { self.el.classList.remove('dragging'); clearDropMarks(); dragged = null; });
    this.el.addEventListener('dragover', function (ev) {
      if (!dragged || dragged === self) { return; }
      ev.preventDefault();
      clearDropMarks();
      self.el.classList.add('drop-before');
    });
    this.el.addEventListener('drop', function (ev) {
      if (!dragged || dragged === self) { return; }
      ev.preventDefault();
      ev.stopPropagation();
      moveTab(dragged, tabs.indexOf(self));
    });
    tabsEl.appendChild(this.el);

    this.pane = el('div', 'pane');
    panesEl.appendChild(this.pane);

    var opts = termOptions();
    opts.allowProposedApi = true;
    this.term = new Terminal(opts);
    this.fit = new FitAddon.FitAddon();
    this.term.loadAddon(this.fit);
    try { this.term.loadAddon(new WebLinksAddon.WebLinksAddon()); } catch (e) { /* optional */ }
    this.search = null;
    try { this.search = new SearchAddon.SearchAddon(); this.term.loadAddon(this.search); } catch (e) { /* optional */ }
    this.term.open(this.pane);

    this.term.onData(function (d) { self.send('I', applyModifiers(d)); });
    this.term.onBinary(function (d) {
      var b = new Uint8Array(d.length);
      for (var i = 0; i < d.length; i++) { b[i] = d.charCodeAt(i) & 255; }
      self.send('I', b);
    });
    this.term.onResize(function (sz) {
      if (self.following || !isShown(self)) { return; }
      self.sized = true;
      self.foreign = false;
      self.send('R', sz.cols + ' ' + sz.rows);
    });
    this.term.onTitleChange(function (t) {
      if (self.pinned || !t) { return; }
      self.setTitle(t);
      self.send('T', t);
    });
    this.term.onBell(function () {
      if (settings.bell === 'none') { return; }
      if (active !== self) { self.el.classList.add('bell'); }
      if (settings.bell === 'sound') { beep(); }
      if (settings.bell === 'notify' && (document.hidden || active !== self) && window.Notification && Notification.permission === 'granted') {
        try {
          var n = new Notification('Terminale: ' + self.title, { body: 'Bell in this terminal', tag: 'terminale-' + self.id });
          n.onclick = function () { window.focus(); activate(self); n.close(); };
        } catch (e) { /* not allowed here */ }
      }
    });
    this.term.onSelectionChange(function () {
      if (!settings.copyOnSelect) { return; }
      var sel = self.term.getSelection();
      if (sel && navigator.clipboard) { navigator.clipboard.writeText(sel).catch(function () { /* denied */ }); }
    });
    // OSC 52: a program (tmux, vim, remote tools) asks to put text on the
    // clipboard. Writing is allowed (a setting); reading the clipboard is
    // never offered to programs.
    try {
      this.term.parser.registerOscHandler(52, function (data) {
        var semi = data.indexOf(';');
        var b64 = semi >= 0 ? data.slice(semi + 1) : '';
        if (!settings.allowClipboard || !b64 || b64 === '?' || !navigator.clipboard) { return true; }
        try {
          var bin = atob(b64), bytes = new Uint8Array(bin.length);
          for (var i = 0; i < bin.length; i++) { bytes[i] = bin.charCodeAt(i); }
          navigator.clipboard.writeText(dec.decode(bytes)).then(function () { toast('Copied to the clipboard by the terminal'); }).catch(function () { /* denied */ });
        } catch (e) { /* not base64 */ }
        return true;
      });
    } catch (e) { /* parser hooks unavailable */ }
    this.pane.addEventListener('contextmenu', function (ev) {
      if (!settings.rightClickPaste || !navigator.clipboard || !navigator.clipboard.readText) { return; }
      ev.preventDefault();
      navigator.clipboard.readText().then(function (t) { if (t) { self.term.paste(t); } }).catch(function () { /* denied */ });
    });
    this.pane.addEventListener('mousedown', function () { if (active !== self) { activate(self); } }, true);
    this.term.attachCustomKeyEventHandler(function (ev) { return keyHandler(self, ev); });

    this.connect();
  }

  Tab.prototype.setTitle = function (t) {
    this.title = t;
    this.titleEl.textContent = t;
    this.el.title = t;
    if (active === this) { document.title = t + ' - Terminale'; }
  };

  Tab.prototype.send = function (type, payload) {
    if (!this.ws || this.ws.readyState !== 1) { return; }
    if (type === 'I' && typeof payload === 'string' && payload.length > 16384) {
      // big paste: keep frames well under the server's message limit
      for (var i = 0; i < payload.length; i += 16384) { this.ws.send(frame('I', payload.slice(i, i + 16384))); }
      return;
    }
    this.ws.send(frame(type, payload));
  };

  // Tell the session our size once per connection, and only from a visible
  // tab (hidden ones are not laid out and would report xterm's default 80x24).
  // Sending it even when unchanged makes full-screen programs repaint.
  Tab.prototype.syncSize = function () {
    if (!isShown(this) || !this.connected || this.sized) { return; }
    this.sized = true;
    this.foreign = false;
    this.send('R', this.term.cols + ' ' + this.term.rows);
  };

  // Browsers allow only a handful of WebGL contexts, so only terminals that
  // are on screen hold one.
  Tab.prototype.enableWebgl = function () {
    if (this.gl || !settings.webgl || typeof WebglAddon === 'undefined') { return; }
    var self = this;
    try {
      var gl = new WebglAddon.WebglAddon();
      gl.onContextLoss(function () { self.disableWebgl(); });
      this.term.loadAddon(gl);
      this.gl = gl;
    } catch (e) { /* DOM renderer stays */ }
  };

  Tab.prototype.disableWebgl = function () {
    if (!this.gl) { return; }
    try { this.gl.dispose(); } catch (e) { /* already gone */ }
    this.gl = null;
  };

  // Take the size another browser gave the session, without echoing it back
  Tab.prototype.follow = function (cols, rows) {
    if (cols === this.term.cols && rows === this.term.rows) { return; }
    this.following = true;
    try { this.term.resize(Math.max(2, cols), Math.max(1, rows)); } catch (e) { /* keep */ }
    this.following = false;
    this.foreign = true;
  };

  Tab.prototype.connect = function () {
    var self = this;
    if (this.ended || this.detached) { return; }
    var ws = new WebSocket(wsUrl(this.id));
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    ws.onopen = function () {
      self.connected = true;
      self.retry = 0;
      self.paused = false;
      self.pending = 0;
      self.sized = false;
      self.el.classList.remove('offline');
      self.syncSize();
      updateStatus();
    };
    ws.onmessage = function (ev) {
      var data = new Uint8Array(ev.data);
      if (data.length === 0) { return; }
      var type = data[0];
      if (type === 79) {                      // O: output
        var chunk = data.subarray(1);
        self.pending += chunk.length;
        if (!self.paused && self.pending > HIGH_WATER) { self.paused = true; self.send('P'); }
        self.term.write(chunk, function () {
          self.pending -= chunk.length;
          if (self.paused && self.pending < LOW_WATER) { self.paused = false; self.send('p'); }
        });
      } else if (type === 83 || type === 90) { // S: (re)attached, scrollback follows; Z: resized elsewhere
        var m = /^(\d+) (\d+)$/.exec(dec.decode(data.subarray(1)));
        if (type === 83) {
          self.term.reset();
          // a background tab cannot measure itself: use the session's size
          if (m && !isShown(self)) { self.follow(+m[1], +m[2]); self.foreign = false; }
        } else if (m) {
          self.follow(+m[1], +m[2]);
        }
      } else if (type === 88) {               // X: the shell ended
        self.ended = true;
        removeTab(self);
      }
    };
    ws.onclose = function (ev) {
      if (self.ws !== ws) { return; }
      self.connected = false;
      self.ws = null;
      if (self.ended || self.detached) { return; }
      self.el.classList.add('offline');
      updateStatus();
      // 1012: the server worker is recycling -- reconnect at once
      if (ev && ev.code === 1012) { self.retry = 0; self.connect(); return; }
      self.retry = Math.min(self.retry + 1, 6);
      setTimeout(function () { self.reconnect(); }, Math.min(250 * Math.pow(2, self.retry - 1), 5000));
    };
  };

  // Before reconnecting, check the session still exists (and we are still
  // signed in: a 401 reloads the page to the login form).
  Tab.prototype.reconnect = function () {
    var self = this;
    if (this.ended || this.detached) { return; }
    api('GET', 'api/sessions').then(function (j) {
      var alive = j.sessions.some(function (s) { return s.id === self.id; });
      if (alive) { self.connect(); } else { self.ended = true; removeTab(self); }
    }).catch(function () {
      self.retry = Math.min(self.retry + 1, 6);
      setTimeout(function () { self.reconnect(); }, 3000);
    });
  };

  Tab.prototype.kill = function () {
    var self = this;
    if (this.ended) { return; }
    if (settings.confirmClose && !window.confirm('Close "' + this.title + '"? Its shell and anything running in it will end.')) { return; }
    this.ended = true;
    api('POST', 'api/sessions/' + this.id + '/kill').catch(function () { /* already gone */ });
    removeTab(self);
  };

  // Close the tab in this browser only; the session keeps running and can
  // be re-attached from the sessions menu.
  Tab.prototype.detach = function () {
    var h = hiddenIds();
    h[this.id] = 1;
    store('hidden', h);
    this.detached = true;
    var title = this.title;
    removeTab(this, true);
    toast('Detached "' + title + '" - it keeps running (sessions menu to re-attach)');
  };

  Tab.prototype.rename = function () {
    var self = this;
    var input = document.createElement('input');
    input.value = this.title;
    input.maxLength = 80;
    this.titleEl.replaceWith(input);
    input.focus();
    input.select();
    var done = false;
    function finish(save) {
      if (done) { return; }
      done = true;
      var v = input.value.trim();
      input.replaceWith(self.titleEl);
      var pinned = store('pinned') || {};
      if (save && v) {
        self.pinned = true;
        pinned[self.id] = 1;
        self.setTitle(v);
        self.send('T', v);
      } else if (save && !v) {
        self.pinned = false;               // empty name: follow the program's title again
        delete pinned[self.id];
      }
      store('pinned', pinned);
      self.term.focus();
    }
    input.addEventListener('keydown', function (ev) {
      ev.stopPropagation();
      if (ev.key === 'Enter') { finish(true); } else if (ev.key === 'Escape') { finish(false); }
    });
    input.addEventListener('blur', function () { finish(true); });
    input.addEventListener('mousedown', function (ev) { ev.stopPropagation(); });
    input.addEventListener('dblclick', function (ev) { ev.stopPropagation(); });
  };

  Tab.prototype.dispose = function () {
    var ws = this.ws;
    this.ws = null;
    if (ws) { try { ws.close(); } catch (e) { /* closing */ } }
    this.disableWebgl();
    this.term.dispose();
    this.el.remove();
    this.pane.remove();
  };

  // ---- layout: one or two terminals on screen -----------------------------------

  function fitShown() {
    slots.forEach(function (t) {
      if (!t) { return; }
      try { t.fit.fit(); } catch (e) { /* not laid out yet */ }
      t.syncSize();
    });
  }

  function render() {
    if (!slots[focus]) { focus = 0; }
    active = slots[focus] || null;
    panesEl.classList.toggle('split', !!slots[1]);
    tabs.forEach(function (t) {
      var slot = slots[0] === t ? 0 : slots[1] === t ? 1 : -1;
      t.pane.className = 'pane' + (slot >= 0 ? ' shown slot' + slot : '') + (t === active ? ' focused' : '');
      t.el.classList.toggle('active', t === active);
      t.el.classList.toggle('second', slot >= 0 && t !== active);
      if (slot >= 0) { t.enableWebgl(); } else { t.disableWebgl(); }
    });
    fitShown();
    if (active) {
      active.el.classList.remove('bell');
      active.term.focus();
      active.el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    }
    saveOrder();
    updateStatus();
  }

  function activate(tab) {
    if (!tab) { slots = [null, null]; focus = 0; render(); return; }
    if (slots[0] === tab) { focus = 0; }
    else if (slots[1] === tab) { focus = 1; }
    else { slots[focus] = tab; }
    render();
  }

  // Put `tab` in the right-hand pane (or leave split view)
  function toggleSplit(tab) {
    tab = tab || active;
    if (slots[1]) { slots = [slots[focus], null]; focus = 0; render(); return; }
    if (tabs.length < 2) { toast('Open a second terminal to split the view'); return; }
    if (slots[0] === tab) {             // splitting from the tab on screen: keep typing in it
      var i = tabs.indexOf(tab);
      slots[1] = tabs[i + 1] || tabs[i - 1];
      focus = 0;
    } else {
      slots[1] = tab;
      focus = 1;
    }
    render();
  }

  function removeTab(tab, keepSession) {
    var i = tabs.indexOf(tab);
    if (i < 0) { return; }
    tabs.splice(i, 1);
    if (!keepSession) {
      var pinned = store('pinned') || {};
      delete pinned[tab.id];
      store('pinned', pinned);
    }
    if (slots[1] === tab) { slots[1] = null; focus = 0; }
    if (slots[0] === tab) {
      if (slots[1]) { slots[0] = slots[1]; slots[1] = null; }
      else { slots[0] = tabs[i] || tabs[i - 1] || null; }
      focus = 0;
    }
    tab.dispose();
    render();
  }

  function addTab(info, makeActive) {
    var tab = new Tab(info);
    tabs.push(tab);
    if (makeActive || !active) { activate(tab); } else { render(); }
    return tab;
  }

  var creating = false;
  function newTab() {
    if (creating) { return; }
    creating = true;
    var cols = active ? active.term.cols : 80;
    var rows = active ? active.term.rows : 24;
    api('POST', 'api/sessions', { cols: cols, rows: rows })
      .then(function (info) { addTab(info, true); })
      .catch(function (e) { if (e.message !== 'signed out') { toast(e.message, true); } })
      .then(function () { creating = false; });
  }

  function step(delta) {
    if (tabs.length < 2 || !active) { return; }
    var i = (tabs.indexOf(active) + delta + tabs.length) % tabs.length;
    activate(tabs[i]);
  }

  // drag-and-drop reordering
  var dragged = null;
  function clearDropMarks() {
    tabs.forEach(function (t) { t.el.classList.remove('drop-before'); });
  }
  function moveTab(tab, index) {
    var from = tabs.indexOf(tab);
    if (from < 0 || index < 0) { return; }
    tabs.splice(from, 1);
    if (from < index) { index--; }
    tabs.splice(index, 0, tab);
    tabs.forEach(function (t) { tabsEl.appendChild(t.el); });
    clearDropMarks();
    saveOrder();
  }
  tabsEl.addEventListener('dragover', function (ev) { if (dragged) { ev.preventDefault(); } });
  tabsEl.addEventListener('drop', function (ev) {      // dropped past the last tab
    if (!dragged) { return; }
    ev.preventDefault();
    var t = dragged;
    tabs.splice(tabs.indexOf(t), 1);
    tabs.push(t);
    tabs.forEach(function (x) { tabsEl.appendChild(x.el); });
    clearDropMarks();
    saveOrder();
  });

  // ---- menus -----------------------------------------------------------------------

  var menuEl = $('menu');
  function closeMenu() { menuEl.hidden = true; menuEl.textContent = ''; }
  function openMenu(x, y, build) {
    menuEl.textContent = '';
    build(menuEl);
    menuEl.hidden = false;
    var r = menuEl.getBoundingClientRect();
    menuEl.style.left = Math.max(4, Math.min(x, window.innerWidth - r.width - 4)) + 'px';
    menuEl.style.top = Math.max(4, Math.min(y, window.innerHeight - r.height - 4)) + 'px';
    var first = menuEl.querySelector('button.item');
    if (first) { first.focus(); }
  }
  function menuItem(parent, label, hint, fn) {
    var b = el('button', 'item');
    b.setAttribute('role', 'menuitem');
    b.appendChild(el('span', 'grow', label));
    if (hint) { b.appendChild(el('small', '', hint)); }
    b.addEventListener('click', function () { closeMenu(); fn(); });
    parent.appendChild(b);
    return b;
  }
  document.addEventListener('mousedown', function (ev) { if (!menuEl.hidden && !menuEl.contains(ev.target)) { closeMenu(); } }, true);
  menuEl.addEventListener('keydown', function (ev) {
    var items = Array.prototype.slice.call(menuEl.querySelectorAll('button.item'));
    var i = items.indexOf(document.activeElement);
    if (ev.key === 'Escape') { closeMenu(); if (active) { active.term.focus(); } }
    else if (ev.key === 'ArrowDown') { ev.preventDefault(); (items[i + 1] || items[0]).focus(); }
    else if (ev.key === 'ArrowUp') { ev.preventDefault(); (items[i - 1] || items[items.length - 1]).focus(); }
  });

  function tabMenu(tab, x, y) {
    openMenu(x, y, function (m) {
      menuItem(m, 'Rename', 'double-click', function () { tab.rename(); });
      menuItem(m, slots[1] ? 'Leave split view' : 'Split view with this tab', 'Alt+Shift+S', function () { toggleSplit(tab); });
      menuItem(m, 'Detach (keeps running)', 'Alt+Shift+D', function () { tab.detach(); });
      m.appendChild(el('div', 'sep'));
      menuItem(m, 'Close (ends the shell)', 'Alt+Shift+W', function () { tab.kill(); });
    });
  }

  // Every running session: open here, or detached (running without a tab)
  function sessionsMenu() {
    var r = $('sessions-btn').getBoundingClientRect();
    api('GET', 'api/sessions').then(function (j) {
      openMenu(r.left, r.bottom + 2, function (m) {
        m.appendChild(el('div', 'head', j.sessions.length + ' running session' + (j.sessions.length === 1 ? '' : 's')));
        j.sessions.sort(function (a, b) { return a.created - b.created; });
        j.sessions.forEach(function (s) {
          var here = tabs.filter(function (t) { return t.id === s.id; })[0];
          var b = el('button', 'item');
          b.setAttribute('data-session', s.id);
          var label = el('span', 'grow', s.title || 'shell');
          label.title = s.cwd || '';
          b.appendChild(label);
          b.appendChild(el('small', '', (here ? 'open here' : 'detached') + ' \u00b7 started ' + ago(s.created)
            + (s.clients > (here ? 1 : 0) ? ' \u00b7 open elsewhere' : '')));
          b.addEventListener('click', function () {
            closeMenu();
            if (here) { activate(here); return; }
            var h = hiddenIds();
            delete h[s.id];
            store('hidden', h);
            addTab(s, true);
          });
          var end = el('span', 'mini danger', 'end');
          end.title = 'End this session';
          end.setAttribute('role', 'button');
          end.addEventListener('click', function (ev) {
            ev.stopPropagation();
            if (!window.confirm('End "' + (s.title || 'shell') + '"? Anything running in it will stop.')) { return; }
            closeMenu();
            if (here) { here.ended = true; removeTab(here); }
            api('POST', 'api/sessions/' + s.id + '/kill').catch(function () { /* already gone */ });
          });
          b.appendChild(end);
          m.appendChild(b);
        });
        m.appendChild(el('div', 'sep'));
        menuItem(m, 'New terminal', 'Alt+Shift+T', newTab);
      });
    }).catch(function (e) { if (e.message !== 'signed out') { toast(e.message, true); } });
  }

  // ---- search ------------------------------------------------------------------------

  var searchBar = $('searchbar'), searchInput = $('search-input');
  function runSearch(forward, incremental) {
    if (!active || !active.search) { return; }
    var q = searchInput.value;
    if (!q) { active.search.clearDecorations(); return; }
    var opts = {
      caseSensitive: $('search-case').checked, regex: $('search-regex').checked, incremental: !!incremental,
      decorations: { matchOverviewRuler: '#888888', activeMatchColorOverviewRuler: '#ffaa00', matchBackground: '#665500', activeMatchBackground: '#aa7700' }
    };
    try {
      if (forward) { active.search.findNext(q, opts); } else { active.search.findPrevious(q, opts); }
    } catch (e) { /* bad regular expression while typing */ }
  }
  function toggleSearch(show) {
    var open = show === undefined ? searchBar.hidden : show;
    searchBar.hidden = !open;
    if (open) {
      var sel = active ? active.term.getSelection() : '';
      if (sel && sel.indexOf('\n') < 0) { searchInput.value = sel; }
      searchInput.focus();
      searchInput.select();
      runSearch(true, true);
    } else {
      tabs.forEach(function (t) { if (t.search) { t.search.clearDecorations(); } });
      if (active) { active.term.focus(); }
    }
  }
  searchInput.addEventListener('input', function () { runSearch(true, true); });
  searchInput.addEventListener('keydown', function (ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); runSearch(!ev.shiftKey, false); }
    else if (ev.key === 'Escape') { toggleSearch(false); }
  });
  $('search-next').addEventListener('click', function () { runSearch(true, false); });
  $('search-prev').addEventListener('click', function () { runSearch(false, false); });
  $('search-close').addEventListener('click', function () { toggleSearch(false); });
  $('search-case').addEventListener('change', function () { runSearch(true, true); });
  $('search-regex').addEventListener('change', function () { runSearch(true, true); });
  $('search-btn').addEventListener('click', function () { toggleSearch(); });

  // ---- files -------------------------------------------------------------------------

  var filesEl = $('files'), filesList = $('files-list'), filesInput = $('files-input'), filesStatus = $('files-status');
  var filesPath = '';

  function loadFiles(path) {
    var params = path ? { path: path } : { session: active ? active.id : '' };
    filesList.textContent = '';
    filesList.appendChild(el('div', 'note', 'Loading...'));
    api('GET', 'api/files', params).then(function (j) {
      filesPath = j.path;
      filesInput.value = j.path;
      filesList.textContent = '';
      j.entries.sort(function (a, b) {
        if (a.dir !== b.dir) { return a.dir ? -1 : 1; }
        return a.name.localeCompare(b.name);
      });
      j.entries.forEach(function (f) {
        var b = el('button', f.dir ? 'dir' : 'file');
        b.appendChild(el('span', 'name', f.name + (f.dir ? '/' : '')));
        b.appendChild(el('small', '', f.dir ? '' : sizeText(f.size)));
        b.title = f.dir ? 'Open' : 'Download';
        b.addEventListener('click', function () {
          var full = (j.path === '/' ? '' : j.path) + '/' + f.name;
          if (f.dir) { loadFiles(full); return; }
          var a = document.createElement('a');
          a.href = 'api/download?' + new URLSearchParams({ path: full }).toString();
          a.download = f.name;
          document.body.appendChild(a);
          a.click();
          a.remove();
        });
        filesList.appendChild(b);
      });
      if (j.entries.length === 0) { filesList.appendChild(el('div', 'note', 'Empty directory.')); }
    }).catch(function (e) {
      if (e.message === 'signed out') { return; }
      filesList.textContent = '';
      filesList.appendChild(el('div', 'note', e.message));
    });
  }

  // Upload into `target`: { path: dir } or { session: id } (its current directory)
  function uploadFiles(fileList, target) {
    var files = Array.prototype.slice.call(fileList);
    var done = 0, failed = 0;
    if (!files.length) { return; }
    function next() {
      if (!files.length) {
        filesStatus.textContent = '';
        toast(failed ? (done + ' uploaded, ' + failed + ' failed') : (done + ' file' + (done === 1 ? '' : 's') + ' uploaded'), failed > 0);
        if (!filesEl.hidden) { loadFiles(filesPath); }
        return;
      }
      var f = files.shift();
      filesStatus.textContent = 'Uploading ' + f.name + '...';
      toast('Uploading ' + f.name + ' (' + sizeText(f.size) + ')...');
      var form = new FormData();
      Object.keys(target).forEach(function (k) { form.append(k, target[k]); });
      form.append('file', f, f.name);
      api('POST', 'api/upload', form).then(function () { done++; })
        .catch(function (e) {
          failed++;
          if (e.message !== 'signed out') { toast(f.name + ': ' + (/HTTP 413/.test(e.message) ? 'larger than the upload limit' : e.message), true); }
        })
        .then(next);
    }
    next();
  }

  function toggleFiles(show) {
    var open = show === undefined ? filesEl.hidden : show;
    filesEl.hidden = !open;
    if (open) { togglePanel(false); loadFiles(''); }
    else if (active) { active.term.focus(); }
  }
  $('files-btn').addEventListener('click', function () { toggleFiles(); });
  $('files-close').addEventListener('click', function () { toggleFiles(false); });
  $('files-up').addEventListener('click', function () { loadFiles(filesPath.replace(/\/[^/]*$/, '') || '/'); });
  $('files-here').addEventListener('click', function () { loadFiles(''); });
  filesInput.addEventListener('keydown', function (ev) { if (ev.key === 'Enter') { loadFiles(filesInput.value.trim()); } });
  $('files-upload').addEventListener('click', function () { $('files-pick').click(); });
  $('files-pick').addEventListener('change', function () {
    uploadFiles($('files-pick').files, { path: filesPath });
    $('files-pick').value = '';
  });
  filesEl.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') { toggleFiles(false); } });

  // drag files from the desktop onto the page
  var dropEl = $('drop'), dragDepth = 0;
  function hasFiles(ev) { return !dragged && ev.dataTransfer && Array.prototype.indexOf.call(ev.dataTransfer.types || [], 'Files') >= 0; }
  document.addEventListener('dragenter', function (ev) {
    if (!hasFiles(ev)) { return; }
    dragDepth++;
    $('drop-dir').textContent = !filesEl.hidden ? filesPath : (active ? 'the terminal\'s current directory' : 'your home directory');
    dropEl.hidden = false;
  });
  document.addEventListener('dragleave', function (ev) { if (hasFiles(ev) && --dragDepth <= 0) { dragDepth = 0; dropEl.hidden = true; } });
  document.addEventListener('dragover', function (ev) { if (hasFiles(ev)) { ev.preventDefault(); } });
  document.addEventListener('drop', function (ev) {
    if (!hasFiles(ev)) { return; }
    ev.preventDefault();
    dragDepth = 0;
    dropEl.hidden = true;
    uploadFiles(ev.dataTransfer.files, !filesEl.hidden ? { path: filesPath } : { session: active ? active.id : '' });
  });

  // ---- touch keys --------------------------------------------------------------------

  var mods = { ctrl: false, alt: false };
  function syncMods() {
    Array.prototype.forEach.call(document.querySelectorAll('#keybar [data-mod]'), function (b) {
      b.classList.toggle('on', !!mods[b.getAttribute('data-mod')]);
    });
  }
  // Apply a "sticky" Ctrl / Alt from the on-screen keys to the next key typed
  function applyModifiers(data) {
    if (!mods.ctrl && !mods.alt) { return data; }
    var out = data;
    if (mods.ctrl && data.length === 1) {
      var c = data.toUpperCase().charCodeAt(0);
      if (c >= 64 && c <= 95) { out = String.fromCharCode(c - 64); }
      else if (data === ' ') { out = '\x00'; }
      else if (data === '?') { out = '\x7f'; }
    }
    if (mods.alt) { out = '\x1b' + out; }
    mods.ctrl = false;
    mods.alt = false;
    syncMods();
    return out;
  }
  $('keybar').addEventListener('click', function (ev) {
    var b = ev.target.closest('button');
    if (!b || !active) { return; }
    var mod = b.getAttribute('data-mod'), key = b.getAttribute('data-key'), text = b.getAttribute('data-text');
    if (mod) { mods[mod] = !mods[mod]; syncMods(); active.term.focus(); return; }
    if (text) { active.send('I', applyModifiers(text)); active.term.focus(); return; }
    if (key === 'paste') {
      if (navigator.clipboard && navigator.clipboard.readText) {
        navigator.clipboard.readText().then(function (t) { if (t) { active.term.paste(t); } }).catch(function () { toast('Clipboard access was denied', true); });
      }
      active.term.focus();
      return;
    }
    var app = active.term.modes && active.term.modes.applicationCursorKeysMode;
    var arrow = app ? '\x1bO' : '\x1b[';
    var seq = { esc: '\x1b', tab: '\t', up: arrow + 'A', down: arrow + 'B', right: arrow + 'C', left: arrow + 'D',
      home: '\x1b[H', end: '\x1b[F', pgup: '\x1b[5~', pgdn: '\x1b[6~' }[key];
    if (seq) { active.send('I', mods.alt ? applyModifiers(seq) : seq); mods.ctrl = false; syncMods(); }
    active.term.focus();
  });
  $('keybar').addEventListener('mousedown', function (ev) { ev.preventDefault(); });   // keep the keyboard up

  // ---- keys ----------------------------------------------------------------------------

  // Shortcuts that stay in the page; everything else goes to the shell.
  function keyHandler(tab, ev) {
    if (ev.type !== 'keydown') { return true; }
    if (ev.altKey && ev.shiftKey && !ev.ctrlKey) {
      if (ev.code === 'KeyT') { ev.preventDefault(); newTab(); return false; }
      if (ev.code === 'KeyW') { ev.preventDefault(); tab.kill(); return false; }
      if (ev.code === 'KeyD') { ev.preventDefault(); tab.detach(); return false; }
      if (ev.code === 'KeyS') { ev.preventDefault(); toggleSplit(tab); return false; }
      if (ev.code === 'ArrowLeft') { ev.preventDefault(); step(-1); return false; }
      if (ev.code === 'ArrowRight') { ev.preventDefault(); step(1); return false; }
    }
    if (ev.altKey && !ev.shiftKey && !ev.ctrlKey && !ev.metaKey && /^Digit[1-9]$/.test(ev.code)) {
      var n = parseInt(ev.code.slice(5), 10) - 1;
      if (tabs[n]) { ev.preventDefault(); activate(tabs[n]); return false; }
    }
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'Comma') { ev.preventDefault(); return false; }   // handled on document
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'KeyF') { ev.preventDefault(); return false; }
    if (ev.ctrlKey && !ev.shiftKey && !ev.altKey && (ev.code === 'Equal' || ev.code === 'NumpadAdd')) { ev.preventDefault(); setSetting('fontSize', settings.fontSize + 1); return false; }
    if (ev.ctrlKey && !ev.shiftKey && !ev.altKey && (ev.code === 'Minus' || ev.code === 'NumpadSubtract')) { ev.preventDefault(); setSetting('fontSize', settings.fontSize - 1); return false; }
    if (ev.ctrlKey && !ev.shiftKey && !ev.altKey && ev.code === 'Digit0') { ev.preventDefault(); setSetting('fontSize', DEFAULTS.fontSize); return false; }
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'KeyC') {
      var sel = tab.term.getSelection();
      if (sel && navigator.clipboard) { navigator.clipboard.writeText(sel).catch(function () { /* denied */ }); }
      ev.preventDefault();
      return false;
    }
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'KeyV') {
      if (navigator.clipboard && navigator.clipboard.readText) {
        navigator.clipboard.readText().then(function (t) { if (t) { tab.term.paste(t); } }).catch(function () { /* denied */ });
      }
      ev.preventDefault();
      return false;
    }
    return true;
  }

  // ---- settings panel ---------------------------------------------------------

  var panel = $('settings');
  var panelBtn = $('settings-btn');
  var savedEl = $('set-saved');
  var savedTimer = null;

  function flashSaved(text) {
    savedEl.textContent = text;
    clearTimeout(savedTimer);
    savedTimer = setTimeout(function () { savedEl.textContent = ''; }, 2000);
  }

  function field(key) { return $('set-' + key); }

  // Show the current settings in the controls
  function syncPanel() {
    Object.keys(DEFAULTS).forEach(function (key) {
      var e = field(key);
      if (!e) { return; }
      if (e.type === 'checkbox') { e.checked = !!settings[key]; }
      else if (document.activeElement !== e) { e.value = String(settings[key]); }
    });
    $('custom-font-row').hidden = settings.fontFamily !== 'custom';
    var t = currentTheme().term;
    var sw = $('swatches');
    sw.textContent = '';
    [t.background, t.foreground, t.red, t.green, t.yellow, t.blue, t.magenta, t.cyan, t.brightBlack, t.brightWhite].forEach(function (c) {
      var s = document.createElement('span');
      s.style.background = c;
      sw.appendChild(s);
    });
  }

  function browserName(ua) {
    var m = /(Firefox|Edg|OPR|Chrome|Safari)\/(\d+)/.exec(ua || '');
    var os = /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Mac OS X/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : '';
    var name = m ? ({ Edg: 'Edge', OPR: 'Opera' }[m[1]] || m[1]) + ' ' + m[2] : (ua ? ua.slice(0, 30) : 'unknown client');
    return name + (os ? ' on ' + os : '');
  }

  // Who is signed in, with a way to sign the others out
  function loadLogins() {
    var box = $('logins');
    api('GET', 'api/logins').then(function (j) {
      box.textContent = '';
      box.appendChild(el('div', 'note', 'Two-factor sign-in is ' + (j.totp ? 'on.' : 'off (run ./totp-setup.sh to turn it on).')));
      j.active.sort(function (a, b) { return (b.current ? 1 : 0) - (a.current ? 1 : 0) || b.created - a.created; });
      j.active.forEach(function (s) {
        var row = el('div', 'login');
        var who = el('span', 'grow', browserName(s.browser) + (s.current ? ' (this browser)' : ''));
        who.title = s.browser;
        row.appendChild(who);
        row.appendChild(el('small', '', s.address + ' \u00b7 ' + ago(s.created)));
        if (!s.current) {
          var b = el('button', '', 'Sign out');
          b.addEventListener('click', function () { api('POST', 'api/logins/revoke', { id: s.id }).then(loadLogins); });
          row.appendChild(b);
        }
        box.appendChild(row);
      });
      if (j.active.length > 1) {
        var all = el('button', 'revoke-all', 'Sign out everywhere else');
        all.addEventListener('click', function () {
          api('POST', 'api/logins/revoke', { others: '1' }).then(function (r) { toast(r.revoked + ' other sign-in' + (r.revoked === 1 ? '' : 's') + ' ended'); loadLogins(); });
        });
        box.appendChild(all);
      }
      var det = el('details');
      det.appendChild(el('summary', '', 'Recent sign-in attempts'));
      j.recent.forEach(function (r) {
        var row = el('div', 'login');
        row.appendChild(el('span', r.result === 'ok' ? 'ok' : 'bad', r.result === 'ok' ? 'signed in' : r.result === 'locked' ? 'blocked' : r.result === 'bad-code' ? 'wrong code' : 'failed'));
        var who = el('span', 'grow', r.address + ' \u00b7 ' + browserName(r.browser));
        who.title = r.browser;
        row.appendChild(who);
        row.appendChild(el('small', '', ago(r.time)));
        det.appendChild(row);
      });
      box.appendChild(det);
    }).catch(function () { /* signed out or offline */ });
  }

  function togglePanel(show) {
    var open = show === undefined ? panel.hidden : show;
    panel.hidden = !open;
    panelBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) { filesEl.hidden = true; syncPanel(); loadLogins(); field('theme').focus(); }
    else if (active && filesEl.hidden) { active.term.focus(); }
  }

  THEMES.forEach(function (t) {
    var o = document.createElement('option');
    o.value = t.id;
    o.textContent = t.name;
    field('theme').appendChild(o);
  });
  FONTS.forEach(function (f) {
    var o = document.createElement('option');
    o.value = f.id;
    o.textContent = f.name;
    field('fontFamily').appendChild(o);
  });
  Object.keys(DEFAULTS).forEach(function (key) {
    var e = field(key);
    if (!e) { return; }
    e.addEventListener(e.tagName === 'SELECT' || e.type === 'checkbox' ? 'change' : 'input', function () {
      var v = e.type === 'checkbox' ? e.checked : e.value;
      if (typeof DEFAULTS[key] === 'number') {
        v = parseFloat(v);
        if (isNaN(v)) { return; }           // still typing
        if (key === 'fontSize' && (v < 8 || v > 32)) { return; }
      }
      setSetting(key, v);
    });
  });
  // preview themes while moving through the list with the arrow keys
  field('theme').addEventListener('keyup', function () { if (field('theme').value !== settings.theme) { setSetting('theme', field('theme').value); } });
  Array.prototype.forEach.call(document.querySelectorAll('[data-step]'), function (b) {
    b.addEventListener('click', function () { setSetting(b.getAttribute('data-step'), settings[b.getAttribute('data-step')] + parseFloat(b.getAttribute('data-by'))); });
  });
  $('set-reset').addEventListener('click', function () {
    settings = cleanSettings({});
    applySettings();
    syncPanel();
    saveSettings();
  });
  panelBtn.addEventListener('click', function () { togglePanel(); });
  $('settings-close').addEventListener('click', function () { togglePanel(false); });
  panel.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') { togglePanel(false); } });
  document.addEventListener('keydown', function (ev) {
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'Comma') { ev.preventDefault(); togglePanel(); }
    if (ev.ctrlKey && ev.shiftKey && ev.code === 'KeyF') { ev.preventDefault(); toggleSearch(true); }
  });

  // the server's copy wins over this browser's (it may be newer)
  api('GET', 'api/settings').then(function (remote) {
    if (remote && Object.keys(remote).length) {
      settings = cleanSettings(remote);
      store('settings', settings);
      applySettings();
      syncPanel();
    }
  }).catch(function () { /* keep the local copy */ });

  // ---- start -----------------------------------------------------------------

  $('new').addEventListener('click', newTab);
  $('empty-new').addEventListener('click', newTab);
  $('sessions-btn').addEventListener('click', sessionsMenu);
  $('logout').addEventListener('click', function () {
    fetch('logout', { method: 'POST', credentials: 'same-origin' }).then(function () { location.reload(); });
  });

  // Full screen: with the Keyboard Lock API (Chromium) the browser's own
  // shortcuts -- Ctrl+W, Ctrl+T, Ctrl+N, Esc -- reach the terminal instead.
  $('fs-btn').addEventListener('click', function () {
    if (document.fullscreenElement) { document.exitFullscreen(); return; }
    var p = document.documentElement.requestFullscreen ? document.documentElement.requestFullscreen() : null;
    if (p && p.then) {
      p.then(function () {
        if (navigator.keyboard && navigator.keyboard.lock) {
          navigator.keyboard.lock().then(function () { toast('Full screen: browser shortcuts now go to the terminal. Hold Esc to leave.'); }).catch(function () { /* not allowed */ });
        }
      }).catch(function () { toast('Full screen is not available here', true); });
    }
  });
  document.addEventListener('fullscreenchange', function () {
    if (!document.fullscreenElement && navigator.keyboard && navigator.keyboard.unlock) { navigator.keyboard.unlock(); }
    scheduleFit();
  });

  window.addEventListener('beforeunload', function (ev) {
    if (settings.warnOnLeave && tabs.length > 0) { ev.preventDefault(); ev.returnValue = ''; }
  });

  var resizeTimer = null;
  function scheduleFit() {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(fitShown, 60);
  }
  if (typeof ResizeObserver !== 'undefined') { new ResizeObserver(scheduleFit).observe(panesEl); }
  window.addEventListener('resize', scheduleFit);
  // Coming back to this window: take the session back to our size if another
  // browser changed it meanwhile.
  function reclaim() {
    slots.forEach(function (t) {
      if (t && t.foreign) { t.sized = false; }
    });
    fitShown();
  }
  window.addEventListener('focus', reclaim);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && active) { reclaim(); active.term.focus(); }
  });
  if (document.fonts && document.fonts.ready) { document.fonts.ready.then(fitShown); }
  // phones: keep the page (and the key bar) above the on-screen keyboard
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', function () {
      document.body.style.height = window.visualViewport.height + 'px';
      scheduleFit();
    });
  }

  api('GET', 'api/sessions').then(function (j) {
    $('user').textContent = j.user + '@' + location.hostname;
    var order = store('order') || [];
    var want = store('active');
    var hidden = hiddenIds(), stillHidden = {};
    j.sessions.forEach(function (s) { if (hidden[s.id]) { stillHidden[s.id] = 1; } });
    store('hidden', stillHidden);            // forget sessions that no longer exist
    var mine = j.sessions.filter(function (s) { return !stillHidden[s.id]; });
    mine.sort(function (a, b) {
      var ia = order.indexOf(a.id), ib = order.indexOf(b.id);
      if (ia < 0 && ib < 0) { return a.created - b.created; }
      if (ia < 0) { return 1; }
      if (ib < 0) { return -1; }
      return ia - ib;
    });
    if (j.sessions.length === 0) { newTab(); return; }
    mine.forEach(function (s) { addTab(s, false); });
    if (mine.length === 0) {
      updateStatus();
      emptyEl.querySelector('p').textContent = j.sessions.length + ' session' + (j.sessions.length === 1 ? ' is' : 's are') + ' running detached - use the sessions menu to re-attach.';
      return;
    }
    activate(tabs.filter(function (t) { return t.id === want; })[0] || tabs[0]);
  }).catch(function (e) {
    if (e.message !== 'signed out') { emptyEl.hidden = false; emptyEl.querySelector('p').textContent = 'Could not load sessions: ' + e.message; }
  });
})();
