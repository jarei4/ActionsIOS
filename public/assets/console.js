// console.js — 极光控制台前端（原生 ES 模块，零框架，与后端同一套契约）
const $ = (selector) => document.querySelector(selector);
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[c]));

const RING_LENGTH = 2 * Math.PI * 42;

const state = {
  token: null,
  user: null,
  notes: [],
  stats: { total: 0, done: 0, open: 0, urgent: 0, overdue: 0 },
  filter: 'all',
  query: '',
  mode: 'login',
  editing: null,
  priority: 1,
  revealed: false,
  loading: false,
};

const FILTERS = [
  { key: 'all', label: '全部' },
  { key: 'open', label: '待办' },
  { key: 'done', label: '完成' },
  { key: 'pinned', label: '置顶' },
];

/* ── 网络层：401 自动刷新一次并重放 ───────────────────────── */
class ApiError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

async function request(method, path, body, { retry = true } = {}) {
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (state.token && !path.startsWith('/api/auth/')) {
    headers.Authorization = `Bearer ${state.token}`;
  }

  let response;
  try {
    response = await fetch(path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'same-origin',
    });
  } catch {
    throw new ApiError(0, '连不上服务端');
  }

  if (response.status === 401 && retry && !path.startsWith('/api/auth/')) {
    const revived = await tryRefresh();
    if (revived) return request(method, path, body, { retry: false });
    signOutLocally('会话已过期，请重新登录');
    throw new ApiError(401, '会话已过期');
  }

  const text = await response.text();
  let payload = null;
  try { payload = text ? JSON.parse(text) : null; } catch { /* 非 JSON */ }

  if (!response.ok) {
    throw new ApiError(response.status, payload?.error || `请求失败（${response.status}）`);
  }
  return payload;
}

async function tryRefresh() {
  try {
    const payload = await request('POST', '/api/auth/refresh', undefined, { retry: false });
    if (payload?.access) {
      state.token = payload.access;
      state.user = payload.user;
      return true;
    }
  } catch { /* 刷新失败按登出处理 */ }
  return false;
}

/* ── 提示 ─────────────────────────────────────────────── */
let toastTimer = 0;
function toast(message, kind = 'ok') {
  const node = $('#toast');
  node.textContent = message;
  node.className = `toast ${kind} show`;
  node.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    node.classList.remove('show');
    setTimeout(() => { node.hidden = true; }, 300);
  }, 2600);
}

/* ── 时间文案 ─────────────────────────────────────────── */
function ago(ms) {
  const seconds = Math.max(0, (Date.now() - Number(ms)) / 1000);
  if (seconds < 60) return '刚刚';
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)} 天前`;
  return new Date(Number(ms)).toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' });
}

function dueLabel(ms) {
  if (!ms) return null;
  const date = new Date(Number(ms));
  const today = new Date();
  const sameDay = date.toDateString() === today.toDateString();
  const clock = date.toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  if (sameDay) return `今天 ${clock}`;
  return date.toLocaleDateString('zh-CN', { month: 'numeric', day: 'numeric' });
}

function greeting() {
  const hour = new Date().getHours();
  if (hour < 5) return '夜深了';
  if (hour < 11) return '早上好';
  if (hour < 14) return '中午好';
  if (hour < 18) return '下午好';
  if (hour < 23) return '晚上好';
  return '夜深了';
}

/* ── 渲染 ─────────────────────────────────────────────── */
function renderAuth() {
  const busy = state.loading;
  $('#submit .label').textContent = state.mode === 'login' ? '进入控制台' : '创建并进入';
  $('#submit .spinner').hidden = !busy;
  $('#submit').disabled = busy;
  $('#tab-login').classList.toggle('is-active', state.mode === 'login');
  $('#tab-register').classList.toggle('is-active', state.mode === 'register');
  $('#tab-login').setAttribute('aria-selected', String(state.mode === 'login'));
  $('#tab-register').setAttribute('aria-selected', String(state.mode === 'register'));
  $('#password').setAttribute('autocomplete', state.mode === 'login' ? 'current-password' : 'new-password');
  $('#password').type = state.revealed ? 'text' : 'password';
  $('#reveal').textContent = state.revealed ? '隐藏' : '显示';
}

function visibleNotes() {
  const needle = state.query.trim().toLowerCase();
  return state.notes.filter((note) => {
    if (state.filter === 'open' && note.status !== 'open') return false;
    if (state.filter === 'done' && note.status !== 'done') return false;
    if (state.filter === 'pinned' && !note.pinned) return false;
    if (!needle) return true;
    return note.title.toLowerCase().includes(needle)
      || note.body.toLowerCase().includes(needle)
      || note.tags.some((tag) => tag.toLowerCase().includes(needle));
  });
}

function renderStats() {
  const stats = state.stats;
  const ratio = stats.total ? Math.min(1, stats.done / stats.total) : 0;
  $('#pct').textContent = String(Math.round(ratio * 100));
  $('#ring-fill').style.strokeDashoffset = String(RING_LENGTH * (1 - Math.max(0.015, ratio)));
  $('#s-open').textContent = String(stats.open ?? 0);
  $('#s-urgent').textContent = String(stats.urgent ?? 0);
  $('#s-done').textContent = String(stats.done ?? 0);
  $('#s-overdue').textContent = String(stats.overdue ?? 0);
}

function countFor(key) {
  if (key === 'all') return state.notes.length;
  if (key === 'pinned') return state.notes.filter((n) => n.pinned).length;
  return state.notes.filter((n) => n.status === key).length;
}

function renderFilters() {
  $('#filters').innerHTML = FILTERS.map((item) => `
    <button class="chip${state.filter === item.key ? ' is-active' : ''}" data-filter="${item.key}">
      ${item.label}<b>${countFor(item.key)}</b>
    </button>
  `).join('');
}

function renderNotes() {
  const notes = visibleNotes();
  const host = $('#notes');

  if (!notes.length) {
    const empty = state.notes.length
      ? { glyph: '⌗', title: '当前筛选下没有条目', text: '换个筛选，或清空搜索词。' }
      : { glyph: '✦', title: '这里还很安静', text: '点「新建」，写下第一条。' };
    host.innerHTML = `
      <div class="panel empty">
        <div class="glyph">${empty.glyph}</div>
        <h3>${empty.title}</h3>
        <p>${empty.text}</p>
      </div>`;
    return;
  }

  host.innerHTML = notes.map((note) => {
    const due = dueLabel(note.due);
    const late = note.status === 'open' && note.due && Number(note.due) < Date.now();
    const tags = note.tags.slice(0, 3).map((tag) => `<span class="tag">#${esc(tag)}</span>`).join('');
    return `
      <article class="note${note.status === 'done' ? ' is-done' : ''}" data-id="${esc(note.id)}">
        <button class="check" data-act="toggle" aria-label="切换完成">✓</button>
        <div class="note-main">
          <div class="note-row1">
            ${note.pinned ? '<span title="已置顶">📌</span>' : ''}
            <h4 class="note-title">${esc(note.title)}</h4>
            <span class="badge p${Number(note.priority)}">${['稍后', '常规', '紧急'][Number(note.priority)] ?? '常规'}</span>
          </div>
          <p class="note-body">${esc(note.body || '还没有正文')}</p>
          <div class="note-meta">
            ${tags}
            ${due ? `<span class="due${late ? ' late' : ''}">${esc(due)}</span>` : ''}
            <span class="stamp">${esc(ago(note.updatedAt))}</span>
          </div>
        </div>
        <div class="note-actions">
          <button class="mini" data-act="pin" title="置顶">${note.pinned ? '⤵' : '⤒'}</button>
          <button class="mini" data-act="edit" title="编辑">✎</button>
          <button class="mini danger" data-act="delete" title="删除">✕</button>
        </div>
      </article>`;
  }).join('');
}

function renderBoard() {
  $('#greeting').textContent = greeting();
  $('#who').textContent = state.user?.email?.split('@')[0] || '极光';
  $('.avatar').textContent = (state.user?.email?.[0] || 'A').toUpperCase();
  renderStats();
  renderFilters();
  renderNotes();
}

function showBoard(show) {
  $('#auth').hidden = show;
  $('#board').hidden = !show;
}

/* ── 数据加载 ─────────────────────────────────────────── */
async function loadAll() {
  const [notes, stats] = await Promise.all([
    request('GET', '/api/notes'),
    request('GET', '/api/stats'),
  ]);
  state.notes = notes.notes ?? [];
  state.stats = stats ?? state.stats;
  renderBoard();
}

async function refreshStats() {
  try {
    state.stats = await request('GET', '/api/stats');
    renderStats();
    renderFilters();
  } catch { /* 统计失败不影响主流程 */ }
}

/* ── 认证流程 ─────────────────────────────────────────── */
async function submitAuth(event) {
  event.preventDefault();
  const email = $('#email').value.trim();
  const password = $('#password').value;
  const hint = $('#auth-hint');

  if (!email.includes('@') || email.length < 5) {
    hint.textContent = '邮箱格式看起来不对';
    hint.hidden = false;
    return;
  }
  if (password.length < 8) {
    hint.textContent = '密码至少 8 位';
    hint.hidden = false;
    return;
  }
  hint.hidden = true;

  state.loading = true;
  renderAuth();
  try {
    const path = state.mode === 'login' ? '/api/auth/login' : '/api/auth/register';
    const payload = await request('POST', path, { email, password }, { retry: false });
    state.token = payload.access;
    state.user = payload.user;
    await enterBoard();
    toast(state.mode === 'login' ? '欢迎回来' : '账号已创建', 'ok');
  } catch (error) {
    toast(error.message, 'error');
    hint.textContent = error.message;
    hint.hidden = false;
  } finally {
    state.loading = false;
    renderAuth();
  }
}

async function enterBoard() {
  showBoard(true);
  try {
    await loadAll();
  } catch (error) {
    toast(error.message, 'error');
  }
}

function signOutLocally(message) {
  state.token = null;
  state.user = null;
  state.notes = [];
  state.stats = { total: 0, done: 0, open: 0, urgent: 0, overdue: 0 };
  showBoard(false);
  renderAuth();
  if (message) toast(message, 'warn');
}

/* ── 条目操作 ─────────────────────────────────────────── */
function noteById(id) {
  return state.notes.find((note) => note.id === id);
}

function patchLocal(id, mutate) {
  const index = state.notes.findIndex((note) => note.id === id);
  if (index < 0) return null;
  const snapshot = { ...state.notes[index] };
  state.notes[index] = { ...snapshot, ...mutate };
  renderBoard();
  return snapshot;
}

async function toggleDone(id) {
  const note = noteById(id);
  if (!note) return;
  const target = note.status === 'open' ? 'done' : 'open';
  patchLocal(id, { status: target });
  try {
    const result = await request('PATCH', `/api/notes/${id}`, { status: target, rev: note.rev });
    const index = state.notes.findIndex((n) => n.id === id);
    if (index >= 0) state.notes[index] = result.note;
    renderBoard();
    refreshStats();
  } catch (error) {
    patchLocal(id, { status: note.status, rev: note.rev });
    toast(error.message, 'error');
  }
}

async function togglePin(id) {
  const note = noteById(id);
  if (!note) return;
  const target = !note.pinned;
  patchLocal(id, { pinned: target });
  try {
    const result = await request('PATCH', `/api/notes/${id}`, { pinned: target, rev: note.rev });
    const index = state.notes.findIndex((n) => n.id === id);
    if (index >= 0) state.notes[index] = result.note;
    renderBoard();
  } catch (error) {
    patchLocal(id, { pinned: note.pinned, rev: note.rev });
    toast(error.message, 'error');
  }
}

async function removeNote(id) {
  const snapshot = [...state.notes];
  state.notes = state.notes.filter((note) => note.id !== id);
  renderBoard();
  try {
    await request('DELETE', `/api/notes/${id}`);
    refreshStats();
    toast('已删除', 'ok');
  } catch (error) {
    state.notes = snapshot;
    renderBoard();
    toast(error.message, 'error');
  }
}

/* ── 编辑器 ───────────────────────────────────────────── */
function parseTags(raw) {
  const seen = new Set();
  const out = [];
  for (const piece of String(raw).split(/[\s,，]+/)) {
    const tag = piece.replace(/^#/, '').trim();
    if (!tag || tag.length > 20 || seen.has(tag)) continue;
    seen.add(tag);
    out.push(tag);
    if (out.length === 4) break;
  }
  return out;
}

function toLocalInput(ms) {
  if (!ms) return '';
  const date = new Date(Number(ms) - new Date().getTimezoneOffset() * 60000);
  return date.toISOString().slice(0, 16);
}

function renderPriorityChips() {
  $('#priority').innerHTML = [0, 1, 2].map((value) => `
    <button type="button" class="chip${state.priority === value ? ' is-active' : ''}" data-priority="${value}">
      ${['稍后', '常规', '紧急'][value]}
    </button>`).join('');
}

function openEditor(note) {
  state.editing = note ?? null;
  state.priority = note ? Number(note.priority) : 1;
  $('#editor-title').textContent = note ? '编辑条目' : '新建条目';
  $('#editor-rev').textContent = note ? `v${note.rev}` : '';
  $('#n-title').value = note?.title ?? '';
  $('#n-body').value = note?.body ?? '';
  $('#n-tags').value = note?.tags?.join(' ') ?? '';
  $('#n-due').value = toLocalInput(note?.due);
  renderPriorityChips();
  $('#editor').showModal();
  setTimeout(() => $('#n-title').focus(), 60);
}

async function saveEditor(event) {
  event.preventDefault();
  const title = $('#n-title').value.trim();
  if (!title) {
    toast('标题不能为空', 'warn');
    $('#n-title').focus();
    return;
  }

  const dueRaw = $('#n-due').value;
  const due = dueRaw ? new Date(dueRaw).getTime() : null;
  const payload = {
    title,
    body: $('#n-body').value,
    priority: state.priority,
    tags: parseTags($('#n-tags').value),
  };

  try {
    if (state.editing) {
      const patch = { ...payload, rev: state.editing.rev };
      if (due) patch.due = due;
      if (!due && state.editing.due) patch.due = null; // 显式清空
      const result = await request('PATCH', `/api/notes/${state.editing.id}`, patch);
      const index = state.notes.findIndex((n) => n.id === state.editing.id);
      if (index >= 0) state.notes[index] = result.note;
      toast('已保存', 'ok');
    } else {
      const result = await request('POST', '/api/notes', { ...payload, due });
      state.notes.unshift(result.note);
      toast(`已创建「${result.note.title}」`, 'ok');
    }
    $('#editor').close();
    renderBoard();
    refreshStats();
  } catch (error) {
    toast(error.message, error.status === 409 ? 'warn' : 'error');
    if (error.status === 409) loadAll();
  }
}

/* ── 设置 ─────────────────────────────────────────────── */
async function openSettings() {
  let version = { name: 'Aurora', version: '—', build: '—' };
  try { version = await request('GET', '/api/version'); } catch { /* 忽略 */ }

  $('#settings-body').innerHTML = `
    <div class="setting"><span>账号</span><code>${esc(state.user?.email ?? '—')}</code></div>
    <div class="setting"><span>角色</span><code>${state.user?.role === 'owner' ? '主控' : '成员'}</code></div>
    <div class="setting"><span>服务端</span><code>${esc(location.origin)}</code></div>
    <div class="setting"><span>版本</span><code>v${esc(version.version)} (${esc(version.build)})</code></div>
    <div class="setting"><span>会话</span><code>15 分钟访问令牌 + 可旋转刷新</code></div>
  `;
  $('#settings').showModal();
}

/* ── 事件绑定 ─────────────────────────────────────────── */
function bindEvents() {
  $('#tab-login').addEventListener('click', () => { state.mode = 'login'; renderAuth(); });
  $('#tab-register').addEventListener('click', () => { state.mode = 'register'; renderAuth(); });
  $('#reveal').addEventListener('click', () => { state.revealed = !state.revealed; renderAuth(); });
  $('#auth-form').addEventListener('submit', submitAuth);

  $('#new-note').addEventListener('click', () => openEditor(null));
  $('#refresh').addEventListener('click', async () => {
    try {
      await loadAll();
      toast('已刷新', 'ok');
    } catch (error) { toast(error.message, 'error'); }
  });
  $('#open-settings').addEventListener('click', openSettings);
  $('#settings-close').addEventListener('click', () => $('#settings').close());

  $('#search').addEventListener('input', (event) => {
    state.query = event.target.value;
    renderNotes();
  });

  $('#filters').addEventListener('click', (event) => {
    const button = event.target.closest('[data-filter]');
    if (!button) return;
    state.filter = button.dataset.filter;
    renderFilters();
    renderNotes();
  });

  $('#notes').addEventListener('click', (event) => {
    const article = event.target.closest('.note');
    if (!article) return;
    const action = event.target.closest('[data-act]')?.dataset.act;
    const id = article.dataset.id;
    if (action === 'toggle') toggleDone(id);
    else if (action === 'pin') togglePin(id);
    else if (action === 'edit') openEditor(noteById(id));
    else if (action === 'delete') removeNote(id);
  });

  $('#editor-cancel').addEventListener('click', () => $('#editor').close());
  $('#editor-form').addEventListener('submit', saveEditor);
  $('#priority').addEventListener('click', (event) => {
    const button = event.target.closest('[data-priority]');
    if (!button) return;
    state.priority = Number(button.dataset.priority);
    renderPriorityChips();
  });

  $('#signout').addEventListener('click', async () => {
    try { await request('POST', '/api/auth/logout', undefined, { retry: false }); } catch { /* 忽略 */ }
    $('#settings').close();
    signOutLocally('已退出登录');
  });

  document.addEventListener('keydown', (event) => {
    if (event.target.matches('input, textarea')) return;
    if (event.key === 'n' && state.user && !$('#editor').open) { event.preventDefault(); openEditor(null); }
    if (event.key === '/') { event.preventDefault(); $('#search').focus(); }
    if (event.key === 'r' && state.user) { loadAll().catch(() => {}); }
  });
}

/* ── 启动 ─────────────────────────────────────────────── */
async function boot() {
  bindEvents();
  renderAuth();

  $('#server-chip').textContent = location.origin;

  try {
    const version = await request('GET', '/api/version', undefined, { retry: false });
    $('#version-chip').textContent = `v${version.version} · ${version.channel ?? 'stable'}`;
  } catch {
    $('#version-chip').textContent = '服务端未就绪';
  }

  // HttpOnly 刷新令牌还在 → 直接恢复会话，不用再输一次密码
  if (await tryRefresh()) {
    await enterBoard();
  } else {
    showBoard(false);
    setTimeout(() => $('#email').focus(), 120);
  }
}

boot();
