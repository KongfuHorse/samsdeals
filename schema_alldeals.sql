-- 后台"全部入库"：所有抓到的优惠（可以按状态筛选、按关键词搜索），按抓取时间从新到旧，分页读取
-- 搜索：标题或商家里包含所有关键词（空格分开，不分大小写）
drop function if exists admin_deals_all(text, int, int);
drop function if exists admin_deals_all(text, int, int, text);
create or replace function admin_deals_all(p_token text, p_offset int default 0, p_limit int default 50, p_status text default null, p_query text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_limit int := least(greatest(coalesce(p_limit, 50), 1), 200);
        v_words text[] := array_remove(regexp_split_to_array(lower(trim(coalesce(p_query, ''))), '\s+'), '');
begin
  perform _admin_check(p_token);
  return (with m as (
      select * from deals d
      where coalesce(array_length(v_words, 1), 0) = 0
         or not exists (select 1 from unnest(v_words) w
                        where strpos(lower(d.title || ' ' || coalesce(d.store, '')), w) = 0))
    select jsonb_build_object(
      'total', (select count(*) from m where p_status is null or status = p_status),
      'counts', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from m group by status) c),
      'deals', (select coalesce(jsonb_agg(x), '[]') from (
        select id, title, url, source, store, price, category, gpu, apple_model, condition, status, created_at, expired_at
        from m where p_status is null or status = p_status
        order by created_at desc, id desc
        offset greatest(coalesce(p_offset, 0), 0) limit v_limit) x)));
end $$;
grant execute on function admin_deals_all(text, int, int, text, text) to anon;
notify pgrst, 'reload schema';
