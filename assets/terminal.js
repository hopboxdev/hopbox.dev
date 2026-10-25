(function () {
  'use strict';

  var LINES = [
    { cmd: true, text: 'hopbox new box1' },
    { cmd: false, text: 'state   running' },
    { cmd: false, text: 'url     https://box1.dev.hopbox.dev (private, port 8000)' },
    { cmd: false, text: 'ssh     ssh box1.hop (port 10001)' },
    { cmd: true, text: 'ssh box1.hop' },
    { cmd: false, text: 'user@box1:~$ exit' },
    { cmd: true, text: 'hopbox url public box1' },
    { cmd: false, text: 'https://box1.dev.hopbox.dev (public, port 8000)' }
  ];
  var TICK_MS = 45;
  var WAIT_START = 6;
  var WAIT_RESTART = 8;
  var WAIT_AFTER_CMD = 12;
  var WAIT_AFTER_OUTPUT = 5;
  var HOLD_AT_END = 80;

  var transcript = document.getElementById('terminal-transcript');
  if (!transcript) return;

  var reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  var screen = null;
  var timer = null;
  var state;
  var rows;

  function createRow(isCmd) {
    var el = document.createElement('div');
    el.className = 'terminal-line ' + (isCmd ? 'terminal-cmd' : 'terminal-out');
    if (isCmd) {
      var prompt = document.createElement('span');
      prompt.className = 'terminal-prompt';
      prompt.textContent = '$ ';
      el.appendChild(prompt);
    }
    var text = document.createTextNode('');
    el.appendChild(text);
    var caret = document.createElement('span');
    caret.className = 'caret';
    return { el: el, isCmd: isCmd, text: text, caret: caret };
  }

  function visibleLines() {
    var lines = [];
    for (var i = 0; i < LINES.length && i <= state.step; i++) {
      var line = LINES[i];
      if (i === state.step && !line.cmd) continue;
      var typing = i === state.step && line.cmd;
      lines.push({
        cmd: line.cmd,
        text: typing ? line.text.slice(0, state.chars) : line.text,
        caret: typing
      });
    }
    if (state.step >= LINES.length) lines.push({ cmd: true, text: '', caret: true });
    return lines;
  }

  // Rows are reused across ticks so the caret keeps blinking instead of restarting its animation.
  function render() {
    var lines = visibleLines();
    lines.forEach(function (line, i) {
      var row = rows[i];
      if (!row || row.isCmd !== line.cmd) {
        var fresh = createRow(line.cmd);
        if (row) screen.replaceChild(fresh.el, row.el);
        else screen.appendChild(fresh.el);
        row = rows[i] = fresh;
      }
      if (row.text.data !== line.text) row.text.data = line.text;
      if (line.caret && !row.caret.parentNode) row.el.appendChild(row.caret);
      if (!line.caret && row.caret.parentNode) row.el.removeChild(row.caret);
    });
    rows.splice(lines.length).forEach(function (row) {
      screen.removeChild(row.el);
    });
  }

  function tick() {
    if (state.wait > 0) {
      state.wait--;
      return;
    }
    if (state.step >= LINES.length) {
      if (!state.hold) {
        state.hold = true;
        state.wait = HOLD_AT_END;
        return;
      }
      state = { step: 0, chars: 0, wait: WAIT_RESTART, hold: false };
    } else {
      var line = LINES[state.step];
      if (line.cmd && state.chars < line.text.length) {
        state.chars++;
      } else {
        state.step++;
        state.chars = 0;
        state.wait = line.cmd ? WAIT_AFTER_CMD : WAIT_AFTER_OUTPUT;
      }
    }
    render();
  }

  // The static transcript stays under the animated copy, so screen readers read it once
  // instead of hearing every tick.
  function start() {
    if (timer || reducedMotion.matches || document.hidden) return;
    if (!screen) {
      screen = document.createElement('div');
      screen.setAttribute('aria-hidden', 'true');
      transcript.classList.add('terminal-underlay');
      transcript.parentNode.insertBefore(screen, transcript.nextSibling);
      state = { step: 0, chars: 0, wait: WAIT_START, hold: false };
      rows = [];
      render();
    }
    timer = setInterval(tick, TICK_MS);
  }

  function pause() {
    clearInterval(timer);
    timer = null;
  }

  function stop() {
    pause();
    if (!screen) return;
    screen.parentNode.removeChild(screen);
    screen = null;
    transcript.classList.remove('terminal-underlay');
  }

  reducedMotion.addEventListener('change', function () {
    if (reducedMotion.matches) stop();
    else start();
  });

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) pause();
    else start();
  });

  start();
})();
