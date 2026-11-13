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
import re
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


SITE_URL = "https://subdeals.net/"
INK, MUTED, FAINT, LINE, SEAL, PAPER = "#17202A", "#5D6772", "#8B949E", "#D3D9DE", "#BE3A2E", "#ECEFF1"
FONT = "-apple-system,'PingFang SC','Microsoft YaHei','Noto Sans SC',Helvetica,Arial,sans-serif"


def money(x, cents=False):
    x = float(x)
    return f"${x:,.2f}" if cents or x != int(x) else f"${x:,.0f}"


def clean_title(t):
    """和网站一样：去掉开头的 [GPU] 标签，以及结尾的价格、商家、运费等"""
    t = re.sub(r"^\s*\[[^\]]{1,20}\]\s*", "", t or "")
    t = re.sub(r"^\s*[-–—•]+\s*", "", t)
    t = re.sub(r"^\s*\$[\d,.]+\*?\s*\|\s*", "", t)
    t = re.sub(r"\s*[-–:|,]?\s*\(\s*\$[\d,]+(?:\.\d+)?\*?\s*\)\s*$", "", t)
    t = re.sub(r"\s*(?:[-–:|,]\s*)?(?:(?:starting\s+at|as\s+low\s+as|from|for|at|only|now|just)\s+)?\$[\d,]+(?:\.\d+)?\*?(?:\s+.*)?$", "", t, flags=re.I)
    t = re.sub(r"\s*\[[^\]]{1,30}\]\s*$", "", t)
    t = re.sub(r"\s+@\s+[\w .'&-]+$", "", t)
    t = re.sub(r"\s*[-–:|,]\s*$", "", t)
    return t.strip()


def deal_block(d):
    facts = [CATEGORY_LABELS.get(d.get("category"), ""), CONDITION_LABELS.get(d.get("condition"), "")]
    if (d.get("quantity") or 1) > 1:
        facts.append(f'{d["quantity"]} 件装')
    if d.get("store"):
        facts.append(html.escape(d["store"]))
    if d.get("source") in SOURCE_LABELS:
        facts.append("来自 " + SOURCE_LABELS[d["source"]])
    facts_html = "&nbsp;&nbsp;&nbsp;".join(f for f in facts if f)
    return f"""
<tr><td style="padding:26px 0;border-bottom:1px solid {LINE};">
  <table width="100%" cellpadding="0" cellspacing="0"><tr>
    <td valign="top" style="font:500 16px/1.5 {FONT};color:{INK};padding-right:16px;">
      <a href="{html.escape(d['url'])}" style="color:{INK};text-decoration:none;">{html.escape(clean_title(d['title']))}</a>
      <div style="font:13px/1.6 {FONT};color:{MUTED};margin-top:6px;">{facts_html}</div>
    </td>
    <td valign="top" align="right" style="white-space:nowrap;">
      <div style="font:800 26px/1 {FONT};color:{INK};letter-spacing:-0.3px;">{money(d['price'])}</div>
    </td>
  </tr></table>
  <div style="margin-top:12px;"><a href="{html.escape(d['url'])}" style="font:500 13px {FONT};color:{INK};">查看这个优惠</a></div>
</td></tr>"""


def build_html(deals, date_text):
    order = list(CATEGORY_LABELS)
    deals = sorted(deals, key=lambda d: (order.index(d["category"]) if d.get("category") in order else 99))
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:{PAPER};">
<table width="100%" cellpadding="0" cellspacing="0" style="background:{PAPER};"><tr><td align="center" style="padding:28px 12px;">
<table width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;">
  <tr><td style="padding:0 4px 28px;">
    <table cellpadding="0" cellspacing="0"><tr>
      <td style="background:{SEAL};color:#ffffff;font:900 12px/1.05 'Songti SC','Noto Serif SC',serif;padding:5px 6px;border-radius:4px;text-align:center;">精<br>选</td>
      <td style="padding-left:10px;font:700 17px {FONT};color:{INK};">Subdeals</td>
    </tr></table>
  </td></tr>
  <tr><td style="padding:0 4px 8px;">
    <div style="font:700 24px/1.4 {FONT};color:{INK};">今天有 {len(deals)} 条优惠低于价格线</div>
    <div style="font:14px/1.7 {FONT};color:{MUTED};margin-top:6px;">{date_text}。每条都低于我们给这个型号定的价格线。好价格通常很快就没了，下单前请在商家页面确认价格、成色和库存。</div>
  </td></tr>
  <tr><td style="padding:0 4px;">
    <table width="100%" cellpadding="0" cellspacing="0" style="border-top:1px solid {LINE};">
      {''.join(deal_block(d) for d in deals)}
    </table>
  </td></tr>
  <tr><td style="padding:24px 4px 0;font:13px/1.7 {FONT};color:{FAINT};">
    在网站上查看全部：<a href="{SITE_URL}" style="color:{MUTED};">{SITE_URL.replace("https://", "").rstrip("/")}</a>
  </td></tr>
</table>
</td></tr></table>
</body></html>"""


def create_draft(deals):
    now = datetime.now(ET)
    date_text = now.strftime("%Y-%m-%d")
    body = {
        "name": f"Deal 精选 {now.strftime('%Y-%m-%d %H:%M')}",
        "type": "regular",
        "emails": [{
            "subject": f"今天有 {len(deals)} 条优惠低于价格线（{date_text}）",
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
         "price": 2499.99, "price_checked": 2499.99, "threshold": 2645, "condition": "new", "store": "Best Buy", "quantity": 1, "source": "slickdeals"},
        {"category": "graphics_card", "title": "ZOTAC RTX 5070 Ti SOLID 16GB", "url": "https://slickdeals.net/",
         "price": 699.99, "price_checked": 699.99, "threshold": 1200, "condition": "new", "store": "Newegg", "quantity": 1, "source": "reddit"},
        {"category": "hdd", "title": "Seagate Exos X18 18TB Recertified (2-Pack)", "url": "https://slickdeals.net/",
         "price": 399.98, "price_checked": 11.11, "threshold": 24.9, "condition": "refurb",
         "store": "ServerPartDeals", "quantity": 2},
    ]
    open("preview.html", "w", encoding="utf-8").write(build_html(sample, datetime.now(ET).strftime("%Y-%m-%d")))
    print("已生成 preview.html")


if __name__ == "__main__":
    preview() if "--preview" in sys.argv else main()
