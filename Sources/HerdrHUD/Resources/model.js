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
  function parseClaude(text){
    let lines=text.replace(/\r/g,'').trimEnd().split('\n'),model='',reasoning='',footer=[];
    // Strip the prompt box and status line: the last ❯ line that sits under a rule.
    for(let i=lines.length-1;i>=Math.max(0,lines.length-40);i--){
      if(!CLAUDE.prompt.test(lines[i]))continue;
      let j=i-1;while(j>=0&&!lines[j].trim())j--;
      if(j>=0&&CLAUDE.rule.test(lines[j])){footer=lines.slice(j);lines=lines.slice(0,j);break;}
    }
    const found=CLAUDE.model.exec(footer.join('\n'));if(found)model=`${found[1][0].toUpperCase()}${found[1].slice(1).toLowerCase()} ${found[2]}`;
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
    return {text:lines.join('\n').trimEnd(),model,reasoning,blocks};
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

  const api={sorted,alerts,parse,identity,pane,labels,preview,chatProviders};if(typeof module!=='undefined')module.exports=api;else root.HUDModel=api;
})(globalThis);
