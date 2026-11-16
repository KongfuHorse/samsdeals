-- 后台"全部入库"：所有抓到的优惠（不管什么状态），按抓取时间从新到旧，分页读取
create or replace function admin_deals_all(p_token text, p_offset int default 0, p_limit int default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  perform _admin_check(p_token);
  return jsonb_build_object(
    'total', (select count(*) from deals),
    'deals', (select coalesce(jsonb_agg(d), '[]') from (
      select id, title, url, source, store, price, category, gpu, apple_model, condition, status, created_at, expired_at
      from deals order by created_at desc, id desc
      offset greatest(coalesce(p_offset, 0), 0) limit v_limit) d));
end $$;
grant execute on function admin_deals_all(text, int, int) to anon;
