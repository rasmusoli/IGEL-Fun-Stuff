# UMS SSO AutoLaunch

Unofficial lightweight launcher for the IGEL UMS Web App. Opening `/webapp/sso/` automatically starts UMS's existing SSO flow without changing the normal login page.

## Install

1. Copy [`webapp#sso.war`](webapp%23sso.war) into `C:\Program Files\IGEL\RemoteManager\rmguiserver\webapps\` **alongside** `webapp.war`, not inside the `webapp` folder. Keep the filename exactly `webapp#sso.war`.
2. With Tomcat `autoDeploy=true`, it should deploy automatically to `https://<UMS-FQDN>:8443/webapp/sso/`. A restart is normally unnecessary.
3. Test both an unauthenticated browser session and an already-authenticated session. The original `/auth-service/login` page remains available.

**Verified in lab:** WAR deployment completed and `/webapp/sso/index.html` responded HTTP 200 on UMS 12.14.x (October 28, 2026). A configured identity provider **was not available**, so completing an actual SSO login has **not** been validated. Test against your UMS version and configured IdP before relying on it.

## How it works

- `index.html` loads `sso.js`. The script requests `/auth-service/login` with the browser's existing session.
- If already signed in, it navigates to `/webapp`. Otherwise it extracts the native SSO authorization URL from UMS's rendered `handleButtonLoginSso` handler, then navigates to that URL.
- If SSO is unavailable or the login page differs, it displays a fallback link to the normal login. **No passwords or tokens are collected or stored by this launcher.**

The script uses UMS-provided registration information; there is no lab-specific hostname or IdP ID hardcoded in the WAR.

## Verify and troubleshoot

```powershell
$apps = 'C:\Program Files\IGEL\RemoteManager\rmguiserver\webapps'
Get-Item -LiteralPath "$apps\webapp#sso.war"
Get-FileHash -LiteralPath "$apps\webapp#sso.war" -Algorithm SHA256
curl.exe -k -s -o NUL -w "HTTP %{http_code}`n" "https://localhost:8443/webapp/sso/index.html"
```

Expected SHA-256 of the supplied WAR: `2008349a8dc4283f96ef5269b674e532b0f637ffdde59a7706ec6cef0d38b5bb`.

A 200 status proves the page is served, **not** that SSO has completed. To inspect deployment messages, search the UMS `rmguiserver\logs\stdout.log` or `device-connector.log` for `webapp#sso.war`. The first attempt at a plain `sso.war` returned 404; the nested-context WAR succeeded.

## Remove

Delete `webapp#sso.war` from `webapps`. With auto-deploy enabled Tomcat should undeploy it. Do not change `webapp.war` or `auth-service.war`.

## Contents and limitations

- `webapp#sso.war`: deployment-ready package, the exact uploaded and validated lab file
- `src/index.html`, `src/sso.js`, `src/WEB-INF/web.xml`: extracted source included for inspection

This is an **unsupported UMS customization**, based on login-page behavior observed in UMS 12.14.103. The HTML-parsing method depends on the login page's rendered JavaScript and could break after UMS upgrades. The URL does not enforce SSO or disable explicit credential login; it only offers a separate entry point. Users with existing UMS sessions may be redirected straight into the Web App.
