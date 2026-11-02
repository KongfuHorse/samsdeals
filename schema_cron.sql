-- ============================================
-- 定时：Supabase 每 10 分钟检查一次，到了后台设的刷新间隔就通知 GitHub 运行抓取
-- （GitHub 自己的定时很不准，常常几个小时才跑一次，这里改由 Supabase 负责）
-- 需要先在后台"刷新设置"里填好 GitHub 令牌
-- 用法：先运行 schema.sql 和 schema_admin.sql，再运行这个文件
-- ============================================

create extension if not exists pg_cron;

alter table settings add column if not exists last_cron_dispatch_at timestamptz;

create or replace function cron_tick()
returns text language plpgsql security definer set search_path = public, extensions, net as $$
declare
  s settings%rowtype;
  last_start timestamptz; last_finish timestamptz; due boolean; v_req bigint;
begin
  select * into s from settings where id = 1;
  if s.github_token is null or s.github_token = '' then return 'no token'; end if;
  select started_at, finished_at into last_start, last_finish from runs order by finished_at desc limit 1;

  -- 上次通知后还没跑完：等它，20 分钟后还没结果才重试
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

revoke all on function cron_tick() from public, anon, authenticated;

-- 每 10 分钟执行一次（重复运行这个文件不会建出两个定时任务）
select cron.unschedule(jobid) from cron.job where jobname = 'samsdeals-tick';
select cron.schedule('samsdeals-tick', '*/10 * * * *', 'select cron_tick()');
