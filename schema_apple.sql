-- ============================================
-- 苹果产品标签：按产品线 + 尺寸 + 芯片分（同代芯片的普通版/Pro/Max 放一个 Series 标签，OLED 单独一个）
-- 用法：在 schema_subscribe.sql 之后运行；可以重复运行
--   1. 先运行这个文件
--   2. 再运行 schema_apple_seed.sql（由 apple_models.py 生成：标签和型号选项）
--   3. schema_tags.sql 里这些函数改过，要重新运行：_cat_label、_tag_resolve_structured、public_home、public_tag_deals、admin_tag_save
-- ============================================

-- AI 解析出来的苹果型号（apple_models.py 里的 key）
alter table deals add column if not exists apple_model text;
create index if not exists deals_apple_model on deals (apple_model) where apple_model is not null;

-- 新品类"苹果"
insert into field_options (field, value, label, sort_order) values ('category', 'apple', '苹果', 6)
on conflict (field, value) do update set label = excluded.label, active = true;

-- 结构化标签不能重复：条件里加上苹果型号
drop index if exists tags_structured_uniq;
create unique index tags_structured_uniq on tags
  ((conditions->>'category'), coalesce(conditions->>'gpu', ''), coalesce(conditions->>'capacity_tb', ''), coalesce(conditions->>'apple_model', ''))
  where kind = 'structured' and merged_into is null;

-- 旧的"MacBook Pro"关键词标签（会混进充电器和旧款）换成按芯片分的新标签：删掉它和它自动加的 Slickdeals 搜索
delete from sources where key in (select 'auto_tag_' || id from tags where slug = 'macbook-pro' and kind = 'keyword');
delete from tags where slug = 'macbook-pro' and kind = 'keyword';
