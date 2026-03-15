Sora License Server

This server adds online activation/validation on top of the signed license keys
used by the Sora All In One extension.

It can run in 2 modes:
- Local mode on one computer: `http://127.0.0.1:8787`
- Public website mode for many computers: `https://your-domain.com`

Files:
- server.mjs : HTTP license server
- admin.mjs : local admin tool for revoke/reset/list/status
- manager-panel.html : local manager page for key generation and server admin
- buy-panel.html : public buy page for one computer
- package.json : deploy/start file for Node hosting
- .env.example : example environment variables for public deployment
- render.yaml : ready-to-deploy Render blueprint
- data/licenses.json : JSON database created automatically

Default address:
- http://127.0.0.1:8787

Public deployment:
- set `HOST=0.0.0.0`
- set `PUBLIC_BASE_URL=https://your-domain.com`
- set `ADMIN_TOKEN`
- set `DATA_DIR` to persistent storage
- recommended: set `LICENSE_PRIVATE_KEY_PEM` or `LICENSE_PRIVATE_KEY_PEM_BASE64`
- set `TRIAL_POLICY` if you want to control free access globally
- set `BAKONG_ACCOUNT_ID` and at least one price (`LICENSE_PRICE_USD` or `LICENSE_PRICE_KHR`) if you want the public Buy page to work

Easy mode:
- a ready file already exists at:
  - /Users/nin/Downloads/sora_license_server/.env
- the server now loads `.env` automatically
- if you do not understand env files, just edit this one line later when you have a real domain:
  - `PUBLIC_BASE_URL=https://your-domain.com`

Start for public deployment:
1. Copy `.env.example`
2. Set your real values
3. Start with:
   node /Users/nin/Downloads/sora_license_server/server.mjs

Public deployment notes:
- Do not leave this repository public if it still contains the built-in private key.
- Best practice is to set `LICENSE_PRIVATE_KEY_PEM` or `LICENSE_PRIVATE_KEY_PEM_BASE64` in the host environment.
- Your hosting must keep `DATA_DIR` on persistent disk, or license history will reset after redeploy.
- After deploy, open:
  - `https://your-domain.com/manager`
  - `https://your-domain.com/admin`
  - `https://your-domain.com/buy`
- The extension popup uses your public server URL for activation/restore and can open the public buy page.

Render easiest setup:
1. Push this folder to GitHub.
2. On Render, create a new Blueprint / Web Service from that repo.
3. Render can use:
   - /Users/nin/Downloads/sora_license_server/render.yaml
4. In Render dashboard, set these values:
   - `PUBLIC_BASE_URL=https://YOUR-RENDER-DOMAIN.onrender.com`
   - `ADMIN_TOKEN=mysecret123` or your own secret
   - `LICENSE_PRIVATE_KEY_PEM_BASE64=...`
   - `TRIAL_POLICY=1h` or `30d` or `forever` or `off`
   - `BAKONG_ACCOUNT_ID=yourbakongid@bank`
   - `BAKONG_MERCHANT_NAME=Your Name or Shop`
   - `BAKONG_API_TOKEN=YOUR_BAKONG_OPEN_API_TOKEN`
   - `LICENSE_PRICE_USD=35`
   - `BUY_PRICE_3M_USD=105`
   - `BUY_PRICE_LIFETIME_USD=250`
5. Deploy.
6. Open:
   - `https://YOUR-RENDER-DOMAIN.onrender.com/manager`
   - `https://YOUR-RENDER-DOMAIN.onrender.com/buy`

Blogger:
- Blogger cannot run the Node.js server itself.
- But you can place a link or iframe to your public manager page after you deploy:
  - `https://YOUR-RENDER-DOMAIN.onrender.com/manager`
- Ready snippet:
  - /Users/nin/Downloads/sora_license_server/blogger-embed.html
  - /Users/nin/Downloads/sora_license_server/blogger-theme-snippet.html

Start the server:
1. Open Terminal
2. Run:
   node /Users/nin/Downloads/sora_license_server/server.mjs

Or double-click:
- /Users/nin/Downloads/sora_license_server/start-license-server.command
  It will ask for an Admin Token before starting.
  Press Enter with an empty value if you want to run without admin routes.

Local GUI manager:
- /Users/nin/Downloads/sora_license_server/start-license-manager.command
  This starts the local server in background and opens:
  - http://127.0.0.1:8787/manager
  Use this page for Generate Key, Activate, Validate, Status, Revoke, Unrevoke, Reset, and List All.
  If you enter an Admin Token in the launcher, it will be auto-filled in the manager page without showing in the URL.
  Default Admin Token:
  - mysecret123

Optional admin token:
If you want to use the HTTP admin routes, start with:
  ADMIN_TOKEN=YOUR_SECRET node /Users/nin/Downloads/sora_license_server/server.mjs

Health check:
  http://127.0.0.1:8787/health

Admin web panel:
  http://127.0.0.1:8787/admin

Manager page:
  http://127.0.0.1:8787/manager
  You can also change `Trial Policy` directly from this page without opening Render.

On a public host, these become:
- https://your-domain.com/health
- https://your-domain.com/manager
- https://your-domain.com/admin

API routes:
- GET /api/buy/config
  returns public buy-page config such as Bakong ID and price

- POST /api/buy/request
  body: { "deviceId": "..." }
  creates or reuses a pending buy order for one computer

- GET /api/buy/order-status?orderId=...
  returns public order status for the buy page

Trial policy:
- `TRIAL_POLICY=1h`
  one-hour first-use free access
- `TRIAL_POLICY=30d`
  thirty-day first-use free access
- `TRIAL_POLICY=forever`
  free access without expiry until you change the policy
- `TRIAL_POLICY=off`
  disables free access and requires license/buy approval immediately

- POST /api/activate
  body: { "licenseKey": "...", "deviceId": "..." }

- POST /api/validate
  body: { "licenseKey": "...", "deviceId": "..." }

- POST /api/admin/generate
  header: X-Admin-Token: YOUR_SECRET
  body: { "deviceId": "...", "days": 30 }

- POST /api/admin/revoke
- POST /api/admin/unrevoke
- POST /api/admin/reset
  header: X-Admin-Token: YOUR_SECRET
  body: { "licenseKey": "..." }

- GET /api/admin/status?licenseKey=...
  header: X-Admin-Token: YOUR_SECRET

- GET /api/admin/list
  header: X-Admin-Token: YOUR_SECRET

- GET /api/admin/orders
  header: X-Admin-Token: YOUR_SECRET

- GET /api/admin/settings
  header: X-Admin-Token: YOUR_SECRET

- POST /api/admin/settings
  header: X-Admin-Token: YOUR_SECRET
  body: { "trialPolicy": "1h" }

- POST /api/admin/approve-order
  header: X-Admin-Token: YOUR_SECRET
  body: { "orderId": "ORD-...", "days": 30 }

Admin CLI examples:
- List all server records:
  node /Users/nin/Downloads/sora_license_server/admin.mjs list

- Show one license status:
  node /Users/nin/Downloads/sora_license_server/admin.mjs status --key YOUR_LICENSE_KEY

- Revoke one license:
  node /Users/nin/Downloads/sora_license_server/admin.mjs revoke --key YOUR_LICENSE_KEY

- Unrevoke one license:
  node /Users/nin/Downloads/sora_license_server/admin.mjs unrevoke --key YOUR_LICENSE_KEY

- Reset one license activation:
  node /Users/nin/Downloads/sora_license_server/admin.mjs reset --key YOUR_LICENSE_KEY

How it works:
- The signed license key is still verified cryptographically.
- The server then binds that key to one device ID.
- The same computer can still use the same key in multiple Chrome profiles.
- If the key is revoked or reset on the server, future validations fail.
- The public Buy page creates a pending order for one Device ID.
- After you approve that order in the manager page, the extension can auto-restore the license for that computer.
