# افزودن MCP پورتال به همهٔ پروفایل‌ها (مک)

همان کاری که سمت ویندوز انجام شد. سرور `partnerz-portal` را به یک پروفایل اضافه می‌کنیم، `claude-sync` آن را به بقیه پخش می‌کند، و یک بار لاگین OAuth می‌گیریم که بین همهٔ پروفایل‌ها مشترک است.

نیازی به توکن دستی نیست. `env` تنها فیلدی است که claude-sync بین پروفایل‌ها کپی نمی‌کند، پس توکن ۸ساعته در کانفیگ یعنی تمدید دستی برای تک‌تک پروفایل‌ها. مسیر OAuth این را حذف می‌کند.

## ۱. اول claude-sync را آپدیت کن

نسخهٔ نصب‌شده ممکن است عقب مانده باشد. نسخه‌های قبل از ۴.۳ می‌توانند موقع سینک، سرورها را از همهٔ پروفایل‌ها پاک کنند.

```bash
cd ~/Projects/tools/ai/claude-deck && ./sync/claude-sync.sh --install && source ~/.zshrc
claude-sync --version   # باید 4.3.0 یا بالاتر باشد
```

## ۲. سرور را به یک پروفایلِ بسته اضافه کن

```bash
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
cp "$CFG" "$CFG.bak-portal-$(date +%Y%m%d%H%M%S)"
node -e 'const f=process.argv[1],fs=require("fs"),j=JSON.parse(fs.readFileSync(f,"utf8"));(j.mcpServers||(j.mcpServers={}))["partnerz-portal"]={command:"npx",args:["-y","mcp-remote","https://portal.partnerz.io/mcp"]};fs.writeFileSync(f,JSON.stringify(j,null,2))' "$CFG"
```

## ۳. پخش کن بین همهٔ پروفایل‌ها

```bash
claude-sync --dry-run
```

خروجی باید فقط `would add MCP server(s) [partnerz-portal]` باشد. اگر جایی `remove` دیدی، متوقف شو. بعد:

```bash
claude-sync
```

## ۴. بررسی کن

```bash
for f in "$HOME/Library/Application Support/Claude/claude_desktop_config.json" "$HOME/Library/Application Support/Claude Profiles"/*/claude_desktop_config.json; do
  printf '%-22s' "$(basename "$(dirname "$f")")"
  node -e 'const j=require(process.argv[1]);console.log(j.mcpServers["partnerz-portal"]?"OK":"MISSING")' "$f"
done
```

## ۵. یک بار لاگین بگیر

```bash
npx -y mcp-remote https://portal.partnerz.io/mcp
```

مرورگر باز می‌شود، Approve را بزن، بعد با Ctrl+C ببند. توکن در `~/.mcp-auth` می‌نشیند که همهٔ پروفایل‌ها همان را می‌خوانند، پس همین یک تأیید برای همه کافی است و خودش تمدید می‌شود.

به‌صورت پیش‌فرض هر ۲۰ دسترسی پورتال (شامل همهٔ نوشتن‌ها) خواسته می‌شود. برای محدودکردن، قبل از لاگین این را اضافه کن:

```bash
--static-oauth-client-metadata '{"scope":"pages:read pages:write db:read k8s:read dns:read np:read access:read coder:read team_apps:read"}'
```

## ۶. پروفایل‌های باز را ببند و باز کن

کلاد دسکتاپ کانفیگ را فقط موقع اجرا می‌خواند. هر پروفایلی که الان باز است تا بسته و باز نشود سرور جدید را نمی‌بیند.

برگشت به قبل، اگر لازم شد: `claude-sync --revert`.
