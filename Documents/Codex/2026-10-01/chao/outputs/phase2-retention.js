(() => {
  'use strict';

  const api = window.__phase2Api;
  if (!api) return;
  const rpc = (name, payload = {}) => api.rpc(name, payload);
  const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch]);
  const number = value => new Intl.NumberFormat('vi-VN').format(Math.max(0, Number(value) || 0));
  const requestId = scope => {
    const user = api.userId() || 'guest';
    const key = `vuonnho_phase2_request_${user}_${scope}`;
    let value = localStorage.getItem(key);
    if (!value) {
      value = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(16).slice(2)}-${Math.random().toString(16).slice(2)}`;
      localStorage.setItem(key, value);
    }
    return { key, value };
  };
  const forgetRequest = key => localStorage.removeItem(key);
  const style = document.createElement('style');
  style.textContent = `.p2-tabs{display:flex;gap:6px;overflow:auto;padding:3px 1px 8px;position:sticky;top:-10px;background:#fffdf4;z-index:2}.p2-tabs button,.p2-row button{border:1px solid #d9e2cf;border-radius:9px;background:#f3f6e9;color:#344b37;padding:8px 10px;font:700 12px system-ui;white-space:nowrap}.p2-tabs button.active{background:#54865c;color:white}.p2-list{display:grid;gap:8px}.p2-row{display:flex;gap:10px;align-items:center;justify-content:space-between;border:1px solid #e3e2cf;border-radius:11px;background:#fffefa;padding:10px}.p2-row-main{min-width:0;flex:1}.p2-row strong{display:block;font-size:13px}.p2-row small{display:block;color:#73806b;margin-top:3px;line-height:1.4}.p2-row button{background:#54865c;color:white}.p2-row button:disabled{opacity:.48}.p2-note{border-radius:9px;background:#f2f4e8;padding:9px;color:#596c54;font-size:12px;line-height:1.5}.p2-loading{padding:20px;text-align:center;color:#64755e}`;
  document.head.appendChild(style);

  const tabs = [
    ['daily', '📋 Ngày'], ['weekly', '🗓️ Tuần'], ['checkin', '🎁 Điểm danh'],
    ['achievements', '🏅 Thành tích'], ['collection', '📖 Sưu tập']
  ];
  let activeTab = 'daily';
  let renderGeneration = 0;
  let autoCheckinAttempted = false;
  let autoCheckinWaitingForGardenName = false;

  function frame(tab, content) {
    const nav = tabs.map(([key, label]) => `<button type="button" role="tab" aria-selected="${key === tab}" class="${key === tab ? 'active' : ''}" data-p2-tab="${key}">${label}</button>`).join('');
    return `<div class="p2-tabs" role="tablist">${nav}</div><div id="p2-content">${content}</div>`;
  }
  function showLoading() {
    api.openModal('🌱 Nhiệm vụ & phần thưởng', frame(activeTab, '<div class="p2-loading" role="status">Đang tải dữ liệu từ máy chủ…</div>'));
    bindTabs();
  }
  function showError(error) {
    const message = String(error?.message || error || 'Lỗi kết nối').slice(0, 220);
    const isLegacySave = /legacy_farm|legacy farm detected/i.test(message);
    const hint = /function .* does not exist|could not find the function|schema cache|404/i.test(message)
      ? 'Migration của mục này chưa có trên Supabase. Hãy áp dụng các migration Giai đoạn 2 lên staging trước.'
      : isLegacySave
        ? 'Tìm thấy save cũ trên tài khoản. Sau khi áp dụng migration 013 lên Supabase và cập nhật web, bạn có thể chuyển một lần sang dữ liệu máy chủ; bản save gốc được giữ nguyên. Cây đang lớn và lượt vật nuôi đang tạo sản phẩm sẽ tính lại từ lúc chuyển đổi.'
        : /canonical .* not initialized|not initialized/i.test(message)
          ? 'Dữ liệu chuẩn của máy chủ chưa được khởi tạo. Save cũ vẫn được giữ nguyên.'
        : 'Không có thay đổi nào được ghi nhận ở giao dịch này. Kiểm tra kết nối rồi thử lại.';
    const content = `<p class="p2-note">${escapeHtml(hint)}</p><p class="shopmsg">${escapeHtml(message)}</p>${isLegacySave ? '<button class="buy" id="p2Migrate">Chuyển save cũ sang máy chủ</button>' : ''} <button class="buy" id="p2Retry">Thử tải lại</button>`;
    api.body().innerHTML = frame(activeTab, content);
    bindTabs();
    document.getElementById('p2Retry')?.addEventListener('click', () => loadTab(activeTab));
    document.getElementById('p2Migrate')?.addEventListener('click', migrateLegacySave);
  }
  async function migrateLegacySave(event) {
    const button = event.currentTarget;
    if (!window.confirm('Chuyển duy nhất save đang lưu trên máy chủ cho tài khoản này? Save gốc sẽ được giữ nguyên. Xu, XP, kho đồ, luống và vật nuôi sẽ được nhập; cây đang lớn và lượt vật nuôi đang chạy sẽ khởi động lại theo thời gian máy chủ.')) return;
    button.disabled = true;
    button.textContent = 'Đang chuyển save…';
    try {
      const result = await rpc('migrate_legacy_save_v2');
      const summary = Array.isArray(result) ? result[0] : result;
      api.body().innerHTML = frame(activeTab, `<p class="p2-note">Đã chuyển save thành công. ${number(summary?.coins)} xu · ${number(summary?.xp)} XP · ${number(summary?.animals)} vật nuôi · ${number(summary?.planted_plots)} luống đang trồng. Save gốc vẫn được giữ nguyên.</p><p class="p2-note">Đang tải lại game để đọc dữ liệu mới…</p>`);
      window.setTimeout(() => window.location.reload(), 1100);
    } catch (error) {
      button.disabled = false;
      button.textContent = 'Thử chuyển lại';
      const note = document.createElement('p');
      note.className = 'p2-note';
      note.textContent = String(error?.message || error).slice(0, 220);
      api.body().append(note);
    }
  }
  function bindTabs() {
    document.querySelectorAll('[data-p2-tab]').forEach(button => button.addEventListener('click', () => loadTab(button.dataset.p2Tab)));
  }
  function rows(items, render) { return `<div class="p2-list">${items.map(render).join('') || '<p class="p2-note">Chưa có dữ liệu.</p>'}</div>`; }
  function reward(coins, xp) { return `🪙 ${number(coins)} xu · ⭐ ${number(xp)} XP`; }
  function actionRow(title, detail, button, disabled = false) {
    return `<article class="p2-row"><div class="p2-row-main"><strong>${escapeHtml(title)}</strong><small>${escapeHtml(detail)}</small></div>${button ? `<button type="button" ${disabled ? 'disabled' : ''} data-p2-action="${escapeHtml(button.action)}" data-p2-id="${escapeHtml(button.id)}">${escapeHtml(button.label)}</button>` : ''}</article>`;
  }
  async function loadTab(tab) {
    if (!tabs.some(([key]) => key === tab)) return;
    activeTab = tab;
    const generation = ++renderGeneration;
    showLoading();
    try {
      if (!api.session() || !api.ready()) throw new Error('Hãy đăng nhập và đồng bộ tài khoản trước khi dùng tính năng trực tuyến.');
      if (!await api.canonicalReady()) throw new Error('LEGACY_FARM: Tài khoản đang dùng save cũ chưa được chuyển sang dữ liệu chuẩn của máy chủ. Game giữ nguyên save; chưa tự nhập hoặc thưởng dựa trên dữ liệu đó.');
      let html = '';
      if (tab === 'daily') {
        const result = await rpc('get_my_daily_quests_v2');
        const quests = Array.isArray(result) ? result : result?.quests || [];
        html = rows(quests, q => {
          const claimed = !!q.claimed_at;
          const done = Number(q.progress) >= Number(q.target);
          return actionRow(q.title || q.quest_id, `${number(q.progress)} / ${number(q.target)} · ${reward(q.reward_coins, q.reward_xp)}${claimed ? ' · Đã nhận' : ''}`, !claimed && done ? { action: 'claim-daily', id: q.quest_id, label: 'Nhận' } : null, false);
        });
      } else if (tab === 'weekly') {
        const result = await rpc('get_my_weekly_quests_v2');
        html = rows(result?.quests || [], q => {
          const claimed = !!q.claimed_at, done = Number(q.progress) >= Number(q.target), locked = !!q.locked;
          const label = claimed ? 'Đã nhận' : locked ? 'Đang khóa' : done ? 'Nhận' : '';
          return actionRow(`Bước ${number(q.chain_step)} · ${q.title || q.quest_id}`, `${number(q.progress)} / ${number(q.target)} · ${reward(q.reward_coins, q.reward_xp)}`, label && !claimed && !locked && done ? { action: 'claim-weekly', id: q.quest_id, label } : null);
        });
      } else if (tab === 'checkin') {
        const result = await rpc('get_my_daily_checkin_v2');
        const rewardData = result?.reward || {};
        const goods = rewardData.item_key ? ` · ${escapeHtml(rewardData.item_key)} × ${number(rewardData.item_quantity)}` : '';
        const detail = `${result?.claimed_today ? 'Đã điểm danh hôm nay' : 'Phần thưởng hôm nay'} · Ngày ${number(result?.streak_day)} · ${reward(rewardData.coins, rewardData.xp)}${goods}`;
        html = `<div class="p2-note">Ngày tính theo giờ Việt Nam (Asia/Ho_Chi_Minh), không theo đồng hồ thiết bị.</div>${rows([1], () => actionRow('Điểm danh hằng ngày', detail, result?.claimed_today ? null : { action: 'claim-checkin', id: 'today', label: 'Nhận quà' }))}`;
      } else if (tab === 'achievements') {
        const result = await rpc('get_my_achievements_v2');
        html = rows(result?.achievements || [], item => {
          const claimed = !!item.claimed_at, done = !!item.unlocked_at && Number(item.progress) >= Number(item.target);
          return actionRow(item.title, `${item.description || ''} · ${number(item.progress)} / ${number(item.target)} · ${reward(item.reward_coins, item.reward_xp)}${claimed ? ' · Đã nhận' : ''}`, done && !claimed ? { action: 'claim-achievement', id: item.achievement_id, label: 'Nhận' } : null);
        });
      } else {
        const result = await rpc('get_my_collection_v2');
        const items = result?.collections || [];
        const discovered = items.filter(item => item.discovered).length;
        html = `<p class="p2-note">Đã khám phá ${number(discovered)} / ${number(items.length)} mục. Dữ liệu lịch sử trong s.collections được giữ nguyên và không tự đổi thành phần thưởng.</p>${rows(items, item => actionRow(item.discovered ? '✅ ' + item.display_name : '🔒 Chưa khám phá', `${item.category} · ${item.discovered ? 'Đã ghi nhận' : 'Hãy khám phá trong game'}`))}`;
      }
      if (generation !== renderGeneration) return;
      api.body().innerHTML = frame(tab, html);
      bindTabs();
      bindActions();
    } catch (error) {
      if (generation === renderGeneration) showError(error);
    }
  }
  function bindActions() {
    document.querySelectorAll('[data-p2-action]').forEach(button => button.addEventListener('click', () => perform(button)));
  }
  async function perform(button) {
    if (button.disabled) return;
    const action = button.dataset.p2Action, id = button.dataset.p2Id;
    const specs = {
      'claim-daily': ['claim_daily_quest_v2', { p_quest_id: id }, `daily_${id}`],
      'claim-weekly': ['claim_weekly_quest_v2', { p_quest_id: id }, `weekly_${id}`],
      'claim-checkin': ['claim_daily_checkin_v2', {}, 'checkin'],
      'claim-achievement': ['claim_achievement_v2', { p_achievement_id: id }, `achievement_${id}`]
    }[action];
    if (!specs) return;
    const [name, args, scope] = specs, req = requestId(scope);
    button.disabled = true;
    button.textContent = 'Đang xử lý…';
    try {
      await rpc(name, { ...args, p_request_id: req.value });
      forgetRequest(req.key);
      await loadTab(activeTab);
    } catch (error) {
      button.disabled = false;
      button.textContent = 'Thử lại';
      const note = document.createElement('p');
      note.className = 'p2-note';
      note.textContent = `${String(error?.message || error).slice(0, 180)}. Mã yêu cầu được giữ để lần thử lại không nhận thưởng hai lần.`;
      api.body().prepend(note);
    }
  }
  function open() {
    if (!api.session() || !api.ready()) {
      api.openModal('🌱 Nhiệm vụ & phần thưởng', '<p class="p2-note">Hãy đăng nhập và đồng bộ tài khoản trước khi dùng các tính năng trực tuyến.</p><button class="buy" id="p2CloudLogin">Mở đăng nhập</button>');
      document.getElementById('p2CloudLogin')?.addEventListener('click', () => { api.closeModal(); document.getElementById('cloudSync')?.click(); });
      return;
    }
    loadTab(activeTab);
  }
  async function maybeOpenUnclaimedCheckin() {
    if (!api.session() || !api.ready() || autoCheckinAttempted) return;
    if (document.getElementById('gardenNameInput')) {
      autoCheckinWaitingForGardenName = true;
      return;
    }
    autoCheckinWaitingForGardenName = false;
    autoCheckinAttempted = true;
    try {
      const result = await rpc('get_my_daily_checkin_v2');
      if (result && !result.claimed_today && api.session() && api.ready()) {
        activeTab = 'checkin';
        await loadTab('checkin');
      }
    } catch (error) {
      // Keep the game usable if the check-in status cannot be fetched; the player can open it manually.
      console.warn('Không thể kiểm tra thưởng điểm danh tự động:', error);
    }
  }
  window.addEventListener('farm:game-ready', maybeOpenUnclaimedCheckin);
  window.addEventListener('farm:garden-name-saved', () => {
    if (autoCheckinWaitingForGardenName) maybeOpenUnclaimedCheckin();
  });
  document.getElementById('phase2Retention')?.addEventListener('click', open);
})();
