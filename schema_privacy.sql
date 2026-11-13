-- ============================================
-- 1) 公开接口不再返回参考价：网站（anon）只能读展示需要的列
-- 2) 手动添加的优惠可以编辑
-- 用法：在 schema_manual.sql 之后运行；可以重复运行
-- ============================================

-- 公开可读的列（不含 threshold、price_checked、adjustments_applied、matched_rule_id 等参考价信息）
revoke select on deals from anon;
grant select (id, title, url, source, store, price, category, condition, quantity, created_at, status, pinned, pinned_at)
  on deals to anon;

-- 编辑手动添加的优惠
create or replace function admin_update_manual_deal(p_token text, p_id bigint, p_deal jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_url text := trim(p_deal->>'url');
begin
  perform _admin_check(p_token);
  if coalesce(trim(p_deal->>'title'), '') = '' then raise exception '请填写标题'; end if;
  if v_url !~ '^https?://' then raise exception '链接要以 http:// 或 https:// 开头'; end if;
  if coalesce(nullif(p_deal->>'price','')::numeric, 0) <= 0 then raise exception '请填写价格'; end if;
  if exists (select 1 from deals where url = v_url and id <> p_id) then raise exception '这个链接已经存在'; end if;
  if coalesce(p_deal->>'image_url', '') <> '' and p_deal->>'image_url' !~ '^https://' then raise exception '图片链接要以 https:// 开头'; end if;
  update deals set title = trim(p_deal->>'title'), url = v_url, store = nullif(trim(p_deal->>'store'), ''),
    price = (p_deal->>'price')::numeric, price_checked = (p_deal->>'price')::numeric,
    category = p_deal->>'category', condition = coalesce(nullif(p_deal->>'condition',''), 'new'),
    quantity = coalesce(nullif(p_deal->>'quantity','')::int, 1), image_url = nullif(trim(p_deal->>'image_url'), '')
  where id = p_id and source = 'manual';
  if not found then raise exception '只能编辑手动添加的优惠'; end if;
end $$;

grant execute on function admin_update_manual_deal(text, bigint, jsonb) to anon;
