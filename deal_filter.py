"""
Deal 筛选（只判断是否达标，不打分）
规则全部从 Supabase 的 price_rules / price_adjustments 两张表读取。
改规则只需要改表，不需要改这个文件。
"""

MATCH_FIELDS = ("gpu", "ram_gb", "capacity_tb")   # 基础规则可以按这几列区分
NUMBER_FIELDS = ("ram_gb", "capacity_tb")


def norm(x):
    return str(x).strip().lower()


def rule_matches(rule, deal):
    if not rule["active"] or norm(rule["category"]) != norm(deal.get("category", "")):
        return False
    for f in MATCH_FIELDS:
        want = rule.get(f)
        if want is None:
            continue                      # 规则里留空 = 不限
        have = deal.get(f)
        if have is None:
            return False
        if f in NUMBER_FIELDS:
            if float(want) != float(have):
                return False
        elif norm(want) != norm(have):
            return False
    return True


def specificity(rule):
    return sum(1 for f in MATCH_FIELDS if rule.get(f) is not None)


def adjustment_applies(adj, deal):
    if not adj["active"]:
        return False
    if adj.get("category") and norm(adj["category"]) != norm(deal.get("category", "")):
        return False
    have = deal.get(adj["field"])
    if have is None:
        return False
    return norm(have) in [norm(v) for v in adj["value"].split(",")]


def check_deal(deal, rules, adjustments):
    """返回 status：passed（达标）/ not_passed（没达标）/ no_rule（没有规则）/ need_info（缺信息）"""
    candidates = [r for r in rules if rule_matches(r, deal)]
    if not candidates:
        return {"status": "no_rule"}
    rule = max(candidates, key=specificity)

    factor, extra, applied = 1.0, 0.0, []
    for a in adjustments:
        if adjustment_applies(a, deal):
            factor *= 1 + (a.get("pct") or 0) / 100
            extra += a.get("amount") or 0
            applied.append(a.get("note") or f"{a['field']}={deal[a['field']]}")
    threshold = rule["max_price"] * factor + extra

    if not deal.get("price"):
        return {"status": "need_info", "matched_rule_id": rule["id"]}
    unit_price = deal["price"] / (deal.get("quantity") or 1)   # 多件装按单件算

    if rule.get("price_mode") == "per_tb":
        cap = deal.get("capacity_tb")
        if not cap:
            return {"status": "need_info", "matched_rule_id": rule["id"]}
        price = unit_price / cap
    else:
        price = unit_price

    return {
        "status": "passed" if price < threshold else "not_passed",
        "price_checked": round(price, 2),
        "threshold": round(threshold, 2),
        "adjustments_applied": "; ".join(applied),
        "matched_rule_id": rule["id"],
    }


# ---------- 测试：python deal_filter.py ----------
if __name__ == "__main__":
    from schema_rules import RULES, ADJUSTMENTS

    def D(cat, price, gpu=None, cap=None, series=None, cond="new", qty=1):
        return {"category": cat, "price": price, "gpu": gpu, "capacity_tb": cap,
                "series": series, "condition": cond, "quantity": qty}

    tests = [
        ("HDD 20TB $449.99",          D("hdd", 449.99, cap=20)),
        ("HDD 12TB $319",             D("hdd", 319, cap=12)),
        ("HDD 20TB 两件装 $879",        D("hdd", 879, cap=20, qty=2)),
        ("HDD 没写容量 $199",           D("hdd", 199)),
        ("SSD 4TB $329",              D("ssd", 329, cap=4)),
        ("SSD 2TB $279",              D("ssd", 279, cap=2)),
        ("SSD 1TB $89",               D("ssd", 89, cap=1)),
        ("5080 ROG 全新 $2599",        D("laptop", 2599, "RTX 5080", series="ROG")),
        ("5080 Legion 开箱 $2199",     D("laptop", 2199, "RTX 5080", series="Legion", cond="open_box")),
        ("5090 Alienware 翻新 $3499",  D("laptop", 3499, "RTX 5090", series="Alienware", cond="refurb")),
        ("5080 台式机 $2299",           D("desktop", 2299, "RTX 5080")),
        ("5090 显卡 开箱 $5100",        D("graphics_card", 5100, "RTX 5090", cond="open_box")),
    ]
    for name, deal in tests:
        print(f"{name:26s} -> {check_deal(deal, RULES, ADJUSTMENTS)}")
