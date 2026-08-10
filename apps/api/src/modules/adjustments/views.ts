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
 * 另外兩條不變的約束：
 *   * **不使用 IndexedDB／localStorage 保存客戶財務內容**——瀏覽器端只留
 *     edit_session_id（一個 UUID）與序號。財務數字只存在伺服器與這個分頁的 DOM。
 *   * 「已保存」只在**伺服器確認**後才顯示；前端不得自行宣告。
 */
export const autosaveScript = `<script>
(function () {
  var f = document.getElementById("draft");
  if (!f) return;
  var st = document.getElementById("savestate"), note = document.getElementById("savenote");
  var es = crypto.randomUUID();               // 每個分頁一個編輯來源
  f.edit_session_id.value = es;
  var seq = 0;                 // 送出序號（冪等鍵的一部分）
  var gen = 0;                 // 本地編輯世代號：每次輸入 +1
  var savedGen = 0;            // 已獲伺服器確認的世代
  var inflight = null;         // 進行中的請求（Promise）
  var debounce = null, hardCap = null;
  var expired = false;

  function show(cls, text, detail) {
    st.className = "badge st-" + cls; st.textContent = text;
    if (detail !== undefined) note.textContent = detail;
  }
  function dirty() { return gen > savedGen; }

  function schedule() {
    if (debounce) clearTimeout(debounce);
    debounce = setTimeout(function () { save(); }, 800);      // 短 debounce
    if (!hardCap) {                                            // 自 dirty 起算的硬上限
      hardCap = setTimeout(function () { hardCap = null; save(); }, 5000);
    }
  }
  function clearTimers() {
    if (debounce) { clearTimeout(debounce); debounce = null; }
    if (hardCap) { clearTimeout(hardCap); hardCap = null; }
  }

  // 送出一次；回傳 Promise<boolean>（是否已獲伺服器確認到最新世代）
  function save() {
    if (expired) return Promise.resolve(false);
    if (inflight) return inflight;                 // 進行中：由它結束後自行補送
    if (!dirty()) return Promise.resolve(true);
    clearTimers();
    var sending = gen;                             // 這次請求對應的世代
    seq += 1;
    f.client_save_sequence.value = String(seq);
    show("VALIDATING", "保存中");
    var body = new URLSearchParams(new FormData(f));
    body.set("mode", "auto");
    inflight = fetch("/b05/save", { method: "POST", body: body,
        headers: { "content-type": "application/x-www-form-urlencoded",
                   "accept": "application/json" } })
      .then(function (r) {
        if (r.status === 401) { expired = true; return { s: 401, j: { kind: "SESSION_EXPIRED" } }; }
        return r.json().then(function (j) { return { s: r.status, j: j }; });
      })
      .then(function (r) {
        if (r.s === 401) { sessionLost(); return false; }
        if (r.s === 200) {
          f.base_object_version.value = String(r.j.object_version);
          if (gen === sending) {                   // 期間沒有新編輯 → 真的最新
            savedGen = sending;
            show("MATCHED", "已保存", "ov=" + r.j.object_version
              + (r.j.kind === "IDEMPOTENT_REPLAY" ? "（重送，已是最新）" : ""));
            return true;
          }
          show("UPLOADED", "未保存", "保存期間有新編輯，正在補送");
          return false;                            // 交給下方立即補送
        }
        if (r.j.kind === "VERSION_CONFLICT" || r.j.kind === "CONCURRENT_CONFLICT") {
          show("CONFLICT", "版本衝突",
            "草稿已被他人或另一分頁更新；重新載入後再編輯，系統不會靜默覆蓋");
        } else if (r.j.kind === "IDEMPOTENCY_KEY_REUSED") {
          show("QUARANTINED", "保存失敗", "序號重用（內容不一致），將以新序號重送");
        } else {
          show("QUARANTINED", "保存失敗", r.j.kind || "");
        }
        return false;
      })
      .catch(function () {
        show("QUARANTINED", "保存失敗", "連線異常，將於下次編輯後重試");
        return false;
      })
      .then(function (ok) {
        inflight = null;
        if (!ok && !expired && dirty()) return save();   // 補送最新內容
        return ok;
      });
    return inflight;
  }

  /** 等待既有請求並補送最新內容；只有伺服器確認成功才回 true。 */
  function ensureSaved() {
    if (expired) return Promise.resolve(false);
    if (!inflight && !dirty()) return Promise.resolve(true);
    return (inflight || save()).then(function (ok) {
      if (ok && !dirty()) return true;
      if (expired) return false;
      return dirty() ? save() : true;
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
      expired = false; seq += 1; save();
    });
    document.getElementById("btn-discard").addEventListener("click", function () {
      location.reload();
    });
  }

  f.addEventListener("input", function () { gen += 1; show("UPLOADED", "未保存"); schedule(); });
  f.addEventListener("focusout", function () { if (dirty()) save(); });
  // 送覆核／退回等離開草稿的動作：**必須**等到伺服器確認保存成功才放行
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
  // 關閉分頁／切換案件：同步補送最後一次（keepalive 讓請求在卸載後仍完成）
  window.addEventListener("pagehide", function () {
    if (!dirty() || expired) return;
    seq += 1; f.client_save_sequence.value = String(seq);
    var b = new URLSearchParams(new FormData(f)); b.set("mode", "auto");
    fetch("/b05/save", { method: "POST", body: b, keepalive: true,
      headers: { "content-type": "application/x-www-form-urlencoded",
                 "accept": "application/json" } });
  });
})();
</script>`;
