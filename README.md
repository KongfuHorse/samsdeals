# Subdeals

每 30 分钟自动抓取 Slickdeals、r/buildapcsales、Woot（官方 API），以及 Tom's Hardware 和 TechRadar 的 deal 文章，用 AI 读出商品信息，按你的价格规则筛选。
达标的 deal 显示在网站上；每天早上自动生成一封 MailerLite 邮件草稿，你检查后手动发送。

## 网站怎么用

- 首页是一个搜索框。输入想关注的品类，比如"5090 笔记本"、"20TB 硬盘"，会进入这个**标签**的页面，显示近 30 天收集到的价格，从低到高排列（硬盘和固态按每 TB 价格排）。
- 搜索分三步：先在已有标签里联想；再按规则拆出品类、显卡、容量（这两步都在浏览器里完成，不用 AI）；都匹配不上时，用户点"新建标签"才会用 AI。
- AI 新建的标签如果不在我们的品类里（比如 MacBook），会自动加一个 Slickdeals 搜索来源，开始收集。
- 标签页的网址可以分享，比如 `?t=rtx-5090-laptop`。
- 订阅表单目前只有界面，不保存邮箱（第二阶段再做）。

AI 新建标签需要两个保密变量，在 Supabase 后台 → Edge Functions → Secrets 里设置：`ANTHROPIC_API_KEY`（Claude key）和 `SB_SECRET_KEY`（Supabase 的 Secret key）。

## 后台

网址：**https://subdeals.net/admin.html**

- 优惠管理：手动添加优惠并可置顶；审核异常低价或商家不明的优惠；隐藏、删除正在展示的优惠，随时恢复
- 标签：批准、编辑、合并、删除、新建标签；同义词；搜索统计；自动来源；标签设置
- 价格规则、调整规则：增加、修改、删除、临时停用
- 下拉选项：新增显卡型号、系列等（AI 解析也会认识新加的值）
- 优惠来源：逐个开关
- 刷新设置：自动刷新间隔、立即刷新、最近运行记录、修改后台密码
- "立即刷新"想马上生效，需要在后台填一个 GitHub 令牌（页面上有步骤）；不填也能用，最多等 10 分钟

数据库设置：依次运行 schema.sql、schema_admin.sql（运行前把文件最后的 CHANGE_ME_PASSWORD 换成后台密码）、schema_cron.sql、schema_review.sql、schema_woot.sql、schema_manual.sql、schema_privacy.sql、schema_tags.sql。

定时：GitHub 自己的定时很不准（常常几小时才跑一次），所以由 Supabase 每 10 分钟检查一次，到了后台设的间隔就通知 GitHub 运行。抓取在你自己的电脑（自托管运行器）上执行，用家里的网络。

## 文件说明

| 文件 | 作用 | 要不要改 |
|---|---|---|
| schema.sql | 建表 + 你的规则 | 只运行一次 |
| index.html | 网站页面 | 改顶部 3 个设置 |
| admin.html | 后台页面 | 改顶部 2 个设置 |
| schema_admin.sql | 后台用的表和函数 | 只运行一次 |
| schema_cron.sql | Supabase 定时任务 | 只运行一次 |
| schema_review.sql | 待审核、隐藏、删除优惠 | 只运行一次 |
| schema_woot.sql | Woot 每天零点专抓 | 只运行一次 |
| schema_manual.sql | 手动添加优惠、置顶 | 只运行一次 |
| schema_privacy.sql | 公开接口不返回参考价；手动优惠可编辑 | 只运行一次 |
| schema_tags.sql | 标签、搜索、价格排行、自动来源 | 只运行一次 |
| supabase/functions/create-tag/ | AI 新建标签的服务器函数（Supabase Edge Function） | 改了以后要重新部署 |
| run.py | 主程序：抓取 → AI 解析 → 筛选 → 存库 | 不用改 |
| sources.py | 抓取各类来源（来源列表在数据库 sources 表里） | 不用改 |
| parser.py | AI 读标题 | 不用改 |
| deal_filter.py | 按规则判断是否达标 | 不用改 |
| db.py | 读写 Supabase | 不用改 |
| email_draft.py | 生成 MailerLite 草稿 | 不用改 |
| .github/workflows/ | 定时自动运行 | 不用改 |
| sample_titles.txt、sample_article.txt、schema_rules.py | 测试用 | 不用改 |

改价格规则：去 Supabase → Table Editor → price_rules / price_adjustments 直接改，不用碰代码。

## 设置步骤

### 1. Supabase（数据库）
1. supabase.com 注册，New project
2. 左边 SQL Editor → 粘贴 schema.sql 全部内容 → Run
3. 左边 Project Settings → API Keys，记下 3 个值：
   - Project URL（在左上角 Connect 按钮里也能找到，格式 https://xxxx.supabase.co）
   - Publishable key，sb_publishable_ 开头（放网页里，公开没关系）
   - Secret key，sb_secret_ 开头（**保密**，只放 GitHub Secrets 的 SUPABASE_SERVICE_KEY）

### 2. MailerLite
1. Subscribers → Groups → 建一个分组，比如 "Deal Alerts"，记下分组 ID（打开分组，网址里的数字）
2. Forms → 建一个订阅表单，加入这个分组，记下表单链接
3. 发件邮箱：建议用自己域名的邮箱（比如 deals@你的域名.com），在 Settings → Domains 验证。Gmail 地址可以建草稿，但正式发送容易进垃圾箱或被拒

### 3. GitHub（存代码 + 自动运行 + 网站）
1. github.com 注册，New repository，选 **Public**（免费用 Actions 和网站托管）
2. Add file → Upload files，把这个文件夹里所有文件拖进去（包括 .github 文件夹）
   - 网页上传看不到 .github 文件夹的话，可以用 GitHub Desktop 软件上传
3. Settings → Secrets and variables → Actions → New repository secret，逐个添加：

| 名字 | 值 |
|---|---|
| ANTHROPIC_API_KEY | Claude API key |
| SUPABASE_URL | Supabase Project URL |
| SUPABASE_SERVICE_KEY | Supabase Secret key（sb_secret_ 开头） |
| WOOT_API_KEY | Woot 开发者 API key（不填就跳过 Woot） |
| MAILERLITE_API_KEY | MailerLite API key |
| MAILERLITE_FROM_EMAIL | 发件邮箱 |
| MAILERLITE_FROM_NAME | 发件人名字（可不填） |
| MAILERLITE_GROUP_ID | 分组 ID（可不填 = 发给所有订阅者） |

4. Actions 页面 → 如果提示启用，点启用 → 选"抓取并筛选 deal" → Run workflow，测试一次
5. 运行完点进去看日志，会显示抓到几条、达标几条

### 4. 网站
1. 在 GitHub 里编辑 index.html，改顶部 3 个设置：SUPABASE_URL、SUPABASE_ANON_KEY（填 publishable key）、SUBSCRIBE_URL
2. Settings → Pages → Source 选 "Deploy from a branch"，Branch 选 main，保存
3. 几分钟后网站地址会显示在这个页面上

## 日常使用

- **看 deal**：打开网站
- **发邮件**：每天早上 MailerLite 后台 → Campaigns → Drafts 会有一封新草稿，检查后点发送。不想发就删掉
- **马上生成草稿**：GitHub → Actions → "生成邮件草稿" → Run workflow
- **改规则**：Supabase → Table Editor
- **加新显卡型号或系列**：Supabase → field_options 表加一行，AI 解析就会认识它
- **查没规则的 deal**：Supabase → deals 表，筛选 status = no_rule，看看要不要补规则

## 本地测试（可选）
```
pip install -r requirements.txt
python deal_filter.py                 # 测试规则，不需要 key
python email_draft.py --preview       # 生成邮件预览 preview.html，不需要 key
ANTHROPIC_API_KEY=你的key python run.py --dry-run           # 测试 AI 解析帖子标题
ANTHROPIC_API_KEY=你的key python run.py --dry-run-article   # 测试 AI 从文章里找 deal
```

## 费用（demo 阶段）
- GitHub Actions、Pages：公开仓库免费
- Supabase：免费版够用
- Claude API：只有通过关键词粗筛的新内容才会发给 AI，每篇文章只读一次，每月预计几美元到十几美元
- MailerLite：免费版 500 订阅者。通过 API 写入邮件正文需要 Advanced 版（新账号试用期内可用）
