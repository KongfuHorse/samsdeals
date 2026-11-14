// 邮件订阅（Resend 发信）。一个函数，三个地址：
//   POST /mail/subscribe     网页上的订阅表单：检查后发确认邮件
//   GET|POST /mail/unsubscribe?k=…  邮件里的一键退订（Gmail 的"退订"按钮用 POST）
//   POST /mail/notify        数据库定时任务每 10 分钟调用：马上通知；到了晚上 8 点（美东）发每天汇总
// 需要的保密变量（Supabase 后台 Edge Functions → Secrets，不能写进代码）：
//   RESEND_API_KEY      Resend 的 key（只需要发信权限）
//   SB_SECRET_KEY       Supabase Secret key，用来调用只有服务器能用的数据库函数
//   NOTIFY_KEY          和数据库 settings.notify_key 一样，防止别人调用 notify
//   SUBSCRIBE_TEST_KEY  测试用：网站订阅还没打开时，带这个口令也能订阅
// SUPABASE_URL 由 Supabase 自动提供

const SITE = "https://subdeals.net";
const FROM = "Subdeals <deals@subdeals.net>";
const REPLY_TO = "hello@subdeals.net";
const ADDRESS = "Subdeals LLC · 539 W Commerce St, Dallas, TX 75208, USA";
const FN_BASE = `${Deno.env.get("SUPABASE_URL")}/functions/v1/mail`;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info, x-test-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ---------- 小工具 ----------
async function sha256(text: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function rpc(fn: string, args: unknown) {
  const key = Deno.env.get("SB_SECRET_KEY")!;
  const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
  if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`;
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const money = (x: number, cents = false) =>
  "$" + Number(x).toLocaleString("en-US", { minimumFractionDigits: cents || Number(x) % 1 ? 2 : 0, maximumFractionDigits: 2 });
const SRC: Record<string, string> = { slickdeals: "Slickdeals", reddit: "Reddit", tomshardware: "Tom's Hardware", techradar: "TechRadar", woot: "Woot" };

// ---------- 邮件文字：中文 / 英文（按订阅时的网页语言） ----------
type Lang = "zh" | "en";
const q = (s: string) => `「${s}」`;
const qe = (s: string) => `"${s}"`;
const L = {
  zh: {
    html: "zh-CN", font: "'PingFang SC','Microsoft YaHei',Arial,sans-serif",
    cond: { new: "全新", open_box: "开箱", refurb: "翻新", used: "二手" } as Record<string, string>,
    freq: { daily: "每天汇总", instant: "马上通知" } as Record<string, string>,
    found: (days: number) => days < 1 ? "今天发现" : `${days} 天前发现`,
    rank: (n: number) => `第 ${n} 名`,
    total: (p: string) => `总价 ${p}`,
    more: (n: number) => n ? `还有 ${n} 条新价格，看完整排行 →` : "看完整排行 →",
    list: (tags: string[]) => tags.join("、"),
    footer: (tags: string, manage: string, all: string) => `你收到这封邮件，是因为你在 Subdeals 订阅了：${tags}。<br>
<a href="${manage}" style="color:#4338CA;">管理订阅</a> · <a href="${all}" style="color:#4338CA;">退订全部</a><br>
价格以商家页面为准。回复这封邮件可以联系我们。`,
    textFooter: (tags: string, manage: string, all: string) => `你收到这封邮件，是因为你在 Subdeals 订阅了：${tags}。\n管理订阅：${manage}\n退订全部：${all}`,
    textRank: (n: number, price: string, title: string) => `  第 ${n} 名  ${price}  ${title}`,
    textPerTb: (per: string, total: string) => `${per}/TB（总价 ${total}）`,
    textFull: "完整排行：",
    cSubject: (t: string) => `请确认订阅${q(t)}`,
    cPre: (t: string) => `点一下确认，就会开始收到${q(t)}的新优惠。`,
    cIntro: (t: string, f: string) => `你在 Subdeals 订阅了${q(t)}，频率是<b>${f}</b>。点下面的按钮确认后，有新的好价我们会发邮件告诉你。`,
    cBtn: "确认订阅",
    cLink: (l: string) => `按钮点不开的话，复制这个链接到浏览器：<br>${l}<br>链接 7 天内有效。`,
    cFooter: "如果不是你本人订阅的，忽略这封邮件就行。不点确认，我们不会再给你发邮件。",
    cText: (t: string, f: string, l: string) => `你在 Subdeals 订阅了${q(t)}（${f}）。\n打开这个链接确认订阅（7 天内有效）：\n${l}\n\n如果不是你本人订阅的，忽略这封邮件就行。`,
    iSubject1: (t: string, p: string) => `${q(t)}新进前 3 名：${p}`,
    iSubjectN: (n: number) => `${n} 个标签有新的前 3 名`,
    iIntro: "刚发现的新价格排进了你订阅的标签前 3 名：",
    dSubject: (names: string[]) => `今天的新优惠：${names.slice(0, 2).join("、")}${names.length > 2 ? ` 等 ${names.length} 个标签` : ""}`,
    dPre: (n: number) => `${n} 条新价格`,
    dIntro: "这是你订阅的标签今天新发现的价格，名次是在近 30 天价格排行里的位置：",
    dText: "今天新发现的价格：",
  },
  en: {
    html: "en", font: "Arial,Helvetica,sans-serif",
    cond: { new: "New", open_box: "Open box", refurb: "Refurbished", used: "Used" } as Record<string, string>,
    freq: { daily: "daily digest", instant: "instant alerts" } as Record<string, string>,
    found: (days: number) => days < 1 ? "Found today" : `Found ${days} day${days > 1 ? "s" : ""} ago`,
    rank: (n: number) => `#${n}`,
    total: (p: string) => `${p} total`,
    more: (n: number) => n ? `${n} more new price${n > 1 ? "s" : ""}. See the full ranking →` : "See the full ranking →",
    list: (tags: string[]) => tags.join(", "),
    footer: (tags: string, manage: string, all: string) => `You're getting this email because you subscribed to ${tags} on Subdeals.<br>
<a href="${manage}" style="color:#4338CA;">Manage subscriptions</a> · <a href="${all}" style="color:#4338CA;">Unsubscribe from all</a><br>
Prices can change. Check the store page before you buy. Reply to this email to reach us.`,
    textFooter: (tags: string, manage: string, all: string) => `You're getting this email because you subscribed to ${tags} on Subdeals.\nManage subscriptions: ${manage}\nUnsubscribe from all: ${all}`,
    textRank: (n: number, price: string, title: string) => `  #${n}  ${price}  ${title}`,
    textPerTb: (per: string, total: string) => `${per}/TB (${total} total)`,
    textFull: "Full ranking: ",
    cSubject: (t: string) => `Confirm your subscription to ${qe(t)}`,
    cPre: (t: string) => `Confirm to start getting new deals for ${qe(t)}.`,
    cIntro: (t: string, f: string) => `You subscribed to ${qe(t)} on Subdeals (<b>${f}</b>). Confirm below and we'll email you when a good new price shows up.`,
    cBtn: "Confirm subscription",
    cLink: (l: string) => `If the button doesn't work, copy this link into your browser:<br>${l}<br>The link expires in 7 days.`,
    cFooter: "If you didn't sign up, you can ignore this email. We won't email you again unless you confirm.",
    cText: (t: string, f: string, l: string) => `You subscribed to ${qe(t)} on Subdeals (${f}).\nOpen this link to confirm (expires in 7 days):\n${l}\n\nIf you didn't sign up, you can ignore this email.`,
    iSubject1: (t: string, p: string) => `New top 3 for ${qe(t)}: ${p}`,
    iSubjectN: (n: number) => `New top 3 deals in ${n} of your tags`,
    iIntro: "New prices just made the top 3 in tags you follow:",
    dSubject: (names: string[]) => `Today's new deals: ${names.slice(0, 2).join(", ")}${names.length > 2 ? ` and ${names.length - 2} more` : ""}`,
    dPre: (n: number) => `${n} new price${n > 1 ? "s" : ""}`,
    dIntro: "Here are today's new prices for the tags you follow. The rank is the deal's place in the 30-day price ranking:",
    dText: "Today's new prices:",
  },
};
const langOf = (x: unknown): Lang => (x === "en" ? "en" : "zh");
const tagOf = (lang: Lang, s: { tag: string; tag_en?: string | null }) => (lang === "en" && s.tag_en) || s.tag;

// 美东时间：日期和小时
function eastern(d = new Date()) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", hour12: false }).formatToParts(d).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, hour: Number(p.hour) % 24 };
}
const daysAgo = (t: string) => Math.floor((Date.now() - new Date(t).getTime()) / 86400000);

// 和网页一样的标题清理、去重（同一商家、价格差 2% 以内、标题相似）
const norm = (s: unknown) => String(s ?? "").normalize("NFKC").toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, "");
function cleanTitle(t: string) {
  return String(t || "")
    .replace(/^\s*\[[^\]]{1,20}\]\s*/, "")
    .replace(/^\s*[-–—•]+\s*/, "")
    .replace(/^\s*\$[\d,.]+\*?\s*\|\s*/, "")
    .replace(/\s*[-–:|,]?\s*\(\s*\$[\d,]+(?:\.\d+)?\*?\s*\)\s*$/, "")
    .replace(/\s*(?:[-–:|,]\s*)?(?:(?:starting\s+at|as\s+low\s+as|from|for|at|only|now|just)\s+)?\$[\d,]+(?:\.\d+)?\*?(?:\s+.*)?$/i, "")
    .replace(/\s*\[[^\]]{1,30}\]\s*$/, "")
    .replace(/\s+@\s+[\w .'&-]+$/, "")
    .replace(/\s*[-–:|,]\s*$/, "")
    .trim();
}
const words = (t: string) => new Set(cleanTitle(t).toLowerCase().split(/[^a-z0-9一-鿿]+/).filter((w) => w.length > 1));
function similar(a: string, b: string) {
  const A = words(a), B = words(b); if (!A.size || !B.size) return 0;
  let both = 0; for (const w of A) if (B.has(w)) both++;
  return both / (A.size + B.size - both);
}
type Deal = { title: string; url: string; source: string; store: string | null; price: number; condition: string | null;
  created_at: string; image_url: string | null; per_tb: number | null; rank?: number;
  brand?: string | null; gpu?: string | null; apple_model?: string | null; category?: string | null;
  capacity_tb?: number | null; quantity?: number | null; expired_at?: string | null };
// 同品牌、同型号、同价格（四舍五入到整美元）的 deal 只留一条（和网站一样，后台可以关）
const MODEL_STOP = new Set(("graphics card video gpu desktop laptop gaming pc computer internal external ssd hdd hard drive new the with and or "
  + "for of in on at w free shipping less plus after coupon code clip deal deals sale price prime amazon newegg walmart bestbuy best buy "
  + "ebay woot bh b h microcenter micro center target costco").split(" "));
const modelTokens = (title: string) => new Set(String(title || "").toLowerCase().replace(/\$\s?[\d,]+(\.\d+)?/g, " ")
  .replace(/[^a-z0-9]+/g, " ").split(" ").filter((w) => w && !MODEL_STOP.has(w)));
const same = (a: unknown, b: unknown) => String(a ?? "").toLowerCase() === String(b ?? "").toLowerCase();
function sameModel(a: Deal, b: Deal) {
  if (!a.brand || !same(a.brand, b.brand)) return false;
  if (!(["category", "gpu", "apple_model", "condition"] as const).every((k) => same(a[k], b[k]))) return false;
  if (Number(a.capacity_tb || 0) !== Number(b.capacity_tb || 0) || Number(a.quantity || 1) !== Number(b.quantity || 1)) return false;
  const A = modelTokens(a.title), B = modelTokens(b.title);
  const [small, big] = A.size <= B.size ? [A, B] : [B, A];
  return small.size >= 2 && [...small].every((w) => big.has(w));
}
function mergeSame(list: Deal[], on: boolean) {
  if (!on) return list;
  const kept: Deal[] = [];
  for (const d of list) if (!kept.some((k) => Math.round(k.price) === Math.round(d.price) && sameModel(k, d))) kept.push(d);
  return kept;
}
function dedupe(list: Deal[]) {
  const kept: Deal[] = [];
  for (const d of [...list].sort((a, b) => +new Date(b.created_at) - +new Date(a.created_at))) {
    const dup = kept.some((k) => norm(k.store) === norm(d.store) && Math.abs(k.price - d.price) / Math.max(k.price, d.price) <= 0.02
                                  && similar(k.title, d.title) >= 0.6);
    if (!dup) kept.push(d);
  }
  return list.filter((d) => kept.includes(d)).map((d, i) => ({ ...d, rank: i + 1 }));
}

// ---------- 邮件样式 ----------
function layout(lang: Lang, o: { preheader: string; heading: string; intro: string; body: string; footer: string }) {
  const F = L[lang].font;
  return `<!doctype html><html lang="${L[lang].html}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<meta name="color-scheme" content="light"><title>${o.heading}</title></head>
<body style="margin:0;padding:0;background:#F5F4FA;">
<div style="display:none;max-height:0;overflow:hidden;">${esc(o.preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F5F4FA;"><tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#FFFFFF;border-radius:18px;border:1px solid #E7E6EF;">
<tr><td style="padding:22px 26px 6px;font:500 24px/1 Arial,Helvetica,sans-serif;color:#1B1A2E;letter-spacing:-0.5px;">sub<b style="color:#4338CA;font-weight:800;">deals</b></td></tr>
<tr><td style="padding:14px 26px 0;font:700 22px/1.35 ${F};color:#1B1A2E;">${o.heading}</td></tr>
<tr><td style="padding:8px 26px 4px;font:400 15px/1.7 ${F};color:#4C4A63;">${o.intro}</td></tr>
<tr><td style="padding:8px 26px 18px;">${o.body}</td></tr>
</table>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;"><tr><td style="padding:16px 26px;font:400 12px/1.7 ${F};color:#6B6985;">${o.footer}</td></tr></table>
</td></tr></table></body></html>`;
}
const btn = (lang: Lang, href: string, text: string) =>
  `<a href="${esc(href)}" style="display:inline-block;background:#4338CA;color:#FFFFFF;font:700 15px/1 ${L[lang].font};padding:14px 26px;border-radius:10px;text-decoration:none;">${esc(text)}</a>`;

function dealRow(lang: Lang, d: Deal, perTbTag: boolean) {
  const T = L[lang], F = T.font;
  const big = perTbTag && d.per_tb != null ? `${money(d.per_tb, true)}/TB` : money(d.price);
  const small = perTbTag && d.per_tb != null ? T.total(money(d.price)) : "";
  const meta = [T.cond[d.condition ?? ""], d.store, SRC[d.source], T.found(daysAgo(d.created_at))].filter(Boolean).join(" · ");
  const img = /^https:\/\//.test(d.image_url || "")
    ? `<img src="${esc(d.image_url)}" width="64" height="64" alt="" style="display:block;width:64px;height:64px;object-fit:contain;border:1px solid #ECEBF3;border-radius:10px;background:#FFFFFF;">`
    : `<div style="width:64px;height:64px;border:1px solid #ECEBF3;border-radius:10px;background:#F5F4FA;"></div>`;
  return `<tr>
<td width="72" valign="top" style="padding:14px 0;border-top:1px solid #EFEEF5;">${img}</td>
<td valign="top" style="padding:14px 10px;border-top:1px solid #EFEEF5;font-family:${F};">
  <div style="font:700 12px/1.4 Arial,sans-serif;color:#4338CA;">${T.rank(d.rank!)}</div>
  <a href="${esc(d.url)}" style="font:600 15px/1.4 ${F};color:#1B1A2E;text-decoration:none;">${esc(cleanTitle(d.title))}</a>
  <div style="font:400 12px/1.6 ${F};color:#6B6985;">${esc(meta)}</div>
</td>
<td valign="top" align="right" style="padding:14px 0;border-top:1px solid #EFEEF5;white-space:nowrap;">
  <div style="font:800 18px/1.3 Arial,sans-serif;color:#1B1A2E;">${esc(big)}</div>
  ${small ? `<div style="font:400 12px/1.5 Arial,sans-serif;color:#6B6985;">${esc(small)}</div>` : ""}
</td></tr>`;
}
// 网站链接：英文订阅者带上 lang=en，打开就是英文页面
const site = (lang: Lang, path: string) => `${SITE}/${path}${lang === "en" ? (path.includes("?") ? "&" : "?") + "lang=en" : ""}`;
const tagUrl = (lang: Lang, slug: string) => site(lang, `?t=${encodeURIComponent(slug)}`);
const manageUrl = (lang: Lang, key: string, all = false) => site(lang, `manage.html?k=${key}${all ? "&unsubscribe=all" : ""}`);
function tagBlock(lang: Lang, tag: { tag: string; slug: string; perTb: boolean; deals: Deal[]; more?: number }) {
  const F = L[lang].font;
  return `<div style="padding:10px 0 4px;font:700 17px/1.4 ${F};color:#1B1A2E;">${esc(tag.tag)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0">${tag.deals.map((d) => dealRow(lang, d, tag.perTb)).join("")}</table>
<div style="padding:8px 0 14px;font:600 14px/1.5 ${F};">
  <a href="${esc(tagUrl(lang, tag.slug))}" style="color:#4338CA;text-decoration:none;">${esc(L[lang].more(tag.more || 0))}</a></div>`;
}
function subFooter(lang: Lang, key: string, tags: string[]) {
  return `${L[lang].footer(esc(L[lang].list(tags)), esc(manageUrl(lang, key)), esc(manageUrl(lang, key, true)))}<br>${esc(ADDRESS)}`;
}
function textDeals(lang: Lang, t: { tag: string; slug: string; perTb: boolean; deals: Deal[] }) {
  const T = L[lang];
  return `${t.tag}\n` + t.deals.map((d) => `${T.textRank(d.rank!, t.perTb && d.per_tb != null ? T.textPerTb(money(d.per_tb, true), money(d.price)) : money(d.price), cleanTitle(d.title))}\n  ${d.url}`).join("\n")
    + `\n  ${T.textFull}${tagUrl(lang, t.slug)}\n`;
}
const textFooter = (lang: Lang, key: string, tags: string[]) =>
  `\n—\n${L[lang].textFooter(L[lang].list(tags), manageUrl(lang, key), manageUrl(lang, key, true))}\n${ADDRESS}\n`;
const listHeaders = (lang: Lang, key: string) => ({
  "List-Unsubscribe": `<${FN_BASE}/unsubscribe?k=${key}${lang === "en" ? "&lang=en" : ""}>, <mailto:${REPLY_TO}?subject=unsubscribe>`,
  "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
});

// ---------- Resend ----------
type Mail = { to: string; subject: string; html: string; text: string; headers?: Record<string, string>;
  log: { kind: string; subscriber_id?: number | null }; digestIds?: number[] };
async function resend(path: string, body: unknown) {
  const r = await fetch(`https://api.resend.com${path}`, {
    method: "POST", headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d?.message || `resend ${r.status}`);
  return d;
}
// 发信并记录；一次最多 100 封（Resend 批量接口的上限）
async function sendAll(mails: Mail[]) {
  const logs: unknown[] = [];
  for (let i = 0; i < mails.length; i += 100) {
    const chunk = mails.slice(i, i + 100);
    const payload = chunk.map((m) => ({ from: FROM, to: [m.to], reply_to: REPLY_TO, subject: m.subject, html: m.html, text: m.text,
                                        ...(m.headers ? { headers: m.headers } : {}) }));
    try {
      const d = chunk.length === 1 ? { data: [await resend("/emails", payload[0])] } : await resend("/emails/batch", payload);
      chunk.forEach((m, j) => logs.push({ ...m.log, subject: m.subject, resend_id: d.data?.[j]?.id ?? null, ok: true }));
    } catch (e) {
      chunk.forEach((m) => logs.push({ ...m.log, subject: m.subject, ok: false, error: String((e as Error).message).slice(0, 300) }));
    }
  }
  if (logs.length) await rpc("email_log_add", { p_rows: logs });
  return logs as { ok: boolean }[];
}

// ---------- 订阅 ----------
async function subscribe(req: Request) {
  const body = await req.json().catch(() => ({}));
  const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "unknown";
  const testKey = Deno.env.get("SUBSCRIBE_TEST_KEY");
  const test = !!testKey && req.headers.get("x-test-key") === testKey;
  const r = await rpc("sub_request", { p_email: String(body.email || "").slice(0, 300), p_slug: String(body.tag || ""),
    p_frequency: body.frequency === "instant" ? "instant" : "daily", p_ip_hash: await sha256("samsdeals:" + ip), p_test: test,
    p_lang: body.lang === "en" ? "en" : "zh" });
  if (r.error) return json({ error: r.error }, r.error === "closed" ? 403 : r.error === "limited" || r.error === "quota" ? 429 : 400);
  if (!r.send) return json({ ok: true });
  const s = r.send, lang = langOf(s.lang), T = L[lang], tag = tagOf(lang, s), freq = T.freq[s.frequency];
  const link = site(lang, `manage.html?c=${s.confirm}`);
  const sent = await sendAll([{
    to: s.email, subject: T.cSubject(tag), log: { kind: "confirm", subscriber_id: s.subscriber_id },
    html: layout(lang, {
      preheader: T.cPre(tag),
      heading: esc(T.cSubject(tag)),
      intro: T.cIntro(esc(tag), esc(freq)),
      body: `<div style="padding:10px 0 6px;">${btn(lang, link, T.cBtn)}</div>
<div style="font:400 12px/1.7 Arial,sans-serif;color:#6B6985;word-break:break-all;">${T.cLink(esc(link))}</div>`,
      footer: `${T.cFooter}<br>${esc(ADDRESS)}`,
    }),
    text: `${T.cText(tag, freq, link)}\n${ADDRESS}\n`,
  }]);
  return sent[0]?.ok ? json({ ok: true }) : json({ error: "server" }, 500);
}

// ---------- 一键退订 ----------
async function unsubscribe(req: Request, url: URL) {
  const key = url.searchParams.get("k") || "";
  if (req.method === "GET") {        // 浏览器打开：交给网页处理（避免邮件安全软件预先打开链接时误退订）
    return new Response(null, { status: 302, headers: { Location: `${SITE}/manage.html?k=${encodeURIComponent(key)}&unsubscribe=all${url.searchParams.get("lang") === "en" ? "&lang=en" : ""}` } });
  }
  await rpc("public_sub_remove_all", { p_key: key });
  return new Response("unsubscribed", { status: 200, headers: CORS });
}

// ---------- 定时通知 ----------
type Sub = { id: number; subscriber_id: number; email: string; key: string; tag_id: number; slug: string; tag: string;
  tag_en: string | null; lang: string;
  frequency: string; activated_at: string; last_digest_at: string | null; sent: string[]; instant_today: number };
async function notify(req: Request) {
  if (req.headers.get("x-notify-key") !== Deno.env.get("NOTIFY_KEY")) return json({ error: "forbidden" }, 403);
  const body = await req.json().catch(() => ({}));
  const data = await rpc("notify_prepare", {});
  const subs: Sub[] = data.subs || [];
  const st = data.settings, q = data.quota;
  let left = Math.max(0, Math.min(q.day_limit - q.day_used, q.month_limit - q.month_used));
  const now = eastern();
  const digestDue = body.force_digest === true || (now.hour >= st.digest_hour && st.last_digest_date !== now.date);

  // 每个标签只查一次排行
  const lists = new Map<string, { deals: Deal[]; perTb: boolean }>();
  for (const slug of new Set(subs.map((s) => s.slug))) {
    const r = await rpc("public_tag_deals", { p_slug: slug });
    lists.set(slug, { deals: r ? dedupe(mergeSame((r.deals || []).filter((d: Deal) => !d.expired_at), r.merge_same !== false)) : [], perTb: !!r?.tag?.per_tb });   // 过期的不发
  }

  const sent: { id: number; url: string }[] = [];
  const digested: number[] = [];
  const mails: Mail[] = [];
  const bySub = new Map<number, Sub[]>();
  for (const s of subs) bySub.set(s.subscriber_id, [...(bySub.get(s.subscriber_id) || []), s]);

  for (const [, mine] of bySub) {
    const who = mine[0], lang = langOf(who.lang), T = L[lang];
    const allTags = mine.map((s) => tagOf(lang, s));
    // 马上通知：新优惠排进前 3 名（2 天内发现的、订阅之后出现的、没发过的）
    const instant = mine.filter((s) => s.frequency === "instant").map((s) => {
      const R = lists.get(s.slug)!; const seen = new Set(s.sent);
      const deals = R.deals.slice(0, 3).filter((d) => new Date(d.created_at) > new Date(s.activated_at)
        && Date.now() - +new Date(d.created_at) < 2 * 86400000 && !seen.has(d.url));
      return { s, tag: tagOf(lang, s), slug: s.slug, perTb: R.perTb, deals };
    }).filter((x) => x.deals.length);
    if (instant.length && who.instant_today < st.instant_daily_max) {
      const first = instant[0].deals[0];
      const firstPrice = instant[0].perTb && first.per_tb != null ? `${money(first.per_tb, true)}/TB` : money(first.price);
      const subject = instant.length === 1 ? T.iSubject1(instant[0].tag, firstPrice) : T.iSubjectN(instant.length);
      mails.push({
        to: who.email, subject, headers: listHeaders(lang, who.key), log: { kind: "instant", subscriber_id: who.subscriber_id },
        html: layout(lang, { preheader: `${cleanTitle(first.title)} ${firstPrice}`, heading: esc(subject),
          intro: T.iIntro, body: instant.map((x) => tagBlock(lang, x)).join(""), footer: subFooter(lang, who.key, allTags) }),
        text: `${T.iIntro}\n\n${instant.map((x) => textDeals(lang, x)).join("\n")}${textFooter(lang, who.key, allTags)}`,
      });
      for (const x of instant) for (const d of x.deals) sent.push({ id: x.s.id, url: d.url });
    }
    // 每天汇总：上次汇总以后新发现的价格
    if (digestDue) {
      const daily = mine.filter((s) => s.frequency === "daily");
      const blocks = daily.map((s) => {
        const R = lists.get(s.slug)!; const seen = new Set(s.sent);
        const since = new Date(s.last_digest_at || s.activated_at);
        const fresh = R.deals.filter((d) => new Date(d.created_at) > since && !seen.has(d.url));
        return { s, tag: tagOf(lang, s), slug: s.slug, perTb: R.perTb, deals: fresh.slice(0, 5), more: Math.max(0, fresh.length - 5), all: fresh };
      }).filter((x) => x.deals.length);
      // 没有新价格的订阅：直接把"上次汇总时间"往后挪；有新价格的，发成功以后再挪
      for (const s of daily) if (!blocks.some((b) => b.s.id === s.id)) digested.push(s.id);
      if (blocks.length) {
        const names = blocks.map((b) => b.tag);
        const subject = T.dSubject(names);
        mails.push({
          to: who.email, subject, headers: listHeaders(lang, who.key), log: { kind: "digest", subscriber_id: who.subscriber_id },
          digestIds: blocks.map((b) => b.s.id),
          html: layout(lang, { preheader: T.dPre(blocks.reduce((n, b) => n + b.all.length, 0)), heading: esc(subject),
            intro: T.dIntro, body: blocks.map((b) => tagBlock(lang, b)).join(""),
            footer: subFooter(lang, who.key, allTags) }),
          text: `${T.dText}\n\n${blocks.map((b) => textDeals(lang, b)).join("\n")}${textFooter(lang, who.key, allTags)}`,
        });
        for (const b of blocks) for (const d of b.all) sent.push({ id: b.s.id, url: d.url });
      }
    }
  }

  // 额度不够就先不发，记一条失败，下次再试
  const toSend = mails.slice(0, left), skipped = mails.slice(left);
  const results = toSend.length ? await sendAll(toSend) : [];
  left -= results.filter((r) => r.ok).length;
  if (skipped.length) {
    await rpc("email_log_add", { p_rows: skipped.map((m) => ({ ...m.log, subject: m.subject, ok: false, error: "额度用完，没有发" })) });
  }
  const okTo = new Set(toSend.filter((_, i) => results[i]?.ok).map((m) => m.log.subscriber_id));
  toSend.forEach((m, i) => { if (results[i]?.ok && m.digestIds) digested.push(...m.digestIds); });
  const okSent = sent.filter((x) => okTo.has(subs.find((s) => s.id === x.id)?.subscriber_id));

  // 额度用到 80% 时提醒一次（每天最多一次）
  let alertDate: string | null = null;
  const dayUsed = q.day_used + results.filter((r) => r.ok).length, monthUsed = q.month_used + results.filter((r) => r.ok).length;
  if (st.admin_email && st.quota_alert_date !== now.date && left > 0
      && (dayUsed >= q.day_limit * 0.8 || monthUsed >= q.month_limit * 0.8)) {
    await sendAll([{ to: st.admin_email, subject: "Subdeals：邮件额度快用完了", log: { kind: "alert" },
      html: layout("zh", { preheader: "Resend 免费额度快用完了", heading: "邮件额度快用完了",
        intro: `今天已发 ${dayUsed} / ${q.day_limit} 封，最近 30 天已发 ${monthUsed} / ${q.month_limit} 封。用完以后会先停发，不会超额。需要的话可以升级 Resend 套餐，再到后台"订阅"里调高上限。`,
        body: "", footer: ADDRESS }),
      text: `今天已发 ${dayUsed}/${q.day_limit} 封，最近 30 天已发 ${monthUsed}/${q.month_limit} 封。\n` }]);
    alertDate = now.date;
  }

  await rpc("notify_commit", { p_sent: okSent, p_digested: digestDue ? digested : [], p_digest_date: digestDue && body.force_digest !== true ? now.date : null,
    p_alert_date: alertDate });
  return json({ ok: true, digest: digestDue, emails: results.length, failed: results.filter((r) => !r.ok).length, skipped: skipped.length });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const url = new URL(req.url);
  const route = url.pathname.split("/").filter(Boolean).pop();
  try {
    if (route === "subscribe" && req.method === "POST") return await subscribe(req);
    if (route === "unsubscribe") return await unsubscribe(req, url);
    if (route === "notify" && req.method === "POST") return await notify(req);
    return json({ error: "not_found" }, 404);
  } catch (e) {
    console.error(e);
    return json({ error: "server" }, 500);
  }
});
