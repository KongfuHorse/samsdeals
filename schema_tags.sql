-- ============================================
-- 第一阶段：标签、搜索、价格排行、自动来源
-- 用法：在 schema_privacy.sql 之后运行；可以重复运行
--
-- 公开函数（网页可以调用）：public_home、public_resolve_tag、public_tag_deals、public_log_miss
-- 服务器函数（只有 Edge Function 用 secret key 能调用）：tag_ai_prepare、tag_ai_commit、auto_sources_maintain
-- 后台函数：admin_tags_get、admin_tag_save、admin_tag_approve、admin_tag_merge、admin_tag_delete、
--           admin_synonym_save、admin_synonym_delete、admin_tag_settings_save
-- 其他以下划线开头的函数只在内部使用，网页调用不了
-- ============================================

-- ---------- 表 ----------
create table if not exists tags (
  id bigint generated always as identity primary key,
  slug text unique not null,                    -- 用在网址里，比如 ?t=rtx-5090-laptop
  name_zh text not null,                        -- 中文显示名
  name_en text,                                 -- 英文显示名（第三阶段用）
  aliases text[] not null default '{}',         -- 别名，联想时也会匹配
  kind text not null default 'structured' check (kind in ('structured', 'keyword')),
  conditions jsonb not null default '{}',       -- structured: {category, gpu, capacity_tb}；keyword: {keywords: [...]}
  in_scope boolean not null default true,       -- 是否在我们覆盖的品类里
  created_by text not null default 'admin' check (created_by in ('admin', 'rule', 'ai')),
  approved boolean not null default false,
  merged_into bigint references tags(id) on delete set null,   -- 被合并到哪个标签（旧网址自动跳转）
  created_at timestamptz not null default now()
);
-- 删除一个标签时，合并到它名下的旧标签也一起删除
alter table tags drop constraint if exists tags_merged_into_fkey;
alter table tags add constraint tags_merged_into_fkey foreign key (merged_into) references tags(id) on delete cascade;
create unique index if not exists tags_structured_uniq on tags
  ((conditions->>'category'), coalesce(conditions->>'gpu', ''), coalesce(conditions->>'capacity_tb', ''))
  where kind = 'structured' and merged_into is null;

create table if not exists tag_synonyms (       -- 同义词：用户输入的词 → 品类
  id bigint generated always as identity primary key,
  term text unique not null,                    -- 小写、不带空格，比如 笔记本、laptop
  category text not null
);

create table if not exists tag_searches (       -- 搜索记录；tag_id 为空 = 没有结果的搜索
  id bigint generated always as identity primary key,
  query text,
  tag_id bigint references tags(id) on delete cascade,
  visitor text,
  created_at timestamptz not null default now()
);
create index if not exists tag_searches_tag_idx on tag_searches (tag_id, visitor);
create index if not exists tag_searches_time_idx on tag_searches (created_at desc);

create table if not exists tag_ai_cache (       -- 同样的输入只问一次 AI
  query text primary key,
  tag_id bigint not null references tags(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists tag_create_log (     -- 新建标签的记录，用来限制每个访客每天的次数
  id bigint generated always as identity primary key,
  ip_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists tag_create_log_idx on tag_create_log (ip_hash, created_at desc);

alter table tags enable row level security;
alter table tag_synonyms enable row level security;
alter table tag_searches enable row level security;
alter table tag_ai_cache enable row level security;
alter table tag_create_log enable row level security;
revoke all on tags, tag_synonyms, tag_searches, tag_ai_cache, tag_create_log from anon, authenticated;

alter table settings add column if not exists tag_public_min_visitors int not null default 10 check (tag_public_min_visitors between 1 and 100000);
alter table settings add column if not exists auto_source_max int not null default 50 check (auto_source_max between 0 and 500);
alter table settings add column if not exists auto_source_stale_days int not null default 14 check (auto_source_stale_days between 1 and 365);
alter table settings add column if not exists tag_daily_limit int not null default 5 check (tag_daily_limit between 0 and 1000);

alter table sources add column if not exists auto boolean not null default false;      -- 是否自动添加
alter table sources add column if not exists tag_id bigint references tags(id) on delete cascade;
alter table sources add column if not exists created_at timestamptz not null default now();
alter table sources add column if not exists last_hit_at timestamptz;                  -- 最近一次有相关结果的时间

-- ---------- 内部函数 ----------
create or replace function _ip_hash()
returns text language sql stable security definer set search_path = public, extensions as $$
  select encode(digest('samsdeals:' || coalesce(nullif(split_part(
    nullif(current_setting('request.headers', true), '')::json->>'x-forwarded-for', ',', 1), ''), 'unknown'), 'sha256'), 'hex');
$$;

create or replace function _tag_rate_ok(p_ip_hash text)
returns boolean language sql stable security definer set search_path = public as $$
  select (select count(*) from tag_create_log where ip_hash = p_ip_hash and created_at > now() - interval '24 hours')
       < (select tag_daily_limit from settings where id = 1);
$$;

create or replace function _cat_label(p_category text, p_lang text)
returns text language sql immutable as $$
  select case p_lang when 'en' then
    case p_category when 'laptop' then 'Gaming Laptop' when 'desktop' then 'Desktop' when 'graphics_card' then 'Graphics Card'
                    when 'ssd' then 'SSD' when 'hdd' then 'HDD' else p_category end
  else
    case p_category when 'laptop' then '游戏本' when 'desktop' then '台式机' when 'graphics_card' then '显卡'
                    when 'ssd' then '固态硬盘' when 'hdd' then '机械硬盘' else p_category end
  end;
$$;

-- 所有标签 + 统计（不同访客数、搜索次数、是否公开）
create or replace function _tags_with_stats()
returns table (id bigint, slug text, name_zh text, name_en text, aliases text[], kind text, conditions jsonb, in_scope boolean,
               created_by text, approved boolean, merged_into bigint, created_at timestamptz,
               visitors bigint, searches bigint, is_public boolean)
language sql stable security definer set search_path = public as $$
  select t.id, t.slug, t.name_zh, t.name_en, t.aliases, t.kind, t.conditions, t.in_scope, t.created_by, t.approved,
         t.merged_into, t.created_at, coalesce(s.visitors, 0), coalesce(s.searches, 0),
         t.merged_into is null and (t.approved or coalesce(s.visitors, 0) >= (select tag_public_min_visitors from settings where id = 1))
  from tags t
  left join (select tag_id, count(distinct visitor) visitors, count(*) searches
             from tag_searches where tag_id is not null group by tag_id) s on s.tag_id = t.id;
$$;

-- 按结构化条件找标签，没有就新建。返回 (标签 id, 是否新建)
create or replace function _tag_resolve_structured(p_category text, p_gpu text, p_capacity numeric, p_created_by text, p_approved boolean,
                                                   out o_id bigint, out o_created boolean)
language plpgsql security definer set search_path = public as $$
declare v_cond jsonb; v_merged bigint; v_slug text; v_gpu text := nullif(trim(p_gpu), ''); v_cap numeric := p_capacity;
begin
  o_created := false;
  if not exists (select 1 from field_options where field = 'category' and value = p_category and active) then
    raise exception '不支持的品类';
  end if;
  if p_category in ('laptop', 'desktop', 'graphics_card') then
    v_cap := null;
    if v_gpu is not null and not exists (select 1 from field_options where field = 'gpu' and value = v_gpu and active) then
      raise exception '不支持的显卡型号';
    end if;
  else
    v_gpu := null;
    if v_cap is not null and (v_cap <= 0 or v_cap > 200) then raise exception '容量不对'; end if;
  end if;
  v_cap := trim_scale(v_cap);
  v_cond := jsonb_strip_nulls(jsonb_build_object('category', p_category, 'gpu', v_gpu, 'capacity_tb', v_cap));

  select id, merged_into into o_id, v_merged from tags
  where kind = 'structured' and conditions->>'category' = p_category
    and coalesce(conditions->>'gpu', '') = coalesce(v_gpu, '')
    and coalesce(conditions->>'capacity_tb', '') = coalesce(v_cap::text, '')
  order by merged_into nulls first limit 1;
  if o_id is not null then
    o_id := coalesce(v_merged, o_id);
    return;
  end if;

  v_slug := concat_ws('-', lower(replace(v_gpu, ' ', '-')), v_cap::text || 'tb',
                      case p_category when 'graphics_card' then 'gpu' else p_category end);
  if exists (select 1 from tags where slug = v_slug) then v_slug := v_slug || '-' || floor(random() * 100000)::text; end if;
  insert into tags (slug, name_zh, name_en, kind, conditions, in_scope, created_by, approved)
  values (v_slug,
          concat_ws(' ', v_gpu, v_cap::text || 'TB', _cat_label(p_category, 'zh')),
          concat_ws(' ', v_gpu, v_cap::text || 'TB', _cat_label(p_category, 'en')),
          'structured', v_cond, true, p_created_by, p_approved)
  returning id into o_id;
  o_created := true;
end $$;

-- 自动来源的两道保护：太久没有结果的停用；超过上限时停用最久没有结果的
create or replace function _auto_sources_enforce()
returns void language plpgsql security definer set search_path = public as $$
declare s settings%rowtype;
begin
  select * into s from settings where id = 1;
  update sources set enabled = false
  where auto and enabled and coalesce(last_hit_at, created_at) < now() - make_interval(days => s.auto_source_stale_days);
  update sources set enabled = false
  where key in (select key from sources where auto and enabled
                order by coalesce(last_hit_at, created_at) desc offset s.auto_source_max);
end $$;

-- ---------- 公开函数 ----------
-- 首页数据：公开的标签、同义词、显卡型号
create or replace function public_home()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tags', (select coalesce(jsonb_agg(jsonb_build_object('slug', t.slug, 'name', t.name_zh, 'name_en', t.name_en,
                      'aliases', t.aliases, 'kind', t.kind, 'heat', t.visitors, 'deals', t.n,
                      'category', t.conditions->>'category', 'gpu', t.conditions->>'gpu', 'capacity_tb', t.conditions->'capacity_tb')
                    order by t.visitors desc, t.n desc, t.id), '[]')
             from (select x.*, (select count(*) from deals d
                                where x.kind = 'structured' and d.created_at > now() - interval '30 days'
                                  and d.status in ('passed', 'not_passed', 'no_rule')
                                  and d.category = x.conditions->>'category'
                                  and (x.conditions->>'gpu' is null or d.gpu = x.conditions->>'gpu')
                                  and (x.conditions->>'capacity_tb' is null or d.capacity_tb = (x.conditions->>'capacity_tb')::numeric)) n
                   from _tags_with_stats() x where x.is_public) t),
    'synonyms', (select coalesce(jsonb_agg(jsonb_build_object('term', term, 'category', category)), '[]') from tag_synonyms),
    'gpus', (select coalesce(jsonb_agg(value order by sort_order), '[]') from field_options where field = 'gpu' and active)
  );
$$;

-- 第 2 层：按规则拆解出来的条件，找到标签或新建，返回 slug
create or replace function public_resolve_tag(p_category text, p_gpu text, p_capacity_tb numeric)
returns text language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_created boolean; v_ip text := _ip_hash(); v_slug text;
begin
  -- 先看是不是已经有了（已有的不受次数限制）
  if not exists (select 1 from tags where kind = 'structured' and conditions->>'category' = p_category
                   and coalesce(conditions->>'gpu', '') = coalesce(case when p_category in ('laptop','desktop','graphics_card') then nullif(trim(p_gpu), '') end, '')
                   and coalesce(conditions->>'capacity_tb', '') = coalesce(case when p_category in ('ssd','hdd') then trim_scale(p_capacity_tb)::text end, ''))
     and not _tag_rate_ok(v_ip) then
    raise exception '今天新建的标签太多了，请明天再试';
  end if;
  select o_id, o_created into v_id, v_created from _tag_resolve_structured(p_category, p_gpu, p_capacity_tb, 'rule', false);
  if v_created then insert into tag_create_log (ip_hash) values (v_ip); end if;
  select slug into v_slug from tags where id = v_id;
  return v_slug;
end $$;

-- 标签页：标签信息 + 近 30 天的价格排行；同时记一次搜索
create or replace function public_tag_deals(p_slug text, p_visitor text default null, p_query text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t tags%rowtype; v_storage boolean; v_deals jsonb; v_kw text[]; v_public boolean;
begin
  select * into t from tags where slug = p_slug;
  if not found then return null; end if;
  if t.merged_into is not null then select * into t from tags where id = t.merged_into; end if;

  if coalesce(p_visitor, '') <> '' then
    insert into tag_searches (query, tag_id, visitor) values (left(p_query, 80), t.id, left(p_visitor, 40));
  end if;

  if t.kind = 'structured' then
    v_storage := t.conditions->>'category' in ('ssd', 'hdd');
    select coalesce(jsonb_agg(to_jsonb(x) - 'sort_key' order by x.sort_key nulls last, x.price), '[]') into v_deals from (
      select d.title, d.url, d.source, d.store, d.price, d.category, d.condition, d.quantity, d.capacity_tb, d.created_at,
             case when v_storage and d.capacity_tb > 0 then round(d.price / greatest(d.quantity, 1) / d.capacity_tb, 2) end as per_tb,
             case when v_storage then case when d.capacity_tb > 0 then d.price / greatest(d.quantity, 1) / d.capacity_tb end
                  else d.price end as sort_key
      from deals d
      where d.created_at > now() - interval '30 days' and d.price is not null
        and d.status in ('passed', 'not_passed', 'no_rule')
        and d.category = t.conditions->>'category'
        and (t.conditions->>'gpu' is null or d.gpu = t.conditions->>'gpu')
        and (t.conditions->>'capacity_tb' is null or d.capacity_tb = (t.conditions->>'capacity_tb')::numeric)
      order by sort_key nulls last limit 300) x;
  else
    v_storage := false;
    select array_agg('%' || replace(replace(replace(k, '\', '\\'), '%', '\%'), '_', '\_') || '%') into v_kw
    from jsonb_array_elements_text(coalesce(t.conditions->'keywords', '[]')) k;
    select coalesce(jsonb_agg(to_jsonb(x) order by x.price), '[]') into v_deals from (
      select d.title, d.url, d.source, d.store, d.price, d.category, d.condition, d.quantity, d.capacity_tb, d.created_at,
             null::numeric as per_tb
      from deals d
      where d.created_at > now() - interval '30 days' and d.price is not null
        and d.status in ('passed', 'not_passed', 'no_rule', 'other')
        and v_kw is not null and d.title ilike all (v_kw)
      order by d.price limit 300) x;
  end if;

  select is_public into v_public from _tags_with_stats() s where s.id = t.id;
  return jsonb_build_object(
    'tag', jsonb_build_object('slug', t.slug, 'name', t.name_zh, 'name_en', t.name_en, 'kind', t.kind,
                              'in_scope', t.in_scope, 'per_tb', v_storage, 'is_public', v_public, 'created_at', t.created_at,
                              'category', t.conditions->>'category'),
    'deals', v_deals);
end $$;

-- 没有结果的搜索，记下来供后台统计
create or replace function public_log_miss(p_query text, p_visitor text)
returns void language sql security definer set search_path = public as $$
  insert into tag_searches (query, tag_id, visitor)
  select left(p_query, 80), null, left(p_visitor, 40) where coalesce(trim(p_query), '') <> '';
$$;

-- ---------- 服务器函数（AI 新建标签，只有 Edge Function 能调用） ----------
create or replace function tag_ai_prepare(p_query text, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_slug text;
begin
  select coalesce(m.slug, t.slug) into v_slug
  from tag_ai_cache c join tags t on t.id = c.tag_id left join tags m on m.id = t.merged_into
  where c.query = p_query;
  if v_slug is not null then return jsonb_build_object('cached', v_slug); end if;
  if not _tag_rate_ok(p_ip_hash) then return jsonb_build_object('limited', true); end if;
  return jsonb_build_object('context', jsonb_build_object(
    'categories', (select jsonb_agg(value order by sort_order) from field_options where field = 'category' and active),
    'gpus', (select jsonb_agg(value order by sort_order) from field_options where field = 'gpu' and active),
    'tags', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name_zh, 'conditions', conditions) order by id), '[]')
             from (select id, name_zh, conditions from tags where merged_into is null order by id limit 400) x)));
end $$;

create or replace function tag_ai_commit(p_query text, p_result jsonb, p_ip_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_created boolean := false; v_type text := p_result->>'type'; v_slug text; v_name text;
        v_kw text[]; v_term text;
begin
  if v_type = 'existing' then
    select coalesce(merged_into, id) into v_id from tags where id = (p_result->>'tag_id')::bigint;
    if v_id is null then return jsonb_build_object('error', 'not_found'); end if;

  elsif v_type = 'structured' then
    select o_id, o_created into v_id, v_created
    from _tag_resolve_structured(p_result->>'category', p_result->>'gpu', nullif(p_result->>'capacity_tb', '')::numeric, 'ai', false);

  elsif v_type = 'keyword' then
    v_name := left(trim(p_result->>'name'), 40);
    select array_agg(k order by k) into v_kw from (
      select distinct lower(trim(k)) k from jsonb_array_elements_text(coalesce(p_result->'keywords', '[]')) k
      where length(trim(k)) between 2 and 30 limit 4) x;
    if coalesce(v_name, '') = '' or v_kw is null then return jsonb_build_object('error', 'bad_result'); end if;

    select coalesce(merged_into, id) into v_id from tags
    where kind = 'keyword' and (select array_agg(lower(k) order by lower(k)) from jsonb_array_elements_text(conditions->'keywords') k) = v_kw
    order by merged_into nulls first limit 1;

    if v_id is null then
      v_slug := trim(both '-' from lower(regexp_replace(coalesce(nullif(trim(p_result->>'name_en'), ''), v_name), '[^a-zA-Z0-9]+', '-', 'g')));
      if length(v_slug) < 2 or exists (select 1 from tags where slug = v_slug) then
        v_slug := trim(both '-' from v_slug || '-' || floor(random() * 1000000)::text);
      end if;
      insert into tags (slug, name_zh, name_en, kind, conditions, in_scope, created_by, approved)
      values (v_slug, v_name, nullif(left(trim(p_result->>'name_en'), 60), ''), 'keyword', jsonb_build_object('keywords', to_jsonb(v_kw)), false, 'ai', false)
      returning id into v_id;
      v_created := true;
      -- 自动加一个 Slickdeals 搜索来源
      v_term := trim(both '+' from regexp_replace(lower(coalesce(p_result->>'search_term', '')), '[^a-z0-9]+', '+', 'g'));
      if length(v_term) >= 2 then
        insert into sources (key, name, kind, url, enabled, sort_order, auto, tag_id)
        values ('auto_tag_' || v_id, '自动：' || v_name, 'post_rss',
                'https://slickdeals.net/newsearch.php?q=' || left(v_term, 60) || '&searcharea=deals&searchin=first&rss=1',
                true, 1000, true, v_id)
        on conflict (key) do nothing;
        perform _auto_sources_enforce();
      end if;
    end if;
  else
    return jsonb_build_object('error', 'not_product');
  end if;

  if v_created then insert into tag_create_log (ip_hash) values (p_ip_hash); end if;
  insert into tag_ai_cache (query, tag_id) values (p_query, v_id) on conflict (query) do update set tag_id = excluded.tag_id;
  select slug into v_slug from tags where id = v_id;
  return jsonb_build_object('slug', v_slug, 'created', v_created);
end $$;

-- 抓取程序每次运行后调用：停用太久没结果的自动来源，并保证不超过上限
create or replace function auto_sources_maintain()
returns void language sql security definer set search_path = public as $$ select _auto_sources_enforce(); $$;

-- ---------- 后台函数 ----------
create or replace function admin_tags_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  return jsonb_build_object(
    'tags', (select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('subscribers', 0,
                      'merged_into_name', (select name_zh from tags m where m.id = t.merged_into))
                    order by t.merged_into nulls first, t.approved, t.visitors desc, t.id desc), '[]') from _tags_with_stats() t),
    'synonyms', (select coalesce(jsonb_agg(to_jsonb(s) order by s.category, s.term), '[]') from tag_synonyms s),
    'settings', (select jsonb_build_object('tag_public_min_visitors', tag_public_min_visitors, 'auto_source_max', auto_source_max,
                   'auto_source_stale_days', auto_source_stale_days, 'tag_daily_limit', tag_daily_limit) from settings where id = 1),
    'top_searches', (select coalesce(jsonb_agg(to_jsonb(x) order by x.searches desc), '[]') from (
        select t.name_zh as tag, count(*) searches, count(distinct s.visitor) visitors, max(s.created_at) last_at
        from tag_searches s join tags t on t.id = s.tag_id
        where s.created_at > now() - interval '30 days' group by t.name_zh order by count(*) desc limit 30) x),
    'misses', (select coalesce(jsonb_agg(to_jsonb(x) order by x.searches desc, x.last_at desc), '[]') from (
        select query, count(*) searches, count(distinct visitor) visitors, max(created_at) last_at
        from tag_searches where tag_id is null and created_at > now() - interval '30 days'
        group by query order by count(*) desc, max(created_at) desc limit 50) x),
    'auto_sources', (select coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'name', s.name, 'url', s.url, 'enabled', s.enabled,
                       'tag', t.name_zh, 'created_at', s.created_at, 'last_hit_at', s.last_hit_at) order by s.created_at desc), '[]')
                     from sources s left join tags t on t.id = s.tag_id where s.auto),
    'options', (select coalesce(jsonb_agg(jsonb_build_object('field', field, 'value', value, 'label', label) order by field, sort_order), '[]')
                from field_options where active and field in ('category', 'gpu'))
  );
end $$;

-- 新建或修改标签。p_tag: {id?, name_zh, name_en, aliases[], kind, category, gpu, capacity_tb, keywords[], approved}
create or replace function admin_tag_save(p_token text, p_tag jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := nullif(p_tag->>'id', '')::bigint; v_created boolean; v_kind text := coalesce(nullif(p_tag->>'kind', ''), 'structured');
        v_aliases text[]; v_kw text[]; v_cond jsonb; v_slug text; v_name text := trim(p_tag->>'name_zh');
        v_cat text := p_tag->>'category'; v_gpu text := nullif(trim(p_tag->>'gpu'), ''); v_cap numeric := trim_scale(nullif(p_tag->>'capacity_tb', '')::numeric);
begin
  perform _admin_check(p_token);
  select coalesce(array_agg(distinct trim(a)), '{}') into v_aliases
  from jsonb_array_elements_text(coalesce(p_tag->'aliases', '[]')) a where trim(a) <> '';

  if v_kind = 'keyword' then
    select array_agg(distinct lower(trim(k))) into v_kw from jsonb_array_elements_text(coalesce(p_tag->'keywords', '[]')) k where trim(k) <> '';
    if v_kw is null then raise exception '请至少填一个关键词'; end if;
    if coalesce(v_name, '') = '' then raise exception '请填写标签名'; end if;
    v_cond := jsonb_build_object('keywords', to_jsonb(v_kw));
    if v_id is null then
      v_slug := trim(both '-' from lower(regexp_replace(coalesce(nullif(trim(p_tag->>'name_en'), ''), v_name), '[^a-zA-Z0-9]+', '-', 'g')));
      if length(v_slug) < 2 or exists (select 1 from tags where slug = v_slug) then
        v_slug := trim(both '-' from v_slug || '-' || floor(random() * 1000000)::text);
      end if;
      insert into tags (slug, name_zh, name_en, aliases, kind, conditions, in_scope, created_by, approved)
      values (v_slug, v_name, nullif(trim(p_tag->>'name_en'), ''), v_aliases, 'keyword', v_cond, false, 'admin', coalesce((p_tag->>'approved')::boolean, true))
      returning id into v_id;
      return v_id;
    end if;
  else
    if v_id is null then
      select o_id, o_created into v_id, v_created from _tag_resolve_structured(v_cat, v_gpu, v_cap, 'admin', true);
      if not v_created then raise exception '已经有条件相同的标签了'; end if;
    else
      if v_cat in ('laptop', 'desktop', 'graphics_card') then v_cap := null; else v_gpu := null; end if;
      if exists (select 1 from tags where id <> v_id and kind = 'structured' and merged_into is null
                   and conditions->>'category' = v_cat and coalesce(conditions->>'gpu', '') = coalesce(v_gpu, '')
                   and coalesce(conditions->>'capacity_tb', '') = coalesce(v_cap::text, '')) then
        raise exception '已经有条件相同的标签了，可以用"合并"';
      end if;
      if not exists (select 1 from field_options where field = 'category' and value = v_cat and active) then raise exception '不支持的品类'; end if;
    end if;
    v_cond := jsonb_strip_nulls(jsonb_build_object('category', v_cat, 'gpu', v_gpu, 'capacity_tb', v_cap));
  end if;

  update tags set
    name_zh = coalesce(nullif(v_name, ''), name_zh),
    name_en = case when p_tag ? 'name_en' then nullif(trim(p_tag->>'name_en'), '') else name_en end,
    aliases = v_aliases, kind = v_kind, conditions = v_cond, in_scope = (v_kind = 'structured'),
    approved = coalesce((p_tag->>'approved')::boolean, approved)
  where id = v_id;
  if not found then raise exception '找不到这个标签'; end if;
  return v_id;
end $$;

create or replace function admin_tag_approve(p_token text, p_id bigint, p_approved boolean)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); update tags set approved = p_approved where id = p_id; end $$;

-- 合并：把 p_from 并进 p_into。别名和搜索记录并过去，旧网址自动跳转
create or replace function admin_tag_merge(p_token text, p_from bigint, p_into bigint)
returns void language plpgsql security definer set search_path = public as $$
declare f tags%rowtype;
begin
  perform _admin_check(p_token);
  if p_from = p_into then raise exception '不能合并到自己'; end if;
  select * into f from tags where id = p_from;
  if not found or not exists (select 1 from tags where id = p_into and merged_into is null) then raise exception '找不到标签'; end if;
  update tags set aliases = (select array_agg(distinct a) from unnest(aliases || f.aliases || array[f.name_zh]) a where a <> name_zh)
  where id = p_into;
  update tag_searches set tag_id = p_into where tag_id = p_from;
  update tag_ai_cache set tag_id = p_into where tag_id = p_from;
  update sources set tag_id = p_into where tag_id = p_from;
  update tags set merged_into = p_into where merged_into = p_from;
  update tags set merged_into = p_into, approved = false where id = p_from;
end $$;

create or replace function admin_tag_delete(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); delete from tags where id = p_id; end $$;

create or replace function admin_synonym_save(p_token text, p_term text, p_category text)
returns void language plpgsql security definer set search_path = public as $$
declare v_term text := lower(regexp_replace(coalesce(p_term, ''), '\s+', '', 'g'));
begin
  perform _admin_check(p_token);
  if v_term = '' then raise exception '请填写词语'; end if;
  if not exists (select 1 from field_options where field = 'category' and value = p_category and active) then raise exception '不支持的品类'; end if;
  insert into tag_synonyms (term, category) values (v_term, p_category)
  on conflict (term) do update set category = excluded.category;
end $$;

create or replace function admin_synonym_delete(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); delete from tag_synonyms where id = p_id; end $$;

create or replace function admin_tag_settings_save(p_token text, p_min_visitors int, p_source_max int, p_stale_days int, p_daily_limit int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update settings set tag_public_min_visitors = p_min_visitors, auto_source_max = p_source_max,
    auto_source_stale_days = p_stale_days, tag_daily_limit = p_daily_limit where id = 1;
  perform _auto_sources_enforce();
end $$;

-- ---------- 权限 ----------
revoke all on function _ip_hash(), _tag_rate_ok(text), _tags_with_stats(), _tag_resolve_structured(text, text, numeric, text, boolean),
  _auto_sources_enforce(), tag_ai_prepare(text, text), tag_ai_commit(text, jsonb, text), auto_sources_maintain()
  from public, anon, authenticated;
grant execute on function tag_ai_prepare(text, text), tag_ai_commit(text, jsonb, text), auto_sources_maintain() to service_role;
grant execute on function public_home(), public_resolve_tag(text, text, numeric), public_tag_deals(text, text, text),
  public_log_miss(text, text), admin_tags_get(text), admin_tag_save(text, jsonb), admin_tag_approve(text, bigint, boolean),
  admin_tag_merge(text, bigint, bigint), admin_tag_delete(text, bigint), admin_synonym_save(text, text, text),
  admin_synonym_delete(text, bigint), admin_tag_settings_save(text, int, int, int, int) to anon;

-- ---------- 预置数据 ----------
insert into tag_synonyms (term, category) values
  ('笔记本', 'laptop'), ('笔记本电脑', 'laptop'), ('游戏本', 'laptop'), ('笔电', 'laptop'), ('手提电脑', 'laptop'),
  ('laptop', 'laptop'), ('laptops', 'laptop'), ('notebook', 'laptop'),
  ('台式机', 'desktop'), ('台式电脑', 'desktop'), ('台式', 'desktop'), ('主机', 'desktop'), ('整机', 'desktop'),
  ('desktop', 'desktop'), ('desktops', 'desktop'), ('prebuilt', 'desktop'), ('gamingpc', 'desktop'),
  ('显卡', 'graphics_card'), ('独显', 'graphics_card'), ('gpu', 'graphics_card'), ('graphicscard', 'graphics_card'), ('videocard', 'graphics_card'),
  ('固态硬盘', 'ssd'), ('固态', 'ssd'), ('ssd', 'ssd'), ('nvme', 'ssd'),
  ('机械硬盘', 'hdd'), ('机械盘', 'hdd'), ('硬盘', 'hdd'), ('hdd', 'hdd'), ('harddrive', 'hdd'), ('移动硬盘', 'hdd')
on conflict (term) do nothing;

-- 预置标签：5 个品类、每个显卡型号 × 游戏本/台式机/显卡、2TB 和 4TB 固态。后台创建，直接算已批准
do $$
declare c text; g text;
begin
  foreach c in array array['laptop', 'desktop', 'graphics_card', 'ssd', 'hdd'] loop
    perform _tag_resolve_structured(c, null, null, 'admin', true);
  end loop;
  for g in select value from field_options where field = 'gpu' and active order by sort_order loop
    foreach c in array array['laptop', 'desktop', 'graphics_card'] loop
      perform _tag_resolve_structured(c, g, null, 'admin', true);
    end loop;
  end loop;
  perform _tag_resolve_structured('ssd', null, 2, 'admin', true);
  perform _tag_resolve_structured('ssd', null, 4, 'admin', true);
end $$;
