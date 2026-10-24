(() => {
  'use strict';

  const FIRST_RUN_STEPS = [
    { title: 'Đi lại trong nông trại', body: 'Chạm vào đường đi để nhân vật tự di chuyển. Trên máy tính, dùng WASD hoặc phím mũi tên; trên điện thoại, dùng cụm phím điều hướng.' },
    { title: 'Trồng và chăm cây', body: 'Đến gần luống rồi nhấn E hoặc nút thao tác. Cuốc đất, chọn hạt trong Túi, gieo hạt, tưới cây và thu hoạch khi cây chín.' },
    { title: 'Cửa hàng và túi đồ', body: 'Dùng xu mua hạt giống và thức ăn trong Cửa hàng. Nông sản thu hoạch được cất vào Túi, nơi bạn có thể bán để nhận xu và XP.' },
    { title: 'Chăm vật nuôi', body: 'Mở khóa khu nuôi theo cấp, mua con giống trong Cửa hàng, rồi dùng đúng loại thức ăn ở máng. Sản phẩm sẽ sẵn sàng để thu tại máng nhận.' },
    { title: 'Nhiệm vụ và lưu tiến trình', body: 'Mở Nhiệm vụ để xem mục tiêu và phần thưởng. Tiến trình khách lưu trên thiết bị; đăng nhập để đồng bộ nông trại khi đổi thiết bị.' }
  ];

  const UNLOCKS = [
    { level: 5, id: 'chicken', title: 'Đã mở khu gà!', body: 'Đến khu gà và mở Cửa hàng để mua gà. Mua cám gà, cho ăn tại máng; khi sẵn sàng, thu trứng ở máng nhận sản phẩm.' },
    { level: 10, id: 'pig', title: 'Đã mở khu heo!', body: 'Khu heo đã mở. Mua heo và cám heo trong Cửa hàng; cho ăn ở máng riêng rồi quay lại thu sản phẩm khi hoàn tất.' },
    { level: 15, id: 'cow', title: 'Đã mở khu bò!', body: 'Khu bò đã mở. Mua bò và cỏ khô bò trong Cửa hàng; cho ăn tại máng bò và thu sữa ở máng nhận.' },
    { level: 20, id: 'fish', title: 'Đã mở ao cá!', body: 'Ao cá đã mở. Mua cá và thức ăn cá trong Cửa hàng, cho ăn tại hồ rồi thu cá khi sản phẩm sẵn sàng.' },
    { level: 20, id: 'land-expansion', title: 'Đất trồng được mở rộng', body: 'Bạn đã mở thêm đất trồng. Hãy khám phá các luống mới và dùng hạt giống phù hợp với cấp hiện tại.' }
  ];

  const api = () => window.__farmTutorialApi;
  const pending = new Map();
  let timer = 0;
  let welcomeTimer = 0;

  function progress() {
    const current = api()?.getState?.();
    if (!current) return null;
    current.tutorialProgress ||= {};
    return current.tutorialProgress;
  }

  function finish(key) {
    const state = progress();
    if (!state) return;
    state[key] = true;
    api()?.save?.();
  }

  function isNewFarm(state) {
    return Number(state.xp || 0) === 0 && Number(state.harvested || 0) === 0 &&
      Number(state.day || 1) <= 1 && !(state.plots || []).some(plot => plot?.crop) &&
      !Object.values(state.inv || {}).some(amount => Number(amount) > 0) &&
      !Object.values(state.animalCounts || {}).some(amount => Number(amount) > 0);
  }

  function renderTutorial(key, title, steps, doneKeys = [key]) {
    let index = 0;
    const draw = () => {
      const step = steps[index];
      const dots = steps.map((_, i) => `<span aria-hidden="true" style="display:inline-block;width:7px;height:7px;margin:0 3px;border-radius:50%;background:${i === index ? '#54865c' : '#cbd8be'}"></span>`).join('');
      api()?.openModal?.(title, `<div class="tips" style="padding:4px 2px"><div style="color:#71846a;font-size:12px;font-weight:800;margin-bottom:8px">${index + 1} / ${steps.length} · HƯỚNG DẪN</div><h3 style="margin:0 0 8px;color:#31533c">${step.title}</h3><p style="line-height:1.65">${step.body}</p><div style="text-align:center;margin:12px 0">${dots}</div><div style="display:flex;gap:8px;justify-content:flex-end"><button type="button" class="buy" id="tutorialSkip">Để sau</button><button type="button" class="buy" id="tutorialNext">${index === steps.length - 1 ? 'Bắt đầu chơi' : 'Tiếp theo'}</button></div></div>`);
      document.getElementById('tutorialSkip')?.addEventListener('click', () => { doneKeys.forEach(finish); api()?.closeModal?.(); });
      document.getElementById('tutorialNext')?.addEventListener('click', () => {
        if (index < steps.length - 1) { index += 1; draw(); return; }
        doneKeys.forEach(finish);
        api()?.closeModal?.();
      });
    };
    draw();
    document.getElementById('close')?.addEventListener('click', () => doneKeys.forEach(finish), { once: true });
  }

  function showFirstRunGuide() {
    const state = api()?.getState?.();
    const seen = progress();
    if (!state || !seen || seen.firstRun || !isNewFarm(state) || !state.gardenName) return;
    if (api()?.isModalOpen?.()) { window.setTimeout(showFirstRunGuide, 450); return; }
    renderTutorial('firstRun', '🌱 Làm quen với Vườn Nhỏ', FIRST_RUN_STEPS);
  }

  function flushUnlocks() {
    timer = 0;
    if (!pending.size) return;
    if (!api()?.isGameReady?.() || api()?.isModalOpen?.()) { timer = window.setTimeout(flushUnlocks, 500); return; }
    const slides = [...pending.values()];
    pending.clear();
    renderTutorial('unlocks:' + slides.map(item => item.id).join(','), '🎉 Tính năng mới đã mở', slides, slides.map(item => 'unlock_' + item.id));
  }

  function onLevelUp(previousLevel, currentLevel, unlockedNames = []) {
    const seen = progress();
    if (!seen) return;
    for (const item of UNLOCKS) {
      if (previousLevel < item.level && currentLevel >= item.level && !seen['unlock_' + item.id]) pending.set(item.id, item);
    }
    if (pending.size && !timer) timer = window.setTimeout(flushUnlocks, 500);
  }

  function scheduleFirstRunGuide() {
    if (welcomeTimer) window.clearTimeout(welcomeTimer);
    welcomeTimer = window.setTimeout(() => { welcomeTimer = 0; showFirstRunGuide(); }, 600);
  }

  window.__farmTutorials = { showFirstRunGuide, onLevelUp };
  window.addEventListener('farm:game-ready', scheduleFirstRunGuide);
  window.addEventListener('farm:garden-name-saved', scheduleFirstRunGuide);
})();
