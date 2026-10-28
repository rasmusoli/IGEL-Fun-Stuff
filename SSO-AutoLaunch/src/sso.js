// Unofficial, standalone UMS 12.14.103 SSO launcher, v1.1. No authentication is handled here.
(async () => {
  const loginPath = '/auth-service/login';

  try {
    // Resolve the SSO registration chosen by UMS itself. Never hardcode an IdP ID.
    const response = await fetch(loginPath, {
      credentials: 'same-origin',
      redirect: 'follow',
      cache: 'no-store'
    });
    if (!response.ok) throw new Error(`UMS login returned HTTP ${response.status}`);

    const finalUrl = new URL(response.url, window.location.origin);
    if (finalUrl.origin !== window.location.origin) {
      throw new Error('UMS login redirected to an unexpected origin');
    }
    if (finalUrl.pathname === '/auth-service/logininfo') {
      window.location.replace('/webapp'); // Already logged in; preserve the UMS session.
      return;
    }
    if (finalUrl.pathname !== loginPath) {
      throw new Error('Unexpected UMS login destination');
    }

    const html = await response.text();
    const handlerAt = html.indexOf('function handleButtonLoginSso');
    if (handlerAt < 0) throw new Error('Native UMS SSO action not found');

    // Thymeleaf renders the SSO URL as a JavaScript string argument.
    const handler = html.slice(handlerAt, handlerAt + 700);
    const encoded = handler.match(/window\.location\.replace\(\s*("(?:\\.|[^"\\])*")\s*\)/)?.[1];
    if (!encoded) throw new Error('Rendered UMS SSO redirect not found');

    const target = new URL(JSON.parse(encoded), response.url);
    if (target.origin !== window.location.origin ||
        !/^\/auth-service\/oauth2\/authorization\/[^/]+$/.test(target.pathname)) {
      throw new Error('Unexpected UMS SSO redirect');
    }

    window.location.replace(target.href);
  } catch (error) {
    console.error('UMS SSO launcher:', error);
    document.getElementById('status').textContent =
      'Automatic SSO could not be started. Use the normal UMS login link below.';
  }
})();
