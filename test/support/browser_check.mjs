// Optional real-browser check. Install playwright in a separate dev tools directory.
import assert from 'node:assert/strict';
import {mkdirSync} from 'node:fs';
const {chromium}=await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base=process.env.TEST_BASE_URL || 'http://localhost:4000';
const live=process.env.TEST_LIVE_PI==='1';
const out=process.env.TEST_OUTPUT_DIR || '/tmp/session-desk-browser';mkdirSync(out,{recursive:true});
for(let i=0;i<100;i++){try{if((await fetch(base+'/health')).ok)break;}catch{}await new Promise(r=>setTimeout(r,200));}
const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
const errors=[];
try {
  let context=await browser.newContext({viewport:{width:1440,height:1000}});
  let page=await context.newPage();page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(base);await page.waitForSelector('.phx-connected');
  await page.screenshot({path:out+'/desktop-empty.png',fullPage:true});
  await page.getByLabel('Message your agent').fill('Make a three-step plan and ask me a question.');
  await page.getByRole('button',{name:'Send',exact:false}).click();
  await page.waitForTimeout(250);
  await page.reload();await page.waitForSelector('.phx-connected');
  await page.getByText(live?'Prototype: Can you see the real Gentle Todo list?':'Which behavior should we verify next?',{exact:true}).waitFor({timeout:20000});
  assert.equal(await page.locator('.task').count(),3);
  await page.screenshot({path:out+'/desktop-question.png',fullPage:true});
  await context.close();
  context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
  page=await context.newPage();page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(base);await page.waitForSelector('.phx-connected');
  assert.equal(await page.locator('.question').count(),1);
  await page.screenshot({path:out+'/mobile-question.png',fullPage:true});
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile horizontal overflow');
  await page.getByRole('button',{name:live?'Yes':'Reconnect while working',exact:false}).click();
  await page.waitForFunction(()=>document.querySelector('#session-status').textContent.includes('Ready'),{},{timeout:20000});
  assert.equal(await page.locator('.task.done').count(),3);
  assert.equal(await page.locator('.message.user').count(),1);
  assert.equal(await page.locator('.question').count(),0);
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,mode:live?'real-pi-deterministic-provider':'demo',checks:['desktop','streaming','reload','close and reopen browser context','question answer','task updates','mobile overflow','no duplicate prompt','no browser errors'],screenshots:out}));
} finally {await browser.close();}
