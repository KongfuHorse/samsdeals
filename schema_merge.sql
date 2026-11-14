-- 同品牌、同型号、同价格的 deal 自动合并（网站和邮件只显示一条）
-- 后台"优惠管理"里可以开关，默认开启。合并只影响显示，数据库里的 deal 不删。
-- 运行顺序：schema_merge.sql → 再运行 schema_tags.sql 里的 public_home、public_tag_deals 和 schema_manual.sql 里的 admin_get_all
alter table settings add column if not exists merge_same_deals boolean not null default true;

create or replace function admin_save_merge_setting(p_token text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _admin_check(p_token);
  update settings set merge_same_deals = coalesce(p_on, true) where id = 1;
end $$;
grant execute on function admin_save_merge_setting(text, boolean) to anon;

-- 首页精选直接读 deals 表，判断同型号要用到这几列（都是商品信息）
grant select (brand, gpu, apple_model, capacity_tb) on deals to anon;
