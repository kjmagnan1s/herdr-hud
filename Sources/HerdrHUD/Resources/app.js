'use strict';
const $=id=>document.getElementById(id);
const post=data=>window.webkit?.messageHandlers?.hud ? window.webkit.messageHandlers.hud.postMessage(data) : window.chrome.webview.postMessage(data);
if(window.chrome?.webview)window.chrome.webview.addEventListener('message',event=>window.receive(event.data));
let agents=[],selected='',opened=false,mode='chat',filter='',reading=false,sending=false,requestSequence=0,lastOutput='',lastRendered='',selectionEpoch=0;
let baseline=false,unread=new Set(),drafts=new Map(),outputs=new Map(),since=new Map(),uncertain=new Set(),promptByRequest=new Map();
let names=new Map(),parsed=new Map(),failed=new Set(),wantSelected=false;
const chatProviders=new Set(['codex','claude']);
if(window.webkit?.messageHandlers?.hud)document.documentElement?.classList.add('glass'); // macOS draws a native blur behind the page.
function request(op,extra={}){const requestID=`${Date.now()}-${++requestSequence}`;post({op,requestID,...extra});return requestID;}
function active(){return agents.find(a=>a.id===selected);}
function name(a){return names.get(a.id)||a.tab_label||a.name||a.pane_id||'Agent';}
function parsedOutput(id,provider){const text=outputs.get(id)?.text||'';const hit=parsed.get(id);if(hit?.text===text&&hit.provider===provider)return hit.data;const data=HUDModel.parse(text,provider);parsed.set(id,{text,provider,data});return data;}
// Herdr can report an open Claude question menu as idle (herdrdev/herdr#4824).
// When the last read shows a live dialog, treat the agent as blocked so the HUD
// never offers to type into the menu.
function status(a){if(!a)return '';if(a.agent_status!=='blocked'&&typeof HUDModel!=='undefined'&&outputs.has(a.id)&&parsedOutput(a.id,a.agent).dialog)return 'blocked';return a.agent_status||'';}
function stateLabel(a){return !a.online?'Offline':status(a)==='blocked'?'Needs input':a.agent_status==='working'?'Working':unread.has(a.id)?'New':a.agent_status==='done'?'Done':a.agent_status==='idle'?'Idle':'Unknown';}
function stateClass(a){return !a.online?'offline':status(a)==='blocked'?'blocked':a.agent_status==='working'?'working':unread.has(a.id)?'unread':a.agent_status==='done'?'done':'idle';}
function el(tag,text,cls){const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;}
function notice(text){$('notice').hidden=!text;$('notice').textContent=text;}
function badge(){post({op:'badge',count:agents.filter(a=>status(a)==='blocked'||unread.has(a.id)).length});}
// Two-character label for the narrow roster rail: "Documents 2" → "D2", "herdr-hud" → "HH".
function initials(text){const words=String(text).split(/[\s_.-]+/).filter(Boolean);const tail=/\d+$/.exec(text)?.[0];return ((words[0]?.[0]||'?')+(tail||words[1]?.[0]||words[0]?.[1]||'')).toUpperCase().slice(0,3);}
function renderRoster(){
  $('count').textContent=agents.length;const roster=$('roster'),scroll=roster.scrollTop,multiMachine=new Set(agents.map(a=>a.machine_id)).size>1;
  const items=HUDModel.sorted(agents,unread).filter(a=>`${name(a)} ${a.workspace_label} ${a.machine_label} ${a.agent}`.toLowerCase().includes(filter));
  roster.replaceChildren(...items.map(a=>{const state=stateClass(a);const button=el('button',undefined,'agent '+state+(a.id===selected?' selected':''));button.setAttribute('aria-pressed',String(a.id===selected));
    const metadata=parsedOutput(a.id,a.agent),preview=metadata.dialog&&status(a)==='blocked'?metadata.dialog.question||metadata.dialog.title:HUDModel.preview(metadata);
    const meta=[a.workspace_label||a.workspace_id,a.agent||'agent'];if(metadata.mode)meta.push(metadata.mode==='Ask'?'Asks permission':`${metadata.mode} mode`);if(multiMachine)meta.push(a.machine_label);
    button.append(el('span',undefined,'dot '+state),el('span',name(a),'agent-name'),el('span',stateLabel(a),'badge '+state),el('span',initials(name(a)),'agent-abbr'));
    if(preview)button.append(el('span',preview,'agent-sub'));
    button.append(el('span',meta.filter(Boolean).join(' · '),'agent-meta'));
    button.title=[name(a)+' · '+stateLabel(a),meta.join(' · '),metadata.model&&`${metadata.model} ${metadata.reasoning}`.trim()].filter(Boolean).join('\n');button.onclick=()=>select(a.id);return button;}));
  if(!items.length)roster.append(el('p',agents.length?'No matching agents.':'No agents found. Start an agent in Herdr.','empty'));roster.scrollTop=scroll;
}
function select(id){
  drafts.set(selected,$('prompt').value);selected=id;request('preferences',{selectedAgent:id});selectionEpoch++;lastRendered='';$('prompt').value=drafts.get(id)||'';
  lastOutput=outputs.get(id)?.text||'';renderRoster();renderHeader();renderOutput();wantSelected=true;read();
}
// An agent's id changes when its session starts or restarts in the same pane.
// Keep the user looking at that pane, with their draft and any send guard intact.
function rebind(oldID,newID){
  if(drafts.has(oldID)){drafts.set(newID,drafts.get(oldID));drafts.delete(oldID);}
  if(uncertain.has(oldID)){uncertain.add(newID);uncertain.delete(oldID);}
  if(outputs.has(oldID)&&!outputs.has(newID))outputs.set(newID,{...outputs.get(oldID),id:newID});
  if(selected===oldID){selected=newID;request('preferences',{selectedAgent:newID});lastRendered='';}
}
function renderHeader(){
  const a=active();$('title').textContent=a?name(a):'Select an agent';const mode=a&&typeof HUDModel!=='undefined'?parsedOutput(a.id,a.agent).mode:'';$('identity').textContent=a?[a.workspace_label,a.machine_label,a.agent,mode&&(mode==='Ask'?'asks permission':`${mode.toLowerCase()} mode`)].filter(Boolean).join(' · '):'Your configured Herdr machines appear automatically';
  const state=status(a);const busy=state==='working';$('working').hidden=!busy;
  if(busy&&!since.has(a.id))since.set(a.id,Date.now());
  $('send').disabled=!a?.online||!['idle','done'].includes(state)||sending||uncertain.has(selected)||!$('prompt').value.trim();
  $('prompt').disabled=!a;$('chat').disabled=!chatProviders.has(a?.agent);
  $('send-status').textContent=sending?'Sending once…':uncertain.has(selected)?'Delivery uncertain. Inspect this agent in Herdr before sending again.':!a?'Choose an agent to get started.':!a.online?'Machine offline. Your draft is retained.':state==='blocked'?'Needs your input in Herdr. Native approvals remain in its terminal.':busy?'Agent is working. You can draft the next prompt here.':['idle','done'].includes(state)?'Ready for your next prompt.':'Agent state is unknown. Sending is disabled.';
  $('reconcile').hidden=!uncertain.has(selected);
}
function inline(text,parent){HUDRender.inline(text,parent);} // No terminal text is ever interpreted as HTML.
// Raw screen text. Box-drawn tables keep their columns: they never wrap and
// shrink to fit the panel, scrolling sideways past a readable floor. Divider
// rules clip to the panel. Other lines wrap under their own indent and bullet,
// so wrapped text stays aligned instead of falling back to the left edge.
const BOX_LINE=/^\s*[┌├└│╭╰┃╞╘┐┤┘╮╯]/,RULE_LINE=/^\s*[─━]{8,}\s*$/,HANG=/^([-*•●⎿]|\d{1,3}[.)])\s+/;
function terminalText(text){
  const pre=el('pre',undefined,'term'),lines=text.split('\n');
  for(let i=0;i<lines.length;i++){
    const line=lines[i];
    if(BOX_LINE.test(line)){const rows=[];while(i<lines.length&&(BOX_LINE.test(lines[i])||RULE_LINE.test(lines[i])&&BOX_LINE.test(lines[i+1]||'')))rows.push(lines[i++]);i--;pre.append(el('span',rows.join('\n'),'term-box'));continue;}
    if(RULE_LINE.test(line)){pre.append(el('span',line.trim(),'term-rule'));continue;}
    const body=line.trimStart(),indent=line.length-body.length,hang=(HANG.exec(body)?.[0].length)||0,row=el('span',body||' ','term-line');
    row.style.paddingLeft=`${indent+hang}ch`;if(hang)row.style.textIndent=`-${hang}ch`;pre.append(row);
  }
  return pre;
}
function fitTerminal(){
  for(const box of $('output').querySelectorAll('pre.term > .term-box')){
    box.style.fontSize='';if(box.scrollWidth<=box.clientWidth)continue;
    box.style.fontSize=Math.max(9,parseFloat(getComputedStyle(box).fontSize)*box.clientWidth/box.scrollWidth-.1)+'px';
  }
}
function renderOutput(){
  const a=active(),out=$('output'),data=HUDModel.parse(lastOutput,a?.agent||'');const terminal=mode==='terminal'||!chatProviders.has(a?.agent);
  const signature=JSON.stringify([selected,lastOutput,terminal]);if(signature===lastRendered)return;const wasBottom=out.scrollHeight-out.scrollTop-out.clientHeight<70,scroll=out.scrollTop;const first=!lastRendered;lastRendered=signature;
  const expanded=new Set([...out.querySelectorAll('details[open]')].map(n=>n.dataset.key));out.replaceChildren();out.classList.toggle('terminal',terminal);
  if(!lastOutput)out.append(el('p',a?'Loading recent output…':'Select an agent to read its recent output.','empty'));
  else if(terminal||!data.blocks.length)out.append(terminalText(data.text));
  else HUDRender.conversation(out,data,a,expanded);
  if(data.model){$('title').title=`${data.model} ${data.reasoning}`.trim();}
  $('chat').setAttribute('aria-pressed',String(!terminal));$('terminal').setAttribute('aria-pressed',String(terminal));
  fitTerminal();out.scrollTop=first||wasBottom?out.scrollHeight:scroll;
}
function read(){if(!opened||reading||!active()?.online)return;reading=true;wantSelected=false;request('output',{id:selected});}
// While the panel is open and idle, load agents the HUD has not read yet, one at
// a time, so switching to them shows their conversation immediately.
function prefetch(){if(!opened||reading)return;const next=agents.find(a=>a.online&&a.id!==selected&&!outputs.has(a.id)&&!failed.has(a.id));if(!next)return;reading=true;request('output',{id:next.id});}
function send(){if($('send').disabled)return;const id=selected,message=$('prompt').value;sending=true;notice('');const requestID=request('prompt',{id,message});promptByRequest.set(requestID,{id,message});renderHeader();}
window.receive=({type,data})=>{
  if(type==='roster'){
    const before=agents;agents=data.agents||[];
    if(baseline)for(const a of agents){const old=before.find(b=>b.id===a.id);if(old&&a.online&&old.online&&old.agent_status!==a.agent_status)unread.add(a.id);}
    const updates=baseline?HUDModel.alerts(before,agents):[];baseline=true;
    for(const a of agents){if(a.agent_status==='working'&&!since.has(a.id))since.set(a.id,Date.now());if(a.agent_status!=='working')since.delete(a.id);}
    const valid=new Set(agents.map(a=>a.id));names=HUDModel.labels(agents);
    for(const old of before)if(!valid.has(old.id)){const next=agents.find(a=>!before.some(b=>b.id===a.id)&&HUDModel.pane(a)&&HUDModel.pane(a)===HUDModel.pane(old));if(next){rebind(old.id,next.id);if(unread.has(old.id))unread.add(next.id);}}
    unread=new Set([...unread].filter(id=>valid.has(id)));for(const id of [...outputs.keys(),...parsed.keys()])if(!valid.has(id)){outputs.delete(id);parsed.delete(id);}failed=new Set([...failed].filter(id=>valid.has(id)));
    if(updates.length&&!opened){const a=updates[0];request('alertPreview',{id:a.id,title:name(a)+(a.agent_status==='blocked'?' needs input':' finished')});}
    $('machines').replaceChildren(...(data.machines||[]).map(m=>{const node=el('span',undefined,'machine');node.append(el('span',undefined,'dot '+(m.online?'online':'')),document.createTextNode(`${m.label} · ${m.online?`${m.count} agents`:'offline'}`));node.title=m.error||'';return node;}));
    if(data.discoveryError)notice('Herdr setup: '+data.discoveryError);
    if((!selected||!valid.has(selected))&&agents.length)select(agents[0].id);renderRoster();renderHeader();badge();read();prefetch();
  }else if(type==='visibility'){opened=data.open;if(opened){renderHeader();wantSelected=true;read();}}
  else if(type==='resetBaseline'){baseline=false;}
  else if(type==='select'){select(data.id);}
  else if(type==='alertPreview'){if(!opened){const parsed=HUDModel.parse(data.text,data.provider),reply=parsed.dialog?[parsed.dialog.title,parsed.dialog.question].filter(Boolean).join(': '):parsed.blocks.filter(x=>x.kind==='reply').at(-1)?.text||'';post({op:'alert',id:data.id,title:data.title,preview:reply.replace(/\s+/g,' ').slice(0,200)||'Click to read the latest output'});}}
  else if(type==='output'){
    reading=false;if(data.error){if(data.id===selected)notice(data.error);else failed.add(data.id);if(wantSelected)read();else prefetch();return;}
    outputs.set(data.id,data);if(data.id!==selected){renderRoster();if(wantSelected)read();else prefetch();return;}
    lastOutput=data.text;notice('');if(opened){unread.delete(selected);badge();}renderOutput();renderRoster();prefetch();
  }else if(type==='prompt'){
    const pending=promptByRequest.get(data.requestID);if(!pending)return;promptByRequest.delete(data.requestID);sending=false;
    if(data.error){notice(data.error);if(/uncertain/i.test(data.error))uncertain.add(pending.id);}
    else{if(selected===pending.id&&$('prompt').value===pending.message)$('prompt').value='';if(drafts.get(pending.id)===pending.message)drafts.delete(pending.id);notice('Prompt sent.');request('refresh');}renderHeader();
  }else if(type==='preferences'){if(data.selectedAgent&&!selected)selected=data.selectedAgent;if(data.rosterWidth>=56)document.querySelector('aside').style.width=data.rosterWidth+'px';mode=data.mode||'chat';}
  else if(type==='notice'){notice(data.message);}
};
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!event.isComposing){event.preventDefault();request('close');}});
$('refresh').onclick=()=>request('refresh');$('close').onclick=()=>request('close');$('hide').onclick=()=>request('hide');$('send').onclick=send;
$('reconcile').onclick=()=>{uncertain.delete(selected);notice('');renderHeader();};
$('search').oninput=()=>{filter=$('search').value.toLowerCase();renderRoster();};
$('prompt').oninput=()=>{drafts.set(selected,$('prompt').value);renderHeader();};
$('prompt').onkeydown=e=>{
  if(e.key!=='Enter'||e.isComposing||e.keyCode===229)return;
  // Modifier-Enter always inserts a newline, including Control on macOS,
  // whose native textarea behavior is not consistently a line break.
  e.preventDefault();
  if(e.shiftKey||e.ctrlKey||e.metaKey||e.altKey){
    const input=$('prompt');input.setRangeText('\n',input.selectionStart,input.selectionEnd,'end');
    input.dispatchEvent(new Event('input',{bubbles:true}));
  }else if(!e.repeat){send();}
};
if(typeof ResizeObserver==='function')new ResizeObserver(()=>fitTerminal()).observe($('output'));
for(const view of ['chat','terminal'])$(view).onclick=()=>{mode=view;request('preferences',{mode});lastRendered='';renderOutput();};
const divider=$('divider');divider.onpointerdown=e=>{divider.setPointerCapture(e.pointerId);};divider.onpointermove=e=>{if(divider.hasPointerCapture(e.pointerId)){const aside=document.querySelector('aside');aside.style.width=Math.min(Math.max(e.clientX-aside.getBoundingClientRect().left,56),innerWidth*.42)+'px';}};
divider.onpointerup=()=>request('preferences',{rosterWidth:document.querySelector('aside').offsetWidth});
divider.onkeydown=e=>{if(['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();const aside=document.querySelector('aside');aside.style.width=Math.min(Math.max(aside.offsetWidth+(e.key==='ArrowLeft'?-15:15),56),innerWidth*.42)+'px';request('preferences',{rosterWidth:aside.offsetWidth});}};
setInterval(()=>{const a=active();if(a?.agent_status==='working'){const seconds=Math.max(0,Math.floor((Date.now()-(since.get(a.id)||Date.now()))/1000));$('work-text').textContent=`Working · ${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')} observed`; }},1000);
request('ready');
// Read-only integration check used by --verify-ui; never presses Send.
window.verifyControls=async()=>{
  const saved={selected,filter,mode,draft:$('prompt').value,drafts:new Map(drafts)},results={};
  const wait=async predicate=>{const end=Date.now()+22000;while(!predicate()){if(Date.now()>end)throw Error('Timed out waiting for agent output');await new Promise(r=>setTimeout(r,100));}};
  try{
    const local=agents.find(a=>a.machine_id==='local'&&a.online),remote=agents.find(a=>a.machine_id!=='local'&&a.online);
    if(!local||!remote)throw Error('This check requires one local and one remote agent');
    select(local.id);await wait(()=>outputs.has(local.id)&&!reading);results.localOutput=outputs.get(local.id).text.length>0;
    $('prompt').value='HUD verification draft — never submitted';$('prompt').dispatchEvent(new Event('input'));
    select(remote.id);await wait(()=>outputs.has(remote.id)&&!reading);results.remoteOutput=outputs.get(remote.id).text.length>0;
    select(local.id);results.draftPreserved=$('prompt').value==='HUD verification draft — never submitted';
    $('terminal').click();results.terminalView=$('output').querySelector('pre')!==null;
    $('chat').click();results.chatView=$('chat').getAttribute('aria-pressed')==='true';
    $('search').value='a-nonexistent-agent-filter';$('search').dispatchEvent(new Event('input'));results.searchFilters=$('roster').querySelectorAll('.agent').length===0;
    const test=el('div');inline('<img src=x onerror=alert(1)>',test);results.transcriptIsText=test.querySelector('img')===null&&test.textContent.includes('<img');
    results.layoutFits=document.body.scrollWidth<=innerWidth&&document.body.scrollHeight<=innerHeight;
    results.pass=Object.values(results).every(Boolean);return results;
  }finally{drafts=new Map(saved.drafts);filter=saved.filter;mode=saved.mode;$('search').value=saved.filter;select(saved.selected);$('prompt').value=saved.draft;drafts=new Map(saved.drafts);request('preferences',{mode});renderHeader();renderOutput();}
};
