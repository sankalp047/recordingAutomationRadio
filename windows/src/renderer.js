'use strict';

// ---------------------------------------------------------------- constants
const STATION_NAMES = {
  sangam: 'Radio Sangam',
  funasia: 'FunAsia',
  vanakkam: 'Vanakkam FM',
  apnapunjab: 'Apna Punjab',
};
const pretty = (id) => STATION_NAMES[id] || id;

const HEALTH = {
  complete:  { color: 'var(--ok)',     label: 'Recorded',       glyph: '✔' },
  partial:   { color: 'var(--warn)',   label: 'Partly recorded', glyph: '⚠' },
  mostly:    { color: 'var(--midbad)', label: 'Mostly missing',  glyph: '⚠' },
  missing:   { color: 'var(--bad)',    label: 'Not recorded',    glyph: '✖' },
  none:      { color: 'var(--none)',   label: 'Nothing yet',     glyph: '○' },
};
function healthFor(fraction, hasData = true) {
  if (fraction == null || !hasData) return HEALTH.none;
  if (fraction >= 0.95) return HEALTH.complete;
  if (fraction >= 0.5) return HEALTH.partial;
  if (fraction > 0) return HEALTH.mostly;
  return HEALTH.missing;
}

/** "6 AM" reads better than "06" for people who are not engineers. */
function hourLabel(h) {
  const x = h % 24;
  if (x === 0) return '12 AM';
  if (x === 12) return '12 PM';
  return x < 12 ? `${x} AM` : `${x - 12} PM`;
}
const fmtBytes = (n) => {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(n) / Math.log(1024));
  return `${(n / 1024 ** i).toFixed(i ? 1 : 0)} ${u[i]}`;
};
const fmtTime = (s) => {
  if (!isFinite(s) || s < 0) s = 0;
  return `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
};
const fmtDur = (s) => {
  const m = Math.floor(s / 60), r = Math.round(s % 60);
  return m ? `${m}m ${r}s` : `${r}s`;
};

/** Broadcast days are America/Chicago dates, matching the recorder. */
function chicagoToday() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Chicago' }).format(new Date());
}
function chicagoHour() {
  return parseInt(new Intl.DateTimeFormat('en-US',
    { timeZone: 'America/Chicago', hour: 'numeric', hour12: false }).format(new Date()), 10);
}
function friendlyDate(iso) {
  const today = chicagoToday();
  if (iso === today) return 'Today';
  const d = new Date(`${iso}T12:00:00Z`);
  const y = new Date(`${today}T12:00:00Z`);
  if (Math.round((y - d) / 86400000) === 1) return 'Yesterday';
  return d.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' });
}

// ---------------------------------------------------------------- state
const S = {
  api: 'https://radio-api.funasia.net',
  screen: 'find',
  station: null,
  date: chicagoToday(),
  stations: ['sangam', 'funasia', 'vanakkam', 'apnapunjab'],
  startHour: 6,
  endHour: 24,
  coverage: null,
  recordings: [],
  stats: null,
  historyDays: 14,
  signedIn: false,
  identity: null,
  loading: false,
};
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- api
async function get(pathname, query) {
  const r = await window.api.get(S.api, pathname, query);
  if (!r.ok && r.kind === 'signin') { S.signedIn = false; showSignIn(r.message); throw new Error('signin'); }
  if (!r.ok) throw new Error(r.message || 'Request failed');
  return r.data;
}

async function loadDay() {
  S.loading = true; render();
  try {
    const [cov, recs] = await Promise.all([
      get('/coverage', { date: S.date }),
      get('/recordings', { date: S.date }),
    ]);
    S.coverage = cov;
    S.recordings = recs.recordings || [];
    S.startHour = cov.window.start_hour;
    S.endHour = cov.window.end_hour;
    if (cov.stations?.length) S.stations = cov.stations.map((x) => x.station);
    if (!S.station || !S.stations.includes(S.station)) S.station = S.stations[0];
    hideBlocker();
  } catch (e) {
    if (e.message !== 'signin') showError(e.message);
  } finally { S.loading = false; render(); }
}

async function loadMe() {
  try {
    const me = await get('/me');
    S.signedIn = true;
    S.identity = me;
  } catch { S.signedIn = false; }
}

async function loadStats() {
  try { S.stats = await get('/stats', { days: S.historyDays }); render(); }
  catch (e) { if (e.message !== 'signin') showError(e.message); }
}

// ---------------------------------------------------------------- derived
const covFor = (st) => S.coverage?.stations?.find((x) => x.station === st) || null;
const coverageAt = (st, hour) => {
  const c = covFor(st);
  if (!c) return null;
  const g = c.gaps.find((x) => x.hour === hour);
  return g ? g.coverage : 1;
};
// Segments that BEGIN in this hour, not ones overlapping it. Duration comes
// from object size, so a full hour measures a fraction of a second over 3600
// and would also overlap the next hour - putting one recording in two rows,
// highlighting both as playing, and showing a neighbour's duration next to an
// hour's own "Not recorded". Coverage still uses real intervals, from the API.
function segmentsAt(st, hour) {
  return S.recordings
    .filter((r) => r.station === st && Number(r.start_local.slice(0, 2)) === hour)
    .sort((a, b) => a.start_local.localeCompare(b.start_local));
}
const recordingsFor = (st) => S.recordings.filter((r) => r.station === st)
  .sort((a, b) => a.start_local.localeCompare(b.start_local));

// ---------------------------------------------------------------- render
function render() {
  for (const el of document.querySelectorAll('.nav-item')) {
    el.classList.toggle('active', el.dataset.screen === S.screen);
  }
  for (const name of ['find', 'status', 'history']) {
    $(`screen-${name}`).classList.toggle('hidden', S.screen !== name);
  }
  renderAccount();
  if (S.screen === 'find') renderFind();
  if (S.screen === 'status') renderStatus();
  if (S.screen === 'history') renderHistory();
}

function renderAccount() {
  const el = $('account');
  if (S.signedIn && S.identity) {
    const who = S.identity.email || S.identity.name || 'signed in';
    el.innerHTML = '';
    const span = document.createElement('span');
    span.textContent = who;
    span.style.cssText = 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap';
    const out = document.createElement('button');
    out.className = 'ghost-btn';
    out.textContent = 'Sign out';
    out.onclick = async () => {
      await window.api.signOut(S.api);
      S.signedIn = false; S.identity = null;
      showSignIn('You have been signed out.');
    };
    el.append(span, out);
  } else {
    el.innerHTML = '';
    const b = document.createElement('button');
    b.className = 'primary-btn';
    b.textContent = 'Sign in';
    b.onclick = doSignIn;
    el.append(b);
  }
}

function renderFind() {
  $('dayLabel').textContent = friendlyDate(S.date);
  $('datePick').value = S.date;
  $('nextDay').disabled = S.date >= chicagoToday();
  $('todayBtn').style.display = S.date === chicagoToday() ? 'none' : '';

  const row = $('stationRow');
  row.innerHTML = '';
  for (const st of S.stations) {
    const b = document.createElement('button');
    b.className = 'chip' + (st === S.station ? ' active' : '');
    b.textContent = pretty(st);
    b.onclick = () => { S.station = st; render(); };
    row.append(b);
  }

  const list = $('hourList');
  list.innerHTML = '';
  $('saveDay').disabled = recordingsFor(S.station).length === 0;

  if (!S.coverage) {
    list.innerHTML = `<div class="empty">${S.loading ? 'Loading…' : 'Nothing to show.'}</div>`;
    return;
  }
  const isToday = S.date === chicagoToday();
  const nowHour = chicagoHour();
  let any = false;

  for (let h = S.startHour; h < S.endHour; h++) {
    const segs = segmentsAt(S.station, h);
    const future = isToday && h > nowHour;
    const frac = coverageAt(S.station, h);
    const hl = future ? HEALTH.none : healthFor(frac, segs.length > 0 || (frac ?? 0) > 0);
    if (segs.length) any = true;

    const row = document.createElement('div');
    row.className = 'hour-row';
    if (playing.id && segs.some((s) => s.id === playing.id)) row.classList.add('playing');

    const t = document.createElement('div');
    t.className = 'hour-time';
    t.textContent = hourLabel(h);

    const state = document.createElement('div');
    state.className = 'hour-state' + (hl === HEALTH.complete ? ' ok' : '');
    const dot = document.createElement('span');
    dot.className = 'dot';
    dot.style.background = hl.color;
    const lbl = document.createElement('span');
    lbl.textContent = future ? 'Not yet' : hl.label;
    state.append(dot, lbl);

    const note = document.createElement('div');
    note.className = 'hour-note';
    if (segs.length > 1) note.textContent = `saved in ${segs.length} pieces`;
    else if (segs[0]) note.textContent = fmtDur(segs[0].duration_seconds);

    const actions = document.createElement('div');
    actions.className = 'hour-actions';
    if (segs[0]) {
      const isPlaying = playing.id === segs[0].id;
      const play = document.createElement('button');
      play.className = 'primary-btn';
      play.textContent = isPlaying ? 'Playing' : 'Listen';
      play.disabled = isPlaying;
      play.onclick = () => startPlayback(segs[0]);

      const save = document.createElement('button');
      save.className = 'ghost-btn';
      save.textContent = 'Save';
      save.onclick = async () => {
        save.disabled = true;
        const r = await window.api.saveOne(segs[0].audio_url, suggestedName(segs[0]));
        save.disabled = false;
        if (!r.ok && !r.canceled) showError(r.message || 'Could not save.');
      };
      actions.append(play, save);
    }
    row.append(t, state, note, actions);
    list.append(row);
  }
  if (!any) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = isToday
      ? 'Recording runs from 6 AM to midnight. Hours appear here as they finish.'
      : `No audio was saved for ${pretty(S.station)} on ${friendlyDate(S.date)}.`;
    list.append(e);
  }
}

function renderStatus() {
  const c = S.coverage;
  const banner = $('statusBanner');
  banner.innerHTML = '';
  if (!c) return;

  const isToday = S.date === chicagoToday();
  const okHours = c.stations.reduce((a, s) => a + s.hours_ok, 0);
  const allHours = c.stations.reduce((a, s) => a + s.hours_total, 0);
  const hl = isToday ? HEALTH.none : healthFor(allHours ? okHours / allHours : 0);
  const bad = c.stations.filter((s) => !s.complete);

  let title, detail;
  if (isToday) {
    title = 'Recording is in progress';
    detail = `${okHours} complete ${okHours === 1 ? 'hour' : 'hours'} recorded so far today.`;
  } else if (c.complete) {
    title = 'Everything recorded';
    detail = `All ${c.stations.length} stations recorded every hour from 6 AM to midnight.`;
  } else {
    title = bad.length === 1 ? `${pretty(bad[0].station)} has gaps` : `${bad.length} stations have gaps`;
    const missing = allHours - okHours;
    detail = `${missing} ${missing === 1 ? 'hour is' : 'hours are'} missing or incomplete.`;
  }

  const box = document.createElement('div');
  box.className = 'banner';
  box.style.background = `color-mix(in srgb, ${hl.color} 12%, transparent)`;
  box.style.border = `1px solid color-mix(in srgb, ${hl.color} 35%, transparent)`;
  const g = document.createElement('div');
  g.className = 'glyph'; g.style.color = hl.color; g.textContent = isToday ? '⏱' : hl.glyph;
  const txt = document.createElement('div');
  const b = document.createElement('div'); b.className = 'big'; b.textContent = title;
  const d = document.createElement('div'); d.className = 'det'; d.textContent = detail;
  txt.append(b, d);
  box.append(g, txt);
  banner.append(box);

  const cards = $('stationCards');
  cards.innerHTML = '';
  for (const st of S.stations) {
    const sc = covFor(st);
    const card = document.createElement('div');
    card.className = 'card';
    const frac = sc && sc.hours_total ? sc.hours_ok / sc.hours_total : 0;
    const h = sc && sc.files === 0 ? (isToday ? HEALTH.none : HEALTH.missing) : healthFor(frac);

    const head = document.createElement('h3');
    head.append(document.createTextNode(pretty(st)));
    const mark = document.createElement('span');
    mark.style.color = h.color; mark.textContent = h.glyph;
    head.append(mark);

    const sub = document.createElement('div');
    sub.className = 'sub';
    sub.textContent = sc ? `${sc.hours_ok} of ${sc.hours_total} hours` : 'No information';

    const bar = document.createElement('div');
    bar.className = 'bar';
    const fill = document.createElement('span');
    fill.style.width = `${Math.round(frac * 100)}%`;
    fill.style.background = h.color;
    bar.append(fill);

    const gaps = document.createElement('div');
    gaps.className = 'gaps';
    if (sc && sc.gaps.length) {
      const hrs = sc.gaps.map((g2) => hourLabel(g2.hour));
      gaps.style.color = h.color;
      gaps.textContent = 'Missing: ' + (hrs.length <= 3
        ? hrs.join(', ') : `${hrs.slice(0, 3).join(', ')} +${hrs.length - 3} more`);
    } else if (sc) {
      gaps.style.color = 'var(--muted)';
      gaps.textContent = isToday ? 'No problems so far' : 'Complete';
    }

    card.append(head, sub, bar, gaps);
    card.style.cursor = 'pointer';
    card.onclick = () => { S.station = st; S.screen = 'find'; render(); };
    cards.append(card);
  }
}

function renderHistory() {
  const wrap = $('historyList');
  wrap.innerHTML = '';
  if (!S.stats) { wrap.innerHTML = '<div class="empty">Loading…</div>'; return; }

  for (const st of S.stats.stations) {
    const sm = st.summary;
    const h = healthFor(sm.reliability, sm.total_files > 0);
    const card = document.createElement('div');
    card.className = 'hist-card';

    const head = document.createElement('div');
    head.className = 'hist-head';
    const name = document.createElement('div');
    name.style.fontWeight = '600';
    name.textContent = pretty(st.station);
    const rel = document.createElement('div');
    rel.style.cssText = `color:${h.color};font-size:12px;font-weight:500`;
    rel.textContent = `${Math.round(sm.reliability * 100)}% of hours recorded`;
    head.append(name, rel);

    const bars = document.createElement('div');
    bars.className = 'hist-bars';
    for (const d of st.days) {
      const dh = healthFor(d.files > 0 ? d.hours_ok / d.hours_total : null, d.files > 0);
      const b = document.createElement('div');
      b.className = 'b';
      const i = document.createElement('i');
      const frac = d.files > 0 ? d.hours_ok / d.hours_total : 0.06;
      i.style.height = `${Math.max(4, 46 * frac)}px`;
      i.style.background = dh.color;
      const s = document.createElement('span');
      s.textContent = d.date.slice(-2);
      b.title = `${d.date}: ${d.files > 0 ? `${d.hours_ok}/${d.hours_total} hours` : 'nothing recorded'}`
        + (d.restarts ? `\n${d.restarts} restart${d.restarts === 1 ? '' : 's'}` : '');
      b.append(i, s);
      bars.append(b);
    }

    const metrics = document.createElement('div');
    metrics.className = 'metrics';
    const M = [
      ['Complete days', `${sm.days_complete} of ${sm.days_counted}`],
      ['Hours recorded', `${sm.total_hours_ok} of ${sm.total_hours_expected}`],
      ['Restarts', String(sm.total_restarts)],
      ['Stored', fmtBytes(sm.total_bytes)],
    ];
    for (const [k, v] of M) {
      const m = document.createElement('div');
      m.className = 'metric';
      const bb = document.createElement('b'); bb.textContent = k;
      const ii = document.createElement('i'); ii.textContent = v;
      if (k === 'Restarts' && sm.total_restarts > sm.days_counted * 2) ii.style.color = 'var(--midbad)';
      m.append(bb, ii);
      metrics.append(m);
    }

    card.append(head, bars, metrics);
    wrap.append(card);
  }
  const note = document.createElement('div');
  note.className = 'note';
  note.textContent = 'A restart means the recorder reconnected mid-hour and that hour was saved in several pieces. '
    + 'The audio is still complete — a few restarts a day is normal. Days before the recorder was set up show as empty, not as failures.';
  wrap.append(note);
}

// ---------------------------------------------------------------- blockers
function showSignIn(msg) {
  const b = $('blocker');
  b.innerHTML = '';
  const g = document.createElement('div'); g.className = 'glyph'; g.textContent = '\u{1F510}';
  const h = document.createElement('h2'); h.textContent = 'Sign in to continue';
  const p = document.createElement('p');
  p.textContent = msg || 'Use your funasia.net email. You will be sent a 6-digit code.';
  const btn = document.createElement('button');
  btn.className = 'primary-btn'; btn.textContent = 'Sign in';
  btn.onclick = doSignIn;
  b.append(g, h, p, btn);
  b.classList.remove('hidden');
}
function showError(msg) {
  const b = $('blocker');
  b.innerHTML = '';
  const g = document.createElement('div'); g.className = 'glyph'; g.textContent = '⚠';
  const h = document.createElement('h2'); h.textContent = 'Could not load';
  const p = document.createElement('p'); p.textContent = msg;
  const btn = document.createElement('button');
  btn.className = 'primary-btn'; btn.textContent = 'Try again';
  btn.onclick = () => { hideBlocker(); loadDay(); };
  b.append(g, h, p, btn);
  b.classList.remove('hidden');
}
const hideBlocker = () => $('blocker').classList.add('hidden');

async function doSignIn() {
  const r = await window.api.signIn(S.api);
  if (!r.ok) return;
  await loadMe();
  hideBlocker();
  await loadDay();
  if (S.screen === 'history') loadStats();
}

// ---------------------------------------------------------------- playback
const audio = $('audio');
const playing = { id: null, rec: null };

function startPlayback(rec) {
  playing.id = rec.id;
  playing.rec = rec;
  audio.src = rec.audio_url;       // the API supports Range, so seeking is cheap
  audio.play().catch(() => {});
  $('player').classList.remove('hidden');
  $('nowPlaying').innerHTML = '';
  const t = document.createElement('div'); t.textContent = pretty(rec.station);
  const s = document.createElement('small');
  s.textContent = `${hourLabel(parseInt(rec.start_local.slice(0, 2), 10))} · ${fmtDur(rec.duration_seconds)}`;
  $('nowPlaying').append(t, s);
  $('durTime').textContent = fmtTime(rec.duration_seconds);
  $('seek').max = rec.duration_seconds || 100;
  render();
}
audio.addEventListener('timeupdate', () => {
  $('curTime').textContent = fmtTime(audio.currentTime);
  $('seek').value = audio.currentTime;
});
audio.addEventListener('play', () => { $('playPause').innerHTML = '&#10073;&#10073;'; });
audio.addEventListener('pause', () => { $('playPause').innerHTML = '&#9654;'; });
$('playPause').onclick = () => (audio.paused ? audio.play() : audio.pause());
$('back15').onclick = () => { audio.currentTime = Math.max(0, audio.currentTime - 15); };
$('fwd15').onclick = () => { audio.currentTime = audio.currentTime + 15; };
$('seek').oninput = (e) => { audio.currentTime = Number(e.target.value); };
$('closePlayer').onclick = () => {
  audio.pause(); audio.removeAttribute('src'); audio.load();
  playing.id = null; playing.rec = null;
  $('player').classList.add('hidden');
  render();
};

// ---------------------------------------------------------------- misc
const suggestedName = (r) =>
  `${pretty(r.station)} ${r.date} ${hourLabel(parseInt(r.start_local.slice(0, 2), 10)).replace(' ', '')}.mp3`;

function shiftDay(n) {
  const d = new Date(`${S.date}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  const iso = d.toISOString().slice(0, 10);
  if (iso > chicagoToday()) return;
  S.date = iso;
  loadDay();
}

// ---------------------------------------------------------------- wiring
for (const el of document.querySelectorAll('.nav-item')) {
  el.onclick = () => {
    S.screen = el.dataset.screen;
    if (S.screen === 'history' && !S.stats) loadStats();
    render();
  };
}
$('prevDay').onclick = () => shiftDay(-1);
$('nextDay').onclick = () => shiftDay(1);
$('todayBtn').onclick = () => { S.date = chicagoToday(); loadDay(); };
$('datePick').onchange = (e) => { if (e.target.value) { S.date = e.target.value; loadDay(); } };
$('historyDays').onchange = (e) => { S.historyDays = Number(e.target.value); S.stats = null; loadStats(); };
$('saveDay').onclick = async () => {
  const recs = recordingsFor(S.station);
  if (!recs.length) return;
  const items = recs.map((r) => ({ url: r.audio_url, name: suggestedName(r) }));
  $('saveDay').disabled = true;
  const r = await window.api.saveMany(items, `${pretty(S.station)} ${S.date}`);
  $('saveDay').disabled = false;
  $('saveProgress').textContent = '';
  if (r.ok && r.failed) showError(`${r.failed} of ${items.length} could not be saved.`);
};
window.api.onSaveProgress(({ done, total }) => {
  $('saveProgress').textContent = done < total ? `Saving ${done + 1} of ${total}…` : '';
});

(async function boot() {
  const d = await window.api.defaults();
  S.api = d.api;
  $('datePick').value = S.date;
  await loadMe();
  if (S.signedIn) await loadDay();
  else showSignIn();
  render();
})();
