const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const model=require('../Sources/HerdrHUD/Resources/model.js');
const source=fs.readFileSync(path.join(__dirname,'../Sources/HerdrHUD/Resources/app.js'),'utf8');
const agent=(id,status,extra={})=>({id,terminal_id:id,agent_status:status,online:true,tab_label:id,...extra});
const nameOf=a=>a.id;

test('summary puts needs input first and counts both states',()=>{
  const s=model.summary([{agent:agent('docs','done'),tone:'done'},{agent:agent('build','blocked'),tone:'blocked'},{agent:agent('api','done'),tone:'done'}],nameOf);
  assert.deepEqual(s,{id:'build',tone:'blocked',title:'1 needs input, 2 finished',preview:'build, docs, api',count:3});
});
test('summary wording for one agent and for a single state',()=>{
  assert.equal(model.summary([{agent:agent('docs','done'),tone:'done'}],nameOf).title,'docs finished');
  assert.equal(model.summary([{agent:agent('a','blocked'),tone:'blocked'}],nameOf).title,'a needs input');
  assert.equal(model.summary([{agent:agent('a','done'),tone:'done'},{agent:agent('b','idle'),tone:'done'}],nameOf).title,'2 agents finished');
  assert.equal(model.summary([{agent:agent('a','blocked'),tone:'blocked'},{agent:agent('b','blocked'),tone:'blocked'}],nameOf).tone,'blocked');
  assert.equal(model.summary([],nameOf),null);
});

// The real app.js with a fake page and native bridge. Rosters arrive as the
// native host sends them; we watch what the page posts back.
function page(){
  const messages=[],node=()=>({value:'',disabled:false,hidden:false,textContent:'',style:{},classList:{toggle(){}},dataset:{},setAttribute(){},append(){},replaceChildren(){},querySelectorAll:()=>[],querySelector:()=>null,scrollTop:0,scrollHeight:0,clientHeight:0});
  const nodes=new Map(),document={getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id);},createElement:node,createTextNode:()=>({}),querySelector:node,addEventListener(){},documentElement:{classList:{add(){}}}};
  const window={webkit:{messageHandlers:{hud:{postMessage:m=>messages.push(m)}}}};
  const context=vm.createContext({window,document,HUDModel:model,HUDRender:{conversation(){},inline(){}},getComputedStyle:()=>({fontSize:'12px'}),setInterval(){},Event:class{},console});
  vm.runInContext(source,context);
  const roster=agents=>{messages.length=0;window.receive({type:'roster',data:{agents,machines:[]}});return messages;};
  return {context,window,messages,roster};
}
const ops=(messages,op)=>messages.filter(m=>m.op===op).map(m=>JSON.parse(JSON.stringify(m)));

test('H badge counts needs input in red before unread in blue, and reports working',()=>{
  const p=page();p.roster([agent('a','working'),agent('b','working'),agent('c','idle')]);
  assert.deepEqual(ops(p.messages,'badge').at(-1),{op:'badge',count:0,tone:'',working:2});
  p.roster([agent('a','done'),agent('b','working'),agent('c','idle')]);
  assert.deepEqual(ops(p.messages,'badge').at(-1),{op:'badge',count:1,tone:'unread',working:1});
  p.roster([agent('a','done'),agent('b','blocked'),agent('c','idle')]);
  assert.deepEqual(ops(p.messages,'badge').at(-1),{op:'badge',count:1,tone:'blocked',working:0});
});
test('simultaneous alerts become one summary toast instead of dropping all but one',()=>{
  const p=page();p.roster([agent('a','working'),agent('b','working'),agent('c','working')]);
  const sent=p.roster([agent('a','done'),agent('b','blocked'),agent('c','idle')]);
  assert.equal(ops(sent,'alertPreview').length,0);
  const [toast]=ops(sent,'alert');
  assert.equal(toast.title,'1 needs input, 2 finished');assert.equal(toast.tone,'blocked');assert.equal(toast.id,'b');
});
test('a single alert reads a preview first and keeps its tone',()=>{
  const p=page();p.roster([agent('a','working')]);
  const sent=p.roster([agent('a','blocked')]);
  assert.deepEqual(ops(sent,'alertPreview').map(m=>[m.id,m.title,m.tone]),[['a','a needs input','blocked']]);
  p.messages.length=0;p.window.receive({type:'alertPreview',data:{id:'a',title:'a needs input',tone:'blocked',text:'',provider:''}});
  assert.equal(ops(p.messages,'alert')[0].tone,'blocked');
});
test('later alerts update the toast; answered ones shrink it, then clear it',()=>{
  const p=page();p.roster([agent('a','working'),agent('b','working')]);
  p.roster([agent('a','blocked'),agent('b','working')]);
  let sent=p.roster([agent('a','blocked'),agent('b','done')]);
  assert.equal(ops(sent,'alert')[0].title,'1 needs input, 1 finished');
  // Answered in the terminal: a goes back to work. The toast updates in place only.
  sent=p.roster([agent('a','working'),agent('b','done')]);
  assert.deepEqual([ops(sent,'alert')[0].title,ops(sent,'alert')[0].update],['b finished',true]);
  sent=p.roster([agent('a','working'),agent('b','working')]);
  assert.equal(ops(sent,'alertClear').length,1);
});
test('no alerts while the panel is open, and opening it clears the backlog',()=>{
  const p=page();p.roster([agent('a','working')]);
  p.window.receive({type:'visibility',data:{open:true}});
  assert.equal(ops(p.roster([agent('a','done')]),'alert').length+ops(p.messages,'alertPreview').length,0);
});

test('roster cards show how long ago the state changed, like the Claude app',()=>{
  const now=Date.UTC(2026,9,6,12);
  assert.equal(model.ago(now-20e3,now),'now');
  assert.equal(model.ago(now-4*60e3,now),'4m');
  assert.equal(model.ago(now-125*60e3,now),'2h');
  assert.equal(model.ago(now-3*1440*60e3,now),'3d');
  assert.equal(model.ago(now+5e3,now),'now');
});
