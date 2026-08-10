// B-05 自動保存狀態機的行為測試。
//
// 測的是**實際出貨的那段字串**（`autosaveClientSource`），不是它的副本——
// 複製一份到測試裡，兩邊遲早分岔，而分岔的那天沒有人會發現。
//
// 手法：在 node:vm 沙箱裡放假的 DOM／fetch／計時器，用可控時鐘推進時間。
// 這樣「連續輸入時新鮮度不超過 W」「回應延遲顯示儲存延遲」「請求途中編輯會補送」
// 這類**時序**行為才驗得到；只搜尋 HTML 是否含 "5000" 什麼也證明不了。
import { test } from "node:test";
import assert from "node:assert";
import vm from "node:vm";
import { autosaveClientSource, AUTOSAVE_WINDOW_MS as W, AUTOSAVE_FORCE_MS }
  from "../../apps/api/src/modules/adjustments/views.ts";

interface Sent { seq: number; title: string; at: number; confirmedAt?: number }
interface Harness {
  tick(ms: number): Promise<void>;
  type(title: string): Promise<void>;
  blur(): Promise<void>;
  submit(): Promise<void>;
  online(): Promise<void>;
  beforeunload(): { prevented: boolean };
  state(): string;
  note(): string;
  sent: Sent[];
  submitted: boolean;
  now(): number;
}

/** 伺服器回應的決定函式；回傳 null＝傳輸層失敗（離線）。 */
type Responder = (s: Sent, n: number) =>
  | { status: number; body: Record<string, unknown>; delay?: number }
  | null;

function harness(responder: Responder): Harness {
  let now = 0;
  const timers: { id: number; at: number; fn: () => void }[] = [];
  let nextId = 1;
  const listeners = new Map<string, ((e: unknown) => void)[]>();
  const on = (k: string, fn: (e: unknown) => void) => {
    if (!listeners.has(k)) listeners.set(k, []);
    listeners.get(k)!.push(fn);
  };
  const fire = (k: string, e: unknown) => (listeners.get(k) ?? []).forEach((f) => f(e));

  const fields: Record<string, string> = {
    adj: "a", base_object_version: "1", title: "",
    edit_session_id: "", client_save_sequence: "0",
  };
  const mkField = (name: string) => ({
    get value() { return fields[name]; },
    set value(v: string) { fields[name] = v; },
  });
  const badge = { className: "", textContent: "" };
  const noteEl = { className: "", textContent: "" };
  const form: Record<string, unknown> = {
    edit_session_id: mkField("edit_session_id"),
    base_object_version: mkField("base_object_version"),
    client_save_sequence: mkField("client_save_sequence"),
    addEventListener: (k: string, fn: (e: unknown) => void) => on("form:" + k, fn),
    appendChild: () => {},
  };
  let submitted = false;
  const other = {
    addEventListener: (k: string, fn: (e: unknown) => void) => on("other:" + k, fn),
    submit: () => { submitted = true; },
  };
  const sent: Sent[] = [];
  let n = 0;

  const ctx = vm.createContext({
    console,
    Math, Promise, String, Number, JSON, Object, Array,
    Date: { now: () => now },
    crypto: { randomUUID: () => "11110000-0000-4000-8000-00000000000a" },
    URLSearchParams: class {
      m = new Map<string, string>();
      constructor(init?: Record<string, string>) {
        if (init) for (const [k, v] of Object.entries(init)) this.m.set(k, v);
      }
      set(k: string, v: string) { this.m.set(k, v); }
      get(k: string) { return this.m.get(k); }
    },
    FormData: class { constructor() { return { ...fields }; } },
    setTimeout: (fn: () => void, ms: number) => {
      const id = nextId++; timers.push({ id, at: now + ms, fn }); return id;
    },
    clearTimeout: (id: number) => {
      const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1);
    },
    location: { reload: () => {} },
    document: {
      getElementById: (id: string) =>
        id === "draft" ? form : id === "savestate" ? badge : id === "savenote" ? noteEl : null,
      querySelectorAll: () => [form, other],
      createElement: () => ({ id: "", innerHTML: "" }),
    },
    window: { addEventListener: (k: string, fn: (e: unknown) => void) => on("win:" + k, fn) },
    fetch: (_url: string, init: { body: { get(k: string): string } }) => {
      n += 1;
      const rec: Sent = {
        seq: Number(init.body.get("client_save_sequence")),
        title: init.body.get("title"), at: now,
      };
      sent.push(rec);
      const r = responder(rec, n);
      if (!r) return Promise.reject(new Error("network"));
      const respond = () => {
        rec.confirmedAt = now;                 // 伺服器確認的時刻
        return Promise.resolve({ status: r.status, json: () => Promise.resolve(r.body) });
      };
      if (!r.delay) return respond();
      return new Promise((res) => {
        const id = nextId++;
        timers.push({ id, at: now + r.delay!, fn: () => respond().then(res) });
      });
    },
  });
  vm.runInContext(autosaveClientSource, ctx);

  const drain = async () => { for (let i = 0; i < 60; i++) await Promise.resolve(); };
  const tick = async (ms: number) => {
    const target = now + ms;
    for (;;) {
      const due = timers.filter((t) => t.at <= target).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      timers.splice(timers.indexOf(due), 1);
      now = due.at;
      due.fn();
      await drain();
    }
    now = target;
    await drain();
  };
  return {
    tick,
    async type(title) { fields["title"] = title; fire("form:input", {}); await drain(); },
    async blur() { fire("form:focusout", {}); await drain(); },
    async submit() { fire("other:submit", { preventDefault() {} }); await drain(); },
    async online() { fire("win:online", {}); await drain(); },
    beforeunload() {
      let prevented = false;
      fire("win:beforeunload", { preventDefault() { prevented = true; }, returnValue: "" });
      return { prevented };
    },
    state: () => badge.textContent,
    note: () => noteEl.textContent,
    get sent() { return sent; },
    get submitted() { return submitted; },
    now: () => now,
  };
}

const ok = (ov: number) => ({ status: 200, body: { saved: true, kind: "SAVED", object_version: ov } });

test("持續輸入時，每一次編輯都在 W 內取得**伺服器確認**（不因持續打字而無限延後）", async () => {
  let ov = 1;
  // 往返時間必須是**非零**的：零延遲的假伺服器會讓「W 內送出」與
  // 「W 內確認」無法區分，測試就永遠分不出強制送出上限是否留了往返餘裕。
  const RTT = 400;
  const h = harness(() => ({ ...ok(++ov), delay: RTT }));
  // 每 700ms 打一個字，連續 20 次（14 秒）——短 debounce 每次都被重設。
  // 量的是**每次編輯到它被送出的延遲**，不是兩次保存的間隔：
  // 間隔會包含「保存後到下次輸入」的閒置時間，那段不算新鮮度。
  const edits: number[] = [];
  for (let i = 0; i < 20; i++) { edits.push(h.now()); await h.type("v" + i); await h.tick(700); }
  await h.tick(W + 2000);
  assert.ok(h.sent.length >= 3, `應多次保存，實際 ${h.sent.length}`);
  for (const t of edits) {
    // 基線要的是「W 內取得**伺服器確認**」，不是「W 內送出」——
    // 只量送出的話，持續輸入時永遠差一個往返時間。
    const covered = h.sent.find((s) => s.at >= t && s.confirmedAt !== undefined);
    assert.ok(covered, `${t}ms 的編輯從未獲得確認`);
    assert.ok(covered!.confirmedAt! - t <= W,
      `${t}ms 的編輯到確認耗時 ${covered!.confirmedAt! - t}ms，超過 W=${W}ms`);
  }
});

test("儲存延遲的計時自 dirty 起算，不是自 fetch 起算", async () => {
  const h = harness(() => ({ ...ok(2), delay: W * 2 }));
  await h.type("x");                    // dirty 起點 t=0
  await h.tick(900);
  assert.equal(h.state(), "保存中");
  // 推進到「dirty 起算剛好 W」的那一刻。若計時是自 fetch（t≈800）起算，
  // 此刻還差 800ms 才會翻——那就是「等到 fetch 開始 + W」的錯誤基準。
  await h.tick(W - 900 + 10);
  assert.equal(h.state(), "儲存延遲",
    `dirty 後 ${W}ms 仍未獲確認，當下就必須顯示儲存延遲`);
  await h.tick(W * 2);
  assert.equal(h.state(), "已保存");
});

test("請求途中再編輯 → 舊回應不得標成已保存，且立即補送最新版", async () => {
  let ov = 1;
  const h = harness(() => ({ ...ok(++ov), delay: 2000 }));
  await h.type("first");
  await h.tick(900);                    // 第一次請求已送出（進行中，2000ms 後回應）
  assert.equal(h.sent.length, 1);
  await h.type("second");               // 請求途中再編輯
  // 推進到「第一次回應剛落地」的瞬間：此時 debounce 早已被進行中的請求吃掉，
  // 硬上限（5900ms）也還沒到。這一刻的行為只由**編輯世代比對**決定——
  // 少了它，舊回應會把新內容標成「已保存」，然後靜靜等到硬上限才補送。
  await h.tick(2200);                   // now ≈ 3100，第一次回應已於 2900 落地
  assert.notEqual(h.state(), "已保存",
    "舊請求的成功回應不得把期間發生的新編輯標成已保存");
  assert.equal(h.sent.length, 2, "回應落地後必須立即補送最新版，而非等到硬上限");
  assert.equal(h.sent[1].title, "second");
  await h.tick(3000);
  assert.equal(h.state(), "已保存");
});

test("409 版本衝突 → 不產生請求風暴，且不允許提交", async () => {
  const h = harness(() => ({ status: 409, body: { saved: false, kind: "VERSION_CONFLICT" } }));
  await h.type("x");
  await h.tick(900);
  const afterFirst = h.sent.length;
  await h.tick(60_000);                 // 放置一分鐘
  assert.equal(h.sent.length, afterFirst, "衝突後不得自動重送（重送不會讓過期版本變新）");
  assert.equal(h.state(), "版本衝突");
  await h.submit();
  assert.equal(h.submitted, false, "衝突未解除前不得提交");
});

test("斷線 → 顯示「未同步（離線）」並退避重試；online 事件立即重送", async () => {
  let offline = true;
  let ov = 1;
  const h = harness(() => (offline ? null : ok(++ov)));
  await h.type("x");
  await h.tick(900);
  assert.equal(h.state(), "未同步（離線）");
  const beforeRetry = h.sent.length;
  await h.tick(1200);                   // 第一次退避（1s）
  assert.ok(h.sent.length > beforeRetry, "離線後應退避重試");
  offline = false;
  const beforeOnline = h.sent.length;
  await h.online();
  await h.tick(10);
  assert.ok(h.sent.length > beforeOnline, "恢復連線應立即重送");
  await h.tick(100);
  assert.equal(h.state(), "已保存");
});

test("STALE_SEQUENCE 是拒絕：不得清除 dirty，且以新序號補送", async () => {
  let ov = 1;
  // 第一次回應刻意延遲，才觀察得到「被拒絕當下」的狀態；
  // 不延遲的話補送會在同一個微任務鏈內完成，中間狀態看不到。
  const h = harness((_s, n) => n === 1
    ? { status: 409, body: { saved: false, kind: "STALE_SEQUENCE", object_version: ov },
        delay: 1000 }
    : { ...ok(++ov), delay: 1000 });      // 補送也延遲，才觀察得到中間狀態
  await h.type("x");
  await h.tick(900);
  assert.equal(h.sent.length, 1);
  assert.equal(h.state(), "保存中");
  await h.tick(1100);                   // 第一次（被拒絕的）回應落地
  assert.notEqual(h.state(), "已保存", "被拒絕的保存不得標成已保存");
  assert.equal(h.sent.length, 2, "必須以新序號補送");
  assert.ok(h.sent[1].seq > h.sent[0].seq, "補送的序號必須遞增");
  await h.tick(1100);                   // 補送的回應落地
  assert.equal(h.state(), "已保存");
  await h.tick(60_000);
  assert.equal(h.sent.length, 2, "成功後不得繼續重送");
});

test("dirty 時關閉分頁 → beforeunload 警告（UX-h）", async () => {
  const h = harness(() => ({ ...ok(2), delay: 10_000 }));
  assert.equal(h.beforeunload().prevented, false, "乾淨時不應攔截");
  await h.type("x");
  assert.equal(h.beforeunload().prevented, true, "有未保存內容時必須警告");
});

test("提交前等待保存成功才放行（成功路徑）", async () => {
  let ov = 1;
  const h = harness(() => ({ ...ok(++ov), delay: 1500 }));
  await h.type("x");
  await h.submit();                     // 保存尚未完成
  assert.equal(h.submitted, false, "保存未確認前不得提交");
  await h.tick(5000);
  await h.tick(5000);
  assert.equal(h.submitted, true, "伺服器確認後才提交");
});
