// Serve heymate/ on 127.0.0.1:18742 after running verify_explanation_program.sh
// with HEYMATE_EXPLANATION_FIXTURE=heymate/build/talk-program.json.
async page => {
  const check = (condition, message) => { if (!condition) throw Error(message); };
  await page.goto('http://127.0.0.1:18742/scripts/port-render-fixture.html');
  await page.waitForFunction(() => window.portReady);
  const fixture = await (await page.request.get('http://127.0.0.1:18742/build/talk-program.json')).json();
  await page.evaluate(program => {
    HeyMateCanvas.begin({w:1280,h:800,width:1280});
    window.lessonProgram=program;
    const first=program.slice(0,program.indexOf('step(2)'));
    const report=JSON.parse(HeyMateCanvas.feed(first,false));
    if (report.error) throw Error(report.error);
    HeyMateCanvas.line(0);
  }, fixture.program);
  await page.waitForFunction(() => HeyMateCanvas.state()?.includes('Cylinder'));
  await page.waitForFunction(() => portMessages.some(message=>message.type==='beatVisible'&&message.body.line===0), null, {timeout:3000});
  check(await page.evaluate(() => MateStage3D.stages.size===0), 'future figure visible before spoken beat');
  await page.evaluate(() => {
    const report=JSON.parse(HeyMateCanvas.feed(lessonProgram,true));
    if(report.error)throw Error(report.error);
    HeyMateCanvas.lineLength(0,0.5); HeyMateCanvas.line(1);
  });
  await page.waitForFunction(() => [...MateStage3D.stages.values()][0]?.parts.size===2);
  check(await page.evaluate(() => [...MateStage3D.stages.values()][0].motions.length===0), 'future mechanism moving before its beat');
  await page.evaluate(() => { HeyMateCanvas.lineLength(1,0.5); HeyMateCanvas.line(2); HeyMateCanvas.lineLength(2,0.5); HeyMateCanvas.finish(); });
  await page.waitForFunction(() => [...MateStage3D.stages.values()][0]?.motions.some(m => m.kind==='sliderCrank'));
  await page.evaluate(() => {
    window.savedStage=[...MateStage3D.stages.values()][0];
    window.savedRod=[...savedStage.parts.values()].find(p=>p.name==='Connecting rod');
    window.savedGeometry=savedRod.geometry;
    window.savedPosition=savedRod.position.y;
  });
  await page.evaluate(edit => {
    HeyMateCanvas.continue();
    const report=JSON.parse(HeyMateCanvas.feed(edit,true));
    if(report.error)throw Error(report.error);
    HeyMateCanvas.line(0); HeyMateCanvas.lineLength(0,0.5); HeyMateCanvas.finish();
  }, fixture.edit);
  await page.waitForFunction(() => savedRod.material.color.r>savedRod.material.color.g*2);
  check(await page.evaluate(() => [...MateStage3D.stages.values()][0]===savedStage && savedRod.geometry===savedGeometry && savedStage.motions.some(m=>m.kind==='sliderCrank')), 'typed edit rebuilt scene or stopped motion');
  await page.waitForFunction(() => Math.abs(savedRod.position.y-savedPosition)>0.01);
  const input = await page.evaluate(() => {
    const r=savedStage.canvas.getBoundingClientRect(),x=r.left+r.width/2,y=r.top+r.height/2;
    const yaw=savedStage.yaw;
    HeyMateCanvas.input('down',x,y); HeyMateCanvas.input('move',x+45,y+15); HeyMateCanvas.input('up',x+45,y+15);
    const turned=Math.abs(savedStage.yaw-yaw)>0.2;
    HeyMateCanvas.input('wheel',x,y,-240);
    const zoom=savedStage.zoom;
    HeyMateCanvas.input('wheel',0,0,-240);
    return {turned,zoom,backgroundIgnored:savedStage.zoom===zoom};
  });
  check(input.turned&&input.zoom>1&&input.backgroundIgnored,'native input adapter failed');
  await page.evaluate(erase => {
    HeyMateCanvas.continue();
    const report=JSON.parse(HeyMateCanvas.feed(erase,true));
    if(report.error)throw Error(report.error);
    HeyMateCanvas.line(0);HeyMateCanvas.lineLength(0,0.5);HeyMateCanvas.finish();
  }, fixture.erase);
  await page.waitForFunction(() => ![...document.querySelectorAll('svg text')].some(text=>text.textContent==='Cylinder'));
  await page.evaluate(() => HeyMateCanvas.screenChanged());
  check(await page.evaluate(() => !HeyMateCanvas.state().includes('top-left [100,100')), 'stale screen mark survived');
  check(await page.evaluate(() => MateStage3D.stages.size===1), 'screen change removed explanation figure');
  const beats = await page.evaluate(() => portMessages.filter(m=>m.type==='beatVisible').map(m=>m.body.line));
  check(beats.includes(0) && beats.includes(1) && beats.includes(2), 'missing rendered beat acknowledgements');
  await page.screenshot({path:'output/playwright/talk-typed-piston.png'});
  await page.evaluate(() => HeyMateCanvas.clear());
  check(await page.evaluate(() => MateStage3D.stages.size===0), 'clear leaked figure');
  if (fixture.userBase) {
    await page.setViewportSize({width:1512,height:982});
    await page.evaluate(base => {
      HeyMateCanvas.begin({w:2212,h:1437,width:1512});
      const report=JSON.parse(HeyMateCanvas.feed(base,true));
      if(report.error)throw Error(report.error);
      HeyMateCanvas.line(0);HeyMateCanvas.lineLength(0,0.5);HeyMateCanvas.finish();
    },fixture.userBase);
    await page.waitForFunction(()=>[...MateStage3D.stages.values()][0]?.parts.size===7);
    await page.evaluate(()=>{
      window.catStage=[...MateStage3D.stages.values()][0];
      window.catHead=[...catStage.parts.values()][0];
      window.catGeometry=catHead.geometry;
      HeyMateCanvas.continue();
    });
    await page.evaluate(detail=>{
      const report=JSON.parse(HeyMateCanvas.feed(detail,true));
      if(report.error)throw Error(report.error);
      for(let line=0;line<3;line++){HeyMateCanvas.line(line);HeyMateCanvas.lineLength(line,0.5)}
      HeyMateCanvas.finish();
    },fixture.userDetail);
    await page.waitForFunction(()=>catStage.parts.size===27);
    check(await page.evaluate(()=>[...MateStage3D.stages.values()][0]===catStage&&catHead.geometry===catGeometry),'actual user follow-up lost existing space cat');
    await page.screenshot({path:'output/playwright/user-spacecat-fixed.png'});
    await page.evaluate(()=>HeyMateCanvas.clear());
  }
  return {passed:['typed streamed beats','future beat gating','in-place material edit','motion survives edit','screen invalidation preserves figure','render acknowledgements','cleanup'],beats};
}
