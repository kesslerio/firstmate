const { chromium }=require('./pi-prefix/node_modules/playwright');
const fs=require('fs');
const evidence='/Users/kesslerio/.no-mistakes/evidence/01M3RK3ZC6HPM3EB47S4VX8T41';
(async()=>{
 const browser=await chromium.launch({executablePath:process.env.FM_REAL_CHROME,headless:true});
 try {
 const page=await browser.newPage({viewport:{width:1440,height:1100}});
 await page.goto('file://'+evidence+'/calm-export.html');
 await page.waitForSelector('#messages .user-message');
 const before=await page.locator('#messages').innerText();
 const inventory=await page.locator('button,input').evaluateAll(es=>es.map(e=>({tag:e.tagName,id:e.id,text:e.textContent,type:e.type,title:e.title})));
 await page.screenshot({path:evidence+'/calm-export-default.png',fullPage:true});
 await page.locator('#messages .user-message').first().evaluate(el=>el.scrollIntoView({block:'start'}));
 await page.screenshot({path:evidence+'/calm-export-conversation.png'});
 if (before.includes('[firstmate-synthetic-input]')) throw new Error('Synthetic input visible by default');
 if (!before.includes('Show a deterministic tool example.') || !before.includes('The deterministic tool example is complete.')) throw new Error('Conversation missing');
 await page.getByRole('button',{name:/hidden messages/i}).click();
 const shown=await page.locator('#messages').innerText();
 if (!shown.includes('[firstmate-synthetic-input]') || !shown.includes('/tmp/probe.status')) throw new Error('Hidden history toggle lost preserved synthetic input');
 await page.screenshot({path:evidence+'/calm-export-history-shown.png',fullPage:true});
 await page.getByRole('button',{name:/hidden messages/i}).click();
 const restored=await page.locator('#messages').innerText();
 if (restored.includes('[firstmate-synthetic-input]')) throw new Error('Hide toggle failed');
 console.log('Independent browser interaction passed: genuine conversation visible; synthetic row hidden by default, revealed on request, and hidden again.');
 fs.writeFileSync(evidence+'/export-independent-qa.json',JSON.stringify({before,shown,restored,inventory},null,2));
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
