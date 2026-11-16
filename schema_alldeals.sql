-- 后台"全部入库"：所有抓到的优惠（可以按状态筛选），按抓取时间从新到旧，分页读取
drop function if exists admin_deals_all(text, int, int);
create or replace function admin_deals_all(p_token text, p_offset int default 0, p_limit int default 50, p_status text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  perform _admin_check(p_token);
  return jsonb_build_object(
    'total', (select count(*) from deals where p_status is null or status = p_status),
    'counts', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from deals group by status) c),
    'deals', (select coalesce(jsonb_agg(d), '[]') from (
      select id, title, url, source, store, price, category, gpu, apple_model, condition, status, created_at, expired_at
      from deals where p_status is null or status = p_status
      order by created_at desc, id desc
      offset greatest(coalesce(p_offset, 0), 0) limit v_limit) d));
end $$;
grant execute on function admin_deals_all(text, int, int, text) to anon;
notify pgrst, 'reload schema';
