const {test}=require('node:test'),assert=require('node:assert/strict');
const {sorted,alerts,parse}=require('../Sources/HerdrHUD/Resources/model.js');
const row=(id,status)=>({id,terminal_id:id,agent_status:status,online:true});
test('attention before working before read idle',()=>assert.deepEqual(sorted([row('a','idle'),row('b','working'),row('c','blocked')],new Set()).map(a=>a.id),['c','b','a']));
test('status alerts exclude baseline, replacements, and offline recovery',()=>{assert.equal(alerts([],[row('a','done')]).length,0);assert.equal(alerts([row('a','working')],[row('a','done')]).length,1);assert.equal(alerts([row('a','working')],[{...row('a','done'),terminal_id:'new'}]).length,0);assert.equal(alerts([{...row('a','working'),online:false}],[row('a','done')]).length,0)});
test('provider fallback retains all text',()=>assert.equal(parse('plain text','claude').text,'plain text'));
test('Codex composer removed only with model footer',()=>{const p=parse('• Hello\n\n› Ask Codex to do anything\n  gpt-6-astra ultra · ~/repo','codex');assert.equal(p.model,'gpt-6-astra');assert.equal(p.reasoning,'ultra');assert.equal(p.blocks[0].text,'Hello');assert.equal(parse('quote gpt-6-astra\n› Keep this','codex').blocks.at(-1).text,'Keep this')});
test('tool blocks fold and code markers do not invent messages',()=>{const p=parse('• Ran test\n  output\n• Result\n```\n› not a prompt\n```','codex');assert.equal(p.blocks[0].kind,'tool');assert.equal(p.blocks.length,2);assert.match(p.blocks[1].text,/not a prompt/)});
const {labels,pane,preview}=require('../Sources/HerdrHUD/Resources/model.js');
const fs=require('node:fs'),path=require('node:path');
const claude=fs.readFileSync(path.join(__dirname,'fixtures/claude-transcript.txt'),'utf8');
test('Claude transcript becomes speaker turns, tools, subagents and status',()=>{
  const p=parse(claude,'claude'),kinds=p.blocks.map(b=>b.kind);
  assert.equal(p.model,'Opus 5.5');
  assert.deepEqual(kinds,['context','prompt','reply','tool','tool','agent','reply','tool','status','recap','status']);
  assert.equal(p.blocks[1].text,'the overlay text is hard to read, can you look at the parser\nand the stylesheet?');
  assert.equal(p.blocks[3].title,'Read 2 files');
  assert.deepEqual([p.blocks[4].title,p.blocks[4].detail],['Bash','npm test -- --reporter=dot']);
  assert.match(p.blocks[4].result,/12 passing/);
  assert.deepEqual([p.blocks[5].title,p.blocks[5].detail],['Explore','Find transcript rendering code']);
  assert.equal(p.blocks[8].text,'Brewed for 4m 38s · done Thursday 8:36 PM');
});
test('Claude prompt box, status line and fenced prompt markers never become messages',()=>{
  const p=parse(claude,'claude');
  assert.ok(!p.blocks.some(b=>/auto mode|40% of/.test(b.text)));
  assert.equal(p.blocks.filter(b=>b.kind==='prompt').length,1);
  assert.match(p.blocks[6].text,/```js\nconst terminal = mode === 'terminal';\n❯ not a prompt inside a fence\n```/);
  assert.match(p.blocks[6].text,/^Here is what I found:\n\n## Causes/);
});
test('Claude output without a prompt box keeps all text',()=>{const p=parse('⏺ Hello\n  world','claude');assert.equal(p.blocks[0].text,'Hello\nworld');});
test('roster names skip numeric tab labels and number duplicates',()=>{
  const a=(id,extra)=>({id,tab_id:'t'+id,workspace_label:'Documents',...extra});
  const names=labels([a('1',{tab_label:'1'}),a('2',{tab_label:'1'}),a('3',{tab_label:'deck audit'}),a('4',{tab_label:'2',workspace_label:'~'})]);
  assert.deepEqual([...names.values()],['Documents 1','Documents 2','deck audit','~']);
});
test('pane identity survives a session change and preview prefers the latest prompt',()=>{
  assert.equal(pane({machine_id:'local',pane_id:'w1:p1',agent_session:'a'}),pane({machine_id:'local',pane_id:'w1:p1',agent_session:'b'}));
  assert.notEqual(pane({machine_id:'local',pane_id:'w1:p1'}),pane({machine_id:'remote',pane_id:'w1:p1'}));
  assert.equal(pane({}),'');
  assert.equal(preview(parse(claude,'claude')),'the overlay text is hard to read, can you look at the parser and the stylesheet?');
});
const read=name=>fs.readFileSync(path.join(__dirname,`fixtures/claude-${name}.txt`),'utf8');
test('Claude permission prompt becomes a dialog block and the mode is read from the status line',()=>{
  const p=parse(read('permission'),'claude');
  assert.equal(p.mode,'Accept edits');assert.equal(p.model,'Opus 5.5');
  assert.deepEqual(p.blocks.map(b=>b.kind),['prompt','reply','tool','dialog']);
  assert.equal(p.dialog.type,'permission');assert.equal(p.dialog.title,'Bash command');
  assert.equal(p.dialog.detail,'rm -rf build/\nRemove stale build output');
  assert.equal(p.dialog.question,'Do you want to proceed?');
  assert.deepEqual(p.dialog.options.map(o=>[o.n,o.selected]),[[1,true],[2,false],[3,false]]);
});
test('Claude AskUserQuestion becomes a question dialog with option descriptions',()=>{
  const p=parse(read('question'),'claude');
  assert.deepEqual(p.blocks.map(b=>b.kind),['prompt','reply','dialog']);
  assert.equal(p.dialog.type,'question');assert.equal(p.dialog.title,'Quarter');
  assert.equal(p.dialog.question,'Which quarter should slide 7 report?');
  assert.equal(p.dialog.options[0].description,'What the spreadsheet has today');
  assert.equal(p.dialog.options.length,3);
});
test('a reply that asks a question with a numbered list is not a dialog',()=>{
  const p=parse('⏺ Do you want to proceed with one of these?\n\n  1. Merge now\n  2. Wait for review','claude');
  assert.equal(p.dialog,null);assert.equal(p.blocks[0].kind,'reply');
  assert.equal(parse(claude,'claude').mode,'Auto');
});
test('AskUserQuestion menus keep options across the rule drawn inside the menu',()=>{
  // Layout from herdrdev/herdr#4824: a rule above "Chat about this" and one below the footer.
  const p=parse(read('question-rules'),'claude');
  assert.deepEqual(p.blocks.map(b=>b.kind),['reply','dialog']);
  assert.equal(p.dialog.question,'Which palette should the badges use?');
  assert.equal(p.dialog.title,'Palette');
  assert.deepEqual(p.dialog.options.map(o=>o.label),['Warm','Cool','High contrast','Type something.','Chat about this']);
  assert.equal(p.dialog.options.find(o=>o.selected).n,4);
  assert.equal(p.dialog.options[2].description,'Pure colors for bright game scenes');
});
test('real Claude Code screen from a user report: ● markers, hook results, update notice, 1M footer',()=>{
  const p=parse(read('real-footer'),'claude');
  assert.equal(p.model,'Opus 5.5');assert.equal(p.mode,'');assert.equal(p.dialog,null);
  assert.deepEqual(p.blocks.map(b=>b.kind),['context','tool','status','status']);
  assert.equal(p.blocks[1].title,'Ran 4 stop hooks');assert.match(p.blocks[1].result,/node: command not found/);
  assert.equal(p.blocks[3].text,'✔ Update installed · Restart to update');
  assert.ok(!p.blocks.some(b=>/cleanup on these folders/.test(b.text)));
});
test('a no-break space after the ❯ prompt still strips the prompt box',()=>{
  const p=parse(read('real-footer').replace('❯ \n','❯\u00a0\n'),'claude');
  assert.ok(!p.blocks.some(b=>/cleanup on these folders|1000k/.test(b.text)));assert.equal(p.model,'Opus 5.5');
});
require('../Sources/HerdrHUD/Resources/render.js');
const {boxTable}=globalThis.HUDRender;
test('Claude box tables rebuild into rows with wrapped cells joined',()=>{
  const p=parse(fs.readFileSync(path.join(__dirname,'fixtures/claude-box-table.txt'),'utf8'),'claude');
  const lines=p.blocks[0].text.split('\n').filter(l=>/^\s*[┌├└│]/.test(l));
  const grid=boxTable(lines);
  assert.deepEqual(grid.head,['Project','What happened','Outcome']);
  assert.deepEqual(grid.rows[0],['Mountain Gate','stopped one phase into its plan','ran to schedule; next cycle 2030']);
  assert.equal(grid.rows.length,3);
  assert.deepEqual(grid.rows[2],['`harbor.js`','**paused** for review','pending']);
});
test('box tables with only a header rule keep one row per line; box art stays art',()=>{
  const grid=boxTable(['┌───┬───┐','│ a │ b │','├───┼───┤','│ 1 │ 2 │','│ 3 │ 4 │','└───┴───┘']);
  assert.deepEqual(grid,{head:['a','b'],rows:[['1','2'],['3','4']]});
  assert.equal(boxTable(['╭──────╮','│ hi   │','╰──────╯']),null);
  assert.equal(boxTable(['│ a │ b │','│ c │']),null);
});
