-- ============================================
-- Woot 零点专抓：Woot 每天中部时间（芝加哥）零点上新，
-- 零点过 2 分钟和过 15 分钟各只抓一次 Woot，不影响常规刷新节奏
-- 用法：在 schema_review.sql 之后运行；可以重复运行
-- ============================================

alter table runs add column if not exists scope text not null default 'all';   -- all = 常规抓取；woot = 零点专抓
alter table settings add column if not exists woot_midnight boolean not null default true;

-- 常规定时只看常规抓取的记录（零点专抓不打乱常规刷新节奏）
create or replace function cron_tick()
returns text language plpgsql security definer set search_path = public, extensions, net as $$
declare
  s settings%rowtype;
  last_start timestamptz; last_finish timestamptz; due boolean; v_req bigint;
begin
  select * into s from settings where id = 1;
  if s.github_token is null or s.github_token = '' then return 'no token'; end if;
  select started_at, finished_at into last_start, last_finish from runs where scope = 'all' order by finished_at desc limit 1;

  if s.last_cron_dispatch_at is not null
     and (last_finish is null or s.last_cron_dispatch_at > last_finish)
     and now() - s.last_cron_dispatch_at < interval '20 minutes' then
    return 'waiting for previous run';
  end if;

  due := last_finish is null
      or (s.refresh_requested_at is not null and s.refresh_requested_at > coalesce(last_start, last_finish))
      or now() - last_finish >= make_interval(mins => s.refresh_minutes - 2);
  if not due then return 'not due'; end if;

  select net.http_post(
    url := 'https://api.github.com/repos/' || s.github_repo || '/actions/workflows/fetch.yml/dispatches',
    body := '{"ref":"main"}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || s.github_token, 'Accept', 'application/vnd.github+json',
                                  'User-Agent', 'samsdeals-cron', 'X-GitHub-Api-Version', '2022-11-28',
                                  'Content-Type', 'application/json')
  ) into v_req;
  update settings set last_cron_dispatch_at = now(), last_dispatch_id = v_req where id = 1;
  return 'dispatched';
end $$;

-- Woot 零点专抓：只在芝加哥时间 0 点那一小时内触发（自动适应夏令时）
create or replace function woot_tick()
returns text language plpgsql security definer set search_path = public, extensions, net as $$
declare s settings%rowtype; v_req bigint;
begin
  select * into s from settings where id = 1;
  if not s.woot_midnight then return 'off'; end if;
  if s.github_token is null or s.github_token = '' then return 'no token'; end if;
  if extract(hour from now() at time zone 'America/Chicago') <> 0 then return 'not midnight in Chicago'; end if;
  select net.http_post(
    url := 'https://api.github.com/repos/' || s.github_repo || '/actions/workflows/fetch.yml/dispatches',
    body := '{"ref":"main","inputs":{"only":"woot"}}'::jsonb,
    headers := jsonb_build_object('Authorization', 'Bearer ' || s.github_token, 'Accept', 'application/vnd.github+json',
                                  'User-Agent', 'samsdeals-woot', 'X-GitHub-Api-Version', '2022-11-28',
                                  'Content-Type', 'application/json')
  ) into v_req;
  return 'dispatched ' || v_req;
end $$;
revoke all on function woot_tick() from public, anon, authenticated;

-- UTC 5 点和 6 点都排上（夏令时芝加哥零点 = UTC 5 点，冬令时 = UTC 6 点），函数里再判断当地时间
select cron.unschedule(jobid) from cron.job where jobname = 'samsdeals-woot-midnight';
select cron.schedule('samsdeals-woot-midnight', '2,15 5,6 * * *', 'select woot_tick()');

-- 后台：读取和保存开关
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
                   'github_repo', github_repo,
                   'review_discount_pct', review_discount_pct,
                   'review_unknown_store', review_unknown_store,
                   'woot_midnight', woot_midnight) from settings where id = 1),
    'runs', (select coalesce(jsonb_agg(x), '[]') from (select * from runs order by finished_at desc limit 10) x),
    'deal_stats', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from deals group by status) y),
    'deals', (select coalesce(jsonb_agg(d order by d.created_at desc), '[]') from (
                select id, title, url, source, store, price, price_checked, threshold, category, gpu, capacity_tb,
                       quantity, condition, status, adjustments_applied, created_at, emailed_at
                from deals
                where status in ('review', 'passed', 'hidden')
                   or (status = 'removed' and created_at > now() - interval '30 days')
                order by created_at desc limit 300) d)
  );
end $$;

create or replace function admin_set_woot_midnight(p_token text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin perform _admin_check(p_token); update settings set woot_midnight = p_on where id = 1; end $$;

grant execute on function admin_get_all(text), admin_set_woot_midnight(text, boolean) to anon;
