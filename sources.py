"""
抓取 deal 来源。两种类型：
  - 帖子型（Slickdeals、Reddit）：一个标题 = 一个 deal，标题里有价格
  - 文章型（Tom's Hardware、TechRadar）：一篇文章里可能有多个 deal，价格在正文里
  - Woot：用官方 API（需要 WOOT_API_KEY），每个商品当作一条帖子处理
来源列表在 Supabase 的 sources 表里，后台可以开关；要加新来源，在表里加一行。
"""
import calendar
import json
import os
import re
import time

import feedparser
import requests
from bs4 import BeautifulSoup

HEADERS = {"User-Agent": "Mozilla/5.0 (deal-filter demo)"}

# 所有来源都存在 Supabase 的 sources 表里，后台可以开关。
# 每个来源：{"key", "name", "kind": post_rss / article_rss / woot, "url", "deal_titles_only", "enabled"}

# 标题像 deal 的文章才读（用于混有新闻的 RSS）
DEAL_TITLE = re.compile(r"(deal|save |saving|\$\d|% off|lowest price|record low|price drop|sale\b)", re.I)


def source_label(key):
    """存进 deals 表的来源名，网站上显示用"""
    if key.startswith("sd_") or key.startswith("auto_"):
        return "slickdeals"
    if key.startswith("reddit"):
        return "reddit"
    if key.startswith("woot"):
        return "woot"
    return key

# 关键词粗筛：只把可能相关的内容交给 AI，省钱
KEYWORDS = re.compile(
    r"\b(hdd|hard drive|ssd|nvme|m\.2|\d+\s?tb|rtx|geforce|50[5-9]0|laptop|notebook|"
    r"desktop|gaming pc|prebuilt|graphics card|gpu|alienware|rog|legion|omen)\b",
    re.I,
)
ARTICLE_MAX_CHARS = 15000   # 文章太长就截断，控制 AI 费用
MAX_AGE_DAYS = 3            # 只看最近几天发布的内容，避免旧 deal 被当成新的


def _parse(url):
    try:
        return feedparser.parse(url, request_headers=HEADERS).entries
    except Exception as e:                  # 一个来源出错不影响其他来源
        print(f"[warn] 抓取失败 {url}: {e}")
        return []


def _too_old(entry):
    t = entry.get("published_parsed") or entry.get("updated_parsed")
    if not t:
        return False                       # 没有日期就不跳过
    return time.time() - calendar.timegm(t) > MAX_AGE_DAYS * 86400


def _clean_link(link):
    return (link or "").split("?")[0]     # 去掉追踪参数，方便去重


def fetch_posts(sources):
    """返回 (帖子列表, 这次有相关结果的自动来源的 key)。
    自动来源 = 用户新建标签时自动加的 Slickdeals 搜索（sources 表里 auto = true）。
    它们的帖子不走关键词粗筛（否则 MacBook 这类不在品类里的标题会被丢掉），
    改成只保留标题里包含这个标签全部关键词的帖子。"""
    items, seen, hits = [], set(), set()
    active = [s for s in sources if s["kind"] == "post_rss" and s["enabled"]]
    for src in sorted(active, key=lambda s: not s.get("auto")):       # 自动来源先处理，避免被别的来源去重掉
        source = source_label(src["key"])
        auto, keywords = bool(src.get("auto")), [k.lower() for k in src.get("tag_keywords") or []]
        for e in _parse(src["url"]):
            link, title = _clean_link(e.get("link")), (e.get("title") or "").strip()
            if not link or not title or _too_old(e):
                continue
            relevant = auto and keywords and all(k in title.lower() for k in keywords)
            if relevant:
                hits.add(src["key"])
            if link in seen:
                continue
            seen.add(link)
            if relevant or KEYWORDS.search(title):
                items.append({"title": title, "url": link, "source": source})
    print(f"帖子：抓到 {len(seen)} 条，筛选后 {len(items)} 条")
    return items, hits


def html_to_text(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "nav", "footer", "aside", "form"]):
        tag.decompose()
    # 先找正文区域（Tom's Hardware、TechRadar 用 #article-body），找不到再用整篇
    body = soup.select_one("#article-body") or soup.find("article") or soup.body or soup
    text = re.sub(r"\n\s*\n+", "\n", body.get_text("\n"))
    return text.strip()


def fetch_articles(sources):
    """返回 [{"title", "url", "source", "html"}]"""
    articles, seen = [], set()
    for src in sources:
        if src["kind"] != "article_rss" or not src["enabled"]:
            continue
        source, deal_titles_only = source_label(src["key"]), src.get("deal_titles_only")
        for e in _parse(src["url"]):
            link, title = _clean_link(e.get("link")), (e.get("title") or "").strip()
            if not link or link in seen or _too_old(e):
                continue
            if deal_titles_only and not DEAL_TITLE.search(title):
                continue
            seen.add(link)
            content = ""
            if e.get("content"):
                content = e["content"][0].get("value", "")
            content = content or e.get("summary", "")
            articles.append({"title": title, "url": link, "source": source, "html": content})
    print(f"文章：抓到 {len(articles)} 篇")
    return articles


def load_article_text(article):
    """RSS 里的内容太短或没有价格时，去文章页面取全文"""
    text = html_to_text(article.get("html") or "")
    if len(text) < 1500 or "$" not in text:
        try:
            r = requests.get(article["url"], headers=HEADERS, timeout=20)
            r.raise_for_status()
            text = html_to_text(r.text)
        except Exception as e:
            print(f"[warn] 打不开文章 {article['url']}: {e}")
    return text[:ARTICLE_MAX_CHARS]


# ---------------- Woot（官方 API） ----------------
WOOT_MAX_PAGES = 10


def fetch_woot(sources):
    """返回 [{"title", "url", "source"}]。标题里拼上成色和价格，交给 AI 解析。
    来源的 url 字段填 Woot 分类名，比如 Computers"""
    feeds = [src["url"] for src in sources if src["kind"] == "woot" and src["enabled"]]
    if not feeds:
        return []
    key = os.environ.get("WOOT_API_KEY")
    if not key:
        print("[info] 没有设置 WOOT_API_KEY，跳过 Woot")
        return []
    headers = {"x-api-key": key, "Content-Type": "application/json"}
    offers = {}
    try:
        for feed in feeds:
            page = 1
            while True:
                r = requests.get(f"https://developer.woot.com/feed/{feed}", headers=headers,
                                 params={"page": page}, timeout=30)
                r.raise_for_status()
                d = r.json()
                for o in d.get("Items", []):
                    offers[o["OfferId"]] = o
                if page >= min(d.get("TotalPages") or 1, WOOT_MAX_PAGES):
                    break
                page += 1
    except Exception as e:
        print(f"[warn] Woot 抓取失败: {e}")
        return []

    relevant = [o for o in offers.values() if not o.get("IsSoldOut") and KEYWORDS.search(o.get("Title", ""))]
    items, variants = [], []
    for o in relevant:
        sp = o.get("SalePrice") or {}
        if sp.get("Minimum") is not None and sp.get("Minimum") == sp.get("Maximum"):
            cond = o.get("Condition") or "New"
            items.append({"title": f"{o['Title']} - {cond} - ${sp['Minimum']}",
                          "url": _clean_link(o["Url"]), "source": "woot"})
        else:
            variants.append(o)

    # 有多个规格（价格是区间）的商品：查每个规格的价格，一个规格一条
    for i in range(0, len(variants), 25):
        chunk = variants[i:i + 25]
        try:
            r = requests.post("https://developer.woot.com/getoffers", headers=headers,
                              data=json.dumps([o["OfferId"] for o in chunk]), timeout=30)
            r.raise_for_status()
            details = r.json()
        except Exception as e:
            print(f"[warn] Woot 规格查询失败: {e}")
            continue
        for offer in details:
            base = _clean_link(offer.get("Url") or "")
            for n, it in enumerate(offer.get("Items") or []):
                if it.get("IsSoldOut") or it.get("SalePrice") is None:
                    continue
                attrs = ", ".join(str(a.get("Value")) for a in it.get("Attributes") or [] if a.get("Value"))
                items.append({"title": f"{offer.get('Title')} ({attrs}) - ${it['SalePrice']}",
                              "url": f"{base}#item-{n + 1}", "source": "woot"})
    print(f"Woot：{len(offers)} 个商品，关键词粗筛后 {len(relevant)} 个，展开规格后 {len(items)} 条")
    return items
