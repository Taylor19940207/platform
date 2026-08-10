// B-05 的呈現片段。
//
// 與 routes.ts 分開的理由跟 workbench 一樣：查詢／授權與「怎麼呈現」不該混在
// 同一個檔案；自動保存腳本尤其——它是一段有行為的資產，值得單獨被讀。

/**
 * B-05 草稿的自動保存腳本。
 *
 * 四個**會造成草稿遺失或誤顯示已保存**的情境，各自對應一段實作：
 *
 * 1. **連續輸入不得無限延後保存**——短 debounce（800ms）＋自 dirty 起算的
 *    **5 秒硬上限**。只做 debounce 的話，連續打字兩分鐘就兩分鐘不保存。
 * 2. **保存中繼續編輯不得丟資料**——每次編輯遞增 `gen`（本地編輯世代號）。
 *    回應只有在 `gen` 未再前進時才清 dirty；否則立刻補送下一版。
 *    少了它，舊請求的成功回應會把新編輯標成「已保存」。
 * 3. **提交前必須真的等到保存成功**——`ensureSaved()` 等待進行中的請求、
 *    補送最新內容，只有**伺服器確認成功**才放行送覆核／退回。
 * 4. **Session 失效不得靜默**——autosave 收到 401 時保留分頁與表單內容，
 *    顯示「尚未保存」並讓使用者另頁登入後選擇「重試保存／放棄並重載」。
 *
 * 5. **衝突不得變成請求風暴**——409 之後停止自動重送（重送不會讓過期的
 *    base 版本變新），改由使用者重新載入。只有傳輸層失敗才退避重試。
 * 6. **延遲與斷線必須看得見**——超過 W 未獲確認顯示「儲存延遲」；
 *    傳輸失敗顯示「未同步（離線）」並退避重試，`online` 事件立即重送。
 * 7. **dirty 時關閉分頁必須警告**（UX-h）——beforeunload 攔截。
 *
 * 另外兩條不變的約束：
 *   * **不使用 IndexedDB／localStorage 保存客戶財務內容**——瀏覽器端只留
 *     edit_session_id（一個 UUID）與序號。財務數字只存在伺服器與這個分頁的 DOM。
 *   * 「已保存」只在**伺服器確認**後才顯示；前端不得自行宣告。
 */
export const AUTOSAVE_WINDOW_MS = 5000;

/** 瀏覽器端狀態機原始碼。單元測試直接在 vm 沙箱執行**這個字串**，不是它的副本。 */
export const autosaveClientSource = `
(function () {
  var W = ${AUTOSAVE_WINDOW_MS};          // 確認新鮮度上限
  var f = document.getElementById("draft");
  if (!f) return;
  var st = document.getElementById("savestate"), note = document.getElementById("savenote");
  f.edit_session_id.value = crypto.randomUUID();   // 每個分頁一個編輯來源
  var seq = 0, gen = 0, savedGen = 0;
  var inflight = null, debounce = null, hardCap = null, slowTimer = null, backoff = null;
  var attempts = 0, halted = "";                   // halted：停止自動重送的原因

  function show(cls, text, detail) {
    st.className = "badge st-" + cls; st.textContent = text;
    if (detail !== undefined) note.textContent = detail;
  }
  function dirty() { return gen > savedGen; }
  function clearTimers() {
    if (debounce) { clearTimeout(debounce); debounce = null; }
    if (hardCap) { clearTimeout(hardCap); hardCap = null; }
  }
  function schedule() {
    if (halted) return;
    if (debounce) clearTimeout(debounce);
    debounce = setTimeout(function () { debounce = null; save(); }, 800);
    if (!hardCap) hardCap = setTimeout(function () { hardCap = null; save(); }, W);
  }
  function retryLater() {                          // 只有傳輸層失敗才退避重試
    attempts += 1;
    var wait = Math.min(30000, 1000 * Math.pow(2, attempts - 1));
    if (backoff) clearTimeout(backoff);
    backoff = setTimeout(function () { backoff = null; save(); }, wait);
  }

  function save() {
    if (halted) return Promise.resolve(false);
    if (inflight) return inflight;
    if (!dirty()) return Promise.resolve(true);
    clearTimers();
    var sending = gen;
    seq += 1;
    f.client_save_sequence.value = String(seq);
    show("VALIDATING", "保存中");
    slowTimer = setTimeout(function () {
      slowTimer = null;
      if (inflight) show("UPLOADED", "儲存延遲", "超過 " + (W / 1000) + " 秒未獲伺服器確認");
    }, W);
    var body = new URLSearchParams(new FormData(f));
    body.set("mode", "auto");
    inflight = fetch("/b05/save", { method: "POST", body: body,
        headers: { "content-type": "application/x-www-form-urlencoded",
                   "accept": "application/json" } })
      .then(function (r) {
        if (r.status === 401) return { s: 401, j: { kind: "SESSION_EXPIRED" } };
        return r.json().then(function (j) { return { s: r.status, j: j }; });
      })
      .then(function (r) {
        attempts = 0;
        if (r.s === 401) { halted = "SESSION_EXPIRED"; sessionLost(); return false; }
        if (r.s === 200) {
          f.base_object_version.value = String(r.j.object_version);
          if (gen === sending) {
            savedGen = sending;
            show("MATCHED", "已保存", "ov=" + r.j.object_version
              + (r.j.kind === "IDEMPOTENT_REPLAY" ? "（重送，已是最新）" : ""));
            return true;
          }
          show("UPLOADED", "未保存", "保存期間有新編輯，正在補送");
          return false;                          // 由尾端立即補送
        }
        if (r.j.kind === "VERSION_CONFLICT" || r.j.kind === "CONCURRENT_CONFLICT") {
          // 重送不會讓過期的 base 版本變新——自動重試只會變成 409 風暴
          halted = "CONFLICT";
          show("CONFLICT", "版本衝突",
            "草稿已被他人或另一分頁更新；請重新載入後再編輯，系統不會靜默覆蓋");
          return false;
        }
        if (r.j.kind === "IDEMPOTENCY_KEY_REUSED") {
          show("UPLOADED", "未保存", "序號重用，改以新序號重送");
          return false;                          // 序號已遞增，尾端補送即可
        }
        halted = "FAILED";
        show("QUARANTINED", "保存失敗", r.j.kind || "");
        return false;
      })
      .catch(function () {                        // 傳輸層失敗＝離線
        show("QUARANTINED", "未同步（離線）", "連線異常，將自動重試");
        retryLater();
        return false;
      })
      .then(function (ok) {
        inflight = null;
        if (slowTimer) { clearTimeout(slowTimer); slowTimer = null; }
        if (!ok && !halted && !backoff && dirty()) return save();
        return ok;
      });
    return inflight;
  }

  function ensureSaved() {
    if (halted) return Promise.resolve(false);
    if (!inflight && !dirty()) return Promise.resolve(true);
    return (inflight || save()).then(function (ok) {
      if (halted) return false;
      return (ok && !dirty()) ? true : (dirty() ? save() : true);
    });
  }

  function sessionLost() {
    clearTimers();
    show("QUARANTINED", "尚未保存（登入已失效）",
      "本頁內容仍在，未送出。請於另一分頁登入後選擇下方動作。");
    if (document.getElementById("resave")) return;
    var box = document.createElement("p");
    box.id = "resave";
    box.innerHTML = '<a href="/" target="_blank">另開分頁登入</a>　' +
      '<button type="button" id="btn-retry">重試保存</button>　' +
      '<button type="button" id="btn-discard">放棄並重載</button>';
    f.appendChild(box);
    document.getElementById("btn-retry").addEventListener("click", function () {
      halted = ""; save();
    });
    document.getElementById("btn-discard").addEventListener("click", function () {
      location.reload();
    });
  }

  f.addEventListener("input", function () {
    gen += 1;
    if (halted === "FAILED") halted = "";          // 內容改了，值得再試一次
    if (!halted) show("UPLOADED", "未保存");
    schedule();
  });
  f.addEventListener("focusout", function () { if (dirty()) save(); });
  document.querySelectorAll('form[action^="/b05/"]').forEach(function (other) {
    if (other === f) return;
    other.addEventListener("submit", function (e) {
      if (!dirty() && !inflight) return;
      e.preventDefault();
      ensureSaved().then(function (ok) {
        if (ok) other.submit();
        else show("QUARANTINED", "未送出", "草稿尚未保存成功，已阻止送出以免遺失內容");
      });
    });
  });
  window.addEventListener("online", function () {  // 恢復連線立即重送
    if (backoff) { clearTimeout(backoff); backoff = null; }
    if (dirty() && !halted) save();
  });
  window.addEventListener("beforeunload", function (e) {   // UX-h
    if (!dirty() && !inflight) return;
    e.preventDefault(); e.returnValue = "";
    return "";
  });
  window.addEventListener("pagehide", function () {
    if (!dirty() || halted) return;
    seq += 1; f.client_save_sequence.value = String(seq);
    var b = new URLSearchParams(new FormData(f)); b.set("mode", "auto");
    fetch("/b05/save", { method: "POST", body: b, keepalive: true,
      headers: { "content-type": "application/x-www-form-urlencoded",
                 "accept": "application/json" } });
  });
})();
`;

export const autosaveScript = `<script>${autosaveClientSource}</script>`;
