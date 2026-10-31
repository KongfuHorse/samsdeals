# Deal 筛选网站 Demo

每 30 分钟自动抓取 Slickdeals、r/buildapcsales，以及 Tom's Hardware 和 TechRadar 的 deal 文章，用 AI 读出商品信息，按你的价格规则筛选。
达标的 deal 显示在网站上；每天早上自动生成一封 MailerLite 邮件草稿，你检查后手动发送。

## 文件说明

| 文件 | 作用 | 要不要改 |
|---|---|---|
| schema.sql | 建表 + 你的规则 | 只运行一次 |
| index.html | 网站页面 | 改顶部 3 个设置 |
| run.py | 主程序：抓取 → AI 解析 → 筛选 → 存库 | 不用改 |
| sources.py | deal 来源（RSS 地址）。帖子型和文章型分开列 | 加来源时改 |
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
3. 左边 Project Settings → API，记下 3 个值：
   - Project URL
   - anon public key（放网页里，公开没关系）
   - service_role key（**保密**，只放 GitHub Secrets）

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
| SUPABASE_SERVICE_KEY | Supabase service_role key |
| MAILERLITE_API_KEY | MailerLite API key |
| MAILERLITE_FROM_EMAIL | 发件邮箱 |
| MAILERLITE_FROM_NAME | 发件人名字（可不填） |
| MAILERLITE_GROUP_ID | 分组 ID（可不填 = 发给所有订阅者） |

4. Actions 页面 → 如果提示启用，点启用 → 选"抓取并筛选 deal" → Run workflow，测试一次
5. 运行完点进去看日志，会显示抓到几条、达标几条

### 4. 网站
1. 在 GitHub 里编辑 index.html，改顶部 3 个设置：SUPABASE_URL、SUPABASE_ANON_KEY、SUBSCRIBE_URL
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
