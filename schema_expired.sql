-- 优惠过期：后台手动标记。过期的优惠在标签页变灰、划线、标"已过期"，排到最后，不再算名次；
-- 首页推荐和订阅邮件里不再出现。取消过期就恢复正常。
-- 运行顺序：schema_expired.sql → 再运行 schema_tags.sql 里的 public_tag_deals 和 schema_manual.sql 里的 admin_get_all
alter table deals add column if not exists expired_at timestamptz;
grant select (expired_at) on deals to anon;

create or replace function admin_set_deal_expired(p_token text, p_id bigint, p_expired boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update deals set expired_at = case when p_expired then coalesce(expired_at, now()) end where id = p_id;
  if not found then raise exception '找不到这条优惠'; end if;
end $$;
grant execute on function admin_set_deal_expired(text, bigint, boolean) to anon;

-- 自动过期：抓取超过 15 天的优惠（全库，不分状态）自动标记过期；pg_cron 每小时跑一次
create or replace function _auto_expire_deals()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update deals set expired_at = now() where expired_at is null and created_at < now() - interval '15 days';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function _auto_expire_deals() from public, anon, authenticated;
select cron.unschedule('subdeals-auto-expire') where exists (select 1 from cron.job where jobname = 'subdeals-auto-expire');
select cron.schedule('subdeals-auto-expire', '7 * * * *', 'select _auto_expire_deals()');
