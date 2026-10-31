import test from 'node:test';
import assert from 'node:assert/strict';
import { sumDownloads, loadStats } from '../api/stats.mjs';
const response = (data, link='') => ({ ok:true, json:async()=>data, headers:new Headers({link}) });
test('count exact DMG assets, including zero, excluding drafts and malformed counts', () => {
  assert.equal(sumDownloads([{assets:[{name:'HeyMate.dmg',download_count:15},{name:'appcast.xml',download_count:800},{name:'HeyMate.dmg.sha256',download_count:40},{name:'HeyMate.dmg',download_count:-1},{name:'HeyMate.dmg',download_count:'7'}]}, {draft:true,assets:[{name:'HeyMate.dmg',download_count:10}]}]),15);
  assert.equal(sumDownloads([]),0);
  assert.throws(()=>sumDownloads({}));
});
test('aggregate every release page and preserve zero stars', async()=> {
  const paths=[];
  const result=await loadStats(async url=> { paths.push(url); return url.includes('page=2') ? response([{assets:[{name:'HeyMate.dmg',download_count:9}]}]) : url.includes('/releases?') ? response([{assets:[{name:'HeyMate.dmg',download_count:11}]}],'<https://api.github.com/page=2>; rel="next"') : response({stargazers_count:0}); });
  assert.equal(result.downloads,20); assert.equal(result.stars,0); assert.equal(paths.length,3);
});
test('upstream failure never becomes invented zero totals', async()=> {
  await assert.rejects(loadStats(async()=>({ok:false,status:429})),/GitHub unavailable/);
  await assert.rejects(loadStats(async url=>response(url.includes('/releases?')?[]:{stargazers_count:'12'})),/Invalid stars/);
});
