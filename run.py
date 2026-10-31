"""
主程序：抓取 → AI 解析 → 筛选 → 存进 Supabase
用法：
  python run.py                    正式运行（需要 Supabase 和 Claude 的 key）
  python run.py --dry-run          测试帖子型：用 sample_titles.txt，只用 Claude key，不写数据库
  python run.py --dry-run-article  测试文章型：用 sample_article.txt，只用 Claude key，不写数据库
"""
import re
import sys

from deal_filter import check_deal
from parser import extract_from_article, parse_titles

# 测试模式用的默认选项（和 schema.sql 一致）
DRY_OPTIONS = {
    "category": ["hdd", "ssd", "laptop", "desktop", "graphics_card"],
    "gpu": ["RTX 5050", "RTX 5060", "RTX 5060 Ti", "RTX 5070", "RTX 5070 Ti", "RTX 5080", "RTX 5090"],
    "condition": ["new", "open_box", "refurb", "used"],
    "series": ["ROG", "Alienware"],
}

DB_COLUMNS = ["title", "url", "article_url", "source", "store", "price", "category", "gpu", "ram_gb",
              "capacity_tb", "quantity", "brand", "series", "condition", "status", "price_checked",
              "threshold", "adjustments_applied", "matched_rule_id"]


GPU_CATEGORIES = ("laptop", "desktop", "graphics_card")


def judge(row, rules, adjustments, options, text):
    """AI 解析后再用程序检查一遍，然后按规则筛选。text = 原始标题或文章正文"""
    gpu = row.get("gpu")
    if gpu:
        number = re.search(r"\d{4}", gpu)
        if gpu not in options.get("gpu", []) or not number or number.group() not in text:
            row["gpu"] = None                       # AI 给的显卡不在选项里，或原文里没出现，就不信
    if row.get("category") in (None, "other"):
        row["status"] = "other"
    elif row["category"] in GPU_CATEGORIES and not row.get("gpu"):
        row["status"] = "other"                     # 没有 RTX 50 系显卡的电脑/显卡，不在范围内
    else:
        row.update(check_deal(row, rules, adjustments))
    return row


def process_posts(items, options, rules, adjustments):
    parsed = parse_titles([it["title"] for it in items], options)
    rows = []
    for it, p in zip(items, parsed):
        row = dict(it)
        if p is None:
            row["status"] = "need_info"
        else:
            row.update(p)
            judge(row, rules, adjustments, options, it["title"])
        rows.append(row)
    return rows


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:80]


def process_article(article, text, options, rules, adjustments):
    rows = []
    for d in extract_from_article(article["title"], text, options):
        row = dict(d)
        row["source"] = article["source"]
        row["article_url"] = article["url"]
        row["url"] = f"{article['url']}#{slug(d['title'])}"   # 每个 deal 一个唯一链接
        rows.append(judge(row, rules, adjustments, options, text))
    return rows


def to_db_rows(rows):
    out = []
    for r in rows:
        o = {k: r.get(k) for k in DB_COLUMNS}        # 每行的列必须一样，缺的填空
        o["quantity"] = o["quantity"] or 1
        out.append(o)
    return out


def show(rows):
    for r in rows:
        extra = f"  比较价 {r['price_checked']} / 标准 {r['threshold']}" if r.get("threshold") else ""
        print(f"[{r['status']:10s}] {r['title'][:70]}{extra}")
        print(f"             -> {r.get('category')}, {r.get('gpu')}, {r.get('capacity_tb')}TB x{r.get('quantity')}, "
              f"{r.get('brand')} {r.get('series')}, {r.get('condition')}, ${r.get('price')}, {r.get('store')}")


def dry_run():
    from schema_rules import RULES, ADJUSTMENTS
    titles = [t.strip() for t in open("sample_titles.txt", encoding="utf-8") if t.strip()]
    items = [{"title": t, "url": f"test://{i}", "source": "test"} for i, t in enumerate(titles)]
    rows = process_posts(items, DRY_OPTIONS, RULES, ADJUSTMENTS)
    show(rows)
    return rows


def dry_run_article():
    from schema_rules import RULES, ADJUSTMENTS
    from sources import html_to_text
    raw = open("sample_article.txt", encoding="utf-8").read()
    title, html = raw.split("\n", 1)
    article = {"title": title.strip(), "url": "https://example.com/test-article", "source": "test"}
    rows = process_article(article, html_to_text(html), DRY_OPTIONS, RULES, ADJUSTMENTS)
    print(f"文章里找到 {len(rows)} 个相关 deal")
    show(rows)
    return rows


def main():
    import db
    from datetime import datetime, timezone
    from sources import KEYWORDS, fetch_articles, fetch_posts, fetch_woot, load_article_text

    started = datetime.now(timezone.utc).isoformat()
    rules, adjustments = db.load_rules()
    options = db.load_options()
    all_rows = []

    # 1. 帖子型（Slickdeals、Reddit、Woot）
    posts = fetch_posts() + fetch_woot()
    if posts:
        known = db.existing_urls([it["url"] for it in posts])
        new_posts = [it for it in posts if it["url"] not in known]
        print(f"新帖子 {len(new_posts)} 条")
        if new_posts:
            rows = process_posts(new_posts, options, rules, adjustments)
            db.save_deals(to_db_rows(rows))
            all_rows += rows

    # 2. 文章型（每篇只读一次）
    articles = fetch_articles()
    if articles:
        seen = db.seen_articles([a["url"] for a in articles])
        new_articles = [a for a in articles if a["url"] not in seen]
        print(f"新文章 {len(new_articles)} 篇")
        for a in new_articles:
            text = load_article_text(a)
            rows = []
            if KEYWORDS.search(a["title"] + " " + text):
                try:
                    rows = process_article(a, text, options, rules, adjustments)
                except Exception as e:
                    print(f"[warn] 文章解析失败 {a['url']}: {e}")
                    continue                     # 不标记为已读，下次再试
            db.save_deals(to_db_rows(rows))
            db.mark_articles_seen([{"url": a["url"], "source": a["source"], "deals_found": len(rows)}])
            all_rows += rows

    passed = [r for r in all_rows if r.get("status") == "passed"]
    print(f"本次新增 {len(all_rows)} 条，其中达标 {len(passed)} 条")
    for r in passed:
        print("  ✓", r["title"])

    # 记录这次运行，网站上显示"上次抓取"信息
    db.save_run({
        "started_at": started,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "checked": len(posts) + len(articles),     # 本次检查的帖子/商品数 + 文章数
        "new_deals": len(all_rows),
        "passed": len(passed),
    })


if __name__ == "__main__":
    if "--dry-run-article" in sys.argv:
        dry_run_article()
    elif "--dry-run" in sys.argv:
        dry_run()
    else:
        main()
