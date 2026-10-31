"""
生成 MailerLite 邮件草稿：把还没发过的达标 deal 做成一封邮件，存成草稿。
不会自动发送。你在 MailerLite 后台检查后，自己点发送。

用法：
  python email_draft.py              正式运行
  python email_draft.py --preview    只生成 preview.html 看效果（用测试数据，不需要任何 key）
需要环境变量：MAILERLITE_API_KEY、MAILERLITE_FROM_EMAIL
可选：MAILERLITE_GROUP_ID（只发给这个分组；不填 = 所有订阅者）、MAILERLITE_FROM_NAME
"""
import html
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import requests

ET = ZoneInfo("America/New_York")
CATEGORY_LABELS = {
    "laptop": "游戏笔记本", "desktop": "台式机", "graphics_card": "显卡",
    "ssd": "固态硬盘", "hdd": "机械硬盘",
}
CONDITION_LABELS = {"new": "全新", "open_box": "开箱", "refurb": "翻新", "used": "二手"}
SOURCE_LABELS = {"slickdeals": "Slickdeals", "reddit": "Reddit", "tomshardware": "Tom's Hardware", "techradar": "TechRadar", "woot": "Woot"}


def money(x):
    return f"${x:,.2f}".replace(".00", "")


def build_html(deals, date_text):
    groups = {}
    for d in deals:
        groups.setdefault(d.get("category"), []).append(d)

    parts = []
    for cat in CATEGORY_LABELS:
        if cat not in groups:
            continue
        parts.append(f'<h2 style="font-size:18px;margin:28px 0 8px;color:#111;">{CATEGORY_LABELS[cat]}</h2>')
        for d in groups[cat]:
            if d.get("category") == "hdd" and d.get("price_checked"):
                compare = f'每 TB {money(d["price_checked"])}（标准 {money(d["threshold"])}）'
            else:
                compare = f'标准 {money(d["threshold"])}'
            tags = [CONDITION_LABELS.get(d.get("condition"), "")]
            if (d.get("quantity") or 1) > 1:
                tags.append(f'{d["quantity"]} 件装')
            if d.get("store"):
                tags.append(html.escape(d["store"]))
            if d.get("source") in SOURCE_LABELS:
                tags.append("来自 " + SOURCE_LABELS[d["source"]])
            parts.append(f"""
<table width="100%" cellpadding="0" cellspacing="0" style="border:1px solid #e5e5e5;border-radius:8px;margin:0 0 10px;">
<tr><td style="padding:12px 14px;font-family:Arial,sans-serif;">
  <a href="{html.escape(d['url'])}" style="color:#0b57d0;font-size:15px;text-decoration:none;font-weight:bold;">{html.escape(d['title'])}</a>
  <div style="margin-top:6px;font-size:14px;color:#333;">
    <b style="color:#0a7a2f;font-size:16px;">{money(d['price'])}</b>
    &nbsp;·&nbsp;{compare}
  </div>
  <div style="margin-top:4px;font-size:12px;color:#777;">{' · '.join(t for t in tags if t)}</div>
</td></tr></table>""")

    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;background:#f6f6f6;">
<table width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:20px 10px;">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;background:#fff;border-radius:10px;">
<tr><td style="padding:24px;font-family:Arial,sans-serif;">
  <h1 style="font-size:22px;margin:0 0 4px;color:#111;">今日达标 Deal</h1>
  <div style="font-size:13px;color:#777;">{date_text} · 共 {len(deals)} 条 · 价格随时可能变化，以商家页面为准</div>
  {''.join(parts)}
</td></tr></table>
</td></tr></table>
</body></html>"""


def create_draft(deals):
    now = datetime.now(ET)
    date_text = now.strftime("%Y-%m-%d")
    body = {
        "name": f"Deal 精选 {now.strftime('%Y-%m-%d %H:%M')}",
        "type": "regular",
        "emails": [{
            "subject": f"今日达标 Deal {len(deals)} 条（{date_text}）",
            "from_name": os.environ.get("MAILERLITE_FROM_NAME") or "Deal Alerts",
            "from": os.environ["MAILERLITE_FROM_EMAIL"],
            "content": build_html(deals, date_text),
        }],
    }
    if os.environ.get("MAILERLITE_GROUP_ID"):
        body["groups"] = [os.environ["MAILERLITE_GROUP_ID"]]

    r = requests.post(
        "https://connect.mailerlite.com/api/campaigns",
        headers={"Authorization": f"Bearer {os.environ['MAILERLITE_API_KEY']}",
                 "Content-Type": "application/json", "Accept": "application/json"},
        json=body,
        timeout=30,
    )
    if r.status_code >= 400:
        print("MailerLite 返回错误：", r.status_code, r.text[:500])
        r.raise_for_status()
    return r.json()["data"]["id"], now


def main():
    import db
    deals = db.deals_to_email()
    if not deals:
        print("没有新的达标 deal，不生成草稿")
        return
    campaign_id, now = create_draft(deals)
    db.mark_emailed([d["id"] for d in deals], campaign_id, now.isoformat())
    print(f"已生成草稿（{len(deals)} 条 deal），去 MailerLite 后台 Campaigns → Drafts 检查并发送")


def preview():
    sample = [
        {"category": "laptop", "title": "ASUS ROG Strix G16 RTX 5080 32GB 2TB", "url": "https://slickdeals.net/",
         "price": 2499.99, "threshold": 2645, "condition": "new", "store": "Best Buy", "quantity": 1},
        {"category": "graphics_card", "title": "ZOTAC RTX 5070 Ti SOLID 16GB", "url": "https://slickdeals.net/",
         "price": 699.99, "threshold": 1200, "condition": "new", "store": "Newegg", "quantity": 1},
        {"category": "hdd", "title": "Seagate Exos X18 18TB Recertified (2-Pack)", "url": "https://slickdeals.net/",
         "price": 399.98, "price_checked": 11.11, "threshold": 24.9, "condition": "refurb",
         "store": "ServerPartDeals", "quantity": 2},
    ]
    open("preview.html", "w", encoding="utf-8").write(build_html(sample, datetime.now(ET).strftime("%Y-%m-%d")))
    print("已生成 preview.html")


if __name__ == "__main__":
    preview() if "--preview" in sys.argv else main()
