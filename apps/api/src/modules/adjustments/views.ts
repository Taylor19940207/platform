// B-05 的呈現片段。
//
// 與 routes.ts 分開的理由跟 workbench 一樣：查詢／授權與「怎麼呈現」不該混在
// 同一個檔案；自動保存腳本尤其——它是一段有行為的資產，值得單獨被讀。

/**
 * B-05 草稿的自動保存腳本。
 *
 * 幾條刻意的約束：
 *   * **不使用 IndexedDB／localStorage 保存客戶財務內容**——瀏覽器端只留
 *     edit_session_id（一個 UUID，非業務資料）與序號。財務數字只存在伺服器。
 *   * `edit_session_id` 每個**分頁載入**產生一次：同一自然人的兩個分頁因此不同，
 *     後送出的不會靜默覆蓋先送出的（NFR-INT-002 INT-a2）。
 *   * 「已保存」只在**伺服器確認**後才顯示；送出中一律顯示「保存中」。
 *     前端不得自行宣告保存成功——那正是「已確認保存卻遺失」的來源。
 *   * dirty 才送。乾淨時不送，避免把伺服器當心跳用。
 */
export const autosaveScript = `<script>
(function () {
  var f = document.getElementById("draft");
  if (!f) return;
  var st = document.getElementById("savestate"), note = document.getElementById("savenote");
  var es = crypto.randomUUID();               // 每個分頁一個編輯來源
  f.edit_session_id.value = es;
  var seq = 0, dirty = false, inflight = false, timer = null;

  function show(cls, text, detail) {
    st.className = "badge st-" + cls; st.textContent = text;
    if (detail !== undefined) note.textContent = detail;
  }
  function mark() {
    dirty = true; show("UPLOADED", "未保存");
    if (timer) clearTimeout(timer);
    timer = setTimeout(save, 5000);           // dirty 起算 5 秒內自動保存
  }
  function save(force) {
    if (inflight || (!dirty && !force)) return Promise.resolve();
    inflight = true; show("VALIDATING", "保存中");
    seq += 1; f.client_save_sequence.value = String(seq);
    var body = new URLSearchParams(new FormData(f));
    body.set("mode", "auto");
    return fetch("/b05/save", { method: "POST", body: body,
        headers: { "content-type": "application/x-www-form-urlencoded" } })
      .then(function (r) { return r.json().then(function (j) { return { s: r.status, j: j }; }); })
      .then(function (r) {
        if (r.s === 200) {
          dirty = false;
          f.base_object_version.value = String(r.j.object_version);
          show("MATCHED", "已保存", "ov=" + r.j.object_version
            + (r.j.kind === "IDEMPOTENT_REPLAY" ? "（重送，已是最新）" : ""));
        } else if (r.j.kind === "VERSION_CONFLICT" || r.j.kind === "CONCURRENT_CONFLICT") {
          show("CONFLICT", "版本衝突", "草稿已被他人或另一分頁更新；重新載入後再編輯，系統不會靜默覆蓋");
        } else {
          show("QUARANTINED", "保存失敗", r.j.kind || "");
        }
      })
      .catch(function () { show("QUARANTINED", "保存失敗", "連線異常，將於下次編輯後重試"); })
      .finally(function () { inflight = false; });
  }
  f.addEventListener("input", mark);
  f.addEventListener("focusout", function () { if (dirty) save(); });   // blur 立即保存
  // 送覆核／退回等離開草稿的動作：先確保草稿已落地
  document.querySelectorAll('form[action^="/b05/"]').forEach(function (other) {
    if (other === f) return;
    other.addEventListener("submit", function (e) {
      if (!dirty) return;
      e.preventDefault(); save().then(function () { other.submit(); });
    });
  });
  // 切換案件／關閉分頁：同步送出最後一次（keepalive 讓請求在卸載後仍完成）
  window.addEventListener("pagehide", function () {
    if (!dirty) return;
    seq += 1; f.client_save_sequence.value = String(seq);
    var b = new URLSearchParams(new FormData(f)); b.set("mode", "auto");
    fetch("/b05/save", { method: "POST", body: b, keepalive: true,
      headers: { "content-type": "application/x-www-form-urlencoded" } });
  });
})();
</script>`;
