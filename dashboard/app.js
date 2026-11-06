(() => {
  'use strict';

  const DATA_KEY = 'project-status:last';
  const THEME_KEY = 'project-status:theme';
  const TOKEN_KEY = 'project-status:token';
  const NOTICE_MS = 7000;
  const MOBILE_QUERY = '(max-width: 719px)';
  const SPLIT_QUERY = '(min-width: 1280px)';
  const PANE_WIDTH = 520;
  const COPY_MS = 2600;
  const DAY_MS = 864e5;
  const DORMANT_MS = 14 * DAY_MS;
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  const ST = {
    working: { label: 'Working', icon: 'ph-spinner-gap', color: 'var(--work)' },
    input: { label: 'Needs input', icon: 'ph-chat-circle-dots', color: 'var(--warn)' },
    idle: { label: 'Idle', icon: 'ph-pause-circle', color: 'var(--faint)' },
    failed: { label: 'Failed', icon: 'ph-x-circle', color: 'var(--bad)' },
    done: { label: 'Done', icon: 'ph-check-circle', color: 'var(--ok)' },
    stopped: { label: 'Stopped', icon: 'ph-stop-circle', color: 'var(--faint)' },
  };
  const ORDER = ['input', 'failed', 'working', 'idle', 'done', 'stopped'];
  const OPEN = new Set(['working', 'input', 'idle']);

  const app = document.getElementById('app');
  const mobileQuery = matchMedia(MOBILE_QUERY);
  const splitQuery = matchMedia(SPLIT_QUERY);

  const state = {
    data: null,
    fetchFailed: false,
    nextTryAt: 0,
    renderedOffline: false,
    view: parseHash(),
    theme: document.documentElement.dataset.theme || 'dark',
    dormantOpen: false,
    copiedKey: null,
    toastCmd: null,
    openMenuKey: null,
    mobile: mobileQuery.matches,
    wide: splitQuery.matches,
    api: null,
    starting: null,
    notice: null,
    tokenAsk: null,
    tokenDraft: '',
    tokenError: '',
    confirmRemove: null,
    removing: null,
    paneFor: null,
  };
  let cmdMap = {};
  let copyTimer = 0;
  let noticeTimer = 0;
  let confirmTimer = 0;
  let fetchTimer = 0;

  const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const ts = v => (v ? new Date(v).getTime() || 0 : 0);
  const short = id => String(id || '').replace(/^session_/, '').slice(0, 8);
  const pad = n => String(n).padStart(2, '0');
  const hm = d => pad(d.getHours()) + ':' + pad(d.getMinutes());
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many);
  const interval = () => state.data?.intervalSeconds || 30;
  const host = () => state.data?.host || location.hostname || 'localhost';

  function parseHash() {
    const m = location.hash.match(/^#\/p\/([^/]+)(\/full)?$/);
    return { name: m ? decodeURIComponent(m[1]) : null, full: !!(m && m[2]) };
  }

  const canSplit = () => state.wide && !state.mobile;
  const listShown = v => !v.name || (canSplit() && !v.full);

  function span(ms) {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60);
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60);
    if (h < 24) return h + 'h';
    return Math.floor(h / 24) + 'd';
  }
  const ago = t => span(Date.now() - t) + ' ago';

  function dayLabel(d) {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const that = new Date(d);
    that.setHours(0, 0, 0, 0);
    const days = Math.round((today - that) / DAY_MS);
    if (days === 0) return 'Today';
    if (days === 1) return 'Yesterday';
    return MONTHS[d.getMonth()] + ' ' + d.getDate();
  }
  const when = v => { const d = new Date(v); return dayLabel(d) + ' ' + hm(d); };
  const dateOnly = v => { const d = new Date(v); const l = dayLabel(d); return l === 'Today' || l === 'Yesterday' ? l + ' ' + hm(d) : l; };
  const startedLabel = v => { if (!v) return '—'; const d = new Date(v); return dayLabel(d) === 'Today' ? hm(d) : when(v); };
  function sinceLabel(ymd) {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(ymd || '');
    return m ? MONTHS[Number(m[2]) - 1] + ' ' + Number(m[3]) : ymd || '';
  }

  function activity(s) {
    const started = ts(s.startedAt);
    switch (s.state) {
      case 'working': return started ? 'running ' + span(Date.now() - started) : 'running';
      case 'input': return s.waitingFor ? 'waiting for ' + s.waitingFor : 'waiting';
      case 'idle': return started ? 'open ' + span(Date.now() - started) : 'open';
      default: {
        const end = ts(s.lastActivityAt);
        if (!end || end === started) return 'ended';
        if (Date.now() - end < DAY_MS) return 'ended ' + ago(end);
        return 'ended ' + dateOnly(s.lastActivityAt).replace(/^Yesterday/, 'yesterday');
      }
    }
  }

  function shellPath(p) {
    if (/^[\w.\/~+-]+$/.test(p)) return p;
    const home = p.startsWith('~/');
    const body = (home ? p.slice(2) : p).replace(/["\\$`]/g, '\\$&');
    return home ? `"$HOME/${body}"` : `"${body}"`;
  }
  const sq = s => s.replace(/'/g, `'\\''`);
  const claude = () => shellPath(state.data?.claude || 'claude');
  const local = () => !location.hostname || /^(localhost|127\.\d+\.\d+\.\d+|\[::1\])$/.test(location.hostname);
  const onHost = cmd => (local() ? cmd : `ssh ${host()} -t '${sq(cmd)}'`);
  const rc = () => (state.data?.remoteControl === false ? '' : ' --remote-control');
  const cAttach = id => onHost(`${claude()} attach ${id}`);
  const cNew = p => onHost(`cd ${shellPath(p.path)} && ${claude()}${rc()}`);
  const cResume = (p, s) => onHost(`cd ${shellPath(s.dir || p.path)} && ${claude()} --resume ${s.id}${rc()}`);
  const sshApp = html => (local() ? '' : html);

  function copyJump(key, cmd, label, hint) {
    cmdMap[key] = cmd;
    return { type: 'copy', key, cmd, label, hint, caption: cmd };
  }

  function jumpFor(p, s, site) {
    if (!s) return copyJump('new:' + p.name, cNew(p), 'Jump in', 'new session');
    if (!s.isOpen) return copyJump('r:' + s.id, cResume(p, s), 'Resume', 'resume ' + short(s.id));
    if (s.url) {
      const sshKey = s.kind === 'background' ? 'ssh:' + s.id : null;
      const sshCmd = sshKey ? cAttach(s.id) : null;
      if (sshKey) cmdMap[sshKey] = sshCmd;
      return {
        type: 'link', key: site + ':' + s.id, url: s.url, sid: short(s.id),
        hint: 'in Claude · ' + short(s.id), caption: s.url.replace(/^https?:\/\//, ''),
        sshKey, sshCmd,
      };
    }
    if (s.kind === 'background') return copyJump(s.id, cAttach(s.id), 'Jump in', 'attach ' + short(s.id));
    return { type: 'none', key: 'none:' + s.id, hint: 'in a terminal', caption: 'Running in a terminal on ' + host() };
  }

  function derive(data) {
    const now = Date.now();
    const byOrder = (a, b) => ORDER.indexOf(a.state) - ORDER.indexOf(b.state);
    const projects = (data.projects || []).map(raw => {
      const sessions = (raw.sessions || []).map(s => {
        const st = ST[s.state] ? s.state : 'stopped';
        return { ...s, ...ST[st], state: st, isOpen: OPEN.has(st), attachable: !!s.url || s.kind === 'background' };
      });
      const open = sessions.filter(s => s.isOpen).sort(byOrder);
      const recent = sessions.filter(s => !s.isOpen).sort((a, b) => ts(b.lastActivityAt) - ts(a.lastActivityAt));
      const target = open.find(s => s.attachable) || null;
      const lastActivity = Math.max(0, ts(raw.updatedAt), ...sessions.map(s => ts(s.lastActivityAt)));
      const counts = ORDER
        .filter(k => OPEN.has(k) || k === 'failed')
        .map(k => ({ k, n: sessions.filter(s => s.state === k).length }))
        .filter(c => c.n)
        .map(c => ({ icon: ST[c.k].icon, color: ST[c.k].color, text: c.n + ' ' + ST[c.k].label.toLowerCase() }));
      return {
        ...raw,
        next: raw.next || [],
        blocked: raw.blocked || [],
        sessions, open, recent, target, counts, lastActivity,
        shownAt: ts(raw.updatedAt) || lastActivity,
        dormant: !open.length && now - lastActivity > DORMANT_MS,
      };
    });
    projects.sort((a, b) => b.lastActivity - a.lastActivity);

    const needs = [];
    projects.forEach(p => {
      p.sessions.forEach(s => {
        if (s.state === 'input' || s.state === 'failed') needs.push({ rank: ORDER.indexOf(s.state), kind: 'session', p, s });
      });
      p.blocked.forEach(b => needs.push({ rank: 2, kind: 'blocked', p, b }));
      if (p.stale) needs.push({ rank: 3, kind: 'stale', p });
    });
    needs.sort((a, b) => a.rank - b.rank);

    const working = projects.reduce((n, p) => n + p.sessions.filter(s => s.state === 'working').length, 0);
    return {
      projects,
      active: projects.filter(p => !p.dormant),
      dormant: projects.filter(p => p.dormant),
      needs,
      working,
    };
  }

  function needView(n, site) {
    if (n.kind === 'session') {
      const j = n.s.attachable ? jumpFor(n.p, n.s, site) : null;
      const time = activity(n.s);
      const meta = short(n.s.id) + (n.s.worktree ? ' · worktree ' + n.s.worktree.name : '');
      return { label: n.s.label, icon: n.s.icon, color: n.s.color, title: n.s.title || short(n.s.id), project: n.p.name, meta, time, shortTime: n.s.state === 'input' ? 'waiting' : time, jump: j };
    }
    if (n.kind === 'blocked') {
      const since = n.b.since ? 'since ' + sinceLabel(n.b.since) : 'blocked';
      const time = n.b.since ? since : '';
      return { label: 'Blocked', icon: 'ph-hourglass-medium', color: 'var(--warn)', title: n.b.text, project: n.p.name, meta: since, time, shortTime: time, jump: null };
    }
    return {
      label: 'Stale status', icon: 'ph-clock-counter-clockwise', color: 'var(--warn)',
      title: 'Code changed after the last status update', project: n.p.name,
      meta: 'updated ' + when(n.p.updatedAt).split(' ').slice(0, 2).join(' '), time: ago(ts(n.p.updatedAt)), shortTime: ago(ts(n.p.updatedAt)),
      jump: jumpFor(n.p, n.p.target, site),
    };
  }

  function copyButton(j, { style = '', label, secondary = false, extraClass = '', icon = 'ph-copy', iconStyle = '', suffix = '' } = {}) {
    const copied = state.copiedKey === j.key;
    const cls = copied ? 'btn btn-primary is-copied' : 'btn ' + (secondary ? 'btn-secondary' : 'btn-primary');
    const inner = copied
      ? `<i class="ph-bold ph-check"></i><span>Copied</span>`
      : `<i class="ph ${icon}"${iconStyle ? ` style="${iconStyle}"` : ''}></i><span>${esc(label ?? j.label)}</span>${suffix}`;
    return `<button class="${cls} ${extraClass}" data-act="copy" data-key="${esc(j.key)}" title="${esc(j.cmd)}" style="${style}">${inner}</button>`;
  }

  function menuHtml(j, width, { touch = false, up = false } = {}) {
    if (!j.sshCmd || state.openMenuKey !== j.key) return '';
    return `<div class="menu${up ? ' up' : ''}" style="width:${width}px"><button class="menu-item${touch ? ' touch' : ''}" data-act="ssh" data-key="${esc(j.sshKey)}"><i class="ph ph-terminal-window" style="font-size:16px;color:var(--muted)"></i><span style="font-size:13px;font-weight:500;color:var(--tx)">${local() ? 'Copy attach command' : 'Copy SSH command'}</span><span></span><code class="ellipsis" style="font-size:11px;color:var(--faint)">${esc(j.sshCmd)}</code></button></div>`;
  }

  function menuButton(j, size, iconSize, extraStyle = '') {
    if (!j.sshCmd) return '';
    const copied = state.copiedKey === j.sshKey;
    return `<button class="btn btn-secondary btn-icon" data-act="menu" data-key="${esc(j.key)}" title="More ways to jump in" aria-expanded="${state.openMenuKey === j.key}" style="width:${size}px;height:${size}px;color:${copied ? 'var(--ok)' : 'var(--muted)'};${extraStyle}"><i class="ph-bold ${copied ? 'ph-check' : 'ph-dots-three'}" style="font-size:${iconSize}px"></i></button>`;
  }

  function jumpCompact(j, { touch = false, copyMinWidth } = {}) {
    if (!j) return '';
    if (j.type === 'none') return `<span class="mono faint" style="font-size:11px;white-space:nowrap">${esc(j.hint)}</span>`;
    if (j.type === 'link') {
      const linkStyle = touch ? 'min-height:44px;min-width:78px;white-space:nowrap' : 'min-width:92px;white-space:nowrap';
      return `<div class="jgroup" data-jmenu><a class="btn btn-primary" href="${esc(j.url)}" target="_blank" rel="noopener" data-act="link" style="${linkStyle}"><i class="ph ph-arrow-square-out"></i>Open</a>${menuButton(j, touch ? 44 : 30, touch ? 18 : 15)}${menuHtml(j, touch ? 290 : 330, { touch })}</div>`;
    }
    const minW = copyMinWidth ?? (touch ? 92 : 104);
    return copyButton(j, { style: `${touch ? 'min-height:44px;' : ''}min-width:${minW}px;white-space:nowrap` });
  }

  function badges(p, lg = false) {
    const size = lg ? ' badge-lg' : '';
    let h = '';
    if (p.stale) h += `<span class="badge badge-warn${size}"><i class="ph-bold ph-clock-counter-clockwise"></i>Stale</span>`;
    if (!lg && p.blocked.length) h += `<span class="badge badge-warn"><i class="ph-bold ph-hourglass-medium"></i>${p.blocked.length} blocked</span>`;
    if (p.isNew) h += `<span class="badge badge-new${size}">New</span>`;
    return h;
  }

  function nowText(p) {
    if (p.now) return esc(p.now);
    if (!p.hasStatus) return '<span class="faint">No status file yet. It is created when a session starts here.</span>';
    return '<span class="faint">Nothing recorded.</span>';
  }

  const needsLabel = (m, offline) =>
    (m.needs.length ? plural(m.needs.length, 'item', 'items') : 'all clear') +
    (offline && state.data ? ' · as of ' + hm(new Date(state.data.generatedAt)) : '');
  const calmLine = m =>
    `${plural(m.working, 'session', 'sessions')} working on their own · nothing blocked or stale`;

  function refreshedLabel(compact) {
    const gen = ts(state.data?.generatedAt);
    if (!gen) return compact ? '—' : 'Waiting for data';
    return compact ? ago(gen) : `Refreshed ${ago(gen)} · every ${interval()}s`;
  }

  function minutesAgo(t) {
    const min = Math.round((Date.now() - t) / 60000);
    if (min < 1) return 'just now';
    if (min < 60) return min + ' min ago';
    return span(Date.now() - t) + ' ago';
  }

  function retryText(compact) {
    const left = Math.max(0, Math.ceil((state.nextTryAt - Date.now()) / 1000));
    const next = Math.floor(left / 60) + ':' + pad(left % 60);
    if (!state.data) return compact ? `No data yet. Retrying every ${interval()} s.` : `No data received yet. Retrying every ${interval()} s — next try in ${next}.`;
    const gen = new Date(state.data.generatedAt);
    if (compact) return `Showing data from ${hm(gen)} (${minutesAgo(gen.getTime())}). Retrying every ${interval()} s.`;
    return `Showing the last data received at ${hm(gen)}, ${minutesAgo(gen.getTime())}. Retrying every ${interval()} s — next try in ${next}.`;
  }

  function isOffline() {
    if (state.fetchFailed) return true;
    if (!state.data) return false;
    return Date.now() - ts(state.data.generatedAt) > 4 * interval() * 1000;
  }

  const themeIcon = () => (state.theme === 'dark' ? 'ph-sun' : 'ph-moon');

  function desktopHeader(offline) {
    const status = offline
      ? `<div style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--bad);font-weight:500"><i class="ph-bold ph-cloud-slash" style="font-size:14px"></i><span>Source unreachable${state.data ? ' · data from ' + hm(new Date(state.data.generatedAt)) : ''}</span></div>`
      : `<div style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--faint)"><i class="ph ph-arrows-clockwise" style="font-size:14px"></i><span data-tick="refreshed">${refreshedLabel(false)}</span></div>`;
    return `<header class="topbar desktop-header rule-b">
      <button class="unbutton" data-act="go" style="display:flex;align-items:center;gap:10px;margin-right:auto">
        <i class="ph-bold ph-terminal-window" style="font-size:20px;color:var(--accent)"></i>
        <span style="font-size:16px;font-weight:500;letter-spacing:-0.01em">Project Status</span>
        <span class="mono faint" style="font-size:12px">${esc(host())}</span>
      </button>
      ${status}
      <button class="btn btn-secondary btn-icon" data-act="theme" title="Light / dark" style="width:32px;height:32px"><i class="ph ${themeIcon()}" style="font-size:16px"></i></button>
    </header>`;
  }

  function desktopOfflineBanner() {
    return `<div style="display:flex;gap:12px;align-items:center;padding:12px 14px 12px 16px;border-radius:10px;background:var(--bad-tint);box-shadow:0 0 0 1px var(--bad-line);max-width:820px">
      <i class="ph-bold ph-cloud-slash" style="font-size:20px;color:var(--bad)"></i>
      <div style="display:flex;flex-direction:column;gap:2px;flex:1;min-width:0">
        <span style="font-size:14px;font-weight:500">Can't reach the status source on ${esc(host())}</span>
        <span class="muted" style="font-size:13px" data-tick="retry">${retryText(false)}</span>
      </div>
      <button class="btn btn-secondary" data-act="retry" style="white-space:nowrap"><i class="ph ph-arrows-clockwise"></i>Retry now</button>
    </div>`;
  }

  function desktopNeeds(m, offline) {
    let body;
    if (m.needs.length) {
      body = `<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:12px">${m.needs.map(n => {
        const v = needView(n, 'need');
        return `<div class="panel" style="display:flex;flex-direction:column;gap:8px;padding:14px 16px;border-radius:10px">
          <div style="display:flex;align-items:center;gap:6px;font-size:11px;letter-spacing:0.06em;text-transform:uppercase;font-weight:500;color:${v.color}">
            <i class="ph-bold ${v.icon}" style="font-size:14px"></i><span>${esc(v.label)}</span>
            <span style="margin-left:auto;text-transform:none;letter-spacing:0;font-weight:400;color:var(--faint)">${esc(v.time)}</span>
          </div>
          <div style="font-size:15px;font-weight:500;line-height:1.3;text-wrap:pretty">${esc(v.title)}</div>
          <div class="mono muted" style="display:flex;flex-wrap:wrap;gap:0 6px;font-size:12px"><span>${esc(v.project)}</span><span class="faint">·</span><span class="faint">${esc(v.meta)}</span></div>
          <div style="display:flex;gap:6px;margin-top:4px">
            ${v.jump && v.jump.type !== 'none' ? jumpCompact(v.jump) : ''}
            <button class="btn btn-secondary" data-act="go" data-name="${esc(v.project)}" style="white-space:nowrap">Details</button>
          </div>
        </div>`;
      }).join('')}</div>`;
    } else {
      body = `<div class="panel" style="display:flex;align-items:center;gap:12px;padding:16px 18px;border-radius:10px;max-width:820px">
        <i class="ph ph-check-circle" style="font-size:22px;color:var(--ok)"></i>
        <div style="display:flex;flex-direction:column;gap:1px"><span style="font-size:15px;font-weight:500">Nothing needs you right now.</span><span class="muted" style="font-size:13px">${esc(calmLine(m))}</span></div>
      </div>`;
    }
    return `<section style="display:flex;flex-direction:column;gap:12px">
      <div style="display:flex;align-items:baseline;gap:10px"><h2 class="h-section">Needs you</h2><span class="count">${esc(needsLabel(m, offline))}</span></div>
      ${body}
    </section>`;
  }

  function desktopProjectRow(p, selected) {
    if (selected !== undefined) {
      const on = p.name === selected;
      return `<div class="proj-grid compact rule-soft hov${on ? ' is-selected' : ''}" data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link"${on ? ' aria-current="page"' : ''} style="align-items:start;padding:14px 10px;border-radius:8px">
        <div style="display:flex;flex-direction:column;gap:4px;min-width:0">
          <span class="mono" style="font-size:14px;font-weight:500">${esc(p.name)}</span>
          <div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:2px">${badges(p)}</div>
        </div>
        <div class="clamp3" style="font-size:13px;line-height:1.5;text-wrap:pretty">${nowText(p)}</div>
      </div>`;
    }
    const j = jumpFor(p, p.target, 'row');
    const next2 = p.next.slice(0, 2).map((t, i) => `<div style="display:flex;gap:8px;min-width:0"><span class="mono faint" style="font-size:12px;padding-top:1px">${i + 1}</span><span class="ellipsis">${esc(t)}</span></div>`).join('');
    const more = p.next.length > 2 ? `<span class="faint" style="font-size:12px;padding-left:18px">+${p.next.length - 2} more</span>` : '';
    const counts = p.counts.length
      ? p.counts.map(c => `<span style="display:flex;align-items:center;gap:6px"><i class="ph-bold ${c.icon}" style="font-size:13px;color:${c.color}"></i>${esc(c.text)}</span>`).join('')
      : '<span class="faint">No sessions</span>';
    return `<div class="proj-grid rule-soft hov" data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link" style="align-items:start;padding:14px 10px;border-radius:8px">
      <div style="display:flex;flex-direction:column;gap:4px;min-width:0">
        <span class="mono" style="font-size:14px;font-weight:500">${esc(p.name)}</span>
        ${p.desc ? `<span class="faint" style="font-size:12px">${esc(p.desc)}</span>` : ''}
        <div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:2px">${badges(p)}</div>
      </div>
      <div class="clamp3" style="font-size:13px;line-height:1.5;text-wrap:pretty">${nowText(p)}</div>
      <div class="muted" style="display:flex;flex-direction:column;gap:3px;font-size:13px;min-width:0">${next2}${more}</div>
      <div class="muted" style="display:flex;flex-direction:column;gap:3px;font-size:12px">
        ${counts}
        <span class="faint" style="display:flex;align-items:center;gap:6px;margin-top:2px"><i class="ph ph-clock" style="font-size:13px"></i>${p.shownAt ? ago(p.shownAt) : '—'}</span>
      </div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">
        ${j.type === 'none' ? '' : jumpCompact(j)}
        <span class="mono faint" style="font-size:11px;white-space:nowrap">${esc(j.hint)}</span>
      </div>
    </div>`;
  }

  function desktopDormant(m, selected) {
    if (!m.dormant.length) return '';
    const rows = state.dormantOpen ? m.dormant.map(p => {
      if (selected !== undefined) {
        const on = p.name === selected;
        return `<div class="proj-grid compact hov muted${on ? ' is-selected' : ''}" data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link"${on ? ' aria-current="page"' : ''} style="align-items:center;padding:10px;border-radius:8px">
          <span class="mono" style="font-size:13px">${esc(p.name)}</span>
          <span class="faint ellipsis" style="font-size:13px">${esc(p.summary || p.desc)}</span>
        </div>`;
      }
      const j = jumpFor(p, null, 'dormant');
      const desc = [p.desc, p.summary].filter(Boolean).join(' — ');
      return `<div class="dormant-grid hov muted" data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link" style="padding:10px;border-radius:8px">
        <span class="mono" style="font-size:13px">${esc(p.name)}</span>
        <span class="faint" style="font-size:13px">${esc(desc)}</span>
        <span class="faint" style="font-size:12px">${p.shownAt ? esc(dateOnly(p.shownAt)) + ' · ' + ago(p.shownAt) : ''}</span>
        <div style="display:flex;justify-content:flex-end">${copyButton(j, { secondary: true, style: 'min-width:104px' })}</div>
      </div>`;
    }).join('') : '';
    return `<button class="btn btn-ghost" data-act="dormant" aria-expanded="${state.dormantOpen}" style="align-self:flex-start;margin-top:14px;color:var(--muted);padding:6px 8px;gap:8px"><i class="ph ${state.dormantOpen ? 'ph-caret-down' : 'ph-caret-right'}"></i><span>Dormant · ${m.dormant.length}</span><span class="faint" style="font-weight:400">no activity in 14+ days</span></button>${rows}`;
  }

  const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const LIMITS = [['fiveHour', '5-hour'], ['sevenDay', 'Weekly'], ['spendLimit', 'Spend limit']];

  function tokens(n) {
    if (!n) return '0';
    if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B';
    if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + 'M';
    if (n >= 1e3) return Math.round(n / 1e3) + 'k';
    return String(n);
  }

  const dollars = v => (v == null ? '—' : '$' + (v < 10 ? v.toFixed(2) : Math.round(v).toLocaleString()));

  function resetLabel(v) {
    const t = ts(v);
    if (!t) return '';
    const left = t - Date.now();
    if (left <= 0) return 'resetting';
    const d = new Date(t);
    return left < DAY_MS ? `resets in ${span(left)} · ${hm(d)}` : `resets ${WEEKDAYS[d.getDay()]} ${hm(d)}`;
  }

  function usageRows(m) {
    return m.projects
      .flatMap(p => p.sessions.filter(s => s.usage).map(s => {
        const t = s.usage.tokens || {};
        const input = (t.input || 0) + (t.cacheWrite || 0) + (t.cacheRead || 0);
        return { p, s, input, output: t.output || 0, cost: s.usage.costUsd ?? null };
      }))
      .sort((a, b) => (b.cost ?? -1) - (a.cost ?? -1) || b.input + b.output - (a.input + a.output));
  }

  function meter(key, label, w) {
    const pct = Math.max(0, Math.min(100, w.usedPercentage || 0));
    const color = pct >= 90 ? 'var(--bad)' : pct >= 75 ? 'var(--warn)' : 'var(--ok)';
    const spend = key === 'spendLimit' && w.limitUsd != null
      ? `<span class="muted" style="font-size:12px">${dollars(w.usedUsd)} of ${dollars(w.limitUsd)}${w.period ? ' · ' + esc(w.period) : ''}</span>` : '';
    return `<div class="panel" style="display:flex;flex-direction:column;gap:8px;padding:12px 14px;border-radius:12px;min-width:0">
      <div style="display:flex;align-items:baseline;gap:8px">
        <span class="h-label">${esc(label)}</span>
        <span style="margin-left:auto;font-size:20px;font-weight:500;font-variant-numeric:tabular-nums;color:${pct >= 75 ? color : 'var(--tx)'}">${Math.round(w.usedPercentage || 0)}%</span>
      </div>
      <div class="meter" role="meter" aria-label="${esc(label)} used" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(pct)}"><span style="width:${pct}%;background:${color}"></span></div>
      <span class="faint" style="font-size:12px">${esc(resetLabel(w.resetsAt))}</span>
      ${spend}
    </div>`;
  }

  function usageSection(m, mobile) {
    const limits = state.data?.limits || null;
    const windows = LIMITS.filter(([k]) => limits?.[k]);
    const asOf = limits?.updatedAt ? 'as of ' + hm(new Date(limits.updatedAt)) : '';
    const meters = windows.length
      ? `<div class="meter-grid">${windows.map(([k, label]) => meter(k, label, limits[k])).join('')}</div>`
      : `<div class="faint" style="font-size:13px;line-height:1.5;padding:${mobile ? '0 4px' : '0 10px'}">No plan limits recorded yet. They appear after an interactive session using the project-status status line gets a reply. API-key and gateway logins without a spend limit have none.</div>`;
    const rows = usageRows(m);
    const known = rows.filter(r => r.cost != null);
    const total = known.reduce((n, r) => n + r.cost, 0);
    const summary = rows.length
      ? plural(rows.length, 'session', 'sessions') + (known.length ? ` · ${dollars(total)}${known.length < rows.length ? ` (cost known for ${known.length})` : ''}` : '')
      : '';
    const title = r => esc(r.s.title || short(r.s.id));
    const list = !rows.length ? '' : mobile
      ? `<div style="display:flex;flex-direction:column;gap:6px">${rows.map(r => `<div class="panel" data-act="go" data-name="${esc(r.p.name)}" tabindex="0" role="link" style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:2px 12px;align-items:center;padding:10px 14px;border-radius:12px;cursor:pointer">
          <span class="ellipsis" style="font-size:14px;font-weight:500">${title(r)}</span>
          <span class="mono" style="font-size:13px;font-variant-numeric:tabular-nums">${dollars(r.cost)}</span>
          <span class="ellipsis muted" style="font-size:12px"><span class="mono">${esc(r.p.name)}</span> · ${tokens(r.input)} in · ${tokens(r.output)} out</span>
          <i class="ph-bold ${r.s.icon}" style="font-size:13px;color:${r.s.color};justify-self:end" title="${esc(r.s.label)}"></i>
        </div>`).join('')}</div>`
      : `<div>
          <div class="usage-grid rule-b" style="padding:6px 10px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:var(--faint)">
            <span>Session</span><span>Project</span><span style="text-align:right">Input</span><span style="text-align:right">Output</span><span style="text-align:right">Cost</span>
          </div>
          ${rows.map(r => `<div class="usage-grid rule-soft hov" data-act="go" data-name="${esc(r.p.name)}" tabindex="0" role="link" style="align-items:center;padding:10px;border-radius:8px;font-size:13px">
            <span style="display:flex;align-items:center;gap:8px;min-width:0"><i class="ph-bold ${r.s.icon}" style="font-size:13px;color:${r.s.color}" title="${esc(r.s.label)}"></i><span class="ellipsis">${title(r)}</span></span>
            <span class="mono muted ellipsis" style="font-size:12px">${esc(r.p.name)}</span>
            <span class="mono muted" style="text-align:right;font-variant-numeric:tabular-nums">${tokens(r.input)}</span>
            <span class="mono muted" style="text-align:right;font-variant-numeric:tabular-nums">${tokens(r.output)}</span>
            <span class="mono" style="text-align:right;font-variant-numeric:tabular-nums">${dollars(r.cost)}</span>
          </div>`).join('')}
        </div>`;
    return `<section style="display:flex;flex-direction:column;gap:${mobile ? 8 : 12}px">
      <div style="display:flex;align-items:baseline;gap:${mobile ? 8 : 10}px${mobile ? ';padding:0 4px' : ''}"><h2 class="h-section">Usage</h2><span class="count">${esc([asOf, summary].filter(Boolean).join(' · '))}</span></div>
      ${meters}
      ${list}
    </section>`;
  }

  function desktopOverview(m, offline, selected) {
    const compact = selected !== undefined;
    const heads = compact
      ? '<span>Project</span><span>Now</span>'
      : '<span>Project</span><span>Now</span><span>Next</span><span>Sessions</span><span style="text-align:right">Jump in</span>';
    return `<main style="display:flex;flex-direction:column;gap:32px;padding:24px 32px 72px;${compact ? 'min-width:0' : 'max-width:1240px'}">
      ${offline ? desktopOfflineBanner() : ''}
      ${desktopNeeds(m, offline)}
      <section style="display:flex;flex-direction:column">
        <div style="display:flex;align-items:baseline;gap:10px;margin-bottom:8px"><h2 class="h-section">Projects</h2><span class="count">${m.active.length} active</span></div>
        <div class="proj-grid${compact ? ' compact' : ''} rule-b" style="padding:6px 10px;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;color:var(--faint)">
          ${heads}
        </div>
        ${m.active.map(p => desktopProjectRow(p, selected)).join('')}
        ${desktopDormant(m, selected)}
      </section>
      ${usageSection(m, false)}
    </main>`;
  }

  function worktreeTag(s) {
    if (!s.worktree) return '';
    const b = s.worktree.branch;
    const label = b && b !== s.worktree.name && b !== 'worktree-' + s.worktree.name ? `${s.worktree.name} · ${b}` : s.worktree.name;
    return `<span class="badge-worktree" title="${esc(s.dir || '')}"><i class="ph-bold ph-git-branch"></i>${esc(label)}</span>`;
  }

  function removeButton(s, mobile) {
    if (!state.api || s.kind !== 'background') return '';
    const size = mobile ? 44 : 30;
    const busy = state.removing === s.id;
    const attrs = `data-act="remove" data-key="${esc(s.id)}"${state.removing ? ' disabled' : ''}`;
    if (state.confirmRemove === s.id && !busy) {
      return `<button class="btn btn-secondary" ${attrs} title="Stop the session and delete it and its worktree" style="height:${size}px;padding:0 10px;font-size:13px;white-space:nowrap;color:var(--bad);border-color:var(--bad-line)"><i class="ph-bold ph-trash"></i>Remove?</button>`;
    }
    return `<button class="btn btn-ghost btn-icon" ${attrs} title="Remove session" aria-label="Remove session" style="width:${size}px;height:${size}px;color:var(--faint)"><i class="ph${busy ? '-bold ph-circle-notch spin' : ' ph-trash'}" style="font-size:${mobile ? 18 : 15}px"></i></button>`;
  }

  function sessionRow(p, s, { mobile }) {
    const j = jumpFor(p, s, 'sess');
    const padding = mobile ? '10px 0' : '12px 0';
    const gap = mobile ? 10 : 12;
    const head = `<div style="display:flex;align-items:center;gap:6px;font-size:12px;color:${s.color}"><i class="ph-bold ${s.icon}" style="font-size:14px"></i><span style="font-weight:500">${esc(s.label)}</span><span class="faint">· ${esc(activity(s))}</span></div>`;
    const title = s.isOpen
      ? `<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap"><span style="font-size:14px;font-weight:500">${esc(s.title || short(s.id))}</span>${s.remote ? '<span class="badge-remote"><i class="ph-bold ph-broadcast"></i>Remote</span>' : ''}${worktreeTag(s)}</div>`
      : `<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap"><span class="muted" style="font-size:14px">${esc(s.title || short(s.id))}</span>${worktreeTag(s)}</div>`;
    const meta = `<div class="mono faint" style="font-size:12px">${esc(short(s.id))} · ${mobile ? '' : 'started '}${esc(startedLabel(s.startedAt))}</div>`;
    let action;
    if (!s.isOpen) {
      action = copyButton(j, { secondary: true, style: mobile ? 'min-height:44px;min-width:96px' : 'min-width:104px' });
    } else {
      action = jumpCompact(j, { touch: mobile, copyMinWidth: mobile ? 96 : 104 });
    }
    const remove = removeButton(s, mobile);
    if (remove) action = `<div style="display:flex;align-items:center;gap:4px">${action}${remove}</div>`;
    return `<div class="rule-soft" style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:${gap}px;align-items:center;padding:${padding}">
      <div style="display:flex;flex-direction:column;gap:${mobile ? 1 : 2}px;min-width:0">${head}${title}${meta}</div>
      ${action}
    </div>`;
  }

  function staleCallout(p, mobile) {
    if (!p.stale) return '';
    if (mobile) {
      return `<div style="display:flex;gap:10px;align-items:flex-start;padding:12px;border-radius:10px;background:var(--warn-tint)">
        <i class="ph-bold ph-clock-counter-clockwise" style="font-size:18px;color:var(--warn);margin-top:1px"></i>
        <div style="font-size:14px;line-height:1.45"><span style="font-weight:500">May be out of date.</span> <span class="muted">Code changed after this was written. Jump in and ask Claude to refresh it.</span></div>
      </div>`;
    }
    return `<div style="display:flex;gap:10px;align-items:flex-start;padding:12px 14px;border-radius:10px;background:var(--warn-tint);max-width:820px">
      <i class="ph-bold ph-clock-counter-clockwise" style="font-size:18px;color:var(--warn);margin-top:1px"></i>
      <div style="font-size:14px;line-height:1.5"><span style="font-weight:500">This status may be out of date.</span> <span class="muted">Code changed after it was last written (${esc(when(p.updatedAt))}). Jump in and ask Claude to refresh the status file.</span></div>
    </div>`;
  }

  function blockedRows(p, radius) {
    return p.blocked.map(b => `<div style="display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border-radius:${radius}px;background:var(--warn-tint)">
      <i class="ph-bold ph-hourglass-medium" style="color:var(--warn);font-size:16px;margin-top:2px"></i>
      <div style="display:flex;flex-direction:column"><span style="font-size:14px;font-weight:500">${esc(b.text)}</span>${b.since ? `<span class="muted" style="font-size:12px">Since ${esc(sinceLabel(b.since))}</span>` : ''}</div>
    </div>`).join('');
  }

  function startButton(p, idx, mobile) {
    if (!state.api) return '';
    const key = `start:${p.name}:${idx}`;
    const isNew = idx === 'new';
    const icon = state.starting === key ? 'ph-circle-notch spin' : isNew ? 'ph-plus' : 'ph-play';
    const label = isNew ? 'New session' : 'Start';
    const title = isNew ? 'Start a new Claude session in this repo' : 'Start a Claude session with this as the prompt';
    const attrs = `data-act="start" data-key="${esc(key)}" data-name="${esc(p.name)}" data-idx="${idx}" title="${esc(title)}"${state.starting ? ' disabled' : ''}`;
    if (mobile && !isNew) {
      return `<button class="btn btn-ghost btn-icon" ${attrs} aria-label="${esc(label)}" style="width:40px;height:40px;margin:-8px -8px -8px 0;flex:none"><i class="ph-bold ${icon}" style="font-size:16px"></i></button>`;
    }
    const size = mobile ? 'min-height:40px;margin-right:-8px' : '';
    return `<button class="btn btn-ghost" ${attrs} style="padding:2px 8px;font-size:13px;white-space:nowrap;flex:none;${size}"><i class="ph-bold ${icon}"></i>${label}</button>`;
  }

  function nextRows(p, mobile = false) {
    if (!p.next.length) return '<span class="faint" style="font-size:14px">Nothing queued.</span>';
    return p.next.map((t, i) => `<div class="rule-soft" style="display:flex;gap:12px;align-items:flex-start;padding:8px 0;font-size:14px"><span class="mono faint" style="font-size:12px;padding-top:2px;width:14px;flex:none">${i + 1}</span><span style="flex:1;min-width:0">${esc(t)}</span>${startButton(p, i, mobile)}</div>`).join('');
  }

  function sessionsHeading(p, mobile) {
    const label = `<h2 class="h-label"${mobile ? ' style="margin-bottom:4px"' : ''}>Sessions</h2>`;
    if (!state.api) return label;
    return `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px${mobile ? ';margin-bottom:4px' : ''}">${label.replace(' style="margin-bottom:4px"', '')}${startButton(p, 'new', mobile)}</div>`;
  }

  function startPanel() {
    const place = state.mobile
      ? 'position:fixed;left:12px;right:12px;top:calc(64px + env(safe-area-inset-top, 0px));z-index:7;border-radius:14px;padding:12px 14px'
      : 'position:fixed;right:32px;top:72px;z-index:7;width:380px;border-radius:12px;padding:14px 16px';
    if (state.tokenAsk) {
      return `<form class="toast" data-act="token-form" style="${place};flex-direction:column;align-items:stretch;gap:10px">
        <div style="display:flex;flex-direction:column;gap:2px">
          <span style="font-size:14px;font-weight:500">Enter the dashboard token</span>
          <span class="muted" style="font-size:13px">Run <code>make token</code> on ${esc(host())}. This browser remembers it.</span>
          ${state.tokenError ? `<span style="font-size:13px;color:var(--bad)">${esc(state.tokenError)}</span>` : ''}
        </div>
        <input data-act="token-input" type="password" autocomplete="off" spellcheck="false" value="${esc(state.tokenDraft)}" style="font:inherit;font-family:var(--mono);font-size:13px;color:var(--tx);background:var(--bg);border:0;border-radius:8px;box-shadow:0 0 0 1px var(--line);padding:8px 10px;min-height:${state.mobile ? 44 : 34}px">
        <div style="display:flex;gap:8px;justify-content:flex-end">
          <button type="button" class="btn btn-secondary" data-act="token-cancel" style="min-height:${state.mobile ? 44 : 32}px">Cancel</button>
          <button type="submit" class="btn btn-primary" style="min-height:${state.mobile ? 44 : 32}px">${state.tokenAsk.remove ? '<i class="ph-bold ph-trash"></i>Remove' : '<i class="ph-bold ph-play"></i>Start'}</button>
        </div>
      </form>`;
    }
    const n = state.notice;
    if (!n) return '';
    const ok = n.kind === 'ok';
    return `<div class="toast" role="status" style="${place};gap:12px;align-items:flex-start">
      <i class="${ok ? 'ph-fill ph-check-circle' : 'ph-fill ph-warning-circle'}" style="font-size:22px;color:${ok ? 'var(--ok)' : 'var(--bad)'}"></i>
      <div style="display:flex;flex-direction:column;gap:2px;min-width:0;flex:1">
        <span style="font-size:14px;font-weight:500">${esc(n.title)}</span>
        <span class="muted" style="font-size:13px;overflow-wrap:anywhere">${esc(n.detail)}</span>
      </div>
      <button class="btn btn-ghost btn-icon" data-act="notice-close" title="Dismiss" style="width:28px;height:28px;color:var(--muted);flex:none"><i class="ph ph-x"></i></button>
    </div>`;
  }

  function detailAction(p, j) {
    if (j.type === 'link') {
      return `<div class="jgroup" data-jmenu style="gap:6px">
        <a class="btn btn-primary" href="${esc(j.url)}" target="_blank" rel="noopener" data-act="link" style="min-height:38px;font-size:15px;white-space:nowrap"><i class="ph ph-arrow-square-out"></i>Open in Claude</a>
        ${menuButton(j, 38, 17)}${menuHtml(j, 340)}
      </div>`;
    }
    return copyButton(j, { label: 'Jump in', style: 'min-width:132px;min-height:38px;font-size:15px' });
  }

  function detailSessions(p) {
    const sessions = [];
    if (p.open.length) {
      sessions.push(`<div style="display:flex;flex-direction:column"><span class="muted" style="font-size:12px;font-weight:500">Open · ${p.open.length}</span>${p.open.map(s => sessionRow(p, s, { mobile: false })).join('')}</div>`);
    } else if (p.recent.length) {
      sessions.push('<span class="faint" style="font-size:13px">No open sessions. Jump in starts a new one in this repo.</span>');
    }
    if (p.recent.length) {
      sessions.push(`<div style="display:flex;flex-direction:column"><span class="muted" style="font-size:12px;font-weight:500">Recent</span>${p.recent.map(s => sessionRow(p, s, { mobile: false })).join('')}</div>`);
    }
    if (!p.sessions.length) {
      const nj = jumpFor(p, null, 'empty');
      sessions.push(`<div style="display:flex;flex-direction:column;gap:10px">
        <div style="display:flex;gap:10px;align-items:center;font-size:14px"><i class="ph ph-terminal" style="font-size:18px;color:var(--faint)"></i>No sessions in this repo yet.</div>
        <div class="muted" style="font-size:13px">Jump in copies a command that starts Claude in ${esc(p.path)}.</div>
        <div style="display:flex;align-items:center;gap:8px;padding:6px 6px 6px 12px;border-radius:8px;background:var(--bg);box-shadow:0 0 0 1px var(--line)">
          <code class="ellipsis muted" style="flex:1;min-width:0;font-size:12px">${esc(nj.cmd)}</code>
          ${copyButton(nj, { label: 'Copy', style: 'min-width:96px' })}
        </div>
      </div>`);
    }
    return `<aside class="panel" style="display:flex;flex-direction:column;gap:18px;padding:16px 20px 18px;border-radius:12px">
      ${sessionsHeading(p, false)}
      ${sessions.join('')}
    </aside>`;
  }

  function detailStatus(p) {
    return `<section style="display:flex;flex-direction:column;gap:8px">
        <h2 class="h-label">Now</h2>
        <p style="font-size:17px;line-height:1.5;margin:0;text-wrap:pretty;max-width:62ch">${nowText(p)}</p>
      </section>
      <section style="display:flex;flex-direction:column;gap:8px">
        <h2 class="h-label">Blocked</h2>
        ${p.blocked.length ? blockedRows(p, 8) : '<span class="faint" style="font-size:14px">Nothing blocked.</span>'}
      </section>
      <section style="display:flex;flex-direction:column;gap:4px">
        <h2 class="h-label" style="margin-bottom:4px">Next</h2>
        ${nextRows(p)}
      </section>`;
  }

  function detailUpdated(p) {
    return `<section style="display:flex;flex-direction:column;gap:6px">
        <h2 class="h-label">Last updated</h2>
        ${p.updatedAt
          ? `<div style="font-size:14px"><span style="font-weight:500">${esc(when(p.updatedAt))}</span> <span class="faint">· ${ago(ts(p.updatedAt))}</span></div>${p.summary ? `<div class="muted" style="font-size:14px">${esc(p.summary)}</div>` : ''}`
          : '<div class="faint" style="font-size:14px">No status file yet.</div>'}
      </section>`;
  }

  function desktopPane(p) {
    const j = jumpFor(p, p.target, 'head');
    return `<aside class="pane" aria-label="${esc(p.name)} details" style="width:${PANE_WIDTH}px">
      <div style="display:flex;flex-direction:column;gap:24px;padding:20px 24px 48px">
        <div style="display:flex;flex-direction:column;gap:6px">
          <div style="display:flex;align-items:flex-start;gap:8px">
            <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;flex:1;min-width:0">
              <h1 class="mono" style="font-size:22px;margin:0;letter-spacing:-0.02em;overflow-wrap:anywhere">${esc(p.name)}</h1>
              ${badges(p, true)}
            </div>
            <button class="btn btn-ghost btn-icon" data-act="go" data-name="${esc(p.name)}" data-full="1" title="Expand to full page" aria-label="Expand to full page" style="width:32px;height:32px;color:var(--muted);flex:none"><i class="ph ph-arrows-out-simple" style="font-size:16px"></i></button>
            <button class="btn btn-ghost btn-icon" data-act="go" title="Close (Esc)" aria-label="Close details" style="width:32px;height:32px;color:var(--muted);flex:none"><i class="ph ph-x" style="font-size:16px"></i></button>
          </div>
          <div class="muted" style="font-size:14px">${esc(p.desc)} <span class="mono faint" style="font-size:12px">${p.desc ? '· ' : ''}${esc(p.path)}</span></div>
        </div>
        <div style="display:flex;flex-direction:column;align-items:flex-start;gap:6px">
          ${detailAction(p, j)}
          <code class="faint" style="font-size:11px;overflow-wrap:anywhere">${esc(j.caption)}</code>
        </div>
        ${staleCallout(p, false)}
        ${detailStatus(p)}
        ${detailSessions(p)}
        ${detailUpdated(p)}
      </div>
    </aside>`;
  }

  function desktopDetail(p) {
    const j = jumpFor(p, p.target, 'head');
    const collapse = canSplit()
      ? `<button class="btn btn-ghost" data-act="go" data-name="${esc(p.name)}" style="color:var(--muted);padding:4px 8px 4px 6px"><i class="ph ph-arrows-in-simple"></i>Collapse to side</button>`
      : '';
    return `<main style="display:flex;flex-direction:column;gap:24px;padding:16px 32px 72px;max-width:1240px">
      <div style="display:flex;align-items:center;gap:8px">
        <button class="btn btn-ghost" data-act="go" style="color:var(--muted);padding:4px 8px 4px 4px"><i class="ph ph-arrow-left"></i>All projects</button>
        ${collapse}
      </div>
      <div style="display:flex;align-items:flex-start;gap:24px">
        <div style="display:flex;flex-direction:column;gap:6px;flex:1;min-width:0">
          <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
            <h1 class="mono" style="font-size:28px;margin:0;letter-spacing:-0.02em">${esc(p.name)}</h1>
            ${badges(p, true)}
          </div>
          <div class="muted" style="font-size:14px">${esc(p.desc)} <span class="mono faint" style="font-size:12px">${p.desc ? '· ' : ''}${esc(p.path)}</span></div>
        </div>
        <div style="display:flex;flex-direction:column;align-items:flex-end;gap:6px">
          ${detailAction(p, j)}
          <code class="faint" style="font-size:11px">${esc(j.caption)}</code>
        </div>
      </div>
      ${staleCallout(p, false)}
      <div style="display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr);gap:40px;align-items:start">
        <div style="display:flex;flex-direction:column;gap:28px">
          ${detailStatus(p)}
          ${detailUpdated(p)}
        </div>
        ${detailSessions(p)}
      </div>
    </main>`;
  }

  function desktopToast() {
    if (!state.toastCmd) return '';
    return `<div class="toast toast-desktop" role="status">
      <i class="ph-fill ph-check-circle" style="font-size:22px;color:var(--ok)"></i>
      <div style="display:flex;flex-direction:column;gap:1px;min-width:0">
        <span style="font-size:14px;font-weight:500">Copied — paste into your terminal</span>
        <code class="ellipsis muted" style="font-size:12px">${esc(state.toastCmd)}</code>
      </div>
    </div>`;
  }

  function mobileHeader(p, offline) {
    const left = p
      ? `<button class="btn btn-ghost btn-icon" data-act="go" title="All projects" style="width:44px;height:44px;margin-left:-12px;color:var(--tx)"><i class="ph ph-arrow-left" style="font-size:20px"></i></button>`
      : '';
    const title = p
      ? `<span class="mono ellipsis" style="font-size:17px;font-weight:500">${esc(p.name)}</span>`
      : `<i class="ph-bold ph-terminal-window" style="font-size:20px;color:var(--accent)"></i><span style="font-size:16px;font-weight:500">Project Status</span>`;
    const status = offline
      ? `<span style="display:flex;align-items:center;gap:4px;font-size:12px;color:var(--bad);font-weight:500"><i class="ph-bold ph-cloud-slash"></i>Offline</span>`
      : `<span class="faint" style="display:flex;align-items:center;gap:4px;font-size:12px"><i class="ph ph-arrows-clockwise"></i><span data-tick="refreshed-compact">${refreshedLabel(true)}</span></span>`;
    return `<header class="topbar mobile-header rule-b">
      ${left}
      <div style="display:flex;align-items:center;gap:8px;margin-right:auto;min-width:0">${title}</div>
      ${status}
      <button class="btn btn-ghost btn-icon" data-act="theme" title="Light / dark" style="width:44px;height:44px;color:var(--muted)"><i class="ph ${themeIcon()}" style="font-size:18px"></i></button>
    </header>`;
  }

  function mobileOverview(m, offline) {
    const banner = offline ? `<div style="display:flex;flex-direction:column;gap:10px;padding:12px 14px;border-radius:12px;background:var(--bad-tint);box-shadow:0 0 0 1px var(--bad-line)">
      <div style="display:flex;gap:10px;align-items:flex-start">
        <i class="ph-bold ph-cloud-slash" style="font-size:20px;color:var(--bad);margin-top:1px"></i>
        <div style="display:flex;flex-direction:column;gap:2px"><span style="font-size:14px;font-weight:500">Can't reach ${esc(host())}</span><span class="muted" style="font-size:13px" data-tick="retry-compact">${retryText(true)}</span></div>
      </div>
      <button class="btn btn-secondary" data-act="retry" style="min-height:44px"><i class="ph ph-arrows-clockwise"></i>Retry now</button>
    </div>` : '';

    const needs = m.needs.length
      ? `<div style="display:flex;flex-direction:column;gap:6px">${m.needs.map(n => {
        const v = needView(n, 'need');
        const action = v.jump && v.jump.type !== 'none'
          ? jumpCompact(v.jump, { touch: true })
          : `<button class="btn btn-secondary" data-act="go" data-name="${esc(v.project)}" style="min-height:44px;min-width:92px">View<i class="ph ph-caret-right"></i></button>`;
        return `<div class="panel" style="display:grid;grid-template-columns:20px minmax(0,1fr) auto;gap:10px;align-items:center;padding:10px 10px 10px 14px;border-radius:12px">
          <i class="ph-bold ${v.icon}" style="font-size:18px;color:${v.color}"></i>
          <div data-act="go" data-name="${esc(v.project)}" style="display:flex;flex-direction:column;gap:1px;min-width:0;cursor:pointer">
            <span style="font-size:11px;letter-spacing:0.05em;text-transform:uppercase;font-weight:500;color:${v.color}">${esc(v.label)}${v.shortTime ? ` <span class="faint" style="text-transform:none;letter-spacing:0;font-weight:400">· ${esc(v.shortTime)}</span>` : ''}</span>
            <span style="font-size:14px;font-weight:500;line-height:1.3">${esc(v.title)}</span>
            <span class="mono muted" style="font-size:12px">${esc(v.project)}</span>
          </div>
          ${action}
        </div>`;
      }).join('')}</div>`
      : `<div class="panel" style="display:flex;align-items:center;gap:12px;padding:14px;border-radius:12px">
          <i class="ph ph-check-circle" style="font-size:24px;color:var(--ok)"></i>
          <div style="display:flex;flex-direction:column;gap:1px"><span style="font-size:15px;font-weight:500">Nothing needs you.</span><span class="muted" style="font-size:13px">${esc(calmLine(m))}</span></div>
        </div>`;

    const cards = m.active.map(p => {
      const j = jumpFor(p, p.target, 'row');
      const next2 = p.next.slice(0, 2).map((t, i) => `<div style="display:flex;gap:8px;min-width:0"><span class="mono faint" style="font-size:12px;padding-top:1px">${i + 1}</span><span class="ellipsis">${esc(t)}</span></div>`).join('');
      const counts = p.counts.length
        ? p.counts.map(c => `<span style="display:inline-flex;align-items:center;gap:5px"><i class="ph-bold ${c.icon}" style="font-size:13px;color:${c.color}"></i>${esc(c.text)}</span>`).join('')
        : '<span class="faint">No sessions</span>';
      return `<div class="panel" data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link" style="display:flex;flex-direction:column;gap:8px;padding:12px 12px 12px 14px;border-radius:12px;cursor:pointer">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
          <span class="mono" style="font-size:15px;font-weight:500">${esc(p.name)}</span>
          ${badges(p)}
          <span class="faint" style="margin-left:auto;font-size:12px">${p.shownAt ? ago(p.shownAt) : ''}</span>
        </div>
        <div style="font-size:14px;line-height:1.45;text-wrap:pretty">${nowText(p)}</div>
        ${next2 ? `<div class="muted" style="display:flex;flex-direction:column;gap:2px;font-size:13px;min-width:0">${next2}</div>` : ''}
        <div style="display:flex;align-items:center;gap:10px;margin-top:2px">
          <div class="muted" style="display:flex;flex-wrap:wrap;gap:4px 12px;font-size:12px;flex:1;min-width:0">${counts}</div>
          ${j.type === 'none' ? `<span class="mono faint" style="font-size:11px">${esc(j.hint)}</span>` : jumpCompact(j, { touch: true, copyMinWidth: 100 })}
        </div>
      </div>`;
    }).join('');

    let dormant = '';
    if (m.dormant.length) {
      dormant = `<button class="btn btn-ghost" data-act="dormant" aria-expanded="${state.dormantOpen}" style="justify-content:flex-start;min-height:44px;color:var(--muted);gap:8px;padding:6px 6px"><i class="ph ${state.dormantOpen ? 'ph-caret-down' : 'ph-caret-right'}"></i><span>Dormant · ${m.dormant.length}</span><span class="faint" style="font-weight:400;font-size:13px">quiet 14+ days</span></button>`;
      if (state.dormantOpen) {
        dormant += m.dormant.map(p => {
          const j = jumpFor(p, null, 'dormant');
          return `<div data-act="go" data-name="${esc(p.name)}" tabindex="0" role="link" style="display:flex;align-items:center;gap:10px;padding:8px 8px 8px 14px;border-radius:12px;box-shadow:0 0 0 1px var(--line);cursor:pointer">
            <div style="display:flex;flex-direction:column;flex:1;min-width:0"><span class="mono muted" style="font-size:14px">${esc(p.name)}</span><span class="faint" style="font-size:12px">${esc([p.desc, p.shownAt ? ago(p.shownAt) : ''].filter(Boolean).join(' · '))}</span></div>
            ${copyButton(j, { secondary: true, style: 'min-height:44px;min-width:100px' })}
          </div>`;
        }).join('');
      }
    }

    return `<main style="display:flex;flex-direction:column;gap:24px;padding:14px 12px 32px">
      ${banner}
      <section style="display:flex;flex-direction:column;gap:8px">
        <div style="display:flex;align-items:baseline;gap:8px;padding:0 4px"><h2 class="h-section">Needs you</h2><span class="count">${esc(needsLabel(m, offline))}</span></div>
        ${needs}
      </section>
      <section style="display:flex;flex-direction:column;gap:8px">
        <div style="display:flex;align-items:baseline;gap:8px;padding:0 4px"><h2 class="h-section">Projects</h2><span class="count">${m.active.length} active</span></div>
        ${cards}
        ${dormant}
      </section>
      ${usageSection(m, true)}
    </main>
    ${state.toastCmd ? `<div class="toast toast-mobile" role="status">
      <div style="display:flex;align-items:center;gap:10px">
        <i class="ph-fill ph-check-circle" style="font-size:22px;color:var(--ok)"></i>
        <div style="display:flex;flex-direction:column;min-width:0"><span style="font-size:14px;font-weight:500">Copied — paste into your terminal</span><code class="ellipsis muted" style="font-size:11px">${esc(state.toastCmd)}</code></div>
      </div>
      ${sshApp(`<a href="ssh://${esc(host())}" class="btn btn-secondary" data-act="link" style="min-height:44px"><i class="ph ph-arrow-square-out"></i>Open in SSH app</a>`)}
    </div>` : ''}`;
  }

  function mobileDetail(p) {
    const j = jumpFor(p, p.target, 'bar');
    const sessions = [
      ...p.open.map(s => sessionRow(p, s, { mobile: true })),
      ...p.recent.map(s => sessionRow(p, s, { mobile: true })),
    ].join('') || `<div style="display:flex;flex-direction:column;gap:4px;padding:12px;border-radius:10px;box-shadow:0 0 0 1px var(--line)">
      <div style="display:flex;gap:8px;align-items:center;font-size:14px;font-weight:500"><i class="ph ph-terminal" style="font-size:18px;color:var(--faint)"></i>No sessions yet</div>
      <span class="muted" style="font-size:13px">Jump in below copies a command that starts Claude in this repo.</span>
    </div>`;

    const barCopied = j.type === 'copy' && state.copiedKey === j.key;
    let bar;
    if (j.type === 'link') {
      bar = `<div class="jgroup" data-jmenu style="gap:8px">
        <a class="btn btn-primary on-bg" href="${esc(j.url)}" target="_blank" rel="noopener" data-act="link" style="flex:1;min-height:50px;font-size:15px"><i class="ph ph-arrow-square-out" style="font-size:17px"></i>Open in Claude<span class="mono faint" style="font-size:12px;font-weight:400">· ${esc(j.sid)}</span></a>
        ${menuButton(j, 50, 18, 'background:var(--bg)')}${menuHtml(j, 300, { touch: true, up: true })}
      </div>`;
    } else if (barCopied) {
      bar = `<div style="display:flex;flex-direction:column;gap:8px">
        <div style="display:grid;grid-template-columns:${local() ? '1fr' : '1fr 1fr'};gap:8px">
          ${copyButton(j, { style: 'min-height:50px;font-size:15px' })}
          ${sshApp(`<a href="ssh://${esc(host())}" class="btn btn-secondary on-bg" data-act="link" style="min-height:50px;font-size:15px"><i class="ph ph-arrow-square-out"></i>Open SSH app</a>`)}
        </div>
        <code class="ellipsis muted" style="font-size:11px;text-align:center">${esc(j.cmd)}</code>
      </div>`;
    } else {
      bar = copyButton(j, {
        label: 'Jump in', extraClass: 'on-bg', style: 'width:100%;min-height:50px;font-size:15px',
        iconStyle: 'font-size:17px', suffix: `<span class="mono faint" style="font-size:12px;font-weight:400">· ${esc(j.hint)}</span>`,
      });
    }
    const showToast = state.toastCmd && !barCopied;

    return `<main style="display:flex;flex-direction:column;gap:22px;padding:12px 16px 24px">
      <div style="display:flex;flex-direction:column;gap:6px">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
          ${p.desc ? `<span class="muted" style="font-size:14px">${esc(p.desc)}</span>` : ''}
          ${badges(p)}
        </div>
        <span class="faint" style="font-size:12px">${p.updatedAt ? `Updated ${esc(when(p.updatedAt))} · ${ago(ts(p.updatedAt))}` : 'No status file yet'}</span>
      </div>
      ${staleCallout(p, true)}
      <section style="display:flex;flex-direction:column;gap:6px">
        <h2 class="h-label">Now</h2>
        <p style="font-size:16px;line-height:1.5;margin:0;text-wrap:pretty">${nowText(p)}</p>
      </section>
      ${p.blocked.length ? `<section style="display:flex;flex-direction:column;gap:6px"><h2 class="h-label">Blocked</h2>${blockedRows(p, 10)}</section>` : ''}
      <section style="display:flex;flex-direction:column">
        ${sessionsHeading(p, true)}
        ${sessions}
      </section>
      <section style="display:flex;flex-direction:column">
        <h2 class="h-label" style="margin-bottom:4px">Next</h2>
        ${nextRows(p, true)}
      </section>
      <section style="display:flex;flex-direction:column;gap:4px">
        <h2 class="h-label">Last session</h2>
        <div class="muted" style="font-size:14px">${esc(p.summary || '—')}</div>
      </section>
    </main>
    <div class="bottombar">
      ${showToast ? `<div class="toast" role="status" style="position:absolute;left:12px;right:12px;bottom:100%;gap:10px;padding:12px 14px;border-radius:12px">
        <i class="ph-fill ph-check-circle" style="font-size:20px;color:var(--ok)"></i>
        <div style="display:flex;flex-direction:column;min-width:0;flex:1"><span style="font-size:14px;font-weight:500">Copied</span><code class="ellipsis muted" style="font-size:11px">${esc(state.toastCmd)}</code></div>
        ${sshApp(`<a href="ssh://${esc(host())}" class="btn btn-secondary" data-act="link" style="min-height:40px;white-space:nowrap">Open SSH app</a>`)}
      </div>` : ''}
      ${bar}
    </div>`;
  }

  function focusSignature(el) {
    if (!el || !app.contains(el) || !el.dataset) return null;
    return { act: el.dataset.act, key: el.dataset.key, name: el.dataset.name };
  }

  function restoreFocus(sig) {
    if (!sig || !sig.act) return;
    const match = [...app.querySelectorAll(`[data-act="${CSS.escape(sig.act)}"]`)]
      .find(el => el.dataset.key === sig.key && el.dataset.name === sig.name);
    if (match) match.focus({ preventScroll: true });
  }

  function keepMenuOnScreen() {
    const menu = app.querySelector('.menu');
    if (!menu) return;
    const margin = 8;
    const r = menu.getBoundingClientRect();
    if (r.left < margin) {
      menu.style.right = 'auto';
      menu.style.left = '0';
      const shifted = menu.getBoundingClientRect();
      if (shifted.left < margin) menu.style.left = margin - shifted.left + 'px';
    }
  }

  function render() {
    cmdMap = {};
    const offline = isOffline();
    state.renderedOffline = offline;
    const focus = focusSignature(document.activeElement);

    if (!state.data) {
      const body = offline ? desktopOfflineBanner() : '<div class="loading">Loading…</div>';
      app.innerHTML = (state.mobile ? mobileHeader(null, offline) : desktopHeader(offline)) +
        `<main style="display:flex;flex-direction:column;gap:24px;padding:${state.mobile ? '14px 12px' : '24px 32px'}">${body}</main>`;
      return;
    }

    const m = derive(state.data);
    const detail = state.view.name ? m.projects.find(p => p.name === state.view.name) || null : null;
    app.classList.toggle('fill', state.mobile && !!detail);
    if (state.mobile) {
      app.innerHTML = mobileHeader(detail, offline) + (detail ? mobileDetail(detail) : mobileOverview(m, offline));
    } else {
      const paneScroll = app.querySelector('.pane')?.scrollTop || 0;
      let body;
      if (!detail) body = desktopOverview(m, offline);
      else if (!listShown(state.view)) body = desktopDetail(detail);
      else body = `<div class="split">${desktopOverview(m, offline, detail.name)}${desktopPane(detail)}</div>`;
      app.innerHTML = desktopHeader(offline) + body + desktopToast();
      const header = app.querySelector('.desktop-header');
      if (header) app.style.setProperty('--header-h', header.offsetHeight + 'px');
      const pane = app.querySelector('.pane');
      if (pane && state.paneFor === detail.name) pane.scrollTop = paneScroll;
      state.paneFor = pane ? detail.name : null;
    }
    app.insertAdjacentHTML('beforeend', startPanel());
    keepMenuOnScreen();
    restoreFocus(focus);
  }

  function tick() {
    if (isOffline() !== state.renderedOffline) {
      render();
      return;
    }
    app.querySelectorAll('[data-tick]').forEach(el => {
      switch (el.dataset.tick) {
        case 'refreshed': el.textContent = refreshedLabel(false); break;
        case 'refreshed-compact': el.textContent = refreshedLabel(true); break;
        case 'retry': el.textContent = retryText(false); break;
        case 'retry-compact': el.textContent = retryText(true); break;
      }
    });
  }

  async function refresh() {
    clearTimeout(fetchTimer);
    try {
      const res = await fetch('status.json?t=' + Date.now(), { cache: 'no-store' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const data = await res.json();
      if (!data || !Array.isArray(data.projects)) throw new Error('Unexpected payload');
      state.data = data;
      state.fetchFailed = false;
      try { localStorage.setItem(DATA_KEY, JSON.stringify(data)); } catch (_) {}
    } catch (_) {
      state.fetchFailed = true;
    }
    state.nextTryAt = Date.now() + interval() * 1000;
    fetchTimer = setTimeout(refresh, interval() * 1000);
    render();
  }

  function fallbackCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (_) {}
    ta.remove();
  }

  function writeClipboard(text) {
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
    } else {
      fallbackCopy(text);
    }
  }

  function copy(key, closeMenu) {
    const cmd = cmdMap[key];
    if (!cmd) return;
    writeClipboard(cmd);
    state.copiedKey = key;
    state.toastCmd = cmd;
    if (closeMenu) state.openMenuKey = null;
    clearTimeout(copyTimer);
    copyTimer = setTimeout(() => {
      state.copiedKey = null;
      state.toastCmd = null;
      render();
    }, COPY_MS);
    render();
  }

  function readToken() {
    try { return localStorage.getItem(TOKEN_KEY) || ''; } catch (_) { return ''; }
  }

  function saveToken(token) {
    try {
      if (token) localStorage.setItem(TOKEN_KEY, token);
      else localStorage.removeItem(TOKEN_KEY);
    } catch (_) {}
  }

  function notify(kind, title, detail) {
    state.notice = { kind, title, detail };
    clearTimeout(noticeTimer);
    if (kind === 'ok') {
      noticeTimer = setTimeout(() => {
        state.notice = null;
        render();
      }, NOTICE_MS);
    }
    render();
  }

  function askToken(ask, error) {
    state.tokenAsk = ask;
    state.tokenError = error;
    state.notice = null;
    render();
    app.querySelector('[data-act="token-input"]')?.focus();
  }

  async function api(path, payload, ask) {
    const token = readToken();
    if (!token) {
      askToken(ask, '');
      return null;
    }
    let res = null;
    let body = {};
    try {
      res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Project-Status-Token': token },
        body: JSON.stringify(payload),
      });
      body = await res.json().catch(() => ({}));
    } catch (_) {}
    if (res && res.status === 401) {
      saveToken('');
      askToken(ask, 'That token was rejected. Check it and try again.');
      return null;
    }
    return { ok: !!res && res.ok, body, error: body.error || (res ? 'HTTP ' + res.status : "Can't reach " + host()) };
  }

  function findSession(id) {
    for (const p of state.data?.projects || []) {
      const s = (p.sessions || []).find(x => x.id === id);
      if (s) return { p, s };
    }
    return null;
  }

  function armRemove(id) {
    state.confirmRemove = id;
    clearTimeout(confirmTimer);
    confirmTimer = setTimeout(() => {
      state.confirmRemove = null;
      render();
    }, 4000);
    render();
  }

  async function removeSession(id) {
    if (state.removing) return;
    if (state.confirmRemove !== id) return armRemove(id);
    clearTimeout(confirmTimer);
    const found = findSession(id);
    const name = found?.s.title || short(id);
    if (!readToken()) {
      state.confirmRemove = null;
      return askToken({ remove: id }, '');
    }
    state.confirmRemove = null;
    state.removing = id;
    state.notice = null;
    render();
    const r = await api('api/remove', { id }, { remove: id });
    state.removing = null;
    if (!r) return;
    if (!r.ok) return notify('bad', 'Kept ' + name, r.error);
    notify('ok', 'Removed ' + name, 'The session and its worktree are gone.');
    refresh();
  }

  async function startSession(name, idx, key) {
    if (state.starting) return;
    const project = (state.data?.projects || []).find(p => p.name === name);
    if (!project) return;
    const prompt = idx === 'new' ? '' : (project.next || [])[Number(idx)] || '';
    const ask = { name, idx, key };
    if (!readToken()) return askToken(ask, '');
    state.starting = key;
    state.notice = null;
    render();
    const r = await api('api/start', { repo: name, prompt }, ask);
    state.starting = null;
    if (!r) return render();
    if (!r.ok) return notify('bad', "Couldn't start a session", r.error);
    const body = r.body;
    const where = [body.title || 'New session', body.worktree ? 'worktree ' + body.worktree : ''].filter(Boolean).join(' · ');
    const reach = body.remoteControl ? 'Its Open in Claude link appears in a few seconds.' : `Attach with claude attach ${body.id}.`;
    notify('ok', 'Started in ' + name, `${where}. ${reach}`);
    refresh();
    setTimeout(refresh, 8000);
  }

  function navigate(name, full) {
    const hash = name ? '#/p/' + encodeURIComponent(name) + (full ? '/full' : '') : '#/';
    if (location.hash === hash || (!name && !location.hash)) {
      state.view = parseHash();
      render();
      return;
    }
    location.hash = hash;
  }

  function setTheme(theme, persist) {
    state.theme = theme;
    document.documentElement.dataset.theme = theme;
    if (persist) {
      try { localStorage.setItem(THEME_KEY, theme); } catch (_) {}
    }
    render();
  }

  app.addEventListener('click', e => {
    const el = e.target.closest('[data-act]');
    if (!el || !app.contains(el)) return;
    switch (el.dataset.act) {
      case 'link': return;
      case 'go': navigate(el.dataset.name || null, !!el.dataset.full); return;
      case 'copy': copy(el.dataset.key, false); return;
      case 'ssh': copy(el.dataset.key, true); return;
      case 'menu':
        state.openMenuKey = state.openMenuKey === el.dataset.key ? null : el.dataset.key;
        render();
        return;
      case 'theme': setTheme(state.theme === 'dark' ? 'light' : 'dark', true); return;
      case 'dormant': state.dormantOpen = !state.dormantOpen; render(); return;
      case 'retry': refresh(); return;
      case 'start': startSession(el.dataset.name, el.dataset.idx, el.dataset.key); return;
      case 'remove': removeSession(el.dataset.key); return;
      case 'token-cancel':
        state.tokenAsk = null;
        state.tokenDraft = '';
        render();
        return;
      case 'notice-close':
        clearTimeout(noticeTimer);
        state.notice = null;
        render();
        return;
    }
  });

  app.addEventListener('input', e => {
    if (e.target.dataset && e.target.dataset.act === 'token-input') state.tokenDraft = e.target.value;
  });

  app.addEventListener('submit', e => {
    e.preventDefault();
    const token = state.tokenDraft.trim();
    if (!state.tokenAsk || !token) return;
    const ask = state.tokenAsk;
    saveToken(token);
    state.tokenAsk = null;
    state.tokenDraft = '';
    if (ask.remove) {
      state.confirmRemove = ask.remove;
      removeSession(ask.remove);
    } else {
      startSession(ask.name, ask.idx, ask.key);
    }
  });

  app.addEventListener('keydown', e => {
    if (e.key !== 'Enter' && e.key !== ' ') return;
    const el = e.target;
    if (el.dataset && el.dataset.act === 'go' && el.getAttribute('role') === 'link') {
      e.preventDefault();
      navigate(el.dataset.name || null);
    }
  });

  document.addEventListener('pointerdown', e => {
    if (state.openMenuKey && !e.target.closest('[data-jmenu]')) {
      state.openMenuKey = null;
      render();
    }
  });

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && (state.openMenuKey || state.tokenAsk)) {
      state.openMenuKey = null;
      state.tokenAsk = null;
      state.tokenDraft = '';
      render();
    } else if (e.key === 'Escape' && state.view.name && !state.view.full && canSplit()) {
      navigate(null);
    }
  });

  window.addEventListener('hashchange', () => {
    const prev = state.view;
    state.view = parseHash();
    state.openMenuKey = null;
    render();
    if (!(listShown(prev) && listShown(state.view))) window.scrollTo(0, 0);
  });

  splitQuery.addEventListener('change', e => {
    state.wide = e.matches;
    state.openMenuKey = null;
    render();
  });

  mobileQuery.addEventListener('change', e => {
    state.mobile = e.matches;
    state.openMenuKey = null;
    render();
  });

  matchMedia('(prefers-color-scheme: light)').addEventListener('change', e => {
    let saved = null;
    try { saved = localStorage.getItem(THEME_KEY); } catch (_) {}
    if (!saved) setTheme(e.matches ? 'light' : 'dark', false);
  });

  try {
    const cached = JSON.parse(localStorage.getItem(DATA_KEY) || 'null');
    if (cached && Array.isArray(cached.projects)) state.data = cached;
  } catch (_) {}

  render();
  refresh();
  setInterval(tick, 1000);
  fetch('api/info', { cache: 'no-store' })
    .then(res => (res.ok ? res.json() : null))
    .then(info => {
      if (info && info.start) {
        state.api = info;
        render();
      }
    })
    .catch(() => {});
})();
