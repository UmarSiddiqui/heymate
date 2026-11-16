//
//  RemoteAccessPage.swift
//  HeyMate
//
//  The one page Phone access serves, bundled as three strings so there is no
//  resource lookup and no directory to serve. No frameworks, no build step,
//  no remote origins. The script never writes HTML: every piece of mate text
//  goes in through textContent, because proposals, questions and replies are
//  untrusted.
//

import Foundation

nonisolated enum RemoteAccessPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>HeyMate</title>
<link rel="stylesheet" href="/app.css">
<script src="/app.js" defer></script>
</head>
<body>
<header class="bar"><h1>HeyMate</h1><span id="updated" class="muted small"></span></header>
<main>
<p id="offline" class="notice" role="status" hidden>Can't reach your Mac. It may be asleep, or HeyMate is closed. This page keeps trying.</p>
<p id="toast" class="notice" role="status" hidden></p>
<section id="loading"><p class="muted">Connecting to your Mac…</p></section>
<section id="pair" hidden>
<h2>Pair this phone</h2>
<p class="muted">On your Mac, open HeyMate Settings, then Privacy &amp; Data, then Phone access, and choose Pair a phone. Type the code it shows.</p>
<form id="pairForm" class="row">
<input id="code" name="code" autocomplete="one-time-code" autocapitalize="characters" autocorrect="off" spellcheck="false" maxlength="12" aria-label="Pairing code">
<button type="submit">Pair</button>
</form>
<p id="pairMsg" class="muted" role="status"></p>
</section>
<section id="home" hidden>
<h2>Needs you</h2>
<div id="inbox" class="list"></div>
<h2>Mates</h2>
<div id="mates" class="list"></div>
<p class="foot"><button id="signout" type="button" class="quiet">Unpair this phone</button></p>
</section>
<section id="chat" hidden>
<p><button id="back" type="button" class="quiet">Back</button></p>
<h2 id="chatTitle"></h2>
<div id="thread" class="list"></div>
<form id="msgForm">
<textarea id="msg" maxlength="1000" rows="3" aria-label="Message"></textarea>
<div class="row end"><button type="submit">Send</button></div>
</form>
<p class="muted small">Runs with this mate's usual rules. Anything that needs your approval waits on your Mac.</p>
</section>
</main>
<footer class="muted small">Works on the same Wi-Fi as your Mac. This is a plain, unencrypted connection on your local network.</footer>
</body>
</html>
"""#

    static let css = #"""
:root{--bg:#fff;--fg:#0b0b0b;--muted:#6a6a6a;--card:#f3f3f3;--line:#e1e1e1;--btn:#0b0b0b;--btnfg:#fff;--attn:#7a5200;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#f1f1f1;--muted:#9b9b9b;--card:#131313;--line:#272727;--btn:#f1f1f1;--btnfg:#000;--attn:#e2b457}}
[hidden]{display:none!important}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;padding:0 16px 32px;max-width:640px;margin:0 auto;overflow-wrap:anywhere}
.bar{display:flex;align-items:baseline;justify-content:space-between;padding:20px 0 8px;border-bottom:1px solid var(--line)}
h1{font-size:20px;margin:0;letter-spacing:-.01em}
h2{font-size:13px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:24px 0 8px}
.muted{color:var(--muted)}
.small{font-size:13px}
.list{display:flex;flex-direction:column;gap:8px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px}
.meta{font-size:13px;color:var(--muted);display:flex;gap:8px;justify-content:space-between}
.title{font-weight:600;margin:4px 0}
.detail{margin:0 0 4px;color:var(--fg)}
.tag{display:inline-block;font-size:12px;border:1px solid var(--line);border-radius:999px;padding:2px 8px;color:var(--attn);margin-top:6px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-top:8px}
.end{justify-content:flex-end}
button{font:inherit;font-weight:600;border:1px solid var(--btn);background:var(--btn);color:var(--btnfg);border-radius:999px;padding:8px 16px;min-height:40px;cursor:pointer}
button.quiet,button.choice{background:transparent;color:var(--fg);border-color:var(--line)}
button:disabled{opacity:.45}
input,textarea{font:inherit;color:var(--fg);background:var(--bg);border:1px solid var(--line);border-radius:10px;padding:9px 12px;flex:1;min-width:0;width:100%}
.row input{width:auto}
textarea{resize:vertical;margin-top:8px}
.mate{display:block;width:100%;text-align:left;background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:14px;padding:12px 14px;font-weight:400}
.mate .name{font-weight:600}
.status{float:right;font-size:12px;color:var(--muted)}
.status.waiting{color:var(--attn)}
.bubble{border-radius:14px;padding:10px 12px;white-space:pre-wrap;max-width:92%}
.bubble.me{align-self:flex-end;background:var(--btn);color:var(--btnfg)}
.bubble.mate{align-self:flex-start;background:var(--card);border:1px solid var(--line)}
.notice{border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin:12px 0 0}
.empty{color:var(--muted);padding:12px 0}
.foot{margin-top:28px}
footer{margin-top:24px;border-top:1px solid var(--line);padding-top:12px}
#code{letter-spacing:.2em;text-transform:uppercase;font-family:ui-monospace,Menlo,monospace}
"""#

    static let script = #"""
'use strict';
(function () {
  var csrf = null, chatMate = null, threads = {}, polls = {}, toastTimer = null;
  var KIND = { proposal: 'Proposal', question: 'Question', failed: 'Routine', signin: 'Sign-in', permission: 'Permission' };
  var STATUS = { idle: 'Idle', working: 'Working', waiting: 'Waiting on you' };

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
  function show(id) {
    ['loading', 'pair', 'home', 'chat'].forEach(function (s) { $(s).hidden = s !== id; });
  }
  function toast(text) {
    var t = $('toast');
    t.textContent = text; t.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, 5000);
  }

  function api(method, path, body, extra) {
    var headers = { 'Accept': 'application/json' };
    var options = { method: method, headers: headers, credentials: 'same-origin', cache: 'no-store', redirect: 'error' };
    if (method === 'POST') {
      headers['Content-Type'] = 'application/json';
      if (csrf) headers['X-HeyMate-CSRF'] = csrf;
      if (extra) Object.keys(extra).forEach(function (k) { headers[k] = extra[k]; });
      options.body = JSON.stringify(body || {});
    }
    return fetch(path, options).then(function (response) {
      $('offline').hidden = true;
      return response.json().catch(function () { return {}; }).then(function (data) {
        if (response.status === 401) { csrf = null; chatMate = null; show('pair'); }
        return { status: response.status, data: data };
      });
    }, function (error) {
      $('offline').hidden = false;
      throw error;
    });
  }

  function refresh() {
    return api('GET', '/api/state').then(function (res) {
      if (res.status !== 200) return;
      csrf = res.data.csrf;
      renderInbox(res.data.inbox || []);
      renderMates(res.data.mates || []);
      $('updated').textContent = 'Updated ' + new Date().toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
      if (!chatMate) show('home');
    }).catch(function () {});
  }

  function act(path, body, buttons) {
    buttons.forEach(function (b) { b.disabled = true; });
    return api('POST', path, body).then(function (res) {
      if (res.status === 200) { refresh(); return true; }
      if (res.status === 429) toast('Slow down a moment, then try again.');
      else if (res.status !== 401) toast("Couldn't do that. It may already be handled, or the mate is busy.");
      buttons.forEach(function (b) { b.disabled = false; });
      return false;
    }).catch(function () { buttons.forEach(function (b) { b.disabled = false; }); return false; });
  }

  function renderInbox(items) {
    var box = $('inbox');
    clear(box);
    if (!items.length) { box.appendChild(el('p', 'empty', 'Nothing needs you right now.')); return; }
    items.forEach(function (item) {
      var card = el('div', 'card');
      var meta = el('div', 'meta');
      meta.appendChild(el('span', '', item.mate));
      meta.appendChild(el('span', '', KIND[item.kind] || ''));
      card.appendChild(meta);
      card.appendChild(el('p', 'title', item.title));
      if (item.detail) card.appendChild(el('p', 'detail', item.detail));
      if (item.atMac) card.appendChild(el('span', 'tag', 'Needs you at the Mac'));
      var actions = item.actions || [];
      if (actions.indexOf('approve') >= 0) {
        var row = el('div', 'row');
        var approve = el('button', '', 'Approve'); approve.type = 'button';
        var skip = el('button', 'quiet', 'Skip'); skip.type = 'button';
        approve.addEventListener('click', function () { act('/api/proposals/approve', { id: item.id }, [approve, skip]); });
        skip.addEventListener('click', function () { act('/api/proposals/skip', { id: item.id }, [approve, skip]); });
        row.appendChild(approve); row.appendChild(skip);
        card.appendChild(row);
      }
      if (actions.indexOf('answer') >= 0) {
        var answerRow = el('div', 'row');
        var all = [];
        (item.choices || []).forEach(function (choice) {
          var b = el('button', 'choice', choice); b.type = 'button';
          b.addEventListener('click', function () { act('/api/questions/answer', { id: item.id, answer: choice }, all); });
          all.push(b); answerRow.appendChild(b);
        });
        var form = el('form', 'row');
        var input = el('input'); input.maxLength = 600; input.placeholder = 'Your answer'; input.setAttribute('aria-label', 'Your answer');
        var send = el('button', '', 'Answer'); send.type = 'submit';
        all.push(send);
        form.addEventListener('submit', function (e) {
          e.preventDefault();
          var text = input.value.trim();
          if (text) act('/api/questions/answer', { id: item.id, answer: text }, all);
        });
        form.appendChild(input); form.appendChild(send);
        if (all.length > 1) card.appendChild(answerRow);
        card.appendChild(form);
      }
      box.appendChild(card);
    });
  }

  function renderMates(mates) {
    var box = $('mates');
    clear(box);
    if (!mates.length) { box.appendChild(el('p', 'empty', 'No mates yet.')); return; }
    mates.forEach(function (mate) {
      var b = el('button', 'mate'); b.type = 'button';
      b.appendChild(el('span', 'status ' + mate.status, STATUS[mate.status] || ''));
      b.appendChild(el('div', 'name', mate.name));
      if (mate.line) b.appendChild(el('div', 'muted small', mate.line));
      b.addEventListener('click', function () { openChat(mate); });
      box.appendChild(b);
    });
  }

  function openChat(mate) {
    chatMate = mate;
    $('chatTitle').textContent = mate.name;
    renderThread();
    show('chat');
  }

  function renderThread() {
    var box = $('thread');
    clear(box);
    var list = threads[chatMate.id] || [];
    if (!list.length) box.appendChild(el('p', 'empty', 'Send a short message. The reply shows here when it lands.'));
    list.forEach(function (m) { box.appendChild(el('div', 'bubble ' + (m.me ? 'me' : 'mate'), m.text)); });
  }

  function say(mateID, text, me) {
    (threads[mateID] = threads[mateID] || []).push({ me: me, text: text });
    if (chatMate && chatMate.id === mateID) renderThread();
  }

  var REPLY = {
    queued: 'Waiting for the mate to start…', working: 'Working…',
    atMac: 'Waiting for your approval on the Mac.', question: 'It asked a question. See Needs you.'
  };

  function pollReply(mateID, id, started) {
    if (Date.now() - started > 15 * 60 * 1000) { say(mateID, 'Still working. Check back later on your Mac.', false); return; }
    api('GET', '/api/messages/reply?id=' + encodeURIComponent(id)).then(function (res) {
      if (res.status !== 200) { if (res.status !== 401) say(mateID, 'The reply is no longer available here.', false); return; }
      var s = res.data.state;
      if (s === 'done') { say(mateID, res.data.text || 'Done.', false); return; }
      if (s === 'failed') { say(mateID, "Couldn't finish" + (res.data.text ? ': ' + res.data.text : '.'), false); return; }
      if (polls[id] !== s && REPLY[s]) { polls[id] = s; toast(REPLY[s]); }
      setTimeout(function () { pollReply(mateID, id, started); }, 3000);
    }).catch(function () { setTimeout(function () { pollReply(mateID, id, started); }, 6000); });
  }

  function sendMessage(e) {
    e.preventDefault();
    var input = $('msg'), text = input.value.trim(), mate = chatMate;
    if (!text || !mate) return;
    var button = $('msgForm').querySelector('button');
    button.disabled = true;
    api('POST', '/api/messages', { mate: mate.id, text: text }).then(function (res) {
      button.disabled = false;
      if (res.status === 200 && res.data.id) {
        input.value = '';
        say(mate.id, text, true);
        pollReply(mate.id, res.data.id, Date.now());
      } else if (res.status === 429) toast('Slow down a moment, then try again.');
      else if (res.status !== 401) toast("Couldn't send. The mate may be busy; try again shortly.");
    }).catch(function () { button.disabled = false; });
  }

  function pair(e) {
    e.preventDefault();
    var code = $('code').value.trim();
    if (!code) return;
    $('pairMsg').textContent = 'Pairing…';
    api('POST', '/api/pair', { code: code }, { 'X-HeyMate-Pair': '1' }).then(function (res) {
      if (res.status === 200) { $('pairMsg').textContent = ''; $('code').value = ''; refresh(); }
      else if (res.status === 429) $('pairMsg').textContent = 'Too many tries. Make a new code on your Mac.';
      else $('pairMsg').textContent = "That code didn't work. Check it, or make a new one on your Mac.";
    }).catch(function () { $('pairMsg').textContent = ''; });
  }

  function signOut() {
    api('POST', '/api/sign-out', {}).then(function () { csrf = null; chatMate = null; show('pair'); });
  }

  document.addEventListener('DOMContentLoaded', function () {
    var match = /^#pair=([A-Za-z0-9-]{4,16})$/.exec(location.hash);
    if (match) { $('code').value = match[1]; }
    if (location.hash) history.replaceState(null, '', '/');
    $('pairForm').addEventListener('submit', pair);
    $('msgForm').addEventListener('submit', sendMessage);
    $('back').addEventListener('click', function () { chatMate = null; show('home'); refresh(); });
    $('signout').addEventListener('click', signOut);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) refresh(); });
    setInterval(function () { if (!document.hidden) refresh(); }, 10000);
    refresh();
  });
})();
"""#
}
