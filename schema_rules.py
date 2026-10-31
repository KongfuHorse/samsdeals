"""
测试用的规则副本（和 schema.sql 里的一致）。
正式运行时规则从 Supabase 读取，不用这个文件。
"""


def _r(id, cat, max_price, gpu=None, cap=None, mode="total"):
    return {"id": id, "category": cat, "gpu": gpu, "ram_gb": None, "capacity_tb": cap,
            "price_mode": mode, "max_price": max_price, "active": True}


RULES = [
    _r(1, "hdd", 24.9, mode="per_tb"),
    _r(2, "ssd", 359, cap=4), _r(3, "ssd", 269, cap=2),
    _r(4, "laptop", 999, "RTX 5060"), _r(5, "laptop", 2300, "RTX 5080"), _r(6, "laptop", 3500, "RTX 5090"),
    _r(7, "desktop", 2399, "RTX 5080"), _r(8, "desktop", 7500, "RTX 5090"),
    _r(9, "graphics_card", 1200, "RTX 5070 Ti"), _r(10, "graphics_card", 1599, "RTX 5080"),
    _r(11, "graphics_card", 5500, "RTX 5090"),
]

ADJUSTMENTS = [
    {"category": "laptop", "field": "condition", "value": "open_box,refurb,used", "pct": -10, "amount": 0,
     "note": "笔记本非全新 降 10%", "active": True},
    {"category": "laptop", "field": "series", "value": "Alienware,ROG", "pct": 15, "amount": 0,
     "note": "Alienware / ROG 上浮 15%", "active": True},
    {"category": "graphics_card", "field": "condition", "value": "open_box,refurb,used", "pct": -10, "amount": 0,
     "note": "显卡非全新 降 10%", "active": True},
]
