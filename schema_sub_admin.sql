-- ============================================
-- 后台：订阅邮箱列表 + 一键确认
--   admin_sub_list：所有邮箱和各自订阅的标签（含等待确认的）
--   admin_sub_confirm：把某个邮箱所有等待确认的订阅直接确认（效果和用户点确认链接一样）
-- 用法：在 schema_subscribe.sql 之后运行；可以重复运行
-- ============================================

create or replace function admin_sub_list(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', s.id, 'email', s.email, 'lang', s.lang, 'created_at', s.created_at, 'confirmed_at', s.confirmed_at,
      'subs', (select coalesce(jsonb_agg(jsonb_build_object(
                  'tag', t.name_zh, 'slug', t.slug, 'frequency', x.frequency, 'pending_frequency', x.pending_frequency,
                  'status', x.status, 'requested_at', x.requested_at) order by x.requested_at), '[]')
               from subscriptions x join tags t on t.id = x.tag_id where x.subscriber_id = s.id)
    ) order by s.created_at desc, s.id desc), '[]')
    from subscribers s);
end $$;

create or replace function admin_sub_confirm(p_token text, p_subscriber_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _admin_check(p_token);
  update subscriptions set status = 'active', activated_at = coalesce(activated_at, now()),
         frequency = coalesce(pending_frequency, frequency), pending_frequency = null, confirm_token = null
  where subscriber_id = p_subscriber_id and (status = 'pending' or pending_frequency is not null);
  get diagnostics n = row_count;
  if n > 0 then update subscribers set confirmed_at = coalesce(confirmed_at, now()) where id = p_subscriber_id; end if;
  return n;
end $$;

grant execute on function admin_sub_list(text), admin_sub_confirm(text, bigint) to anon;
notify pgrst, 'reload schema';
