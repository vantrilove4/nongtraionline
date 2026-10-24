(() => {
  'use strict';

  const preferenceKey = 'vuonnho_language_preference';
  const initialPreference = localStorage.getItem(preferenceKey);
  if (initialPreference && initialPreference !== 'vi' && initialPreference !== 'en') localStorage.removeItem(preferenceKey);
  let language = initialPreference === 'vi' || initialPreference === 'en'
    ? initialPreference
    : 'en';

  const translations = [
    ['💬 Chat chung', '💬 Global Chat'], ['Mở chat chung', 'Open global chat'], ['Thu nhỏ chat', 'Minimize chat'],
    ['Đăng nhập để tham gia chat chung.', 'Log in to join the global chat.'], ['Đang tải tin nhắn…', 'Loading messages…'],
    ['Chat chung · mọi người đều có thể xem', 'Global chat · visible to everyone'], ['Chưa kết nối được. Chạm để thử lại.', 'Could not connect. Tap to retry.'],
    ['Viết tin nhắn…', 'Write a message…'], ['Gửi', 'Send'], ['Chưa có tin nhắn. Hãy chào mọi người nhé!', 'No messages yet. Say hello!'],
    ['Thử tải lại', 'Reload'], ['Báo cáo', 'Report'], ['Chặn người chơi', 'Block player'], ['Đã chặn người chơi này.', 'This player has been blocked.'],
    ['Lý do báo cáo', 'Report reason'], ['Quấy rối', 'Harassment'], ['Không phù hợp', 'Inappropriate'],
    ['Tin nhắn tối đa 300 ký tự.', 'Messages can contain up to 300 characters.'], ['Đang gửi…', 'Sending…'],
    ['Mất kết nối chat. Đang thử kết nối lại…', 'Chat disconnected. Reconnecting…'],
    ['Đã gửi báo cáo để quản trị viên xem xét.', 'Report sent for moderator review.'],
    ['Nhiệm vụ & phần thưởng', 'Quests & Rewards'], ['Bảng xếp hạng', 'Leaderboard'], ['Người giao nhiệm vụ', 'Quest giver'], ['5 nhiệm vụ', '5 quests'], ['Chào bạn nhé! Anh Trí sẽ quay lại sau 30 phút.', 'Goodbye! Anh Tri will be back in 30 minutes.'], ['Hẹn gặp lại', 'See you again'],
    ['Chợ người chơi', 'Player Market'], ['Thông tin mới cập nhật', 'What’s New'],
    ['Thời gian vật nuôi', 'Animal production time'], ['Thời gian cây trồng', 'Crop growing time'],
    ['Vật phẩm thu hoạch', 'Harvested items'], ['Nhân vật', 'Character'], ['Nông trại', 'Farm'],
    ['Đang chuẩn bị nông trại của bạn…', 'Preparing your farm…'],
    ['Đang tải hình ảnh và khu vườn', 'Loading images and garden'],
    ['Nông trại đã sẵn sàng!', 'Your farm is ready!'],
    ['Chơi không cần đăng nhập', 'Play as guest'], ['Tiến trình khách được lưu trên thiết bị này.', 'Guest progress is saved on this device.'],
    ['Chưa đăng nhập', 'Not signed in'], ['Đăng nhập để đồng bộ khi đổi máy hoặc trình duyệt.', 'Sign in to sync across devices and browsers.'],
    ['Hãy khám phá trong game', 'Explore in the game'], ['Đã nhận hôm nay', 'Already claimed today'],
    ['Phần thưởng hôm nay', "Today's reward"], ['Chưa có dữ liệu.', 'No data yet.'],
    ['Đã khám phá', 'Discovered'], ['Chưa khám phá', 'Not discovered'], ['Đang khóa', 'Locked'],
    ['Giao hàng', 'Deliver order'], ['Đã giao', 'Delivered'], ['Bước', 'Step'], ['Nhận quà', 'Claim reward'],
    ['Khu chăn nuôi', 'Animal area'], ['Cây trồng', 'Crops'], ['Vật nuôi', 'Livestock'],
    ['Hạt giống', 'Seeds'], ['Thức ăn', 'Feed'], ['Cửa hàng', 'Shop'], ['Túi đồ', 'Inventory'],
    ['Xếp hạng', 'Rankings'], ['Chợ', 'Market'], ['Túi', 'Bag'], ['Bật', 'On'], ['Tắt', 'Off'],
    ['Đăng nhập', 'Log in'], ['Đăng xuất', 'Log out'],
    ['Đồng bộ', 'Sync'], ['Điểm danh', 'Daily check-in'], ['Thành tích', 'Achievements'],
    ['Sưu tập', 'Collection'], ['Nhiệm vụ', 'Quests'], ['Phần thưởng', 'Rewards'],
    ['Nhật ký', 'Journal'], ['Hướng dẫn', 'Guide'], ['Toàn màn hình', 'Fullscreen'],
    ['🌱 Làm quen với Vườn Nhỏ', '🌱 Welcome to Little Garden'], ['🎉 Tính năng mới đã mở', '🎉 A new feature is unlocked'],
    ['Đi lại trong nông trại', 'Moving around the farm'], ['Chạm vào đường đi để nhân vật tự di chuyển. Trên máy tính, dùng WASD hoặc phím mũi tên; trên điện thoại, dùng cụm phím điều hướng.', 'Tap a path to move your character. On a computer, use WASD or the arrow keys; on a phone, use the directional pad.'],
    ['Trồng và chăm cây', 'Plant and care for crops'], ['Đến gần luống rồi nhấn E hoặc nút thao tác. Cuốc đất, chọn hạt trong Túi, gieo hạt, tưới cây và thu hoạch khi cây chín.', 'Go near a plot and press E or the action button. Till the soil, choose seeds from Inventory, plant, water, and harvest when ripe.'],
    ['Cửa hàng và túi đồ', 'The shop and inventory'], ['Dùng xu mua hạt giống và thức ăn trong Cửa hàng. Nông sản thu hoạch được cất vào Túi, nơi bạn có thể bán để nhận xu và XP.', 'Spend coins on seeds and feed in the Shop. Harvested produce goes into Inventory, where you can sell it for coins and XP.'],
    ['Chăm vật nuôi', 'Care for livestock'], ['Mở khóa khu nuôi theo cấp, mua con giống trong Cửa hàng, rồi dùng đúng loại thức ăn ở máng. Sản phẩm sẽ sẵn sàng để thu tại máng nhận.', 'Unlock animal areas by leveling up, buy animals in the Shop, and use the right feed at each trough. Collect products from the collection station when they are ready.'],
    ['Nhiệm vụ và lưu tiến trình', 'Quests and saving progress'], ['Mở Nhiệm vụ để xem mục tiêu và phần thưởng. Tiến trình khách lưu trên thiết bị; đăng nhập để đồng bộ nông trại khi đổi thiết bị.', 'Open Quests to see goals and rewards. Guest progress is saved on this device; sign in to sync your farm across devices.'],
    ['Đã mở khu gà!', 'Chicken area unlocked!'], ['Đến khu gà và mở Cửa hàng để mua gà. Mua cám gà, cho ăn tại máng; khi sẵn sàng, thu trứng ở máng nhận sản phẩm.', 'Visit the chicken area and open the Shop to buy chickens. Buy chicken feed and feed them at the trough; collect eggs from the collection station when ready.'],
    ['Đã mở khu heo!', 'Pig area unlocked!'], ['Khu heo đã mở. Mua heo và cám heo trong Cửa hàng; cho ăn ở máng riêng rồi quay lại thu sản phẩm khi hoàn tất.', 'The pig area is open. Buy pigs and pig feed in the Shop, feed them at their trough, then return to collect their products.'],
    ['Đã mở khu bò!', 'Cow area unlocked!'], ['Khu bò đã mở. Mua bò và cỏ khô bò trong Cửa hàng; cho ăn tại máng bò và thu sữa ở máng nhận.', 'The cow area is open. Buy cows and hay in the Shop, feed them at the cow trough, and collect milk at the collection station.'],
    ['Đã mở ao cá!', 'Fish pond unlocked!'], ['Ao cá đã mở. Mua cá và thức ăn cá trong Cửa hàng, cho ăn tại hồ rồi thu cá khi sản phẩm sẵn sàng.', 'The fish pond is open. Buy fish and fish feed in the Shop, feed them at the pond, and collect fish when ready.'],
    ['Đất trồng được mở rộng', 'More land unlocked'], ['Bạn đã mở thêm đất trồng. Hãy khám phá các luống mới và dùng hạt giống phù hợp với cấp hiện tại.', 'You have unlocked more farmland. Explore the new plots and use seeds available at your current level.'],
    ['HƯỚNG DẪN', 'GUIDE'], ['Để sau', 'Later'], ['Bắt đầu chơi', 'Start playing'], ['Tiếp theo', 'Next'],
    ['Túi nông trại', 'Farm Inventory'], ['Chợ nông trại', 'Farm Market'], ['Cửa hàng nông trại', 'Farm Shop'],
    ['Chọn hạt giống', 'Choose seeds'], ['Chọn nhân vật', 'Choose a character'],
    ['Giao diện', 'Area skins'], ['🏡 Giao diện', '🏡 Area skins'],
    ['Vườn Mộc', 'Woodland Garden'], ['Chuồng Mộc', 'Woodland Livestock'],
    ['Luống gỗ chạm hoa, hàng rào xanh, góc tưới nước và quầy dụng cụ.', 'Ornate wooden beds, green fencing, an irrigation corner, and a garden tool stall.'],
    ['Luống trồng cây gỗ mới; giữ nguyên hàng rào và cảnh quan khu vườn.', 'New wooden planting beds; the existing garden fences and scenery stay the same.'],
    ['Chuồng gỗ đá, máng riêng, bàn thu sản phẩm và hồ cá viền đá.', 'Wood-and-stone shelters, dedicated troughs, collection tables, and a stone-edged fish pond.'],
    ['Mua một lần, dùng lâu dài. Mỗi giao diện có thể trang bị hoặc đổi lại bất cứ lúc nào.', 'Buy once and keep it. Equip or switch each area skin whenever you like.'],
    ['Đã sở hữu', 'Owned'], ['Trang bị', 'Equip'], ['Mua giao diện', 'Buy skin'], ['Đang dùng', 'Equipped'], ['Về giao diện cũ', 'Restore classic look'],
    ['Không yêu cầu cấp độ. Mua bằng xu một lần; có thể đổi giao diện hoặc quay về giao diện cũ bất cứ lúc nào.', 'No level requirement. Buy once with coins; switch skins or restore the classic look at any time.'],
    ['Đã chuyển khu vườn về giao diện cũ.', 'Restored the classic garden look.'], ['Đã chuyển khu chăn nuôi về giao diện cũ.', 'Restored the classic livestock look.'],
    ['Khu vườn', 'Garden'], ['khu vườn', 'garden'], ['khu nuôi', 'animal area'], ['Nông trại', 'Farm'],
    ['Hạt & thức ăn', 'Seeds & feed'], ['Chế biến', 'Crafting'], ['Đơn hàng', 'Orders'],
    ['Tự nhận ngôn ngữ theo vị trí mạng', 'Detect language from network location'], ['Tự động theo IP', 'Auto-detect by IP'],
    ['Người làm vườn đội nón gắn mầm non, lái máy kéo xanh', 'A gardener in a sprout hat, riding a green tractor'],
    ['Nông dân xe kéo', 'Tractor Farmer'], ['Lá Non', 'Green Sprout'],
    ['Cài đặt', 'Settings'], ['Tiện ích', 'Settings'], ['📱 Tải phiên bản điện thoại', '📱 Download Android version'], ['Số lượng', 'Quantity'], ['Số bán', 'Quantity to sell'], ['Giá mỗi món', 'Price per item'],
    ['Mở ở cấp', 'Unlocks at level'], ['Mở khu ở cấp', 'Area unlocks at level'],
    ['Mở khóa', 'Unlock'], ['Đã mở khóa', 'Unlocked'], ['Chưa mở khóa', 'Locked'],
    ['Đang dùng', 'Equipped'], ['Chọn', 'Select'], ['Mua', 'Buy'], ['Bán', 'Sell'],
    ['Thu hoạch', 'Harvest'], ['Gieo hạt', 'Plant'], ['Cuốc đất', 'Till soil'], ['Máng ăn', 'Feed trough'],
    ['Tưới cây', 'Water crops'], ['Cho ăn', 'Feed animals'], ['Chế biến', 'Craft'],
    ['Có:', 'In bag:'], ['còn', 'left'], ['Còn', 'Left'], ['thiếu', 'need'], ['Thiếu', 'Need'],
    ['xu', 'coins'], ['XP', 'XP'], ['cấp', 'level'], ['Cấp', 'Level'], ['ngày', 'day'],
    ['Ngày', 'Day'], ['phút', 'min'], ['giây', 'sec'], ['món', 'items'], ['hạt', 'seeds'],
    ['phần', 'portions'], ['con', 'animals'], ['mùa', 'season'], ['Mùa', 'Season'],
    ['nhanh', 'faster'], ['chậm', 'slower'], ['nhịp thường', 'normal pace'],
    ['Xuân', 'Spring'], ['Hạ', 'Summer'], ['Thu', 'Autumn'], ['Đông', 'Winter'],
    ['Cà rốt', 'Carrot'], ['Cà chua', 'Tomato'], ['Khoai tây', 'Potato'], ['Bắp ngô', 'Corn'],
    ['Bí đỏ', 'Pumpkin'], ['Dâu tây', 'Strawberry'], ['Hoa hướng dương', 'Sunflower'],
    ['Dưa hấu', 'Watermelon'], ['Cà tím', 'Eggplant'], ['Thơm', 'Pineapple'], ['Nho', 'Grapes'],
    ['Trứng gà', 'Eggs'], ['Sữa bò', 'Milk'], ['Thịt heo', 'Pork'], ['Cá tươi', 'Fresh fish'],
    ['Sữa chua dâu', 'Strawberry yogurt'], ['Bánh bí đỏ', 'Pumpkin pie'], ['Súp cá bắp', 'Corn fish soup'],
    ['Xúc xích bắp', 'Corn sausage'], ['Cám gà', 'Chicken feed'], ['Cám heo', 'Pig feed'],
    ['Cỏ khô bò', 'Cow hay'], ['Thức ăn cá', 'Fish feed'], ['khu gà', 'Chicken coop'],
    ['Khu gà', 'Chicken coop'], ['khu bò', 'Cow barn'], ['Khu bò', 'Cow barn'],
    ['khu heo', 'Pig pen'], ['Khu heo', 'Pig pen'], ['khu cá', 'Fish pond'], ['Khu cá', 'Fish pond'],
    ['Chưa đủ xu', 'Not enough coins'], ['Đã mua', 'Purchased'], ['Đã bán', 'Sold'],
    ['Mở xưởng', 'Open workshop'], ['Chọn hạt để gieo', 'Choose seeds to plant'],
    ['Đã chín', 'is ripe'], ['Đang lớn', 'is growing'], ['Đang chờ thu hoạch', 'Waiting for harvest'],
    ['Sản phẩm đã sẵn sàng', 'Products are ready'], ['Hãy chờ thêm chút', 'Please wait a little longer'],
    ['Chạm nền để đi', 'Tap the ground to move'], ['Chạm vào luống đất', 'Tap a plot'],
    ['nhấn nút', 'press the button'], ['Nhấn nút', 'Press the button'], ['nhấn E', 'press E'],
    ['Đi đến', 'Go to'], ['để mở', 'to unlock'], ['để đi', 'to move'], ['mỗi lượt', 'per round'],
    ['mỗi món', 'per item'], ['mỗi con', 'per animal'], ['Tổng thức ăn', 'Total feed'],
    ['Mua hạt giống', 'Buy seeds'], ['Mua con', 'Buy animal'], ['Bán sản phẩm', 'Sell items'],
    ['Đã thu hoạch', 'Harvested'], ['Thu hoạch thành công', 'Harvest successful'],
    ['Đã tưới cây', 'Crops watered'], ['Đã gieo', 'Planted'], ['Đã cho vật nuôi ăn', 'Animals fed'],
    ['Đã nhận', 'Claimed'], ['Đã nhận quà', 'Reward claimed'], ['Đang thực hiện', 'In progress'],
    ['Đang tải', 'Loading'], ['Đang xử lý', 'Processing'], ['Thử tải lại', 'Try again'],
    ['Chưa có', 'No'], ['Chưa đủ', 'Not enough'], ['Còn:', 'Remaining:'], ['Đang', 'Current'],
    ['Nông trại của', 'Farm of'], ['Nông sản', 'Produce'], ['Hàng hóa', 'Goods'],
    ['Nhạc: bật', 'Music: on'], ['Nhạc: tắt', 'Music: off'],
    ['Thử lại', 'Retry'], ['Xong', 'Done'], ['Đóng', 'Close'], ['Lưu', 'Save'], ['Hủy', 'Cancel'],
    ['Nhập số lượng rồi chọn Mua.', 'Enter a quantity, then choose Buy.'],
    ['Chọn số lượng rồi nhấn Bán để bán sản phẩm.', 'Choose a quantity, then select Sell.'],
    ['Không có thay đổi nào được ghi nhận ở giao dịch này. Kiểm tra kết nối rồi thử lại.', 'No changes were recorded for this transaction. Check your connection and try again.'],
    ['Ngày tính theo giờ Việt Nam (Asia/Ho_Chi_Minh), không theo đồng hồ thiết bị.', 'Days use Vietnam time (Asia/Ho_Chi_Minh), not the device clock.'],
    ['VƯỜN NHỎ', 'LITTLE GARDEN'], ['Vườn Nhỏ', 'Little Garden'], ['Menu', 'Menu']
  ].sort((a, b) => b[0].length - a[0].length);

  function translate(value) {
    let result = String(value ?? '');
    if (language !== 'en') return result;
    for (const [source, target] of translations) result = result.replaceAll(source, target);
    return result;
  }
  window.gameTranslate = translate;

  const sourceText = new WeakMap();
  const appliedText = new WeakMap();
  const sourceAttributes = new WeakMap();
  const appliedAttributes = new WeakMap();
  function translateTextNode(node) {
    const current = node.nodeValue;
    if (!sourceText.has(node) || current !== appliedText.get(node)) sourceText.set(node, current);
    const next = language === 'en' ? translate(sourceText.get(node)) : sourceText.get(node);
    if (current !== next) node.nodeValue = next;
    appliedText.set(node, next);
  }
  function translateAttribute(element, attr) {
    const current = element.getAttribute(attr);
    let originals = sourceAttributes.get(element);
    if (!originals) { originals = new Map(); sourceAttributes.set(element, originals); }
    let applied = appliedAttributes.get(element);
    if (!applied) { applied = new Map(); appliedAttributes.set(element, applied); }
    if (!originals.has(attr) || current !== applied.get(attr)) originals.set(attr, current);
    const next = language === 'en' ? translate(originals.get(attr)) : originals.get(attr);
    if (current !== next) element.setAttribute(attr, next);
    applied.set(attr, next);
  }

  function translateNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      translateTextNode(node);
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE || /^(SCRIPT|STYLE|NOSCRIPT)$/.test(node.tagName)) return;
    for (const attr of ['title', 'aria-label', 'placeholder', 'alt']) {
      if (node.hasAttribute(attr)) translateAttribute(node, attr);
    }
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    const textNodes = [];
    while (walker.nextNode()) textNodes.push(walker.currentNode);
    textNodes.forEach(translateNode);
    node.querySelectorAll?.('[title],[aria-label],[placeholder],[alt]').forEach(child => translateNode(child));
  }

  function applyLanguage() {
    document.documentElement.lang = language;
    translateNode(document.body);
    const button = document.getElementById('languageToggle');
    if (button) {
      const manual = localStorage.getItem(preferenceKey);
      button.textContent = manual
        ? (language === 'vi' ? '🌐 Ngôn ngữ: Tiếng Việt' : '🌐 Language: English')
        : (language === 'vi' ? '🌐 Tự động: Tiếng Việt' : '🌐 Auto: English');
      button.title = language === 'vi' ? 'Đổi sang English' : 'Switch to Tiếng Việt';
      button.setAttribute('aria-label', button.title);
    }
    window.dispatchEvent(new CustomEvent('game:language-changed', { detail: { language } }));
  }

  const observer = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes' || record.type === 'characterData') translateNode(record.target);
      else record.addedNodes.forEach(translateNode);
    }
  });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['title', 'aria-label', 'placeholder', 'alt'] });

  if (window.CanvasRenderingContext2D) {
    const proto = CanvasRenderingContext2D.prototype;
    const originalFillText = proto.fillText;
    const originalStrokeText = proto.strokeText;
    const originalMeasureText = proto.measureText;
    proto.fillText = function (text, ...args) { return originalFillText.call(this, translate(text), ...args); };
    proto.strokeText = function (text, ...args) { return originalStrokeText.call(this, translate(text), ...args); };
    proto.measureText = function (text) { return originalMeasureText.call(this, translate(text)); };
  }

  document.getElementById('languageToggle')?.addEventListener('click', () => {
    language = language === 'vi' ? 'en' : 'vi';
    localStorage.setItem(preferenceKey, language);
    applyLanguage();
  });

  document.getElementById('languageAuto')?.addEventListener('click', () => {
    localStorage.removeItem(preferenceKey);
    language = 'en';
    applyLanguage();
    detectLanguageByIp();
  });

  async function detectLanguageByIp() {
    if (localStorage.getItem(preferenceKey) === 'vi' || localStorage.getItem(preferenceKey) === 'en') return;
    const cacheKey = 'vuonnho_ip_language_cache';
    try {
      const cache = JSON.parse(localStorage.getItem(cacheKey) || 'null');
      if (cache?.country && Date.now() - Number(cache.checkedAt) < 86400000) {
        if (localStorage.getItem(preferenceKey) === 'vi' || localStorage.getItem(preferenceKey) === 'en') return;
        language = cache.country === 'VN' ? 'vi' : 'en';
        applyLanguage();
        return;
      }
    } catch { /* Ignore an invalid language cache and check the current connection. */ }
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3500);
    try {
      const response = await fetch('https://ipwho.is/?fields=success,country_code', { signal: controller.signal, cache: 'no-store' });
      if (!response.ok) throw new Error('IP language lookup failed');
      const data = await response.json();
      if (!data?.success || !data?.country_code) throw new Error('IP country was unavailable');
      const country = String(data.country_code).toUpperCase();
        if (localStorage.getItem(preferenceKey) === 'vi' || localStorage.getItem(preferenceKey) === 'en') return;
      localStorage.setItem(cacheKey, JSON.stringify({ country, checkedAt: Date.now() }));
      language = country === 'VN' ? 'vi' : 'en';
      applyLanguage();
    } catch (error) {
      // English is the deterministic fallback when the IP country cannot be resolved.
      console.info('Using English because IP language lookup was unavailable:', error);
    } finally {
      clearTimeout(timeout);
    }
  }

  applyLanguage();
  detectLanguageByIp();
})();
