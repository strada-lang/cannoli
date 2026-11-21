(function () {
  'use strict';
  var form = document.getElementById('login');
  var err = document.getElementById('error');
  var btn = document.getElementById('submit');
  if (location.protocol !== 'https:' && location.hostname !== 'localhost' && location.hostname !== '127.0.0.1' && location.hostname !== '[::1]') {
    err.textContent = 'Warning: this page is not using HTTPS. Your password and terminal traffic can be read on the network.';
    err.hidden = false;
    err.classList.add('warn');
  }
  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    btn.disabled = true;
    var body = new URLSearchParams();
    body.set('username', document.getElementById('username').value);
    body.set('password', document.getElementById('password').value);
    body.set('code', document.getElementById('code').value.replace(/\s+/g, ''));
    fetch('login', { method: 'POST', body: body, credentials: 'same-origin' })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (res) {
        if (res.ok) { location.reload(); return; }
        err.classList.remove('warn');
        err.textContent = res.j.error || 'Sign-in failed.';
        err.hidden = false;
        btn.disabled = false;
        document.getElementById('password').select();
      })
      .catch(function () {
        err.classList.remove('warn');
        err.textContent = 'Cannot reach the server.';
        err.hidden = false;
        btn.disabled = false;
      });
  });
})();
