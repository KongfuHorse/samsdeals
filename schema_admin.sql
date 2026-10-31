-- ============================================
-- 后台管理：登录、优惠来源、刷新设置、所有后台操作
-- 用法：先运行 schema.sql，再运行这个文件
-- 安全说明：
--   - 网页只能调用下面的 admin_ 函数，函数里先检查登录令牌，再做修改
--   - 管理员密码用 bcrypt 加密保存；GitHub 令牌只存在数据库里，网页读不到
--   - 运行前把最下面的 CHANGE_ME_PASSWORD 改成你的后台密码
-- ============================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;

-- ---------- 优惠来源 ----------
create table if not exists sources (
  key text primary key,
  name text not null,
  kind text not null check (kind in ('post_rss', 'article_rss', 'woot')),
  url text,
  deal_titles_only boolean not null default false,  -- 文章型：只读标题像 deal 的文章
  enabled boolean not null default true,
  sort_order int not null default 0
);
alter table sources enable row level security;

insert into sources (key, name, kind, url, deal_titles_only, sort_order) values
  ('sd_frontpage', 'Slickdeals 首页', 'post_rss', 'https://slickdeals.net/newsearch.php?mode=frontpage&searcharea=deals&searchin=first&rss=1', false, 1),
  ('sd_popular', 'Slickdeals 热门', 'post_rss', 'https://slickdeals.net/newsearch.php?mode=popdeals&searcharea=deals&searchin=first&rss=1', false, 2),
  ('sd_rtx5090', 'Slickdeals 搜索 RTX 5090', 'post_rss', 'https://slickdeals.net/newsearch.php?q=rtx+5090&searcharea=deals&searchin=first&rss=1', false, 3),
  ('sd_rtx5080', 'Slickdeals 搜索 RTX 5080', 'post_rss', 'https://slickdeals.net/newsearch.php?q=rtx+5080&searcharea=deals&searchin=first&rss=1', false, 4),
  ('sd_rtx5070ti', 'Slickdeals 搜索 RTX 5070 Ti', 'post_rss', 'https://slickdeals.net/newsearch.php?q=rtx+5070+ti&searcharea=deals&searchin=first&rss=1', false, 5),
  ('sd_rtx5070', 'Slickdeals 搜索 RTX 5070', 'post_rss', 'https://slickdeals.net/newsearch.php?q=rtx+5070&searcharea=deals&searchin=first&rss=1', false, 6),
  ('sd_rtx5060', 'Slickdeals 搜索 RTX 5060', 'post_rss', 'https://slickdeals.net/newsearch.php?q=rtx+5060&searcharea=deals&searchin=first&rss=1', false, 7),
  ('sd_alienware', 'Slickdeals 搜索 Alienware', 'post_rss', 'https://slickdeals.net/newsearch.php?q=alienware&searcharea=deals&searchin=first&rss=1', false, 8),
  ('sd_lenovo_outlet', 'Slickdeals 搜索 Lenovo Outlet', 'post_rss', 'https://slickdeals.net/newsearch.php?q=lenovo+outlet&searcharea=deals&searchin=first&rss=1', false, 9),
  ('sd_hard_drive', 'Slickdeals 搜索 Hard Drive', 'post_rss', 'https://slickdeals.net/newsearch.php?q=hard+drive&searcharea=deals&searchin=first&rss=1', false, 10),
  ('sd_ssd', 'Slickdeals 搜索 SSD', 'post_rss', 'https://slickdeals.net/newsearch.php?q=ssd&searcharea=deals&searchin=first&rss=1', false, 11),
  ('reddit_bapcs', 'Reddit r/buildapcsales', 'post_rss', 'https://www.reddit.com/r/buildapcsales/new/.rss', false, 12),
  ('woot_computers', 'Woot 电脑类（官方 API）', 'woot', 'Computers', false, 13),
  ('tomshardware', 'Tom''s Hardware', 'article_rss', 'https://www.tomshardware.com/feeds.xml', true, 14),
  ('techradar', 'TechRadar Deals', 'article_rss', 'https://www.techradar.com/feeds/tag/deals', false, 15)
on conflict (key) do nothing;

-- ---------- 刷新设置（只有一行） ----------
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  refresh_minutes int not null default 30 check (refresh_minutes between 10 and 1440),
  refresh_requested_at timestamptz,
  github_token text,                       -- 用于"立即刷新"，网页读不到
  github_repo text not null default 'KongfuHorse/samsdeals',
  last_dispatch_id bigint
);
alter table settings enable row level security;
insert into settings (id) values (1) on conflict (id) do nothing;

-- ---------- 管理员和登录 ----------
create table if not exists admin_users (
  username text primary key,
  password_hash text not null
);
alter table admin_users enable row level security;

create table if not exists admin_sessions (
  token text primary key,
  username text not null references admin_users(username) on delete cascade,
  expires_at timestamptz not null
);
alter table admin_sessions enable row level security;

-- ============================================
-- 函数
-- ============================================

create or replace function admin_login(p_username text, p_password text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_token text;
begin
  select password_hash into v_hash from admin_users where username = p_username;
  if v_hash is null or crypt(p_password, v_hash) <> v_hash then
    perform pg_sleep(1);                      -- 放慢猜密码
    raise exception '账号或密码错误';
  end if;
  delete from admin_sessions where expires_at < now();
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into admin_sessions values (v_token, p_username, now() + interval '12 hours');
  return v_token;
end $$;

create or replace function _admin_check(p_token text)
returns text language plpgsql security definer set search_path = public as $$
declare v_user text;
begin
  select username into v_user from admin_sessions where token = p_token and expires_at > now();
  if v_user is null then raise exception '登录已过期，请重新登录'; end if;
  return v_user;
end $$;

create or replace function admin_logout(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from admin_sessions where token = p_token;
$$;

create or replace function admin_change_password(p_token text, p_old text, p_new text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_user text; v_hash text;
begin
  v_user := _admin_check(p_token);
  select password_hash into v_hash from admin_users where username = v_user;
  if crypt(p_old, v_hash) <> v_hash then raise exception '原密码不对'; end if;
  if length(p_new) < 8 then raise exception '新密码至少 8 位'; end if;
  update admin_users set password_hash = crypt(p_new, gen_salt('bf')) where username = v_user;
end $$;

-- 一次读取后台需要的全部数据
create or replace function admin_get_all(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  return jsonb_build_object(
    'rules', (select coalesce(jsonb_agg(r order by r.category, r.gpu, r.capacity_tb, r.id), '[]') from price_rules r),
    'adjustments', (select coalesce(jsonb_agg(a order by a.id), '[]') from price_adjustments a),
    'options', (select coalesce(jsonb_agg(o order by o.field, o.sort_order, o.id), '[]') from field_options o),
    'sources', (select coalesce(jsonb_agg(s order by s.sort_order), '[]') from sources s),
    'settings', (select jsonb_build_object('refresh_minutes', refresh_minutes,
                   'refresh_requested_at', refresh_requested_at,
                   'has_github_token', github_token is not null and github_token <> '',
                   'github_repo', github_repo) from settings where id = 1),
    'runs', (select coalesce(jsonb_agg(x), '[]') from (select * from runs order by finished_at desc limit 10) x),
    'deal_stats', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from deals group by status) y)
  );
end $$;

-- 价格规则：p_rule 里有 id 就更新，没有就新增
create or replace function admin_save_rule(p_token text, p_rule jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := (p_rule->>'id')::bigint;
begin
  perform _admin_check(p_token);
  if v_id is null then
    insert into price_rules (category, gpu, ram_gb, capacity_tb, price_mode, max_price, resale_price, note, active)
    values (p_rule->>'category', nullif(p_rule->>'gpu',''), nullif(p_rule->>'ram_gb','')::int,
            nullif(p_rule->>'capacity_tb','')::numeric, coalesce(nullif(p_rule->>'price_mode',''),'total'),
            (p_rule->>'max_price')::numeric, nullif(p_rule->>'resale_price','')::numeric,
            p_rule->>'note', coalesce((p_rule->>'active')::boolean, true))
    returning id into v_id;
  else
    update price_rules set category = p_rule->>'category', gpu = nullif(p_rule->>'gpu',''),
      ram_gb = nullif(p_rule->>'ram_gb','')::int, capacity_tb = nullif(p_rule->>'capacity_tb','')::numeric,
      price_mode = coalesce(nullif(p_rule->>'price_mode',''),'total'), max_price = (p_rule->>'max_price')::numeric,
      resale_price = nullif(p_rule->>'resale_price','')::numeric, note = p_rule->>'note',
      active = coalesce((p_rule->>'active')::boolean, true)
    where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function admin_delete_rule(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); delete from price_rules where id = p_id; end $$;

create or replace function admin_save_adjustment(p_token text, p_adj jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := (p_adj->>'id')::bigint;
begin
  perform _admin_check(p_token);
  if v_id is null then
    insert into price_adjustments (category, field, value, pct, amount, note, active)
    values (nullif(p_adj->>'category',''), p_adj->>'field', p_adj->>'value',
            coalesce(nullif(p_adj->>'pct','')::numeric, 0), coalesce(nullif(p_adj->>'amount','')::numeric, 0),
            p_adj->>'note', coalesce((p_adj->>'active')::boolean, true))
    returning id into v_id;
  else
    update price_adjustments set category = nullif(p_adj->>'category',''), field = p_adj->>'field',
      value = p_adj->>'value', pct = coalesce(nullif(p_adj->>'pct','')::numeric, 0),
      amount = coalesce(nullif(p_adj->>'amount','')::numeric, 0), note = p_adj->>'note',
      active = coalesce((p_adj->>'active')::boolean, true)
    where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function admin_delete_adjustment(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); delete from price_adjustments where id = p_id; end $$;

create or replace function admin_add_option(p_token text, p_field text, p_value text, p_label text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  if p_field not in ('category', 'gpu', 'condition', 'series') then raise exception '不支持的选项类型'; end if;
  insert into field_options (field, value, label, sort_order)
  values (p_field, trim(p_value), coalesce(nullif(trim(p_label),''), trim(p_value)),
          (select coalesce(max(sort_order),0)+1 from field_options where field = p_field))
  on conflict (field, value) do update set active = true, label = excluded.label;
end $$;

create or replace function admin_delete_option(p_token text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); delete from field_options where id = p_id; end $$;

create or replace function admin_set_source(p_token text, p_key text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); update sources set enabled = p_enabled where key = p_key; end $$;

-- 刷新设置：p_github_token 传 null = 不改；传空字符串 = 删除
create or replace function admin_save_settings(p_token text, p_refresh_minutes int, p_github_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update settings set refresh_minutes = p_refresh_minutes where id = 1;
  if p_github_token is not null then
    update settings set github_token = nullif(trim(p_github_token), '') where id = 1;
  end if;
end $$;

-- 立即刷新：记下请求；有 GitHub 令牌就马上通知 GitHub 运行
create or replace function admin_refresh_now(p_token text)
returns text language plpgsql security definer set search_path = public, extensions, net as $$
declare v_gh text; v_repo text; v_req bigint;
begin
  perform _admin_check(p_token);
  update settings set refresh_requested_at = now() where id = 1 returning github_token, github_repo into v_gh, v_repo;
  if v_gh is null or v_gh = '' then
    return 'queued';            -- 没有令牌：下一次定时检查时运行（最多约 10 分钟）
  end if;
  select net.http_post(
    url := 'https://api.github.com/repos/' || v_repo || '/actions/workflows/fetch.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_gh, 'Accept', 'application/vnd.github+json',
                                  'User-Agent', 'samsdeals-admin', 'X-GitHub-Api-Version', '2022-11-28',
                                  'Content-Type', 'application/json')
  ) into v_req;
  update settings set last_dispatch_id = v_req where id = 1;
  return 'dispatched';
end $$;

-- 查看上一次"立即刷新"有没有被 GitHub 接受（204 = 成功）
create or replace function admin_dispatch_status(p_token text)
returns jsonb language plpgsql security definer set search_path = public, net as $$
declare v_id bigint; v jsonb;
begin
  perform _admin_check(p_token);
  select last_dispatch_id into v_id from settings where id = 1;
  if v_id is null then return null; end if;
  select jsonb_build_object('status_code', status_code, 'error', error_msg, 'body', left(content, 300))
    into v from net._http_response where id = v_id;
  return v;
end $$;

-- 只允许网页调用 admin_ 函数；内部检查函数不对外
revoke all on function _admin_check(text) from public, anon, authenticated;
grant execute on function admin_login(text, text), admin_logout(text), admin_change_password(text, text, text),
  admin_get_all(text), admin_save_rule(text, jsonb), admin_delete_rule(text, bigint),
  admin_save_adjustment(text, jsonb), admin_delete_adjustment(text, bigint),
  admin_add_option(text, text, text, text), admin_delete_option(text, bigint),
  admin_set_source(text, text, boolean), admin_save_settings(text, int, text),
  admin_refresh_now(text), admin_dispatch_status(text) to anon;

-- ---------- 管理员账号（把 CHANGE_ME_PASSWORD 换成你的密码再运行） ----------
insert into admin_users (username, password_hash)
values ('admin', extensions.crypt('CHANGE_ME_PASSWORD', extensions.gen_salt('bf')))
on conflict (username) do nothing;
