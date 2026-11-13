-- ============================================
-- 商品图片：抓取时存下图片地址，网站列表显示缩略图
-- 用法：在 schema_tags.sql 之后运行；可以重复运行
-- 下面这些函数已经在原来的文件里加上了 image_url，改过后要重新运行：
--   schema_tags.sql 的 public_tag_deals；schema_manual.sql 的 admin_add_manual_deal、admin_get_all；
--   schema_privacy.sql 的 admin_update_manual_deal
-- ============================================

alter table deals add column if not exists image_url text;

-- 网站（anon）可以读图片地址
grant select (image_url) on deals to anon;
