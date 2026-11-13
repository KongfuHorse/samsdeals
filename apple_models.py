"""
苹果产品型号表：每个型号就是网站上的一个标签。
- key：程序用的值（也是标签网址 ?t=key），AI 解析时只能从这里选
- name：标签名
- hint：给 AI 看的说明（芯片、年份），帮它判断标题属于哪个型号
- aliases：搜索时也能认出来的写法
改了这个文件以后，运行 python apple_models.py > schema_apple_seed.sql，再把生成的 SQL 在 Supabase 运行一次。
"""

# 同一代芯片的普通版 / Pro / Max / Ultra 放在一个"Series"标签里；OLED 款单独一个标签（名字最后写 OLED）
APPLE_MODELS = [
    # ---------- MacBook Pro 14 ----------
    ("mbp14-m6", "MacBook Pro 14 M6 Series", "MacBook Pro 14-inch with M6 / M6 Pro / M6 Max (Nov 2026 or later)", ["mbp 14 m6", "macbook pro 14 m6"]),
    ("mbp14-m5", "MacBook Pro 14 M5 Series", "MacBook Pro 14-inch with M5 (Oct 2025) or M5 Pro / M5 Max (Mar 2026), mini-LED display, NOT the OLED model", ["mbp 14 m5", "macbook pro 14 m5", "macbook pro 14 m5 pro", "macbook pro 14 m5 max"]),
    ("mbp14-m5-oled", "MacBook Pro 14 M5 Series OLED", "MacBook Pro 14-inch OLED / PROLED XDR touch display with M5 Pro / M5 Max (Nov 2026)", ["mbp 14 oled", "macbook pro 14 oled"]),
    ("mbp14-m4", "MacBook Pro 14 M4 Series", "MacBook Pro 14-inch with M4 / M4 Pro / M4 Max (Nov 2024)", ["mbp 14 m4", "macbook pro 14 m4", "macbook pro 14 m4 pro", "macbook pro 14 m4 max"]),
    ("mbp14-m3", "MacBook Pro 14 M3 Series", "MacBook Pro 14-inch with M3 / M3 Pro / M3 Max (Nov 2023)", ["mbp 14 m3", "macbook pro 14 m3"]),
    ("mbp14-m2", "MacBook Pro 14 M2 Series", "MacBook Pro 14-inch with M2 Pro / M2 Max (Jan 2023)", ["mbp 14 m2", "macbook pro 14 m2"]),
    ("mbp14-m1", "MacBook Pro 14 M1 Series", "MacBook Pro 14-inch with M1 Pro / M1 Max (2021)", ["mbp 14 m1", "macbook pro 14 m1"]),
    # ---------- MacBook Pro 16 ----------
    ("mbp16-m5", "MacBook Pro 16 M5 Series", "MacBook Pro 16-inch with M5 Pro / M5 Max (Mar 2026), mini-LED, NOT OLED", ["mbp 16 m5", "macbook pro 16 m5", "macbook pro 16 m5 pro", "macbook pro 16 m5 max"]),
    ("mbp16-m5-oled", "MacBook Pro 16 M5 Series OLED", "MacBook Pro 16-inch OLED / PROLED XDR touch display with M5 Pro / M5 Max (Nov 2026)", ["mbp 16 oled", "macbook pro 16 oled"]),
    ("mbp16-m4", "MacBook Pro 16 M4 Series", "MacBook Pro 16-inch with M4 Pro / M4 Max (Nov 2024)", ["mbp 16 m4", "macbook pro 16 m4"]),
    ("mbp16-m3", "MacBook Pro 16 M3 Series", "MacBook Pro 16-inch with M3 Pro / M3 Max (Nov 2023)", ["mbp 16 m3", "macbook pro 16 m3"]),
    ("mbp16-m2", "MacBook Pro 16 M2 Series", "MacBook Pro 16-inch with M2 Pro / M2 Max (Jan 2023)", ["mbp 16 m2", "macbook pro 16 m2"]),
    ("mbp16-m1", "MacBook Pro 16 M1 Series", "MacBook Pro 16-inch with M1 Pro / M1 Max (2021)", ["mbp 16 m1", "macbook pro 16 m1"]),
    # ---------- MacBook Pro 13 / Intel ----------
    ("mbp13-m2", "MacBook Pro 13 M2", "MacBook Pro 13-inch with M2 (2022)", ["mbp 13 m2", "macbook pro 13 m2"]),
    ("mbp13-m1", "MacBook Pro 13 M1", "MacBook Pro 13-inch with M1 (2020)", ["mbp 13 m1", "macbook pro 13 m1"]),
    ("mbp13-intel", "MacBook Pro 13 Intel", "MacBook Pro 13-inch with Intel CPU (2020 or earlier)", ["macbook pro 13 intel"]),
    ("mbp15-intel", "MacBook Pro 15 Intel", "MacBook Pro 15-inch, Intel (2019 or earlier)", ["macbook pro 15", "mbp 15"]),
    ("mbp16-intel", "MacBook Pro 16 Intel", "MacBook Pro 16-inch with Intel CPU (2019)", ["macbook pro 16 intel"]),
    # ---------- MacBook Air ----------
    ("mba13-m5", "MacBook Air 13 M5", "MacBook Air 13-inch with M5 (Mar 2026)", ["mba 13 m5", "macbook air 13 m5"]),
    ("mba13-m4", "MacBook Air 13 M4", "MacBook Air 13-inch with M4 (Mar 2025)", ["mba 13 m4", "macbook air 13 m4"]),
    ("mba13-m3", "MacBook Air 13 M3", "MacBook Air 13-inch with M3 (Mar 2024)", ["mba 13 m3", "macbook air 13 m3"]),
    ("mba13-m2", "MacBook Air 13 M2", "MacBook Air 13.6-inch with M2 (2022)", ["mba 13 m2", "macbook air 13 m2"]),
    ("mba13-m1", "MacBook Air 13 M1", "MacBook Air 13.3-inch with M1 (2020)", ["mba m1", "macbook air m1"]),
    ("mba15-m5", "MacBook Air 15 M5", "MacBook Air 15-inch with M5 (Mar 2026)", ["mba 15 m5", "macbook air 15 m5"]),
    ("mba15-m4", "MacBook Air 15 M4", "MacBook Air 15-inch with M4 (Mar 2025)", ["mba 15 m4", "macbook air 15 m4"]),
    ("mba15-m3", "MacBook Air 15 M3", "MacBook Air 15-inch with M3 (Mar 2024)", ["mba 15 m3", "macbook air 15 m3"]),
    ("mba15-m2", "MacBook Air 15 M2", "MacBook Air 15-inch with M2 (Jun 2023)", ["mba 15 m2", "macbook air 15 m2"]),
    ("mba-intel", "MacBook Air Intel", "Any MacBook Air with Intel CPU, any size (13.3-inch, 2020 Intel model or earlier)", ["macbook air intel"]),
    ("macbook-neo", "MacBook Neo", "MacBook Neo 13-inch with A18 Pro chip (2026)", ["macbook neo", "neo"]),
    # ---------- iMac ----------
    ("imac-m6", "iMac M6", "24-inch iMac with M6 (Nov 2026)", ["imac m6"]),
    ("imac-m4", "iMac M4", "24-inch iMac with M4 (2024)", ["imac m4"]),
    ("imac-m3", "iMac M3", "24-inch iMac with M3 (2023)", ["imac m3"]),
    ("imac-m1", "iMac M1", "24-inch iMac with M1 (2021)", ["imac m1"]),
    ("imac-intel", "iMac Intel", "21.5-inch or 27-inch iMac with Intel CPU", ["imac intel", "imac 27", "imac 21.5"]),
    # ---------- Mac mini ----------
    ("macmini-m6", "Mac mini M6", "Mac mini with M6 (Sep 2026)", ["mac mini m6"]),
    ("macmini-m5", "Mac mini M5 Series", "Mac mini with M5 Pro (Sep 2026)", ["mac mini m5", "mac mini m5 pro"]),
    ("macmini-m4", "Mac mini M4 Series", "Mac mini with M4 or M4 Pro (Nov 2024)", ["mac mini m4", "mac mini m4 pro"]),
    ("macmini-m2", "Mac mini M2 Series", "Mac mini with M2 or M2 Pro (2023)", ["mac mini m2", "mac mini m2 pro"]),
    ("macmini-m1", "Mac mini M1", "Mac mini with M1 (2020)", ["mac mini m1"]),
    ("macmini-intel", "Mac mini Intel", "Mac mini with Intel CPU (2018 or earlier)", ["mac mini intel"]),
    # ---------- Mac Studio / Mac Pro ----------
    ("macstudio-m5", "Mac Studio M5 Series", "Mac Studio with M5 Max or M5 Ultra (2026)", ["mac studio m5", "mac studio m5 max", "mac studio m5 ultra"]),
    ("macstudio-m4", "Mac Studio M4 Series", "Mac Studio with M4 Max (Mar 2025)", ["mac studio m4", "mac studio m4 max"]),
    ("macstudio-m3", "Mac Studio M3 Series", "Mac Studio with M3 Ultra (Mar 2025)", ["mac studio m3", "mac studio m3 ultra"]),
    ("macstudio-m2", "Mac Studio M2 Series", "Mac Studio with M2 Max or M2 Ultra (2023)", ["mac studio m2"]),
    ("macstudio-m1", "Mac Studio M1 Series", "Mac Studio with M1 Max or M1 Ultra (2022)", ["mac studio m1"]),
    ("macpro-m2", "Mac Pro M2 Ultra", "Mac Pro with M2 Ultra (2023)", ["mac pro m2"]),
    ("macpro-intel", "Mac Pro Intel", "Mac Pro with Intel Xeon (2019 or earlier)", ["mac pro intel"]),
    # ---------- iPad ----------
    ("ipadpro11-m5", "iPad Pro 11 M5", "iPad Pro 11-inch with M5 (Oct 2025)", ["ipad pro 11 m5"]),
    ("ipadpro13-m5", "iPad Pro 13 M5", "iPad Pro 13-inch with M5 (Oct 2025)", ["ipad pro 13 m5"]),
    ("ipadpro11-m4", "iPad Pro 11 M4", "iPad Pro 11-inch with M4, OLED (May 2024). Not M2/M1", ["ipad pro 11 m4"]),
    ("ipadpro13-m4", "iPad Pro 13 M4", "iPad Pro 13-inch with M4, OLED (May 2024). A 12.9-inch iPad Pro is NOT this one", ["ipad pro 13 m4"]),
    ("ipadpro-older", "iPad Pro 旧款", "Any older iPad Pro: 11-inch or 12.9-inch with M2 (2022) or M1 (2021) or A-series chips, any generation before 2024", ["ipad pro m2", "ipad pro m1", "ipad pro 12.9"]),
    ("ipadair11-m4", "iPad Air 11 M4", "iPad Air 11-inch with M4 (Mar 2026)", ["ipad air 11 m4"]),
    ("ipadair13-m4", "iPad Air 13 M4", "iPad Air 13-inch with M4 (Mar 2026)", ["ipad air 13 m4"]),
    ("ipadair11-m3", "iPad Air 11 M3", "iPad Air 11-inch with M3 (Mar 2025)", ["ipad air 11 m3"]),
    ("ipadair13-m3", "iPad Air 13 M3", "iPad Air 13-inch with M3 (Mar 2025)", ["ipad air 13 m3"]),
    ("ipadair11-m2", "iPad Air 11 M2", "iPad Air 11-inch with M2 (May 2024)", ["ipad air 11 m2"]),
    ("ipadair13-m2", "iPad Air 13 M2", "iPad Air 13-inch with M2 (May 2024)", ["ipad air 13 m2"]),
    ("ipadair-m1", "iPad Air M1", "iPad Air 10.9-inch 5th generation with M1 (2022)", ["ipad air m1", "ipad air 5"]),
    ("ipadmini-a20", "iPad mini A20 Pro", "iPad mini 8.5-inch OLED with A20 Pro (Nov 2026)", ["ipad mini a20", "ipad mini oled"]),
    ("ipadmini-a17", "iPad mini A17 Pro", "iPad mini 8.3-inch 7th generation with A17 Pro (2024)", ["ipad mini a17", "ipad mini 7"]),
    ("ipad-a16", "iPad A16", "Base iPad 11-inch 11th generation with A16 (2025)", ["ipad a16", "ipad 11th"]),
    # ---------- iPhone（不分容量） ----------
    ("iphone-duo", "iPhone Duo", "iPhone Duo, Apple's foldable iPhone (Oct 2026)", ["iphone fold", "iphone 折叠"]),
    ("iphone-18-pro-max", "iPhone 18 Pro Max", "iPhone 18 Pro Max (Sep 2026)", ["iphone 18 pro max"]),
    ("iphone-18-pro", "iPhone 18 Pro", "iPhone 18 Pro, not Pro Max (Sep 2026)", ["iphone 18 pro"]),
    ("iphone-air", "iPhone Air", "iPhone Air (Sep 2025)", ["iphone air"]),
    ("iphone-17-pro-max", "iPhone 17 Pro Max", "iPhone 17 Pro Max (2025)", ["iphone 17 pro max"]),
    ("iphone-17-pro", "iPhone 17 Pro", "iPhone 17 Pro, not Pro Max (2025)", ["iphone 17 pro"]),
    ("iphone-17", "iPhone 17", "iPhone 17 (2025), not Pro, not 17e", ["iphone 17"]),
    ("iphone-17e", "iPhone 17e", "iPhone 17e (2026)", ["iphone 17e"]),
    ("iphone-16-pro-max", "iPhone 16 Pro Max", "iPhone 16 Pro Max (2024)", ["iphone 16 pro max"]),
    ("iphone-16-pro", "iPhone 16 Pro", "iPhone 16 Pro, not Pro Max (2024)", ["iphone 16 pro"]),
    ("iphone-16-plus", "iPhone 16 Plus", "iPhone 16 Plus (2024)", ["iphone 16 plus"]),
    ("iphone-16", "iPhone 16", "iPhone 16 (2024), not Pro/Plus/16e", ["iphone 16"]),
    ("iphone-16e", "iPhone 16e", "iPhone 16e (2025)", ["iphone 16e"]),
    ("iphone-15-series", "iPhone 15 Series", "Any iPhone 15 model: 15, 15 Plus, 15 Pro, 15 Pro Max", ["iphone 15", "iphone 15 pro", "iphone 15 pro max"]),
    ("iphone-14-series", "iPhone 14 Series", "Any iPhone 14 model: 14, 14 Plus, 14 Pro, 14 Pro Max", ["iphone 14", "iphone 14 pro"]),
    # ---------- Apple Watch ----------
    ("watch-ultra-4", "Apple Watch Ultra 4", "Apple Watch Ultra 4 (Sep 2026)", ["watch ultra 4"]),
    ("watch-ultra-3", "Apple Watch Ultra 3", "Apple Watch Ultra 3 (2025)", ["watch ultra 3"]),
    ("watch-ultra-2", "Apple Watch Ultra 2", "Apple Watch Ultra 2", ["watch ultra 2"]),
    ("watch-s12", "Apple Watch Series 12", "Apple Watch Series 12 (Sep 2026), any size", ["apple watch 12", "watch series 12"]),
    ("watch-s11", "Apple Watch Series 11", "Apple Watch Series 11 (2025), any size", ["apple watch 11", "watch series 11"]),
    ("watch-s10", "Apple Watch Series 10", "Apple Watch Series 10 (2024), any size", ["apple watch 10", "watch series 10"]),
    ("watch-s9", "Apple Watch Series 9", "Apple Watch Series 9 (2023), any size", ["apple watch 9", "watch series 9"]),
    ("watch-se3", "Apple Watch SE 3", "Apple Watch SE 3rd generation (2025)", ["apple watch se 3", "watch se 3"]),
    ("watch-se2", "Apple Watch SE 2", "Apple Watch SE 2nd generation (2022-2024)", ["apple watch se 2", "watch se 2"]),
    # ---------- AirPods ----------
    ("airpods-5", "AirPods 5", "AirPods 5 (Sep 2026), any version", ["airpods 5"]),
    ("airpods-pro-3", "AirPods Pro 3", "AirPods Pro 3 (2025)", ["airpods pro 3"]),
    ("airpods-pro-2", "AirPods Pro 2", "AirPods Pro 2nd generation (Lightning or USB-C)", ["airpods pro 2"]),
    ("airpods-4-anc", "AirPods 4 ANC", "AirPods 4 with Active Noise Cancellation", ["airpods 4 anc", "airpods 4 降噪"]),
    ("airpods-4", "AirPods 4", "AirPods 4 without Active Noise Cancellation", ["airpods 4"]),
    ("airpods-max", "AirPods Max", "AirPods Max (Lightning or USB-C)", ["airpods max"]),
]

APPLE_KEYS = [m[0] for m in APPLE_MODELS]

# 给 AI 的说明
APPLE_PROMPT = """- apple_model: ONLY for an Apple-made device (Mac, iPad, iPhone, Apple Watch, AirPods).
  Pick the key whose description matches the title. Use the chip, screen size, OLED, and year to decide.
  If the title gives a year but no chip, use the year only when it points to one model in the list.
  If you cannot tell which key it is, use null. Never guess.
  Accessories are NOT Apple devices here: chargers, adapters, cables, cases, covers, keyboards, mice,
  pencils, bands, AppleCare, gift cards, and third-party products made "for MacBook/iPhone" -> apple_model null.
  When apple_model is set, category must be "apple"; gpu, capacity_tb, ram_gb can be null.
  Use only these exact keys (do not make up new keys):
""" + "\n".join(f"  {k}: {hint}" for k, _, hint, _ in APPLE_MODELS)


_FIXES = [   # AI 有时会照着规律编出不存在的 key，这里改回正确的
    (r"^ipadpro\d*-(m1|m2|a\d+.*|older)$", "ipadpro-older"),
    (r"^mba\d*-intel$", "mba-intel"),
    (r"^imac\d*-intel$", "imac-intel"),
    (r"^macmini\d*-intel$", "macmini-intel"),
    (r"^macpro\d*-intel$", "macpro-intel"),
    (r"^ipadair\d*-m1$", "ipadair-m1"),
]


def fix_apple_key(key):
    """返回型号表里的 key；认不出来就返回 None"""
    import re
    if not key:
        return None
    key = str(key).strip().lower()
    if key in APPLE_KEYS:
        return key
    for pattern, fixed in _FIXES:
        if re.match(pattern, key):
            return fixed
    return None


import re as _re

_FAMILY_WORDS = [   # key 开头 → 标题里必须出现的词
    ("mbp", r"macbook\s*pro|\bmbp\b"), ("mba", r"macbook\s*air|\bmba\b"), ("macbook-neo", r"macbook\s*neo"),
    ("imac", r"\bimac\b"), ("macmini", r"mac\s*mini"), ("macstudio", r"mac\s*studio"), ("macpro", r"\bmac\s*pro\b"),
    ("ipadpro", r"ipad\s*pro"), ("ipadair", r"ipad\s*air"), ("ipadmini", r"ipad\s*mini"), ("ipad-", r"\bipad\b"),
    ("iphone", r"iphone"), ("watch", r"watch"), ("airpods", r"airpods"),
]
_KEY_PARTS = _re.compile(r"^(mbp|mba|ipadpro|ipadair)(\d+)-m(\d)(-oled)?$")


def _sizes_in(title):
    out = set()
    for m in _re.finditer(r"\b(1[1-6](?:\.\d)?)\s*(?:\"|”|''|-?\s*inch|-?\s*in\b|吋|寸)", title, _re.I):
        n = float(m.group(1))
        out.add("12.9" if abs(n - 12.9) < 0.05 else str(int(n)))
    return out


def check_apple_key(key, title):
    """AI 给的型号再用标题核对一遍：产品线的词要在标题里；芯片、尺寸不能和标题矛盾；
    标题没写尺寸时，只有这一代芯片只出过一种尺寸才算。核对不过就返回 None"""
    key = fix_apple_key(key)
    if not key:
        return None
    t = title.lower()
    if _re.search(r"\b(for|compatible with|fits)\s+(the\s+)?(apple\s+)?(macbook|iphone|ipad|imac|mac|airpods|apple watch)", t):
        return None                               # "for MacBook" 这种是配件
    for prefix, words in _FAMILY_WORDS:
        if key.startswith(prefix):
            if not _re.search(words, t):
                return None
            break
    m = _KEY_PARTS.match(key)
    chips = set(_re.findall(r"\bm([1-6])\b", t))
    chip = _re.search(r"-m(\d)", key)
    if chip and chips and chip.group(1) not in chips:
        return None
    if m:
        fam, size, c = m.group(1), m.group(2), m.group(3)
        sizes = _sizes_in(title)
        if sizes and size not in sizes:
            return None
        if not sizes:
            same = {k2 for k2 in APPLE_KEYS if (mm := _KEY_PARTS.match(k2)) and mm.group(1) == fam and mm.group(3) == c}
            if len({_KEY_PARTS.match(k2).group(2) for k2 in same}) > 1:
                return None
    return key


def _sql_text(s):
    return "'" + s.replace("'", "''") + "'"


def seed_sql():
    """生成标签和下拉选项的 SQL（可以重复运行）"""
    lines = ["-- 由 apple_models.py 生成，不要手改", "insert into field_options (field, value, label, sort_order) values"]
    lines.append(",\n".join(f"  ('apple_model', {_sql_text(k)}, {_sql_text(n)}, {i})" for i, (k, n, _, _) in enumerate(APPLE_MODELS)))
    lines.append("on conflict (field, value) do update set label = excluded.label, sort_order = excluded.sort_order, active = true;")
    lines.append("")
    lines.append("insert into tags (slug, name_zh, name_en, aliases, kind, conditions, in_scope, created_by, approved) values")
    rows = []
    for k, n, _, aliases in APPLE_MODELS:
        arr = "array[" + ", ".join(_sql_text(a) for a in aliases) + "]::text[]"
        cond = _sql_text('{"category": "apple", "apple_model": "%s"}' % k) + "::jsonb"
        rows.append(f"  ({_sql_text(k)}, {_sql_text(n)}, {_sql_text(n)}, {arr}, 'structured', {cond}, true, 'admin', true)")
    lines.append(",\n".join(rows))
    lines.append("on conflict (slug) do update set name_zh = excluded.name_zh, name_en = excluded.name_en, aliases = excluded.aliases,")
    lines.append("  conditions = excluded.conditions;")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    print(seed_sql())
