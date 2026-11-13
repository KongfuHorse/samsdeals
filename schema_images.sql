-- ============================================
-- 商品图片：抓取时存下图片地址，网站列表显示缩略图
-- 用法：在 schema_tags.sql 之后运行；可以重复运行
-- （public_tag_deals 在 schema_tags.sql 里，已经带上 image_url，改过后要重新运行那个函数）
-- ============================================

alter table deals add column if not exists image_url text;

-- 网站（anon）可以读图片地址
grant select (image_url) on deals to anon;
