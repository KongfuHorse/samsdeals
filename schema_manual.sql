-- ============================================
-- 手动添加优惠 + 置顶
-- 用法：在 schema_woot.sql 之后运行；可以重复运行
-- 手动添加的优惠：source = 'manual'，直接展示（status = 'passed'），没有参考价
-- ============================================

alter table deals add column if not exists pinned boolean not null default false;
alter table deals add column if not exists pinned_at timestamptz;

-- 手动添加
create or replace function admin_add_manual_deal(p_token text, p_deal jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_url text := trim(p_deal->>'url'); v_pin boolean := coalesce((p_deal->>'pinned')::boolean, false);
begin
  perform _admin_check(p_token);
  if coalesce(trim(p_deal->>'title'), '') = '' then raise exception '请填写标题'; end if;
  if v_url !~ '^https?://' then raise exception '链接要以 http:// 或 https:// 开头'; end if;
  if coalesce(nullif(p_deal->>'price','')::numeric, 0) <= 0 then raise exception '请填写价格'; end if;
  if exists (select 1 from deals where url = v_url) then raise exception '这个链接已经存在，不能重复添加'; end if;
  if coalesce(p_deal->>'image_url', '') <> '' and p_deal->>'image_url' !~ '^https://' then raise exception '图片链接要以 https:// 开头'; end if;
  insert into deals (title, url, source, store, price, price_checked, category, condition, quantity, status, pinned, pinned_at, image_url)
  values (trim(p_deal->>'title'), v_url, 'manual', nullif(trim(p_deal->>'store'), ''),
          (p_deal->>'price')::numeric, (p_deal->>'price')::numeric,
          p_deal->>'category', coalesce(nullif(p_deal->>'condition',''), 'new'),
          coalesce(nullif(p_deal->>'quantity','')::int, 1), 'passed',
          v_pin, case when v_pin then now() end, nullif(trim(p_deal->>'image_url'), ''))
  returning id into v_id;
  return v_id;
end $$;

-- 置顶 / 取消置顶（只用于手动添加的优惠）
create or replace function admin_set_pinned(p_token text, p_id bigint, p_pinned boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update deals set pinned = p_pinned, pinned_at = case when p_pinned then now() end
  where id = p_id and source = 'manual';
  if not found then raise exception '只能置顶手动添加的优惠'; end if;
end $$;

-- 后台读取：deal 列表加上 pinned
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
                   'woot_midnight', woot_midnight,
                   'merge_same_deals', merge_same_deals) from settings where id = 1),
    'runs', (select coalesce(jsonb_agg(x), '[]') from (select * from runs order by finished_at desc limit 10) x),
    'deal_stats', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from deals group by status) y),
    'deals', (select coalesce(jsonb_agg(d order by d.pinned desc, d.pinned_at desc nulls last, d.created_at desc), '[]') from (
                select id, title, url, source, store, price, price_checked, threshold, category, gpu, capacity_tb,
                       quantity, condition, status, adjustments_applied, created_at, emailed_at, pinned, pinned_at, image_url,
                       expired_at
                from deals
                where status in ('review', 'passed', 'hidden')
                   or (status = 'removed' and created_at > now() - interval '30 days')
                order by created_at desc limit 300) d)
  );
end $$;

grant execute on function admin_add_manual_deal(text, jsonb), admin_set_pinned(text, bigint, boolean), admin_get_all(text) to anon;
