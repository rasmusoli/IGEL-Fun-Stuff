const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '..', 'src', 'sso.js'), 'utf8');
const base = 'https://ums.example:8443';
const prefix = '<script> async function handleButtonLoginSso() {\n window.location.replace(';
const suffix = ')\n } </script>';
async function run(html, finalPath='/auth-service/login') {
  const calls=[]; const errors=[]; const status={textContent:'Starting UMS single sign-on...'};
  const window={location:{origin:base,replace:u=>calls.push(u)}};
  const response={ok:true,status:200,url:base+finalPath,text:async()=>html};
  const context={window,fetch:async()=>response,document:{getElementById:()=>status},console:{error:(...a)=>errors.push(a)},URL};
  vm.runInNewContext(source,context);
  await new Promise(setImmediate);
  return {calls,errors,status:status.textContent};
}
(async()=>{
  const ok=await run(prefix+'"/auth-service/oauth2/authorization/entra"'+suffix);
  assert.deepEqual(ok.calls,[base+'/auth-service/oauth2/authorization/entra']);
  const absolute=await run(prefix+'"https://ums.example:8443/auth-service/oauth2/authorization/entra"'+suffix);
  assert.deepEqual(absolute.calls,[base+'/auth-service/oauth2/authorization/entra']);
  const fallback=await run(prefix+'/*[[${ssoForwardUrl}]]*/ "/auth-service/login"'+suffix);
  assert.equal(fallback.calls.length,0);
  assert.match(fallback.status,/could not be started/);
  const invalid=await run(prefix+'"https://attacker.example/auth-service/oauth2/authorization/entra"'+suffix);
  assert.equal(invalid.calls.length,0);
  const auth=await run('', '/auth-service/logininfo');
  assert.deepEqual(auth.calls,['/webapp']);
  console.log('PASS 5 cases: configured relative/absolute SSO URL; no-SSO fallback; unsafe redirect blocked; existing session reused.');
})().catch(e=>{ console.error(e); process.exitCode=1; });
