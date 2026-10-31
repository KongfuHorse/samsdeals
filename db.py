"""
Supabase 读写（用 REST 接口，不需要额外安装 supabase 库）
需要环境变量：SUPABASE_URL、SUPABASE_SERVICE_KEY
"""
import os
import requests


def _base():
    return os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1"


def _headers(extra=None):
    key = os.environ["SUPABASE_SERVICE_KEY"]
    h = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    h.update(extra or {})
    return h


def _get(table, params):
    r = requests.get(f"{_base()}/{table}", headers=_headers(), params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def load_rules():
    rules = _get("price_rules", {"active": "eq.true", "select": "*"})
    adjustments = _get("price_adjustments", {"active": "eq.true", "select": "*"})
    return rules, adjustments


def load_options():
    """返回 {"category": [...], "gpu": [...], ...}"""
    rows = _get("field_options", {"active": "eq.true", "select": "field,value", "order": "sort_order"})
    options = {}
    for r in rows:
        options.setdefault(r["field"], []).append(r["value"])
    return options


def existing_urls(urls):
    """返回已经在库里的链接，避免重复解析（省 AI 费用）"""
    found = set()
    for i in range(0, len(urls), 50):
        chunk = urls[i:i + 50]
        quoted = ",".join('"' + u.replace('"', '') + '"' for u in chunk)
        for row in _get("deals", {"select": "url", "url": f"in.({quoted})"}):
            found.add(row["url"])
    return found


def save_deals(rows):
    if not rows:
        return
    r = requests.post(
        f"{_base()}/deals",
        headers=_headers({"Prefer": "resolution=ignore-duplicates,return=minimal"}),
        params={"on_conflict": "url"},
        json=rows,
        timeout=30,
    )
    r.raise_for_status()


def deals_to_email():
    """达标、还没放进邮件草稿的 deal"""
    return _get("deals", {"select": "*", "status": "eq.passed",
                          "emailed_at": "is.null", "order": "category,created_at.desc"})


def mark_emailed(ids, campaign_id, when):
    if not ids:
        return
    r = requests.patch(
        f"{_base()}/deals",
        headers=_headers({"Prefer": "return=minimal"}),
        params={"id": f"in.({','.join(str(i) for i in ids)})"},
        json={"emailed_at": when, "email_campaign_id": str(campaign_id)},
        timeout=30,
    )
    r.raise_for_status()


def seen_articles(urls):
    """返回已经读过的文章链接（文章不管有没有 deal 都只读一次）"""
    found = set()
    for i in range(0, len(urls), 50):
        quoted = ",".join('"' + u.replace('"', '') + '"' for u in urls[i:i + 50])
        for row in _get("seen_articles", {"select": "url", "url": f"in.({quoted})"}):
            found.add(row["url"])
    return found


def mark_articles_seen(rows):
    """rows: [{"url", "source", "deals_found"}]"""
    if not rows:
        return
    r = requests.post(
        f"{_base()}/seen_articles",
        headers=_headers({"Prefer": "resolution=ignore-duplicates,return=minimal"}),
        params={"on_conflict": "url"},
        json=rows,
        timeout=30,
    )
    r.raise_for_status()
