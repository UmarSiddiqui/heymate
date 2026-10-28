// Serve heymate/ on 127.0.0.1:18742; run via playwright-cli run-code --filename.
async page => {
 const check=(ok,message)=>{if(!ok)throw Error(message)};
 await page.route('**/*', route => route.continue()); // Disable cached wrapper scripts.
 await page.goto('http://127.0.0.1:18742/scripts/port-render-fixture.html');
 await page.waitForFunction(()=>window.portReady);
 await page.evaluate(()=>{
  HeyMateCanvas.begin({w:1280,h:800,width:1280});
  const analysis=JSON.parse(HeyMateCanvas.feed(`step(1);say("First drawing waits for the first spoken sentence.");
const a=paper(200,100,760,560,{title:'Port validation',heading:'Drawing with speech'});
text(a.x+40,a.y+80,'FIRST BEAT',{tone:'ink',size:24});
step(2);say("Second label waits until its matching sentence starts.");
text(a.x+40,a.y+180,'SECOND BEAT',{tone:'blue',size:24});`,true));
  if(analysis.error)throw Error(analysis.error);
 });
 check(await page.evaluate(()=>!document.body.innerText.includes('FIRST BEAT')),'drawn before speech');
 await page.evaluate(()=>HeyMateCanvas.line(0));
 await page.waitForFunction(()=>document.body.innerText.includes('FIRST BEAT'));
 check(await page.evaluate(()=>!document.body.innerText.includes('SECOND BEAT')),'future speech beat visible');
 await page.screenshot({path:'output/playwright/drawing-first-beat.png'});
 await page.evaluate(()=>{HeyMateCanvas.lineLength(0,1.2);HeyMateCanvas.line(1)});
 await page.waitForFunction(()=>document.body.innerText.includes('SECOND BEAT'));
 await page.evaluate(()=>{HeyMateCanvas.lineLength(1,1.2);HeyMateCanvas.finish()});
 await page.waitForTimeout(1000);
 await page.screenshot({path:'output/playwright/drawing-second-beat.png'});
 await page.evaluate(()=>{
  HeyMateCanvas.continue();
  const analysis=JSON.parse(HeyMateCanvas.feed('step(1);say("A continued explanation keeps the earlier drawing.");text(250,500,"CONTINUED",{tone:"ink"});',true));
  if(analysis.error)throw Error(analysis.error);HeyMateCanvas.line(0);HeyMateCanvas.finish();
 });
 await page.waitForFunction(()=>document.body.innerText.includes('CONTINUED'));
 check(await page.evaluate(()=>document.body.innerText.includes('FIRST BEAT')),'continuation erased old card');
 await page.evaluate(()=>{
  HeyMateCanvas.clear(); HeyMateCanvas.begin({w:1280,h:800,width:1280});
  const a=JSON.parse(HeyMateCanvas.feed(`step(1);say("Mark the old page and keep a separate explanation card.");
ring(10,10,130,50,'OLD PAGE');
const a=paper(300,100,680,460,{title:'Keep card'});text(a.x+30,a.y+60,'KEEP CARD',{tone:'ink'});`,true));
  if(a.error)throw Error(a.error); HeyMateCanvas.line(0); HeyMateCanvas.lineLength(0,0.5); HeyMateCanvas.finish();
 });
 await page.waitForFunction(()=>HeyMateCanvas.isFinished());
 check(await page.evaluate(()=>HeyMateCanvas.state().includes('OLD PAGE')),'stale marker missing before cleanup');
 await page.evaluate(()=>HeyMateCanvas.screenChanged());
 check(await page.evaluate(()=>{const s=HeyMateCanvas.state();return s?.includes('KEEP CARD')&&!s.includes('OLD PAGE')}),'screen cleanup did not preserve card and drop stale mark');
 await page.evaluate(()=>{
  HeyMateCanvas.clear();
  HeyMateCanvas.begin({w:1280,h:800,width:1280});
  const analysis=JSON.parse(HeyMateCanvas.feed(`step(1);say("This piston is real geometry built by the recovered engine.");
const f=figure(200,100,760,560,{spin:0.1});
const piston=f.lathe({profile:[[0,-0.3],[0.5,-0.3],[0.5,0.3],[0,0.3]],at:[0,1,0],mat:'alu',name:'piston'});f.label(piston,'piston');
step(2);say("The connecting rod and crank move beneath the piston.");
const rod=f.box({size:[0.2,1,0.2],at:[0,0,0],mat:'steel',name:'connectingRod'});f.label(rod,'connecting rod');
const crank=f.cyl({r:0.15,h:1.6,axis:'x',at:[0,-0.6,0],mat:'iron',name:'crankshaft'});f.label(crank,'crankshaft');
f.tick(t=>{piston.pos=[0,1+0.2*cos(t*3),0];crank.rot=[t*90,0,0]});`,true));
  if(analysis.error)throw Error(analysis.error);HeyMateCanvas.line(0);HeyMateCanvas.lineLength(0,0.5);HeyMateCanvas.line(1);HeyMateCanvas.lineLength(1,0.5);HeyMateCanvas.finish();
 });
 await page.waitForFunction(()=>{const s=[...MateStage3D.stages.values()][0];return s&&s.parts.size===3&&s.labelList.length===3&&s.ticks.length===1&&s.pending.length===0});
 await page.waitForTimeout(1000);
 const read=()=>page.evaluate(()=>{const s=[...MateStage3D.stages.values()][0];return {yaw:s.yaw,position:[...s.parts.values()][0].position.y,vertices:[...s.parts.values()].map(p=>p.geometry.attributes.position.count),rect:s.canvas.getBoundingClientRect().toJSON()}});
 const first=await read();check(first.vertices.every(v=>v>20),'placeholder geometry');
 await page.waitForTimeout(250);check(Math.abs((await read()).position-first.position)>0.001,'tick does not animate');
 await page.screenshot({path:'output/playwright/3d-piston.png'});
 await page.mouse.move(first.rect.x+first.rect.width/2,first.rect.y+first.rect.height/2);
 await page.mouse.down();await page.mouse.move(first.rect.x+first.rect.width/2+60,first.rect.y+first.rect.height/2+20,{steps:10});await page.mouse.up();
 check(Math.abs((await read()).yaw-first.yaw)>0.2,'drag did not turn model');
 // Pick projected mesh center with actual pointer input.
 const point=await page.evaluate(()=>{const s=[...MateStage3D.stages.values()][0],p=[...s.parts.values()][0],r=s.canvas.getBoundingClientRect(),v=p.getWorldPosition(new THREE.Vector3()).project(s.camera);return {x:r.left+(v.x+1)/2*r.width,y:r.top+(1-v.y)/2*r.height}});
 await page.mouse.click(point.x,point.y);
 check(await page.evaluate(()=>portMessages.some(m=>m.type==='askPart'&&m.body==='piston')),'part click did not ask about piston');
 // Move/zoom actual SVG ancestor. WebGL rectangle must track it next frame.
 await page.evaluate(()=>document.querySelector('scene3d').parentElement.setAttribute('transform','translate(35 25) scale(0.8)'));
 await page.waitForTimeout(100);
 const moved=await read();check(Math.abs(moved.rect.width-first.rect.width*0.8)<2,'3D canvas ignores SVG zoom');
 await page.evaluate(()=>HeyMateCanvas.clear());
 check(await page.evaluate(()=>MateStage3D.stages.size===0&&document.querySelectorAll('#mate-canvas > canvas').length===0&&!document.body.innerText.trim()),'clear leaves drawing or WebGL canvas');
 // scene3d() is the recovered illustrated path (no data-look attribute);
 // figure() above selects studio explicitly. Compile the native fragment port
 // on an actual GPU and inspect pixels in the same rendering task.
 const shaderErrors=[];
 const shaderError=message=>{const text=message.text();if(message.type()==='error'&&/shader|VALIDATE_STATUS/i.test(text))shaderErrors.push(text)};
 page.on('console',shaderError);
 await page.evaluate(()=>{
  HeyMateCanvas.begin({w:1280,h:800,width:1280});
  const analysis=JSON.parse(HeyMateCanvas.feed(`step(1);say("The illustrated sphere uses the recovered native shader.");
scene3d(200,100,760,560,s=>{s.sphere({r:1,color:'#E04B3F',roughness:0.65,metalness:0});});`,true));
  if(analysis.error)throw Error(analysis.error);HeyMateCanvas.line(0);HeyMateCanvas.lineLength(0,0.5);HeyMateCanvas.finish();
 });
 await page.waitForFunction(()=>{const s=[...MateStage3D.stages.values()][0];return s&&s.parts.size===1&&s.pending.length===0});
 await page.waitForTimeout(1000);
 const illustrated=await page.evaluate(()=>{
  const s=[...MateStage3D.stages.values()][0],mesh=[...s.parts.values()][0];
  if(!mesh.isMesh||!mesh.material.isShaderMaterial||!mesh.material.userData.nativeDaVinci)throw Error('scene3d bypassed native fragment');
  const gl=s.renderer.getContext(),size=s.renderer.getDrawingBufferSize(new THREE.Vector2());
  s.renderer.render(s.scene,s.camera);
  const pixels=new Uint8Array(size.x*size.y*4);gl.readPixels(0,0,size.x,size.y,gl.RGBA,gl.UNSIGNED_BYTE,pixels);
  let solid=0,red=0;const colors=new Set();
  for(let i=0;i<pixels.length;i+=4)if(pixels[i+3]>200){solid++;if(pixels[i]>pixels[i+1]*1.3&&pixels[i]>pixels[i+2]*1.3)red++;colors.add([pixels[i],pixels[i+1],pixels[i+2]].join(','))}
  return {solid,red,colors:colors.size,vertices:mesh.geometry.attributes.position.count,glError:gl.getError()};
 });
 check(shaderErrors.length===0,shaderErrors.join('\n'));
 check(illustrated.glError===0,'native shader WebGL error');
 check(illustrated.vertices>100&&illustrated.solid>100&&illustrated.red>100&&illustrated.colors>8,'native shader did not shade real visible geometry: '+JSON.stringify(illustrated));
 await page.screenshot({path:'output/playwright/3d-illustrated-port.png'});
 page.off('console',shaderError);
 await page.evaluate(()=>HeyMateCanvas.clear());
 return {passed:['speech beat gating','line durations','continue drawing','real lathe/box/cylinder geometry','labels','tick animation','drag rotation','part picking','SVG move/zoom tracking','clear cleanup','screen change preserves cards and removes stale marks','native illustrated shader GPU compile and visible pixels'],vertices:first.vertices,illustrated};
}
