-- ============================================
-- Deal 筛选网站：Supabase 表结构 + 规则（第 5 版）
-- 用法：Supabase 后台 → SQL Editor → 粘贴全部 → Run
-- 注意：开头几行会删除旧表重建。只在还没有正式数据时运行。
-- ============================================

drop table if exists deals;
drop table if exists seen_articles;
drop table if exists price_adjustments;
drop table if exists price_rules;
drop table if exists field_options;

-- --------------------------------------------
-- 0. 选项表：每一列允许填哪些值
--    用途 1：以后的规则编辑界面用它做下拉菜单
--    用途 2：AI 解析标题时只能从这里选值，保证和规则写法一致
--    要加新显卡、新系列，在这里加一行即可
-- --------------------------------------------
create table field_options (
  id bigint generated always as identity primary key,
  field text not null,             -- category / gpu / condition / series
  value text not null,             -- 程序用的值
  label text,                      -- 界面上显示的中文名
  sort_order int not null default 0,
  active boolean not null default true,
  unique (field, value)
);

-- --------------------------------------------
-- 1. 基础规则：单价低于 max_price 就筛选出来（全新标准）
--    gpu / ram_gb / capacity_tb 留空 = 不限
--    同一条 deal 符合多条规则时，用条件最细的那条
-- --------------------------------------------
create table price_rules (
  id bigint generated always as identity primary key,
  category text not null,
  gpu text,
  ram_gb int,
  capacity_tb numeric,
  price_mode text not null default 'total' check (price_mode in ('total', 'per_tb')),
                                   -- total = 看单件价格；per_tb = 看每 TB 价格
  max_price numeric not null check (max_price > 0),
  resale_price numeric,            -- 转售参考价，以后用，可不填
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- --------------------------------------------
-- 2. 调整规则：在基础规则上按百分比或金额调整
--    deal 的 [field] 等于 [value] 里任何一个时生效
--    多条同时生效：百分比相乘，金额相加
-- --------------------------------------------
create table price_adjustments (
  id bigint generated always as identity primary key,
  category text,                   -- 留空 = 所有品类
  field text not null check (field in ('condition', 'brand', 'series', 'store')),
  value text not null,             -- 多个值用英文逗号隔开
  pct numeric not null default 0,  -- 15 = 上浮 15%，-10 = 降低 10%
  amount numeric not null default 0, -- 300 = 加 300 美元
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 修改规则时自动更新 updated_at
create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql;

create trigger price_rules_updated before update on price_rules
  for each row execute function set_updated_at();
create trigger price_adjustments_updated before update on price_adjustments
  for each row execute function set_updated_at();

-- --------------------------------------------
-- 3. deal 表
-- --------------------------------------------
create table deals (
  id bigint generated always as identity primary key,
  title text,
  url text unique,                 -- 用链接去重
  source text,                     -- 来源：slickdeals / reddit / tomshardware / techradar
  article_url text,                -- 文章型来源：deal 所在的文章链接
  store text,
  price numeric,                   -- 到手总价
  -- AI 解析的字段
  category text,
  gpu text,
  ram_gb int,
  capacity_tb numeric,             -- 单件容量
  quantity int not null default 1, -- 几件装
  brand text,
  series text,
  condition text,
  -- 筛选结果
  status text check (status in ('passed', 'not_passed', 'no_rule', 'need_info', 'other')),
  price_checked numeric,           -- 实际比较的价格（硬盘是每 TB 价格）
  threshold numeric,               -- 调整后的标准价
  adjustments_applied text,
  matched_rule_id bigint,
  emailed_at timestamptz,          -- 已放进邮件草稿的时间，防止重复
  email_campaign_id text,
  created_at timestamptz not null default now()
);

create index deals_status_idx on deals (status, created_at desc);

-- 已经读过的文章（文章型来源每篇只读一次，省 AI 费用）
create table seen_articles (
  url text primary key,
  source text,
  deals_found int not null default 0,
  checked_at timestamptz not null default now()
);
alter table seen_articles enable row level security;

-- --------------------------------------------
-- 4. 访问权限
--    网站（公开）只能看到达标的 deal 和选项表
--    后台程序用 service_role key，不受限制
-- --------------------------------------------
alter table deals enable row level security;
alter table price_rules enable row level security;
alter table price_adjustments enable row level security;
alter table field_options enable row level security;

create policy "public can read passed deals" on deals
  for select to anon using (status = 'passed');
create policy "public can read options" on field_options
  for select to anon using (active);

-- ============================================
-- 选项
-- ============================================
insert into field_options (field, value, label, sort_order) values
  ('category', 'hdd', '机械硬盘', 1),
  ('category', 'ssd', '固态硬盘', 2),
  ('category', 'laptop', '游戏笔记本', 3),
  ('category', 'desktop', '台式机', 4),
  ('category', 'graphics_card', '显卡', 5),
  ('gpu', 'RTX 5050', 'RTX 5050', 0),
  ('gpu', 'RTX 5060', 'RTX 5060', 1),
  ('gpu', 'RTX 5060 Ti', 'RTX 5060 Ti', 2),
  ('gpu', 'RTX 5070', 'RTX 5070', 3),
  ('gpu', 'RTX 5070 Ti', 'RTX 5070 Ti', 4),
  ('gpu', 'RTX 5080', 'RTX 5080', 5),
  ('gpu', 'RTX 5090', 'RTX 5090', 6),
  ('condition', 'new', '全新', 1),
  ('condition', 'open_box', '开箱', 2),
  ('condition', 'refurb', '翻新 / 厂翻', 3),
  ('condition', 'used', '二手', 4),
  ('series', 'ROG', 'ASUS ROG', 1),
  ('series', 'Alienware', 'Dell Alienware', 2);

-- ============================================
-- 你的规则
-- ============================================
insert into price_rules (category, gpu, capacity_tb, price_mode, max_price, note) values
  ('hdd',           null,          null, 'per_tb', 24.9, '机械硬盘：每 TB 低于 24.9'),
  ('ssd',           null,          4,    'total',  359,  '4TB 固态'),
  ('ssd',           null,          2,    'total',  269,  '2TB 固态'),
  ('laptop',        'RTX 5060',    null, 'total',  999,  '5060 游戏本'),
  ('laptop',        'RTX 5080',    null, 'total',  2300, '5080 游戏本'),
  ('laptop',        'RTX 5090',    null, 'total',  3500, '5090 游戏本'),
  ('desktop',       'RTX 5080',    null, 'total',  2399, '5080 台式机'),
  ('desktop',       'RTX 5090',    null, 'total',  7500, '5090 台式机'),
  ('graphics_card', 'RTX 5070 Ti', null, 'total',  1200, '5070 Ti 显卡'),
  ('graphics_card', 'RTX 5080',    null, 'total',  1599, '5080 显卡'),
  ('graphics_card', 'RTX 5090',    null, 'total',  5500, '5090 显卡');

insert into price_adjustments (category, field, value, pct, note) values
  ('laptop',        'condition', 'open_box,refurb,used', -10, '笔记本非全新 降 10%'),
  ('laptop',        'series',    'Alienware,ROG',         15, 'Alienware / ROG 上浮 15%'),
  ('graphics_card', 'condition', 'open_box,refurb,used', -10, '显卡非全新 降 10%');
