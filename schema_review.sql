-- ============================================
-- 优惠审核和管理：异常低价先进"待审核"，后台可以通过、拒绝、隐藏、删除
-- 用法：在 schema.sql、schema_admin.sql、schema_cron.sql 之后运行；可以重复运行
-- 状态说明：
--   passed   达标，网站展示
--   review   待审核（异常低价或商家不明），网站不展示
--   hidden   已隐藏，可以恢复
--   removed  已删除，不再展示；记录保留，下次抓取不会重新加回来
-- ============================================

alter table deals drop constraint if exists deals_status_check;
alter table deals add constraint deals_status_check
  check (status in ('passed', 'not_passed', 'no_rule', 'need_info', 'other', 'review', 'hidden', 'removed'));

alter table settings add column if not exists review_discount_pct int not null default 50
  check (review_discount_pct between 5 and 95);          -- 低于价格线超过这个百分比，转人工审核
alter table settings add column if not exists review_unknown_store boolean not null default true;  -- 商家不明时转人工审核

-- 后台读取全部数据：在原来的基础上加上 deal 列表和审核设置
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
                   'review_unknown_store', review_unknown_store) from settings where id = 1),
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

-- 改 deal 状态：通过 / 拒绝 / 隐藏 / 删除 / 恢复
create or replace function admin_set_deal_status(p_token text, p_id bigint, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  if p_status not in ('passed', 'hidden', 'removed') then raise exception '不支持的操作'; end if;
  update deals set status = p_status where id = p_id;
  if not found then raise exception '找不到这条优惠'; end if;
end $$;

create or replace function admin_save_review_settings(p_token text, p_discount_pct int, p_unknown_store boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update settings set review_discount_pct = p_discount_pct, review_unknown_store = p_unknown_store where id = 1;
end $$;

grant execute on function admin_get_all(text), admin_set_deal_status(text, bigint, text),
  admin_save_review_settings(text, int, boolean) to anon;

-- 用新规则检查一遍现在正在展示的 deal
update deals set status = 'review'
where status = 'passed'
  and (price_checked < threshold * (1 - (select review_discount_pct from settings where id = 1) / 100.0)
       or ((store is null or store = '') and source not in ('slickdeals', 'woot')
           and (select review_unknown_store from settings where id = 1)));
