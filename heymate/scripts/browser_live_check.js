// Run with playwright-cli run-code --filename heymate/scripts/browser_live_check.js.
// Real CDP/DOM actions. Chrome tab/window/group APIs use an isolated in-memory
// facade; this does not establish native-messaging or real Chrome group UI.
async page => {
 const check=(ok,message)=>{if(!ok)throw Error(message)};
 const context=page.context(), control=await context.newPage(), pages=new Map(), sessions=new Map(), tabs=new Map(), groups=new Map();
 const base='http://127.0.0.1:18742/scripts/browser-port-fixture.html';
 let next=1, groupID=10;
 const create=async(url,active=false)=>{
  const p=await context.newPage(),id=next++;pages.set(id,p);
  await p.goto(url);tabs.set(id,{id,url:p.url(),title:await p.title(),active,windowId:1,index:id-1,groupId:-1,status:'complete',incognito:false});
  return {...tabs.get(id)};
 };
 try {
  await control.goto(base);
  await create(base,true);
  await control.exposeFunction('portChrome',async(kind,args)=>{
   const [first,second,third]=args;
   if(kind==='tabs.query') return [...tabs.values()].filter(t=>Object.entries(first||{}).every(([k,v])=>!['lastFocusedWindow','windowType'].includes(k)?t[k]===v:true));
   if(kind==='tabs.get') {if(!tabs.has(first))throw Error('No tab');return {...tabs.get(first)}}
   if(kind==='tabs.create') return create(first.url,first.active);
   if(kind==='tabs.update') {
    const p=pages.get(first),t=tabs.get(first);
    if(second.url){await p.goto(second.url);t.url=p.url();t.title=await p.title();await control.evaluate(id=>engine.invalidate(id),first)}
    Object.assign(t,second);return {...t};
   }
   if(kind==='tabs.remove') {await pages.get(first).close();tabs.delete(first);return}
   if(kind==='tabs.goBack') {await pages.get(first).goBack();tabs.get(first).url=pages.get(first).url();await control.evaluate(id=>engine.invalidate(id),first);return}
   if(kind==='tabs.group') {const id=first.groupId??groupID++;groups.set(id,{id,windowId:1});for(const t of first.tabIds)tabs.get(t).groupId=id;return id}
   if(kind==='tabs.ungroup') {tabs.get(first).groupId=-1;return}
   if(kind==='tabs.move') {Object.assign(tabs.get(first),second);return {...tabs.get(first)}}
   if(kind==='tabGroups.get') {if(!groups.has(first))throw Error('No group');return {...groups.get(first)}}
   if(kind==='tabGroups.update') {Object.assign(groups.get(first),second);return {...groups.get(first)}}
   if(kind==='windows.getAll')return [{id:1,type:'normal',incognito:false}];
   if(kind.startsWith('windows.'))return {id:1,type:'normal',incognito:false};
   if(kind==='debugger.attach'){
    const cdp=await context.newCDPSession(pages.get(first.tabId));sessions.set(first.tabId,cdp);
    for(const method of ['Page.frameNavigated','Page.navigatedWithinDocument'])cdp.on(method,()=>control.evaluate(id=>engine.invalidate(id),first.tabId).catch(()=>{}));
    cdp.on('Page.javascriptDialogOpening',params=>control.evaluate(({id,params})=>engine.dialogOpened(id,params),{id:first.tabId,params}).catch(()=>{}));
    cdp.on('Page.javascriptDialogClosed',()=>control.evaluate(id=>engine.dialogClosed(id),first.tabId).catch(()=>{}));
    return;
   }
   if(kind==='debugger.detach'){await sessions.get(first.tabId)?.detach();sessions.delete(first.tabId);return}
   if(kind==='debugger.sendCommand')return sessions.get(first.tabId).send(second,third);
   throw Error('Unimplemented fixture API '+kind);
  });
  await control.evaluate(async()=>{
   const {BrowserBridge}=await import('../browser/extension/mate-core.mjs');
   const api={};for(const name of ['tabs','windows','tabGroups','debugger'])api[name]=new Proxy({},{get:(_,method)=>(...args)=>portChrome(name+'.'+method,args)});
   window.engine=new BrowserBridge(api);
  });
  const run=(operation,fields={})=>control.evaluate(async({operation,fields})=>engine.execute({task:'fixture/turn',owner:'fixture',groupTitle:'HeyMate QA',operation,...fields}),{operation,fields});
  const opened=await run('open',{url:base});
  check(!opened.error,'open failed: '+opened.error);
  const id=opened.tabId, snapshot=await run('snapshot',{tabId:id});
  const field=snapshot.nodes.find(n=>n.role==='textbox'&&n.name==='Name');
  const greet=snapshot.nodes.find(n=>n.role==='button'&&n.name==='Greet');
  check(field&&greet,'snapshot lacks actual form refs');
  const filled=await run('fill',{tabId:id,ref:field.ref,text:'HeyMate QA'});check(!filled.error,'fill failed: '+filled.error);
  const clicked=await run('click',{tabId:id,ref:greet.ref});check(!clicked.error,'click failed: '+clicked.error);
  check(await pages.get(id).locator('#result').innerText()==='Hello HeyMate QA','real input did not update DOM');
  const password=snapshot.nodes.find(n=>n.role==='textbox'&&n.name==='Password');
  check(password,'password field missing from fixture snapshot');
  const secret=await run('fill',{tabId:id,ref:password.ref,text:'synthetic-not-a-secret'});
  check(!!secret.error,'password fill accepted');
  check(await pages.get(id).locator('input[type=password]').inputValue()==='','password field changed');
  await pages.get(id).evaluate(()=>{const r=document.querySelector('button').getBoundingClientRect(),cover=document.createElement('div');cover.id='test-cover';Object.assign(cover.style,{position:'fixed',left:r.left+'px',top:r.top+'px',width:r.width+'px',height:r.height+'px',zIndex:2147483647,background:'white'});document.body.appendChild(cover)});
  const covered=await run('click',{tabId:id,ref:greet.ref});check(!!covered.error,'covered click accepted');
  await pages.get(id).evaluate(()=>document.querySelector('#test-cover').remove());
  const extracted=await run('extract',{tabId:id});check(JSON.stringify(extracted).includes('Hello HeyMate QA'),'extract missed changed page');
  await run('press',{tabId:id,key:'Tab'});await run('scroll',{tabId:id,direction:'down'});
  check(await pages.get(id).evaluate(()=>scrollY)>0,'scroll did not move page');
  await run('open',{tabId:id,url:base+'?next=1'});
  const stale=await run('click',{tabId:id,ref:greet.ref});check(!!stale.error,'stale ref accepted after navigation');
  await run('back',{tabId:id});
  check(pages.get(id).url()===base,'back failed');
  const uploadSnapshot=await run('snapshot',{tabId:id});
  const uploadRef=uploadSnapshot.nodes.find(n=>n.name==='Upload fixture'&&n.ref);
  check(uploadRef,'upload reference absent');
  const upload=await run('upload',{tabId:id,ref:uploadRef.ref,paths:['/tmp/heymate-next-ports/upload-fixture.txt']});
  check(!upload.error,'upload failed: '+upload.error);
  check(await pages.get(id).locator('#upload-result').innerText()==='upload-fixture.txt','actual file input did not change');
  const dialogSnapshot=await run('snapshot',{tabId:id});
  const dialogRef=dialogSnapshot.nodes.find(n=>n.role==='button'&&n.name==='Open local dialog');
  check(dialogRef,'dialog button absent');
  const dialogClick=await run('click',{tabId:id,ref:dialogRef.ref});
  await run('dialog',{tabId:id,accept:false});
  check(await pages.get(id).locator('#dialog-result').innerText()==='Dismissed','dialog was not dismissed');
  await pages.get(id).screenshot({path:'output/playwright/browser-actions.png'});
  await control.evaluate(async({id})=>{
   await engine.execute({task:'other/turn',owner:'other',operation:'tabs'});
   window.ownerRefusal='';try{await engine.execute({task:'other/turn',owner:'other',operation:'click',tabId:id,ref:'e1'})}catch(e){ownerRefusal=e.message}
  },{id});
  check(await control.evaluate(()=>ownerRefusal.includes('another running')),'cross-owner takeover allowed');
  let refused=false;try{await run('close',{tabId:1})}catch{refused=true}check(refused,'user tab closed');
  const ended=await run('end',{tidy:true});check(ended.closed.includes(id),'owned background tab not tidied');check(!pages.get(1).isClosed(),'user tab removed');
  return {passed:['open','AX refs','fill','click','DOM change','password fill refusal','covered click refusal','extract','press','scroll','navigate','stale-ref refusal','back','cross-owner refusal','user-tab close refusal','real file upload','dialog dismissal','tidy'],scope:'real CDP actions; simulated Chrome tab/group API; no native messaging'};
 } finally {for(const p of pages.values())if(!p.isClosed())await p.close();await control.close()}
}
