-- 首页"捡漏精选"的邮件订阅：用一个特殊标签（kind = featured，slug = picks）接到现有的订阅流程上
-- 这个标签不公开（不出现在热门、搜索、后台标签列表里），内容就是首页的精选：达标、没过期、最近 14 天或置顶的优惠，新的在前
-- 运行顺序：schema_picks.sql → 再运行 schema_tags.sql 里的 _tags_with_stats、public_tag_deals、admin_tags_get
alter table tags drop constraint if exists tags_kind_check;
alter table tags add constraint tags_kind_check check (kind in ('structured', 'keyword', 'featured'));

insert into tags (slug, name_zh, name_en, kind, conditions, in_scope, created_by, approved)
values ('picks', '捡漏精选', 'Today''s Picks', 'featured', '{"sort":"newest"}', false, 'admin', true)
on conflict (slug) do nothing;
