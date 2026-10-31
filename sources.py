"""
抓取 deal 来源。两种类型：
  - 帖子型（Slickdeals、Reddit）：一个标题 = 一个 deal，标题里有价格
  - 文章型（Tom's Hardware、TechRadar）：一篇文章里可能有多个 deal，价格在正文里
要加新来源：在 POST_FEEDS 或 ARTICLE_FEEDS 里加一行即可。
"""
import calendar
import re
import time

import feedparser
import requests
from bs4 import BeautifulSoup

HEADERS = {"User-Agent": "Mozilla/5.0 (deal-filter demo)"}

# 帖子型：(来源名, RSS 地址)
POST_FEEDS = [
    ("slickdeals", "https://slickdeals.net/newsearch.php?mode=frontpage&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?mode=popdeals&searcharea=deals&searchin=first&rss=1"),
    # 按显卡型号分开搜：每个 RSS 只保留最新 25 条，分开搜不容易被新帖子挤掉
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=rtx+5090&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=rtx+5080&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=rtx+5070+ti&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=rtx+5070&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=rtx+5060&searcharea=deals&searchin=first&rss=1"),    ("slickdeals", "https://slickdeals.net/newsearch.php?q=hard+drive&searcharea=deals&searchin=first&rss=1"),
    ("slickdeals", "https://slickdeals.net/newsearch.php?q=ssd&searcharea=deals&searchin=first&rss=1"),
    ("reddit", "https://www.reddit.com/r/buildapcsales/new/.rss"),
]

# 标题像 deal 的文章才读（用于混有新闻的 RSS）
DEAL_TITLE = re.compile(r"(deal|save |saving|\$\d|% off|lowest price|record low|price drop|sale\b)", re.I)

# 文章型：(来源名, RSS 地址, 是否只读标题像 deal 的文章)
ARTICLE_FEEDS = [
    ("tomshardware", "https://www.tomshardware.com/feeds.xml", True),   # 主 RSS，新闻和 deal 混在一起
    ("techradar", "https://www.techradar.com/feeds/tag/deals", False),   # 本身就是 deal 专栏
]

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


def fetch_posts():
    items, seen = [], set()
    for source, url in POST_FEEDS:
        for e in _parse(url):
            link, title = _clean_link(e.get("link")), (e.get("title") or "").strip()
            if not link or not title or link in seen or _too_old(e):
                continue
            seen.add(link)
            if KEYWORDS.search(title):
                items.append({"title": title, "url": link, "source": source})
    print(f"帖子：抓到 {len(seen)} 条，关键词粗筛后 {len(items)} 条")
    return items


def html_to_text(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style", "nav", "footer", "aside", "form"]):
        tag.decompose()
    # 先找正文区域（Tom's Hardware、TechRadar 用 #article-body），找不到再用整篇
    body = soup.select_one("#article-body") or soup.find("article") or soup.body or soup
    text = re.sub(r"\n\s*\n+", "\n", body.get_text("\n"))
    return text.strip()


def fetch_articles():
    """返回 [{"title", "url", "source", "text"}]，text 是正文纯文本"""
    articles, seen = [], set()
    for source, url, deal_titles_only in ARTICLE_FEEDS:
        for e in _parse(url):
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
