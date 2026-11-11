// AI 新建标签（第 3 层）：前两层匹配不上、用户点了"新建标签"时才会调用
// 需要的保密变量（在 Supabase 后台 Edge Functions → Secrets 里设置，不能写进代码）：
//   ANTHROPIC_API_KEY  Claude API key
//   SB_SECRET_KEY      Supabase 的 Secret key（sb_secret_ 开头），用来调用只有服务器能用的数据库函数
// SUPABASE_URL 由 Supabase 自动提供

const MODEL = Deno.env.get("CLAUDE_MODEL") ?? "claude-haiku-5-5";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// 和网页里的写法保持一致：全角转半角、转小写、去掉空格和标点
const normalize = (s: string) => s.normalize("NFKC").toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, "").slice(0, 80);

async function sha256(text: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function rpc(fn: string, args: unknown) {
  const key = Deno.env.get("SB_SECRET_KEY")!;
  const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json" };
  if (key.startsWith("eyJ")) headers.Authorization = `Bearer ${key}`;
  const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, { method: "POST", headers, body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`);
  return r.json();
}

const SYSTEM = `You turn a shopper's search phrase (Chinese or English) into a product tag for a computer-hardware deals site.
Call save_tag exactly once. Choose one type:
- "existing": the phrase means the same thing as one of the existing tags. Give its tag_id. Prefer this whenever one fits.
  Extra details the tags cannot express (brand, RAM, screen size, CPU) do not make it a new tag: "联想5090笔记本" is the existing "RTX 5090 游戏本".
- "structured": a product inside our categories that has no tag yet. Give category, and gpu (laptop / desktop / graphics_card only,
  must be one of the allowed GPUs) or capacity_tb (ssd / hdd only). Use this only when the allowed values fit exactly.
- "keyword": a real product type outside our categories or allowed values (MacBook, monitor, CPU, RTX 4090, phone ...).
  Give: name (short Chinese display name, keep model names in English, max 20 chars), name_en (short English name),
  keywords (1 to 3 English words or short phrases that ALL must appear in a matching deal title, e.g. ["macbook air", "m4"];
  keep them as loose as possible while still specific), search_term (2 to 4 English words to search a deals site).
- "none": not a product someone could buy, gibberish, or offensive.`;

function tool(ctx: { categories: string[]; gpus: string[] }) {
  return {
    name: "save_tag",
    description: "Save the tag decision.",
    input_schema: {
      type: "object",
      properties: {
        type: { type: "string", enum: ["existing", "structured", "keyword", "none"] },
        tag_id: { type: "integer" },
        category: { type: "string", enum: ctx.categories },
        gpu: { type: "string", enum: ctx.gpus },
        capacity_tb: { type: "number" },
        name: { type: "string" },
        name_en: { type: "string" },
        keywords: { type: "array", items: { type: "string" } },
        search_term: { type: "string" },
      },
      required: ["type"],
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const raw = String(body.query ?? "").trim().slice(0, 80);
    const norm = normalize(raw);
    if (norm.length < 2) return json({ error: "too_short" }, 400);

    const ip = (req.headers.get("x-forwarded-for") ?? "unknown").split(",")[0].trim();
    const ipHash = await sha256("samsdeals:" + ip);

    const prep = await rpc("tag_ai_prepare", { p_query: norm, p_ip_hash: ipHash });
    if (prep.cached) return json({ slug: prep.cached, cached: true });
    if (prep.limited) return json({ error: "limited" }, 429);

    const ctx = prep.context;
    const tagList = ctx.tags.map((t: { id: number; name: string }) => `${t.id}: ${t.name}`).join("\n");
    const ai = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": Deno.env.get("ANTHROPIC_API_KEY")!, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 400,
        system: SYSTEM,
        tools: [tool(ctx)],
        tool_choice: { type: "tool", name: "save_tag" },
        messages: [{
          role: "user",
          content: `Categories: ${ctx.categories.join(", ")}\nAllowed GPUs: ${ctx.gpus.join(", ")}\nExisting tags (id: name):\n${tagList}\n\nSearch phrase: ${raw}`,
        }],
      }),
    });
    if (!ai.ok) throw new Error(`anthropic ${ai.status}: ${(await ai.text()).slice(0, 300)}`);
    const msg = await ai.json();
    const result = msg.content?.find((b: { type: string }) => b.type === "tool_use")?.input;
    if (!result) throw new Error("no tool result");

    const out = await rpc("tag_ai_commit", { p_query: norm, p_result: result, p_ip_hash: ipHash });
    if (out.error) return json({ error: out.error }, 422);
    return json({ slug: out.slug, created: out.created });
  } catch (e) {
    console.error(e);
    return json({ error: "server" }, 500);
  }
});
