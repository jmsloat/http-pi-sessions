// Run against a disposable demo server; creates its own temporary workspace fixtures.
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
const {chromium} = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.TEST_BASE_URL || 'http://localhost:4000';
const out = process.env.TEST_OUTPUT_DIR || '/tmp/desk-files-browser';
const root = mkdtempSync(join(tmpdir(), 'desk-files-browser-'));
const project = join(root, 'Preview project');
mkdirSync(join(project, 'docs'), {recursive:true});
mkdirSync(out, {recursive:true});
const git = (...args) => execFileSync('git', args, {cwd:project});
writeFileSync(join(project, 'greeting.ex'), 'defmodule Greeting do\n  def hello, do: "Hello"\nend\n');
writeFileSync(join(project, 'docs', 'notes.html'), '<script>window.untrustedPreviewRan = true</script>\n<h1>Untrusted source</h1>');
git('init', '-q');git('config', 'user.email', 'test@example.com');git('config', 'user.name', 'Test');
git('add', '.');git('commit', '-qm', 'baseline');
writeFileSync(join(project, 'greeting.ex'), 'defmodule Greeting do\n  def hello, do: "Hello, world"\nend\n');
git('add', 'greeting.ex');
writeFileSync(join(project, 'greeting.ex'), 'defmodule Greeting do\n  def hello, do: "Hello from Session Desk"\nend\n');
writeFileSync(join(project, 'new artifact.txt'), 'An untracked artifact\n');
// Valid transparent 1x1 PNG.
writeFileSync(join(project, 'pixel.png'), Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgAAIAAAUAAarVyFEAAAAASUVORK5CYII=', 'base64'));
for (let i=0;i<100;i++) {try {if ((await fetch(base+'/health')).ok) break;} catch {} await new Promise(r=>setTimeout(r,200));}
const browser = await chromium.launch({headless:true,args:['--no-sandbox']});
try {
  const page = await browser.newPage({viewport:{width:1440,height:1000}});
  const errors=[];page.on('pageerror',e=>errors.push(String(e)));
  await page.goto(base);await page.waitForSelector('.phx-connected');
  await page.getByText('Add workspace',{exact:true}).click();
  await page.locator('#add-workspace input[name=name]').fill('Preview project');
  await page.locator('#add-workspace input[name=path]').fill(project);
  await page.getByRole('button',{name:'Add directory',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('#workspace-select').selectedOptions[0].textContent.includes('Preview project'));
  await page.getByLabel('New session name').fill('Inspect agent artifacts');
  await page.getByRole('button',{name:'+ New session',exact:true}).click();
  await page.getByRole('heading',{name:'Inspect agent artifacts',exact:true}).waitFor();
  await page.locator('#files-tab').click();
  await page.locator('.file-entry[phx-value-path="greeting.ex"]').waitFor();
  await page.locator('[phx-click=diff][phx-value-path="greeting.ex"][phx-value-area=staged]').click();
  await page.locator('.diff-preview .added').filter({hasText:'Hello, world'}).waitFor();
  assert.ok(!(await page.locator('.diff-preview').innerText()).includes('Hello from Session Desk'));
  await page.locator('[phx-click=diff][phx-value-path="greeting.ex"][phx-value-area=working]').click();
  await page.locator('.diff-preview .added').filter({hasText:'Hello from Session Desk'}).waitFor();
  await page.screenshot({path:out+'/desktop-diff.png',fullPage:true});
  await page.locator('.file-entry[phx-value-path=docs]').click();
  await page.locator('.file-entry[phx-value-path="docs/notes.html"]').click();
  await page.locator('.source-preview').filter({hasText:'<script>'}).waitFor();
  assert.equal(await page.evaluate(()=>window.untrustedPreviewRan), undefined);
  assert.equal(await page.locator('#file-preview script').count(),0);
  writeFileSync(join(project, 'docs', 'notes.html'), 'Refreshed content\n');
  await page.locator('#refresh-files').click();
  await page.locator('.source-preview').filter({hasText:'Refreshed content'}).waitFor();
  await page.getByRole('button',{name:'Workspace root',exact:true}).click();
  await page.locator('.file-entry[phx-value-path="pixel.png"]').click();
  await page.locator('.image-preview img').waitFor();
  await page.waitForFunction(()=>document.querySelector('.image-preview img')?.naturalWidth===1);
  await page.locator('.file-entry[phx-value-path="new artifact.txt"]').click();
  await page.locator('.source-preview').filter({hasText:'An untracked artifact'}).waitFor();
  await page.setViewportSize({width:390,height:844});
  await page.locator('[phx-click=diff][phx-value-path="greeting.ex"][phx-value-area=working]').click();
  await page.locator('.diff-preview .added').filter({hasText:'Hello from Session Desk'}).waitFor();
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth), 'Mobile overflow');
  await page.screenshot({path:out+'/mobile-diff.png',fullPage:true});
  // A source stays scoped to the selected workspace when navigation changes.
  await page.getByRole('button',{name:'Toggle workspaces',exact:true}).click();
  await page.getByLabel('Workspace',{exact:true}).selectOption({index:0});
  // Switch via a known session link even when the workspace selector ordering changes.
  await page.goto(base+'/sessions/demo-main');await page.waitForSelector('.phx-connected');
  await page.locator('#files-tab').click();
  await page.locator('#refresh-files:not([disabled])').waitFor();
  assert.equal(await page.locator('#file-preview').count(),0);
  assert.equal(await page.locator('.file-entry[phx-value-path="greeting.ex"]').count(),0);
  assert.deepEqual(errors,[]);
  console.log(JSON.stringify({passed:true,checks:['staged/unstaged diffs','escaped HTML source','external edit refresh','image preview','untracked files','workspace isolation','mobile layout','no browser errors'],screenshots:out}));
} finally {await browser.close();rmSync(root,{recursive:true,force:true});}
