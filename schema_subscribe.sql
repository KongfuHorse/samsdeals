-- ============================================
-- 第二阶段：按标签订阅邮件（Resend 发信）
--   订阅 → 确认邮件 → 点链接生效；每天汇总（美东晚上 8 点）或马上通知（新优惠排进前 3 名）
--   每封邮件带"管理订阅"和"退订"；退订全部会立刻删除邮箱
-- 用法：在 schema_images.sql 之后运行；可以重复运行
-- 发信的代码在 supabase/functions/subscribe、unsubscribe、notify
-- ============================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists subscribers (
  id bigint generated always as identity primary key,
  email text not null unique,
  token text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),   -- 管理订阅、退订用
  ip_hash text,
  created_at timestamptz not null default now(),
  confirmed_at timestamptz
);
alter table subscribers add column if not exists lang text not null default 'zh';   -- 邮件语言：zh / en，按订阅时的网页语言

create table if not exists subscriptions (
  id bigint generated always as identity primary key,
  subscriber_id bigint not null references subscribers(id) on delete cascade,
  tag_id bigint not null references tags(id) on delete cascade,
  frequency text not null check (frequency in ('daily', 'instant')),
  status text not null default 'pending' check (status in ('pending', 'active')),
  pending_frequency text check (pending_frequency in ('daily', 'instant')),   -- 已生效的订阅改频率，确认后才换
  confirm_token text unique,
  requested_at timestamptz not null default now(),
  activated_at timestamptz,
  last_digest_at timestamptz,
  unique (subscriber_id, tag_id)
);

-- 每个订阅已经发过的优惠，避免重复发
create table if not exists sub_sent (
  subscription_id bigint not null references subscriptions(id) on delete cascade,
  deal_url text not null,
  sent_at timestamptz not null default now(),
  primary key (subscription_id, deal_url)
);

-- 发信记录（不存邮箱地址；退订删除后 subscriber_id 变成空）
create table if not exists email_log (
  id bigint generated always as identity primary key,
  kind text not null,                     -- confirm / instant / digest / alert
  subscriber_id bigint references subscribers(id) on delete set null,
  subject text,
  resend_id text,
  ok boolean not null default true,
  error text,
  created_at timestamptz not null default now()
);
create index if not exists email_log_created on email_log (created_at);

create table if not exists sub_ip_log (ip_hash text not null, created_at timestamptz not null default now());
create index if not exists sub_ip_log_idx on sub_ip_log (ip_hash, created_at);

alter table subscribers enable row level security;
alter table subscriptions enable row level security;
alter table sub_sent enable row level security;
alter table email_log enable row level security;
alter table sub_ip_log enable row level security;
revoke all on subscribers, subscriptions, sub_sent, email_log, sub_ip_log from anon, authenticated;

alter table settings add column if not exists subscribe_enabled boolean not null default false;   -- 网站订阅开关
alter table settings add column if not exists email_daily_limit int not null default 100;         -- Resend 免费版每天 100 封
alter table settings add column if not exists email_monthly_limit int not null default 3000;      -- 每月 3,000 封
alter table settings add column if not exists digest_hour int not null default 20;                -- 每天汇总：美东时间几点
alter table settings add column if not exists instant_daily_max int not null default 5;           -- 马上通知：每人每天最多几封
alter table settings add column if not exists last_digest_date date;
alter table settings add column if not exists quota_alert_date date;
alter table settings add column if not exists admin_email text;                                   -- 额度快用完时提醒谁
alter table settings add column if not exists notify_key text;                                    -- 定时任务调用 notify 的口令
alter table settings add column if not exists notify_url text
  not null default 'https://pmjmexfueofdaubcumgk.supabase.co/functions/v1/mail/notify';

-- ---------- 内部函数 ----------
-- 还能发多少封：今天（UTC，和 Resend 一样）和最近 30 天，取小的
create or replace function _email_quota()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'day_used', (select count(*) from email_log where ok and created_at >= date_trunc('day', now() at time zone 'utc') at time zone 'utc'),
    'month_used', (select count(*) from email_log where ok and created_at > now() - interval '30 days'),
    'day_limit', s.email_daily_limit, 'month_limit', s.email_monthly_limit)
  from settings s where s.id = 1;
$$;

create or replace function _email_quota_left()
returns int language sql stable security definer set search_path = public as $$
  select greatest(0, least((q->>'day_limit')::int - (q->>'day_used')::int, (q->>'month_limit')::int - (q->>'month_used')::int))
  from (select _email_quota() q) x;
$$;

-- ---------- 服务器用（Edge Function 调用） ----------
-- 订阅请求：检查后返回要发的确认邮件内容
drop function if exists sub_request(text, text, text, text, boolean);
create or replace function sub_request(p_email text, p_slug text, p_frequency text, p_ip_hash text, p_test boolean default false,
                                       p_lang text default 'zh')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_lang text := case when p_lang = 'en' then 'en' else 'zh' end;
  t tags%rowtype; s subscribers%rowtype; x subscriptions%rowtype; v_token text; v_has boolean;
begin
  if not p_test and not (select subscribe_enabled from settings where id = 1) then return jsonb_build_object('error', 'closed'); end if;
  if p_frequency not in ('daily', 'instant') then return jsonb_build_object('error', 'bad_request'); end if;
  if length(v_email) > 254 or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then return jsonb_build_object('error', 'bad_email'); end if;

  select * into t from tags where slug = p_slug;
  if found and t.merged_into is not null then select * into t from tags where id = t.merged_into; end if;
  if not found then return jsonb_build_object('error', 'bad_tag'); end if;

  if (select count(*) from sub_ip_log where ip_hash = p_ip_hash and created_at > now() - interval '24 hours') >= 10 then
    return jsonb_build_object('error', 'limited');
  end if;
  insert into sub_ip_log (ip_hash) values (p_ip_hash);

  insert into subscribers (email, ip_hash, lang) values (v_email, p_ip_hash, v_lang) on conflict (email) do nothing;
  select * into s from subscribers where email = v_email;
  if (select count(*) from email_log where subscriber_id = s.id and kind = 'confirm' and created_at > now() - interval '24 hours') >= 3 then
    return jsonb_build_object('error', 'limited');
  end if;

  select * into x from subscriptions where subscriber_id = s.id and tag_id = t.id;
  v_has := found;
  if v_has and x.status = 'active' and x.frequency = p_frequency and x.pending_frequency is null then
    return jsonb_build_object('ok', true, 'already', true);          -- 已经订阅了，不再发信
  end if;
  if v_has and x.requested_at > now() - interval '10 minutes' and coalesce(x.pending_frequency, x.frequency) = p_frequency then
    return jsonb_build_object('ok', true, 'cooldown', true);         -- 10 分钟内刚发过确认邮件
  end if;
  if _email_quota_left() < 1 then return jsonb_build_object('error', 'quota'); end if;

  v_token := encode(gen_random_bytes(16), 'hex');
  update subscribers set lang = v_lang where id = s.id;               -- 以最近一次订阅时的网页语言为准
  if not v_has then
    insert into subscriptions (subscriber_id, tag_id, frequency, confirm_token) values (s.id, t.id, p_frequency, v_token);
  elsif x.status = 'pending' then
    update subscriptions set frequency = p_frequency, confirm_token = v_token, requested_at = now() where id = x.id;
  else
    update subscriptions set pending_frequency = p_frequency, confirm_token = v_token, requested_at = now() where id = x.id;
  end if;
  return jsonb_build_object('send', jsonb_build_object('email', v_email, 'subscriber_id', s.id, 'confirm', v_token,
    'tag', t.name_zh, 'tag_en', t.name_en, 'slug', t.slug, 'frequency', p_frequency, 'key', s.token, 'lang', v_lang));
end $$;

create or replace function email_log_add(p_rows jsonb)
returns void language sql security definer set search_path = public as $$
  insert into email_log (kind, subscriber_id, subject, resend_id, ok, error)
  select r->>'kind', nullif(r->>'subscriber_id', '')::bigint, r->>'subject', r->>'resend_id', coalesce((r->>'ok')::boolean, true), r->>'error'
  from jsonb_array_elements(p_rows) r;
$$;

-- 发通知前取数据：所有生效的订阅、已发过的优惠、额度
create or replace function notify_prepare()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'settings', (select jsonb_build_object('digest_hour', digest_hour, 'last_digest_date', last_digest_date,
                   'instant_daily_max', instant_daily_max, 'quota_alert_date', quota_alert_date, 'admin_email', admin_email)
                 from settings where id = 1),
    'quota', _email_quota(),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'subscriber_id', s.id, 'email', s.email, 'key', s.token, 'tag_id', t.id, 'slug', t.slug, 'tag', t.name_zh,
        'tag_en', t.name_en, 'lang', s.lang,
        'frequency', x.frequency, 'activated_at', x.activated_at, 'last_digest_at', x.last_digest_at,
        'sent', (select coalesce(jsonb_agg(z.deal_url), '[]') from sub_sent z where z.subscription_id = x.id),
        'instant_today', (select count(*) from email_log l where l.subscriber_id = s.id and l.kind = 'instant' and l.ok
                          and l.created_at > now() - interval '24 hours'))), '[]')
      from subscriptions x join subscribers s on s.id = x.subscriber_id join tags t on t.id = x.tag_id
      where x.status = 'active'));
$$;

-- 发完以后记下来；顺便清理 7 天没确认的订阅请求
create or replace function notify_commit(p_sent jsonb, p_digested bigint[], p_digest_date date, p_alert_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into sub_sent (subscription_id, deal_url)
  select (r->>'id')::bigint, r->>'url' from jsonb_array_elements(coalesce(p_sent, '[]')) r
  where exists (select 1 from subscriptions where id = (r->>'id')::bigint)
  on conflict do nothing;
  update subscriptions set last_digest_at = now() where id = any(coalesce(p_digested, '{}'));
  if p_digest_date is not null then update settings set last_digest_date = p_digest_date where id = 1; end if;
  if p_alert_date is not null then update settings set quota_alert_date = p_alert_date where id = 1; end if;
  perform _sub_cleanup();
end $$;

-- 清理：7 天没确认的订阅请求和邮箱、45 天前的发送记录、2 天前的 IP 摘要（隐私政策里写了这些期限）
create or replace function _sub_cleanup()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from sub_sent where sent_at < now() - interval '45 days';
  delete from subscriptions where status = 'pending' and requested_at < now() - interval '7 days';
  update subscriptions set pending_frequency = null, confirm_token = null
  where status = 'active' and confirm_token is not null and requested_at < now() - interval '7 days';
  delete from subscribers s where s.confirmed_at is null and s.created_at < now() - interval '7 days'
    and not exists (select 1 from subscriptions x where x.subscriber_id = s.id);
  delete from subscribers s where not exists (select 1 from subscriptions x where x.subscriber_id = s.id)
    and s.created_at < now() - interval '7 days';
  delete from sub_ip_log where created_at < now() - interval '2 days';
end $$;

-- ---------- 网页用（确认、管理订阅；凭邮件里的随机链接） ----------
create or replace function public_sub_confirm(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare x subscriptions%rowtype; v_key text; v_tag text; v_tag_en text;
begin
  select * into x from subscriptions where confirm_token = p_token and length(coalesce(p_token, '')) = 32;
  if not found then return jsonb_build_object('error', 'invalid'); end if;
  if x.requested_at < now() - interval '7 days' then return jsonb_build_object('error', 'expired'); end if;
  update subscriptions set status = 'active', activated_at = coalesce(activated_at, now()),
         frequency = coalesce(pending_frequency, frequency), pending_frequency = null, confirm_token = null
  where id = x.id;
  update subscribers set confirmed_at = coalesce(confirmed_at, now()) where id = x.subscriber_id returning token into v_key;
  select name_zh, name_en into v_tag, v_tag_en from tags where id = x.tag_id;
  return jsonb_build_object('key', v_key, 'tag', v_tag, 'tag_en', v_tag_en);
end $$;

create or replace function public_sub_get(p_key text)
returns jsonb language sql security definer set search_path = public as $$
  select case when s.id is null then null else jsonb_build_object('email', s.email, 'subs', (
    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'tag', t.name_zh, 'tag_en', t.name_en, 'slug', t.slug, 'frequency', x.frequency,
                                                 'status', x.status) order by x.requested_at), '[]')
    from subscriptions x join tags t on t.id = x.tag_id where x.subscriber_id = s.id)) end
  from (select 1) one left join subscribers s on s.token = p_key and length(coalesce(p_key, '')) = 32;
$$;

create or replace function public_sub_update(p_key text, p_id bigint, p_frequency text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_frequency not in ('daily', 'instant') then raise exception '频率不对'; end if;
  update subscriptions x set frequency = p_frequency, pending_frequency = null
  from subscribers s where s.id = x.subscriber_id and s.token = p_key and x.id = p_id;
end $$;

create or replace function public_sub_remove(p_key text, p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_sid bigint;
begin
  select id into v_sid from subscribers where token = p_key and length(coalesce(p_key, '')) = 32;
  if v_sid is null then return; end if;
  delete from subscriptions where id = p_id and subscriber_id = v_sid;
  delete from subscribers where id = v_sid and not exists (select 1 from subscriptions where subscriber_id = v_sid);  -- 一个都没订了就删除邮箱
end $$;

-- 退订全部：直接删除邮箱和所有订阅
create or replace function public_sub_remove_all(p_key text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from subscribers where token = p_key and length(coalesce(p_key, '')) = 32;
  return found;
end $$;

-- ---------- 后台 ----------
create or replace function admin_sub_get(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  return jsonb_build_object(
    'settings', (select jsonb_build_object('subscribe_enabled', subscribe_enabled, 'email_daily_limit', email_daily_limit,
                   'email_monthly_limit', email_monthly_limit, 'digest_hour', digest_hour, 'instant_daily_max', instant_daily_max,
                   'admin_email', admin_email, 'last_digest_date', last_digest_date) from settings where id = 1),
    'quota', _email_quota(),
    'stats', jsonb_build_object(
      'subscribers', (select count(*) from subscribers where confirmed_at is not null),
      'active', (select count(*) from subscriptions where status = 'active'),
      'daily', (select count(*) from subscriptions where status = 'active' and frequency = 'daily'),
      'instant', (select count(*) from subscriptions where status = 'active' and frequency = 'instant'),
      'pending', (select count(*) from subscriptions where status = 'pending')),
    'by_tag', (select coalesce(jsonb_agg(to_jsonb(y) order by y.n desc), '[]') from (
        select t.name_zh as tag, t.slug, count(*) n,
               count(*) filter (where x.frequency = 'daily') daily, count(*) filter (where x.frequency = 'instant') instant
        from subscriptions x join tags t on t.id = x.tag_id where x.status = 'active' group by t.name_zh, t.slug) y),
    'log', (select coalesce(jsonb_agg(to_jsonb(l) order by l.created_at desc), '[]') from (
        select kind, subject, ok, error, created_at from email_log order by created_at desc limit 40) l));
end $$;

create or replace function admin_sub_settings_save(p_token text, p_enabled boolean, p_daily int, p_monthly int,
                                                   p_digest_hour int, p_instant_max int, p_admin_email text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  if p_digest_hour not between 0 and 23 then raise exception '汇总时间要在 0 到 23 点之间'; end if;
  if p_daily < 0 or p_monthly < 0 or p_instant_max < 0 then raise exception '数字不能是负数'; end if;
  if coalesce(trim(p_admin_email), '') <> '' and trim(p_admin_email) !~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' then raise exception '提醒邮箱格式不对'; end if;
  update settings set subscribe_enabled = p_enabled, email_daily_limit = p_daily, email_monthly_limit = p_monthly,
         digest_hour = p_digest_hour, instant_daily_max = p_instant_max, admin_email = nullif(trim(p_admin_email), '')
  where id = 1;
end $$;

-- ---------- 定时：每 10 分钟调用一次 notify（马上通知；到了晚上 8 点顺便发每天汇总） ----------
update settings set notify_key = encode(extensions.gen_random_bytes(24), 'hex') where id = 1 and notify_key is null;

create or replace function _notify_tick()
returns bigint language plpgsql security definer set search_path = public, extensions, net as $$
declare s settings%rowtype; v_req bigint;
begin
  perform _sub_cleanup();
  select * into s from settings where id = 1;
  if s.notify_key is null then return null; end if;
  if not exists (select 1 from subscriptions where status = 'active') then return null; end if;   -- 没人订阅就不用跑
  select net.http_post(url := s.notify_url, body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-key', s.notify_key)) into v_req;
  return v_req;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'subdeals-notify';
select cron.schedule('subdeals-notify', '*/10 * * * *', 'select _notify_tick()');

-- ---------- 权限 ----------
revoke all on function _email_quota(), _email_quota_left(), sub_request(text, text, text, text, boolean, text), email_log_add(jsonb),
  notify_prepare(), notify_commit(jsonb, bigint[], date, date), _notify_tick(), _sub_cleanup()
  from public, anon, authenticated;
grant execute on function sub_request(text, text, text, text, boolean, text), email_log_add(jsonb), notify_prepare(),
  notify_commit(jsonb, bigint[], date, date) to service_role;
grant execute on function public_sub_confirm(text), public_sub_get(text), public_sub_update(text, bigint, text),
  public_sub_remove(text, bigint), public_sub_remove_all(text), admin_sub_get(text),
  admin_sub_settings_save(text, boolean, int, int, int, int, text) to anon;
