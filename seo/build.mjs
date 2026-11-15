// 生成给 Google 收录的静态页：/zh/、/en/ 首页，以及每个有优惠的标签的 /zh/deals/标签/、/en/deals/标签/
// 做法：用浏览器打开网站，等内容加载完，把页面原样存成 HTML。访客打开静态页后，页面还会自己去拿最新价格。
// 用法：先在仓库根目录开一个本地服务器（python3 -m http.server 8080），再运行 node seo/build.mjs
import { chromium } from "playwright";
import fs from "fs";
import path from "path";

const ROOT = process.cwd();
const LOCAL = process.env.LOCAL_URL || "http://localhost:8080";
const SITE = "https://subdeals.net";
const SUPABASE = "https://pmjmexfueofdaubcumgk.supabase.co";
const KEY = "sb_publishable_l02lU8RFOe5RwSkO-YasHw_MBTgd-av";   // 公开的 key，网页里本来就有
const LANGS = ["zh", "en"];
const WORKERS = 4;

const home = await (await fetch(`${SUPABASE}/rest/v1/rpc/public_home`, {
  method: "POST", headers: { apikey: KEY, "Content-Type": "application/json" }, body: "{}",
})).json();
const slugs = (home.tags || []).filter(t => t.deals > 0).map(t => t.slug).sort();
if (!slugs.length) throw new Error("没有拿到标签，停止生成（不删除旧页面）");
console.log(`标签 ${slugs.length} 个`);

const template = fs.readFileSync(path.join(ROOT, "index.html"), "utf8");
const browser = await chromium.launch();
const context = await browser.newContext({ locale: "en-US" });
await context.addInitScript(() => { window.__PRERENDER__ = true; });
await context.route("**/cloudflareinsights.com/**", r => r.abort());               // 生成页面不算访问量
await context.route(/^http:\/\/localhost:\d+\/(en|zh)(\/.*)?$/, r =>                 // 本地还没有这些文件，先用 index.html 顶上
  r.fulfill({ status: 200, contentType: "text/html; charset=utf-8", body: template }));

const jobs = [];
for (const lang of LANGS) {
  jobs.push({ url: `/${lang}/`, file: `${lang}/index.html`, tag: false });
  for (const slug of slugs) jobs.push({ url: `/${lang}/deals/${encodeURIComponent(slug)}/`, file: `${lang}/deals/${slug}/index.html`, tag: true });
}

const out = new Map();
let failed = 0;
async function render(page, job) {
  await page.goto(LOCAL + job.url, { waitUntil: "load" });
  if (job.tag) {
    await page.waitForFunction(() => /\/deals\//.test(document.getElementById("seoCanonical").href)
      && document.querySelector("#tagBody .rank-list, #tagBody .empty:not(:empty)") && !/Loading|正在加载/.test(document.getElementById("tagBody").textContent.slice(0, 40)), null, { timeout: 30000 });
  } else {
    await page.waitForFunction(() => document.querySelector("#featured .card-deal, #featured .empty") && document.querySelector("#hotTags li"), null, { timeout: 30000 });
  }
  await page.waitForTimeout(300);                                   // 不等图片和字体，内容到了就存
  return "<!DOCTYPE html>\n" + await page.evaluate(() => document.documentElement.outerHTML) + "\n";
}
async function worker() {
  const page = await context.newPage();
  while (jobs.length) {
    const job = jobs.shift();
    for (let tryNo = 1; ; tryNo++) {
      try { out.set(job.file, await render(page, job)); break; }
      catch (e) {
        if (tryNo >= 2) { failed++; console.log(`失败 ${job.url}: ${e.message.split("\n")[0]}`); break; }
      }
    }
  }
  await page.close();
}
await Promise.all(Array.from({ length: WORKERS }, worker));
await browser.close();
if (failed > slugs.length / 4) throw new Error(`失败太多（${failed} 个），不更新页面`);

// 全部换成新生成的：先删掉旧的 zh/ en/ 目录，再写入
for (const lang of LANGS) fs.rmSync(path.join(ROOT, lang), { recursive: true, force: true });
for (const [file, html] of out) {
  fs.mkdirSync(path.dirname(path.join(ROOT, file)), { recursive: true });
  fs.writeFileSync(path.join(ROOT, file), html);
}

// 网站地图：每个网址都写上中英文对应页面
const today = new Date().toISOString().slice(0, 10);
const alt = p => LANGS.map(l => `    <xhtml:link rel="alternate" hreflang="${l === "zh" ? "zh-Hans" : "en"}" href="${SITE}/${l}${p}"/>`).join("\n")
  + `\n    <xhtml:link rel="alternate" hreflang="x-default" href="${SITE}${p === "/" ? "/" : "/en" + p}"/>`;
const urls = [];
for (const lang of LANGS) {
  urls.push(`  <url>\n    <loc>${SITE}/${lang}/</loc>\n    <lastmod>${today}</lastmod>\n${alt("/")}\n  </url>`);
  for (const slug of slugs) {
    if (!out.has(`${lang}/deals/${slug}/index.html`)) continue;
    const p = `/deals/${encodeURIComponent(slug)}/`;
    urls.push(`  <url>\n    <loc>${SITE}/${lang}${p}</loc>\n    <lastmod>${today}</lastmod>\n${alt(p)}\n  </url>`);
  }
}
urls.push(`  <url>\n    <loc>${SITE}/privacy.html</loc>\n  </url>`);
fs.writeFileSync(path.join(ROOT, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${urls.join("\n")}\n</urlset>\n`);
console.log(`生成 ${out.size} 个页面，失败 ${failed} 个`);
