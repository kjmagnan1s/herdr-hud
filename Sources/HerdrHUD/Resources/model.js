/* MIT — transcript parser and roster semantics shared by desktop shells. */
(function(root){
  function priority(a,unread){return a.agent_status==='blocked'||unread.has(a.id)?0:a.agent_status==='working'?1:2;}
  function sorted(agents,unread){return agents.map((agent,index)=>({agent,index})).sort((a,b)=>priority(a.agent,unread)-priority(b.agent,unread)||a.index-b.index).map(x=>x.agent);}
  function identity(a){return JSON.stringify([a.id,a.terminal_id,a.agent_session||null]);}
  function alerts(previous,current){const old=new Map(previous.map(a=>[a.id,a]));return current.filter(a=>{const b=old.get(a.id);return a.online&&b?.online&&identity(a)===identity(b)&&((a.agent_status==='blocked'&&b.agent_status!=='blocked')||(b.agent_status==='working'&&['idle','done'].includes(a.agent_status)));});}

  // The pane an agent runs in. Its id changes when the agent's session starts or
  // restarts, but the pane is the same place the user was looking at.
  function pane(a){return a?.pane_id?JSON.stringify([a.machine_id||'',a.pane_id]):'';}

  // Herdr names tabs "1", "2"… by default, so a tab label alone often says nothing.
  // Prefer a custom tab label, then the agent name, then the workspace, and number
  // the duplicates so every row in the roster is distinguishable.
  function baseName(a){
    const tab=String(a.tab_label||'');
    if(tab&&tab!==a.tab_id&&!/^\d+$/.test(tab))return tab;
    return a.name||a.workspace_label||a.workspace_id||a.pane_id||'Agent';
  }
  function labels(agents){
    const counts=new Map(),seen=new Map(),out=new Map();
    for(const a of agents){const n=baseName(a);counts.set(n,(counts.get(n)||0)+1);}
    for(const a of agents){const n=baseName(a);const i=(seen.get(n)||0)+1;seen.set(n,i);out.set(a.id,counts.get(n)>1?`${n} ${i}`:n);}
    return out;
  }

  function dedent(lines){
    const indents=lines.filter(l=>l.trim()).map(l=>l.match(/^ */)[0].length);
    const cut=indents.length?Math.min(...indents):0;
    return lines.map(l=>l.slice(cut));
  }
  const trimBlank=lines=>{let a=0,b=lines.length;while(a<b&&!lines[a].trim())a++;while(b>a&&!lines[b-1].trim())b--;return lines.slice(a,b);};

  function parseCodex(text){
    let model='',reasoning='',lines=text.trimEnd().split('\n');
    const footer=/^\s*(gpt-[\w.-]+|o[134](?:-[\w.-]+)?|codex-[\w.-]+)(?:\s+(minimal|low|medium|high|xhigh|max|ultra))?\s+[·|]\s*.+$/.exec(lines.at(-1)||'');
    if(footer){for(let i=lines.length-2;i>=Math.max(0,lines.length-14);i--){if(/^\s*[›❯»](?:\s|$)/.test(lines[i])){model=footer[1];reasoning=footer[2]||'';lines=lines.slice(0,i);break;}if(lines[i].trim()&&(!lines[i].startsWith('  ')||/^\s*•/.test(lines[i])))break;}}
    let kind='context',body=[],fenced=false,blocks=[];
    const flush=()=>{const text=body.join('\n').trim();if(text){const block={kind,text};if(kind==='tool'){const [title,...rest]=text.split('\n');block.title=title;block.result=dedent(rest).join('\n').trim();}blocks.push(block);}body=[];};
    for(const line of lines){const marker=!fenced&&/^([›❯»•●])(?: |$)(.*)/.exec(line),status=!fenced&&/^[─━]+ (Worked for .+|Conversation recap.*)/.exec(line);
      if(marker||status){flush();if(status){kind='status';body=[line.replace(/[─━]/g,'').trim()];}else{kind=/[›❯»]/.test(marker[1])?'prompt':/^(Ran |Explored\b|Viewed Image\b|Searched (for|the web)|Edited .+\(\+|Added .+\(\+|Deleted .+\(-|Interacted with background terminal\b)/.test(marker[2])?'tool':'reply';body=[marker[2]];}}
      else body.push(line);if(line.trimStart().startsWith('```'))fenced=!fenced;
    }flush();return {text:lines.join('\n').trimEnd(),model,reasoning,blocks};
  }

  // Claude Code's TUI, as Herdr reads it back:
  //   ❯ prompt            (or "> prompt" in older releases)
  //   ⏺ reply text        continuation lines are indented two spaces
  //   ⏺ Bash(npm test)    a tool call; "  ⎿  …" lines below it are its result
  //   ⏺ Task(Explore X)   a subagent; its result says "Done (12 tool uses · …)"
  //   ✻ Brewed for 4m 38s status lines start at column 0 with a spinner glyph
  //   ※ recap: …          the session recap
  // followed by the prompt box (rule, ❯ input, rule) and the status line.
  const CLAUDE={
    rule:/^\s*[─━]{8,}\s*$/,
    prompt:/^[>❯](?: (.*)|$)/,
    reply:/^[⏺●](?:︎|️)? ?(.*)$/,
    result:/^ {1,6}⎿ ?\s?(.*)$/,
    status:/^[✻✽✶✳✢✺·*∴] +(.+)$/,
    recap:/^※ *(?:recap:? *)?(.*)$/i,
    tool:/^([A-Z][\w.-]*|[\w.-]+ - [\w.-]+(?: \(MCP\))?)\((.*?)\)?\s*$/,
    summary:/^(?:(?:Read|Searched for|Listed|Wrote|Updated|Edited|Ran|Fetched|Found|Called|Explored|Created|Deleted)\s+\d.*|.*\(ctrl\+[or] to (?:expand|show).*\))$/,
    agents:/^(Task|Agent|Explore|Plan|general-purpose|[\w-]+-agent)$/,
    agentResult:/\d+ tool uses?\b/,
    model:/\b(Opus|Sonnet|Haiku|Fable)\s*([\d.]+)/i
  };
  const MODES={'auto mode':'Auto','accept edits':'Accept edits','plan mode':'Plan','bypass permissions':'Bypass'};
  Object.assign(CLAUDE,{
    mode:/(auto mode|accept edits|plan mode|bypass permissions) on\b/i,
    statusLine:/^\s+.*\b(?:Opus|Sonnet|Haiku|Fable)\s*[\d.]+.*[|·]/,
    option:/^(\s*)(❯\s*)?(\d{1,2})[.)]\s+(.+)$/,
    ask:/(Enter to select|Esc to cancel|↑\/↓ to navigate|Tab to amend)/i,
    boxTop:/^\s*╭/,boxBottom:/^\s*╰/
  });
  // A permission prompt or AskUserQuestion dialog waiting at the bottom of the
  // screen. Box drawing is stripped; options keep their numbers and the cursor.
  function extractDialog(lines){
    const from=Math.max(0,lines.length-45);let anchor=-1;
    for(let i=lines.length-1;i>=from;i--){const t=lines[i].replace(/^[\s│┃]+|[\s│┃]+$/g,'');if(CLAUDE.ask.test(t)||/^❯\s*\d{1,2}[.)]\s/.test(t)){anchor=i;break;}}
    if(anchor<0)return null;
    // Walk up to the dialog's top edge. AskUserQuestion draws rules inside its
    // menu (above "Chat about this"), so a rule only ends the dialog once the
    // walk has passed option 1.
    let start=anchor,passedFirst=false;
    const optionAt=i=>CLAUDE.option.exec(lines[i].replace(/^\s*[│┃]/,''));
    for(let i=anchor;i>=from;i--){
      if(CLAUDE.boxTop.test(lines[i])){start=i;break;}
      if(CLAUDE.rule.test(lines[i])){
        let j=i-1;while(j>=from&&!lines[j].trim())j--;
        if(!passedFirst&&j>=from&&(optionAt(j)||/^\s{3,}\S/.test(lines[j]))){start=i;continue;}
        start=i;break;
      }
      const option=optionAt(i);if(option&&Number(option[3])===1)passedFirst=true;
      if(i<anchor&&!option&&(CLAUDE.reply.test(lines[i])||CLAUDE.prompt.test(lines[i])||CLAUDE.status.test(lines[i]))){start=i+1;break;}
      start=i;
    }
    const raw=lines.slice(start).filter(l=>!CLAUDE.boxTop.test(l)&&!CLAUDE.boxBottom.test(l)&&!CLAUDE.rule.test(l)).map(l=>l.replace(/^\s*[│┃]/,'').replace(/[│┃]\s*$/,'').replace(/\s+$/,''));
    const body=trimBlank(dedent(raw));
    const options=[],text=[],hints=[];
    for(const line of body){
      const m=CLAUDE.option.exec(line);
      if(m){options.push({n:Number(m[3]),label:m[4].trim(),selected:!!m[2]});continue;}
      if(/(Enter to select|Esc to cancel|↑\/↓|Tab to amend|ctrl\+\w to)/i.test(line)){hints.push(line.trim());continue;}
      if(options.length&&/^\s{2,}\S/.test(line)){const last=options.at(-1);last.description=[last.description,line.trim()].filter(Boolean).join(' ');continue;}
      if(!options.length)text.push(line);
    }
    // Only a live cursor on a numbered option or the dialog's key hints count, so
    // a reply that merely asks a question never becomes a dialog.
    if(!options.length||!(options.some(o=>o.selected)||hints.length))return null;
    const content=trimBlank(text),qi=content.map(l=>l.trim()).findLastIndex(l=>/\?$/.test(l));
    const question=qi>=0?content[qi].trim():'';
    const before=qi>=0?content.slice(0,qi):content;
    let title=(before.find(l=>l.trim())||'').trim();
    // A multi-question tab bar ("← ☐ Color  ☐ Size  ✔ Submit →") is not a title.
    title=(title.match(/[☐☒✔]/g)||[]).length>1?'':title.replace(/^[☐☒✔]\s*/,'');
    const detail=trimBlank(dedent(before.slice(before.findIndex(l=>l.trim())+1))).join('\n');
    const kind=/Do you want to|Would you like to/i.test(question)?'permission':'question';
    return {start,type:kind,title:title===question?'':title,detail,question,options,hint:hints.join(' · ')};
  }
  function parseClaude(text){
    // Claude Code pads its ❯ prompt with a no-break space; normalize it first.
    let lines=text.replace(/\r/g,'').replace(/\u00a0/g,' ').trimEnd().split('\n'),model='',reasoning='',footer=[];
    // Strip the prompt box and status line: the last ❯ line that sits under a rule.
    for(let i=lines.length-1;i>=Math.max(0,lines.length-40);i--){
      if(!CLAUDE.prompt.test(lines[i])||/^❯\s*\d{1,2}[.)]\s/.test(lines[i]))continue;
      let j=i-1;while(j>=0&&!lines[j].trim())j--;
      if(j>=0&&CLAUDE.rule.test(lines[j])){footer=lines.slice(j);lines=lines.slice(0,j);break;}
    }
    // While a dialog is open the prompt box is gone, so the status line sits
    // directly under the transcript. Peel it off the end as well.
    if(!footer.length){let k=lines.length;while(k>0&&(!lines[k-1].trim()||CLAUDE.statusLine.test(lines[k-1])||CLAUDE.mode.test(lines[k-1])))k--;if(k<lines.length&&lines.slice(k).some(l=>l.trim())){footer=lines.slice(k);lines=lines.slice(0,k);}}
    const footerText=footer.join('\n'),found=CLAUDE.model.exec(footerText);if(found)model=`${found[1][0].toUpperCase()}${found[1].slice(1).toLowerCase()} ${found[2]}`;
    // Only a mode Claude Code names is shown; a missing line may just be off screen.
    const modeMatch=CLAUDE.mode.exec(footerText),mode=modeMatch?MODES[modeMatch[1].toLowerCase()]:'';
    const dialog=extractDialog(lines);if(dialog)lines=lines.slice(0,dialog.start);
    const blocks=[];let block=null,fenced=false;
    const flush=()=>{
      if(!block)return;
      const body=dedent(block.body),result=trimBlank(dedent(block.resultLines||[]));
      const head=block.head.trim().replace(/\s*\(ctrl\+[or] to (?:expand|show)[^)]*\)$/,'');
      if(block.kind==='tool'){
        const call=CLAUDE.tool.exec(head);
        block.title=call?call[1]:head;block.detail=call?call[2]:'';
        block.result=trimBlank([...body,...result]).join('\n');
        if((call&&CLAUDE.agents.test(call[1]))||CLAUDE.agentResult.test(result.join(' ')))block.kind='agent';
        block.text=[head,block.result].filter(Boolean).join('\n');
      }else{
        block.text=[head,...body].join('\n').trim();
        if(result.length)block.result=result.join('\n');
      }
      delete block.body;delete block.head;delete block.resultLines;
      if(block.text)blocks.push(block);block=null;
    };
    const start=(kind,head)=>{flush();block={kind,head,body:[]};};
    for(const line of lines){
      if(fenced){block?.body.push(line);if(line.trim().startsWith('```'))fenced=false;continue;}
      let m;
      if((m=CLAUDE.prompt.exec(line))){start('prompt',m[1]||'');continue;}
      if((m=CLAUDE.reply.exec(line))){const head=m[1];start(CLAUDE.summary.test(head)||CLAUDE.tool.test(head)?'tool':'reply',head);continue;}
      if((m=CLAUDE.recap.exec(line))){start('recap',m[1]);continue;}
      if((m=CLAUDE.status.exec(line))){start('status',m[1]);flush();continue;}
      if(block&&(m=CLAUDE.result.exec(line))){(block.resultLines??=[]).push(m[1]);continue;}
      if(!line.trim()){if(block)(block.resultLines?block.resultLines:block.body).push('');continue;}
      if(/^\s/.test(line)){
        if(!block)block={kind:'context',head:'',body:[]};
        if(block.resultLines)block.resultLines.push(line.replace(/^ {5}/,''));else block.body.push(line);
        if(line.trim().startsWith('```'))fenced=true;
        continue;
      }
      // A column-0 line without a marker is a system hint ("new task? /clear …").
      start('status',line);flush();
    }
    flush();
    if(dialog){delete dialog.start;blocks.push({kind:'dialog',text:[dialog.title,dialog.question].filter(Boolean).join('\n'),...dialog});}
    return {text:lines.join('\n').trimEnd(),model,reasoning,mode,dialog,blocks};
  }

  function parse(text,provider){
    if(provider==='codex')return parseCodex(text);
    if(provider==='claude')return parseClaude(text);
    return {text,model:'',reasoning:'',blocks:[]};
  }
  const chatProviders=new Set(['codex','claude']);

  // Latest thing the user asked, for the roster preview line.
  function preview(parsed){
    const prompt=parsed.blocks.filter(b=>b.kind==='prompt').at(-1)?.text;
    const reply=parsed.blocks.filter(b=>b.kind==='reply'||b.kind==='recap').at(-1)?.text;
    return (prompt||reply||'').replace(/\s+/g,' ').trim().slice(0,140);
  }

  // One toast for every alert the user has not looked at yet: needs input
  // first, then finished. items are {agent, tone:'blocked'|'done'}.
  function summary(items,nameOf){
    const blocked=items.filter(i=>i.tone==='blocked'),done=items.filter(i=>i.tone!=='blocked'),ordered=[...blocked,...done];
    if(!ordered.length)return null;
    const names=ordered.map(i=>nameOf(i.agent)),plural=(n,one,many)=>`${n} ${n===1?one:many}`;
    const title=ordered.length===1?names[0]+(blocked.length?' needs input':' finished')
      :!done.length?`${blocked.length} agents need input`:!blocked.length?`${done.length} agents finished`
      :`${plural(blocked.length,'needs','need')} input, ${done.length} finished`;
    return {id:ordered[0].agent.id,tone:blocked.length?'blocked':'done',title,preview:names.join(', ').slice(0,200),count:ordered.length};
  }

  const api={sorted,alerts,summary,parse,identity,pane,labels,preview,chatProviders,extractDialog};if(typeof module!=='undefined')module.exports=api;else root.HUDModel=api;
})(globalThis);
