# IGEL UMS SSO AutoLaunch v1.1

A standalone launcher for IGEL Universal Management Suite that **automatically starts the built-in "Log in with SSO" flow** when a user opens `https://<UMS-FQDN>:8443/webapp/sso/`. It does not add an IdP or change UMS authentication. The standard `/auth-service/login` page and allowed local/Superuser login remain available.

## Install

**Prerequisite:** Configure SSO in UMS and confirm that the normal **Log in with SSO** button successfully signs in. Tested on UMS 12.14.x / Windows / Tomcat 11 on October 28, 2026; other versions require validation.

1. Copy [`webapp#sso.war`](webapp%23sso.war) into `C:\Program Files\IGEL\RemoteManager\rmguiserver\webapps\` alongside `webapp.war` (**not** inside the `webapps\webapp` directory).
2. Preserve the exact filename `webapp#sso.war`. Tomcat treats `#` as a nested context separator and deploys it at `/webapp/sso/`. With `autoDeploy=true`, a service restart is normally unnecessary.
3. In a private browser window, open `https://<UMS-FQDN>:8443/webapp/sso/`. It should begin UMS's normal SSO flow automatically.

This WAR is an **independent Tomcat context**, not an alteration of `webapp.war`, and does not inherit Web App access controls. Do not host sensitive resources in it.

## What happens in the browser?

The WAR contains static `index.html`, `sso.js`, and a `WEB-INF/web.xml` descriptor. The JavaScript fetches the existing same-origin `/auth-service/login` page with the current browser session. If a session is already authenticated, it navigates directly to `/webapp`. Otherwise it locates UMS's `handleButtonLoginSso` function and extracts the **Thymeleaf-rendered URL passed to `window.location.replace(...)`**.

The script validates that the resulting URL belongs to the same origin and matches `/auth-service/oauth2/authorization/{registrationId}`, then navigates there. UMS handles the configured IdP, authentication, and callback; the launcher never handles user passwords or IdP secrets. If the native redirect is missing or invalid, a fallback link leads to the normal login page.

**Why v1.1?** Version 1.0 searched the function's source for a literal OAuth path. UMS generates the URL dynamically, so 1.0 incorrectly reported unavailable SSO even with a configured IdP. Version 1.1 reads the actual rendered JavaScript argument. The user confirmed a successful live SSO test with v1.1 on October 28, 2026.

## Build your own WAR

Use the source files in [`src/`](src/) and the included [`Build-SSOAutoLaunch.ps1`](Build-SSOAutoLaunch.ps1). **Windows PowerShell 5.1+** and built-in .NET ZIP APIs are sufficient; no Java SDK, Maven, or third-party dependencies.

From this folder run:

```powershell
.\Build-SSOAutoLaunch.ps1
# Output: .\dist\webapp#sso.war
```

Or choose the destination:

```powershell
.\Build-SSOAutoLaunch.ps1 -OutputPath 'C:\temp\webapp#sso.war'
```

The build script packs only `index.html`, `sso.js` and `WEB-INF/web.xml`, verifies exact forward-slash entry names, and prints its SHA-256. The locally generated ZIP's hash can differ from the prebuilt WAR due to ZIP timestamps; its file contents should match.

Prebuilt, live-tested v1.1 WAR SHA-256:

```
3e6757a339ccbe8742f0b824161f21e93ccdd8a3c1fe0d06f4b2f9a360cae9c2
```

Optional five-case JavaScript check (Node.js, **not required** to build/deploy): `node tests/test-sso.js`.

## Troubleshooting / removal

- **404** at `/webapp/sso/`: verify WAR filename, location, and `rmguiserver\logs\stdout.log` or `device-connector.log` for `webapp#sso.war`. HTTP 200 shows the launcher loads, not that SSO succeeds.
- **"Automatic SSO could not be started"**: first test the native UMS SSO button, then check developer-tools Console for `UMS SSO launcher:`. The message comes from our launcher.
- **Existing session goes straight into UMS**: expected; verify real SSO in a fresh private window.
- **Upgrade**: back up the WAR outside `webapps`, then replace it. The login page's generated JavaScript can change with UMS releases.
- **Uninstall**: delete `webapp#sso.war` from `webapps`. With auto-deployment enabled Tomcat should undeploy the context. Do not edit or delete the original IGEL `webapp.war` or `auth-service.war`.

## Files

- [`webapp#sso.war`](webapp%23sso.war): tested installable WAR
- [`Build-SSOAutoLaunch.ps1`](Build-SSOAutoLaunch.ps1): source-based local WAR builder
- [`src/index.html`](src/index.html): entry page and fallback link
- [`src/sso.js`](src/sso.js): native UMS redirect extraction, validation, navigation
- [`src/WEB-INF/web.xml`](src/WEB-INF/web.xml): static servlet and welcome-file setup
- [`tests/test-sso.js`](tests/test-sso.js): optional offline test cases

**Unsupported customization:** This project is not affiliated with or supported by IGEL. Validate functionality and redirect behavior after UMS upgrades.
