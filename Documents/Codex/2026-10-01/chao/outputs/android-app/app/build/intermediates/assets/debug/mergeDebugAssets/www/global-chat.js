(() => {
  'use strict';

  const api = window.__phase2Api;
  const sdk = window.supabase;
  if (!api || !sdk?.createClient) return;

  const strings = {
    title: '💬 Chat chung', open: 'Mở chat chung', close: 'Thu nhỏ chat',
    login: 'Đăng nhập để tham gia chat chung.', loading: 'Đang tải tin nhắn…',
    ready: 'Chat chung · mọi người đều có thể xem', failed: 'Chưa kết nối được. Chạm để thử lại.',
    placeholder: 'Viết tin nhắn…', send: 'Gửi', empty: 'Chưa có tin nhắn. Hãy chào mọi người nhé!',
    retry: 'Thử tải lại', report: 'Báo cáo', block: 'Chặn người chơi', blocked: 'Đã chặn người chơi này.',
    reportPrompt: 'Lý do báo cáo', spam: 'Spam', harassment: 'Quấy rối', inappropriate: 'Không phù hợp', other: 'Khác', cancel: 'Hủy',
    sent: 'Đã gửi', tooLong: 'Tin nhắn tối đa 300 ký tự.', loginAction: 'Đăng nhập',
    sending: 'Đang gửi…', disconnected: 'Mất kết nối chat. Đang thử kết nối lại…'
  };
  const CHAT_URL = api.supabaseUrl;
  const CHAT_KEY = api.publishableKey;
  if (!CHAT_URL || !CHAT_KEY) return;

  const client = sdk.createClient(CHAT_URL, CHAT_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    accessToken: async () => api.accessToken?.() || null,
    realtime: { params: { eventsPerSecond: 5 } }
  });

  const scene = document.querySelector('.scene');
  if (!scene) return;
  const launcher = document.createElement('button');
  launcher.type = 'button'; launcher.className = 'global-chat-launch'; launcher.textContent = '💬';
  launcher.setAttribute('aria-label', strings.open); launcher.title = strings.open;
  const panel = document.createElement('section');
  panel.className = 'global-chat-panel'; panel.hidden = true; panel.setAttribute('aria-label', strings.title);
  panel.innerHTML = '<header class="global-chat-head"><strong></strong><div><button type="button" class="global-chat-reload" title="Thử tải lại">↻</button><button type="button" class="global-chat-collapse" title="Thu nhỏ chat">−</button></div></header><div class="global-chat-status" role="status" aria-live="polite"></div><div class="global-chat-messages" role="log" aria-live="polite" aria-relevant="additions"></div><div class="global-chat-emoji" aria-label="Biểu tượng cảm xúc"><button type="button">😊</button><button type="button">🌱</button><button type="button">🎉</button><button type="button">❤️</button></div><form class="global-chat-form"><textarea maxlength="600" rows="2" autocomplete="off"></textarea><button type="submit" class="global-chat-send"></button></form>';
  scene.append(launcher, panel);
  const $ = selector => panel.querySelector(selector);
  const status = $('.global-chat-status'), list = $('.global-chat-messages'), form = $('.global-chat-form'), input = form.querySelector('textarea');
  let channel = null, profile = null, blocked = new Set(), known = new Set(), seenOrder = [], lastId = null, pendingId = null, pendingBody = null, activeUser = null, connecting = null;

  function t(key) { return window.gameTranslate ? window.gameTranslate(strings[key] || key) : strings[key] || key; }
  function setStatus(text, kind = '') { status.textContent = text; status.dataset.kind = kind; }
  function showLoginPrompt() { status.replaceChildren(document.createTextNode(t('login') + ' ')); const button = document.createElement('button'); button.type = 'button'; button.textContent = t('loginAction'); button.addEventListener('click', () => api.openCloudModal?.()); status.append(button); status.dataset.kind = 'login'; }
  function currentUser() { return api.userId?.() || null; }
  function canChat() { return !!(currentUser() && api.session?.() && api.ready?.()); }
  function makeUuid() { return crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); }); }
  function addMessage(row) {
    const id = Number(row?.id);
    if (!Number.isSafeInteger(id) || known.has(id) || blocked.has(row.sender_public_id)) return;
    if (list.firstChild?.nodeType === Node.TEXT_NODE) list.replaceChildren();
    known.add(id); seenOrder.push(id); if (seenOrder.length > 500) known.delete(seenOrder.shift()); lastId = lastId === null ? id : Math.max(lastId, id);
    const article = document.createElement('article'); article.className = 'global-chat-message'; article.dataset.messageId = String(id); article.dataset.senderId = row.sender_public_id || '';
    const meta = document.createElement('div'); meta.className = 'global-chat-meta';
    const name = document.createElement('strong'); name.textContent = Array.from(String(row.display_name || 'Nhà vườn')).slice(0, 24).join('');
    const time = document.createElement('time');
    const date = new Date(row.created_at);
    time.dateTime = Number.isNaN(date.valueOf()) ? '' : date.toISOString(); time.textContent = Number.isNaN(date.valueOf()) ? '' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    meta.append(name, time);
    const body = document.createElement('p'); body.textContent = String(row.body || '');
    article.append(meta, body);
    if (row.sender_public_id && row.sender_public_id !== profile?.public_id) {
      const actions = document.createElement('div'); actions.className = 'global-chat-message-actions';
      const report = document.createElement('button'); report.type = 'button'; report.textContent = t('report'); report.addEventListener('click', () => reportMessage(id));
      const block = document.createElement('button'); block.type = 'button'; block.textContent = t('block'); block.addEventListener('click', () => blockUser(row.sender_public_id, article));
      actions.append(report, block); article.append(actions);
    }
    const next = [...list.querySelectorAll('.global-chat-message')].find(node => Number(node.dataset.messageId) > id);
    if (next) list.insertBefore(article, next); else list.append(article);
    while (list.children.length > 50) { const first = list.firstElementChild; first.remove(); }
    if (!next) list.scrollTop = list.scrollHeight;
  }
  function mergeRows(rows) { (Array.isArray(rows) ? rows : []).sort((a, b) => Number(a.id) - Number(b.id)).forEach(addMessage); }
  async function catchUp() {
    if (!canChat()) return;
    const rows = await api.rpc('get_global_chat_messages_v1', { p_after_id: lastId === null ? null : Math.max(0, lastId - 50), p_limit: 50 });
    mergeRows(rows);
    if (!list.children.length) list.textContent = t('empty');
    else if (list.firstChild?.nodeType === Node.TEXT_NODE) list.replaceChildren();
  }
  async function stopRealtime() {
    if (channel) { const old = channel; channel = null; try { await client.removeChannel(old); } catch { /* best effort */ } }
  }
  async function connectNow() {
    if (!canChat()) { showLoginPrompt(); return; }
    const userId = currentUser();
    if (channel && activeUser === userId) { await catchUp(); return; }
    await stopRealtime(); activeUser = userId; profile = null; blocked.clear(); known.clear(); seenOrder = []; lastId = null; list.replaceChildren(); setStatus(t('loading'));
    try {
      const [profileRows, blockRows] = await Promise.all([
        api.rpc('get_my_global_chat_profile_v1', {}), api.rpc('get_my_global_chat_blocks_v1', {})
      ]);
      if (!canChat() || currentUser() !== userId) return;
      profile = Array.isArray(profileRows) ? profileRows[0] : profileRows;
      blocked = new Set((Array.isArray(blockRows) ? blockRows : []).map(row => row.blocked_public_id));
      await catchUp();
      channel = client.channel('global-chat:v1', { config: { private: true } })
        .on('broadcast', { event: 'global_chat_message' }, ({ payload }) => addMessage(payload))
        .on('broadcast', { event: 'global_chat_hide' }, ({ payload }) => { const id = Number(payload?.id); panel.querySelectorAll('.global-chat-message').forEach(node => { if (Number(node.dataset.messageId) === id) node.remove(); }); })
        .subscribe(async state => {
          if (state === 'SUBSCRIBED') { setStatus(t('ready'), 'ready'); catchUp().catch(() => setStatus(t('disconnected'), 'error')); }
          else if (state === 'CHANNEL_ERROR' || state === 'TIMED_OUT' || state === 'CLOSED') setStatus(t('disconnected'), 'error');
        });
      setStatus(t('ready'), 'ready');
    } catch (error) {
      await stopRealtime(); setStatus(String(error?.message || t('failed')).slice(0, 160), 'error');
      if (!list.children.length) { const retry = document.createElement('button'); retry.type = 'button'; retry.textContent = t('retry'); retry.addEventListener('click', connect); list.replaceChildren(retry); }
    }
  }
  function connect() { if (connecting) return connecting; connecting = connectNow().finally(() => { connecting = null; }); return connecting; }
  function reportMessage(messageId) {
    if (!canChat() || panel.querySelector('.global-chat-report-dialog')) return;
    const dialog = document.createElement('div'); dialog.className = 'global-chat-report-dialog';
    const label = document.createElement('label'); label.textContent = t('reportPrompt');
    const select = document.createElement('select');
    for (const value of ['spam', 'harassment', 'inappropriate', 'other']) { const option = document.createElement('option'); option.value = value; option.textContent = t(value); select.append(option); }
    label.append(select);
    const actions = document.createElement('div'); actions.className = 'global-chat-report-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = t('cancel'); cancel.addEventListener('click', () => dialog.remove());
    const send = document.createElement('button'); send.type = 'button'; send.textContent = t('send');
    send.addEventListener('click', async () => { send.disabled = true; try { await api.rpc('report_global_chat_message_v1', { p_message_id: messageId, p_reason: select.value }); dialog.remove(); setStatus('Đã gửi báo cáo để quản trị viên xem xét.', 'ready'); } catch (error) { send.disabled = false; setStatus(String(error?.message || t('failed')).slice(0, 160), 'error'); } });
    actions.append(cancel, send); dialog.append(label, actions); panel.append(dialog); select.focus();
  }
  async function blockUser(publicId, article) {
    if (!canChat() || !publicId) return;
    try { await api.rpc('block_global_chat_user_v1', { p_public_id: publicId, p_block: true }); blocked.add(publicId); panel.querySelectorAll('.global-chat-message').forEach(node => { if (node.dataset.senderId === publicId) node.remove(); }); if (article?.isConnected) article.remove(); setStatus(t('blocked'), 'ready'); }
    catch (error) { setStatus(String(error?.message || t('failed')).slice(0, 160), 'error'); }
  }
  launcher.addEventListener('click', async () => {
    panel.hidden = !panel.hidden; launcher.setAttribute('aria-expanded', String(!panel.hidden));
    if (panel.hidden) { launcher.setAttribute('aria-label', t('open')); return; }
    launcher.setAttribute('aria-label', t('close'));
    if (!canChat()) { showLoginPrompt(); return; }
    await connect(); input.focus({ preventScroll: true });
  });
  $('.global-chat-collapse').addEventListener('click', () => { panel.hidden = true; launcher.setAttribute('aria-expanded', 'false'); launcher.setAttribute('aria-label', t('open')); });
  $('.global-chat-reload').addEventListener('click', () => { connect().catch(() => setStatus(t('failed'), 'error')); });
  $('.global-chat-head strong').textContent = t('title'); $('.global-chat-send').textContent = t('send'); input.placeholder = t('placeholder');
  panel.querySelectorAll('.global-chat-emoji button').forEach(button => button.addEventListener('click', () => { input.value = (input.value + button.textContent).slice(0, 300); input.focus(); if (pendingBody !== input.value) { pendingId = null; pendingBody = null; } }));
  input.addEventListener('input', () => { const bounded = Array.from(input.value).slice(0, 300).join(''); if (input.value !== bounded) input.value = bounded; if (pendingBody !== input.value) { pendingId = null; pendingBody = null; } });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const body = input.value.trim();
    if (!canChat()) { setStatus(t('login'), 'login'); return; }
    if (!body) return;
    if (Array.from(body).length > 300) { setStatus(t('tooLong'), 'error'); return; }
    if (pendingBody !== body || !pendingId) { pendingBody = body; pendingId = makeUuid(); }
    const button = $('.global-chat-send'); button.disabled = true; button.textContent = t('sending');
    try {
      const rows = await api.rpc('send_global_chat_message_v1', { p_request_id: pendingId, p_body: body });
      const row = Array.isArray(rows) ? rows[0] : rows; addMessage(row); input.value = ''; pendingId = null; pendingBody = null; setStatus(t('ready'), 'ready');
    } catch (error) { setStatus(String(error?.message || t('failed')).slice(0, 160), 'error'); }
    finally { button.disabled = false; button.textContent = t('send'); }
  });
  window.addEventListener('farm:game-ready', () => { if (!panel.hidden && canChat()) connect().catch(() => {}); });
  window.addEventListener('farm:cloud-session-changed', () => {
    if (!canChat()) { stopRealtime(); activeUser = null; profile = null; list.replaceChildren(); if (!panel.hidden) showLoginPrompt(); }
    else { try { Promise.resolve(client.realtime.setAuth(api.accessToken())).catch(() => {}); } catch { /* The next channel join will fetch the current token. */ } if (!panel.hidden) connect().catch(() => {}); }
  });
  window.addEventListener('game:language-changed', () => {
    $('.global-chat-head strong').textContent = t('title'); $('.global-chat-send').textContent = t('send'); input.placeholder = t('placeholder');
    if (status.dataset.kind === 'ready') setStatus(t('ready'), 'ready');
  });
  window.addEventListener('beforeunload', () => { if (channel) client.removeChannel(channel); });
})();
