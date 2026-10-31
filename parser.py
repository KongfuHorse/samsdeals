"""
AI 解析：把 deal 标题变成固定格式的字段。
允许的值来自 Supabase 的 field_options 表，AI 只能从里面选。
"""
import os
import anthropic

MODEL = os.environ.get("CLAUDE_MODEL", "claude-haiku-5-5")
BATCH_SIZE = 20   # 一次发给 AI 的标题数

PROMPT = """You read deal post titles from sites like Slickdeals and r/buildapcsales.
For each title, extract the product facts. Rules:
- category: pick one of the allowed values. Use "other" for anything else
  (monitors, CPUs, accessories, phones, laptops with no RTX 50-series GPU, etc).
  A laptop with a discrete GPU is "laptop". A prebuilt PC is "desktop".
  A standalone video card is "graphics_card".
  "hdd" is only for spinning hard drives (internal or external).
  Any SSD, including portable/external SSDs and flash drives, is "ssd".
- gpu: only for laptop/desktop/graphics_card. Set it ONLY if that exact NVIDIA model
  is written in the text. AMD Radeon (RX ...), Intel Arc, RTX 40-series or older,
  integrated graphics, or no GPU named -> null. Never guess a GPU.
  "5070ti", "RTX5070 Ti" -> "RTX 5070 Ti".
- capacity_tb: storage capacity of ONE unit in TB (hdd/ssd only). 500GB -> 0.5. Else null.
- quantity: number of units for the price (2-pack -> 2). Default 1.
- ram_gb: system RAM for laptop/desktop, else null.
- condition: "new" unless the title says open box, refurbished, renewed,
  factory recertified/reconditioned (-> "refurb"), or used/pre-owned (-> "used").
- series: product line like ROG, Alienware, Legion, Omen, TUF, Predator, Strix.
  Use the allowed spelling if it is in the list. Else null.
- brand: maker like Dell, ASUS, Lenovo, HP, MSI, WD, Seagate, Samsung. Else null.
- price: final price in USD after coupons/rebates that apply in the cart.
  Do not subtract mail-in rebates. null if no price.
- store: retailer like Amazon, Best Buy, Newegg, Walmart. Else null.
Return one entry per title, with the same index."""


FIELDS = ["category", "gpu", "capacity_tb", "quantity", "ram_gb", "condition",
          "series", "brand", "price", "store"]


def field_props(options):
    """options: {"category": [...], "gpu": [...], "condition": [...], "series": [...]}"""
    return {
        "category": {"type": "string", "enum": options["category"] + ["other"]},
        "gpu": {"type": ["string", "null"], "enum": options["gpu"] + [None]},
        "capacity_tb": {"type": ["number", "null"]},
        "quantity": {"type": "integer"},
        "ram_gb": {"type": ["integer", "null"]},
        "condition": {"type": "string", "enum": options["condition"]},
        "series": {"type": ["string", "null"],
                   "description": "Allowed spellings: " + ", ".join(options.get("series", []))},
        "brand": {"type": ["string", "null"]},
        "price": {"type": ["number", "null"]},
        "store": {"type": ["string", "null"]},
    }


def build_tool(options, extra_props, extra_required, description):
    return {
        "name": "save_deals",
        "description": description,
        "input_schema": {
            "type": "object",
            "properties": {
                "deals": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {**extra_props, **field_props(options)},
                        "required": extra_required + FIELDS,
                    },
                }
            },
            "required": ["deals"],
        },
    }


def parse_titles(titles, options):
    """titles: 标题列表。返回同样长度的字段列表。"""
    client = anthropic.Anthropic()
    tool = build_tool(options, {"index": {"type": "integer"}}, ["index"],
                      "Save the parsed fields for every title.")
    results = [None] * len(titles)
    for start in range(0, len(titles), BATCH_SIZE):
        chunk = titles[start:start + BATCH_SIZE]
        listing = "\n".join(f"{i}. {t}" for i, t in enumerate(chunk))
        msg = client.messages.create(
            model=MODEL,
            max_tokens=4000,
            system=PROMPT,
            tools=[tool],
            tool_choice={"type": "tool", "name": "save_deals"},
            messages=[{"role": "user", "content": listing}],
        )
        block = next(b for b in msg.content if b.type == "tool_use")
        for d in block.input.get("deals", []):
            i = d.pop("index", None)
            if isinstance(i, int) and 0 <= i < len(chunk):
                d["quantity"] = d.get("quantity") or 1
                results[start + i] = d
    return results


ARTICLE_PROMPT = PROMPT.replace(
    "You read deal post titles from sites like Slickdeals and r/buildapcsales.\nFor each title, extract the product facts.",
    """You read deal articles from tech news sites (Tom's Hardware, TechRadar).
One article may list many products. Return one entry for EACH product deal in the article
that is an HDD, SSD, gaming laptop, gaming desktop, or graphics card with a current sale price.
Skip products in other categories, products with no current price, and prices that are only
mentioned as history ("was $X last month"). If there are none, return an empty list.
For each entry, "title" is a short product name with key specs, like
"MSI Katana 15 RTX 5060, 16GB, 1TB". Extract the product facts.""",
)


def extract_from_article(title, text, options):
    """从一篇文章里找出所有相关 deal，返回字段列表（可能为空）"""
    client = anthropic.Anthropic()
    tool = build_tool(options, {"title": {"type": "string"}}, ["title"],
                      "Save every relevant product deal found in the article.")
    msg = client.messages.create(
        model=MODEL,
        max_tokens=6000,
        system=ARTICLE_PROMPT,
        tools=[tool],
        tool_choice={"type": "tool", "name": "save_deals"},
        messages=[{"role": "user", "content": f"Article title: {title}\n\n{text}"}],
    )
    block = next(b for b in msg.content if b.type == "tool_use")
    deals = []
    for d in block.input.get("deals", []):
        d["quantity"] = d.get("quantity") or 1
        if d.get("category") != "other" and d.get("title"):
            deals.append(d)
    return deals
