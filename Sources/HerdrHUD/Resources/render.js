/* MIT. Renders parsed transcripts as a conversation. Terminal text is never
   interpreted as HTML: every node is built with createElement and textContent. */
(function(root){
  'use strict';
  function el(tag,text,cls){const node=document.createElement(tag);if(text!==undefined)node.textContent=text;if(cls)node.className=cls;return node;}

  const INLINE=/(\*\*[^*\n]+\*\*|`[^`\n]+`|\[[^\]\n]+\]\([^)\s]+\)|(?<![\w*])\*[^*\s][^*\n]*\*(?![\w*]))/g;
  function inline(text,parent){
    for(const part of text.split(INLINE)){
      if(!part)continue;
      if(part.startsWith('**')&&part.endsWith('**')&&part.length>4)parent.append(el('strong',part.slice(2,-2)));
      else if(part.startsWith('`')&&part.endsWith('`')&&part.length>2)parent.append(el('code',part.slice(1,-1)));
      else if(/^\[[^\]]+\]\([^)]+\)$/.test(part)){const [,label,url]=/^\[([^\]]+)\]\(([^)]+)\)$/.exec(part);const link=el('span',label,'link');link.title=url;parent.append(link);}
      else if(part.startsWith('*')&&part.endsWith('*')&&part.length>2)parent.append(el('em',part.slice(1,-1)));
      else parent.append(document.createTextNode(part));
    }
  }

  // A small, forgiving Markdown subset: paragraphs, headings, lists, quotes,
  // fenced code, pipe tables, and the box-drawn tables Claude Code prints.
  function markdown(text,parent){
    const lines=text.split('\n');let para=null,item=null;
    const breakFlow=()=>{para=null;item=null;};
    for(let i=0;i<lines.length;){
      const line=lines[i];let m;
      if(/^\s*```/.test(line)){
        breakFlow();const lang=line.trim().slice(3).trim(),code=[];i++;
        while(i<lines.length&&!/^\s*```/.test(lines[i]))code.push(lines[i++]);i++;
        const pre=el('pre',undefined,'md-code');if(lang)pre.dataset.lang=lang;pre.append(el('code',code.join('\n')));parent.append(pre);continue;
      }
      if(/^\s*[┌├└│╭╰┃╞╘]/.test(line)){
        breakFlow();const rows=[];while(i<lines.length&&/^\s*[┌├└│╭╰┃╞╘┐┤┘]/.test(lines[i]))rows.push(lines[i++]);
        parent.append(el('pre',rows.join('\n'),'md-code md-art'));continue;
      }
      if(/^\s*\|.*\|\s*$/.test(line)){
        breakFlow();const rows=[];while(i<lines.length&&/^\s*\|.*\|\s*$/.test(lines[i]))rows.push(lines[i++]);
        const table=el('table',undefined,'md-table'),separator=/^:?-{2,}:?$/;
        const hasHead=rows.length>1&&rows[1].trim().slice(1,-1).split('|').every(c=>separator.test(c.trim()));
        rows.forEach((row,r)=>{
          const cells=row.trim().slice(1,-1).split('|').map(c=>c.trim());
          if(hasHead&&r===1)return;
          const tr=el('tr');for(const c of cells){const cell=el(hasHead&&r===0?'th':'td');inline(c,cell);tr.append(cell);}
          table.append(tr);
        });
        const wrap=el('div',undefined,'md-table-wrap');wrap.append(table);parent.append(wrap);continue;
      }
      if((m=/^\s{0,3}(#{1,4})\s+(.*)$/.exec(line))){breakFlow();const h=el('div',undefined,`md-h md-h${m[1].length}`);inline(m[2].replace(/\s+#+\s*$/,''),h);parent.append(h);i++;continue;}
      if(/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)){breakFlow();parent.append(el('hr'));i++;continue;}
      if((m=/^(\s*)([-*•◦▪]|\d{1,3}[.)])\s+(.*)$/.exec(line))){
        para=null;const depth=Math.min(3,Math.floor(m[1].length/2));
        item=el('div',undefined,`md-li depth-${depth}`);
        item.append(el('span',/\d/.test(m[2])?m[2]:'•','md-marker'));
        const body=el('span',undefined,'md-li-body');inline(m[3],body);item.append(body);parent.append(item);i++;continue;
      }
      if((m=/^\s*>\s?(.*)$/.exec(line))){breakFlow();const q=el('blockquote');inline(m[1],q);parent.append(q);i++;continue;}
      if(!line.trim()){breakFlow();i++;continue;}
      if(item&&/^\s{2,}\S/.test(line)){const body=item.lastChild;body.append(el('br'));inline(line.trim(),body);i++;continue;}
      if(!para){para=el('p');parent.append(para);}else para.append(el('br'));
      inline(line.trim(),para);i++;
    }
  }

  const PROVIDERS={claude:'Claude',codex:'Codex'};
  const TOOL_GLYPH={Bash:'$',Read:'◱',Write:'✎',Edit:'✎',Update:'✎',MultiEdit:'✎',Grep:'⌕',Glob:'⌕',WebFetch:'↗',WebSearch:'⌕',TodoWrite:'☐'};

  function toolRow(block,key,expanded){
    const name=block.title||'Tool',detail=block.detail||'';
    const head=[el('span',TOOL_GLYPH[name]||'›','tool-glyph'),el('span',name,'tool-name')];
    if(detail)head.push(el('span',detail,'tool-detail'));
    if(!block.result){const row=el('div',undefined,'tool');row.append(...head);return row;}
    const details=el('details',undefined,'tool');details.dataset.key=key;details.open=expanded.has(key);
    const summary=el('summary');summary.append(...head);
    const firstLine=block.result.split('\n')[0];
    if(block.result.split('\n').length===1&&firstLine.length<90){summary.append(el('span',firstLine,'tool-result-inline'));}
    details.append(summary,el('pre',block.result,'tool-output'));return details;
  }

  function agentCard(block,key,expanded){
    const card=el('div',undefined,'subagent');
    const head=el('div',undefined,'subagent-head');
    head.append(el('span','Subagent','chip'),el('span',block.title==='Task'||block.title==='Agent'?'Task':block.title,'subagent-type'));
    card.append(head);
    if(block.detail)card.append(el('div',block.detail,'subagent-task'));
    if(block.result){
      const lines=block.result.split('\n'),last=lines.find(l=>/tool uses?/.test(l))||lines.at(-1);
      const done=/^Done\b/.test(last);
      card.append(el('div',last.replace(/^Done\s*\((.*)\)$/,'Done · $1'),'subagent-result'+(done?' done':'')));
      if(lines.length>1){const d=el('details');d.dataset.key=key;d.open=expanded.has(key);d.append(el('summary','Activity'),el('pre',block.result,'tool-output'));card.append(d);}
    }
    return card;
  }

  // A permission prompt or question Claude is waiting on. The HUD only types
  // text, so the card shows the choices and sends the user to Herdr to answer.
  function dialogCard(block,live){
    const permission=block.type==='permission';
    const card=el('div',undefined,`dialog ${permission?'permission':'question'}${live?' live':''}`);
    const head=el('div',undefined,'dialog-head');
    head.append(el('span',permission?'Permission needed':'Question','chip'));
    if(block.title)head.append(el('span',block.title,'dialog-title'));
    card.append(head);
    if(block.detail)card.append(el('pre',block.detail,'dialog-detail'));
    if(block.question)card.append(el('div',block.question,'dialog-question'));
    const list=el('ol',undefined,'dialog-options');
    for(const option of block.options||[]){
      const item=el('li',undefined,'dialog-option'+(option.selected?' selected':''));
      item.append(el('span',String(option.n),'dialog-n'));
      const text=el('span',undefined,'dialog-label');text.append(el('span',option.label));
      if(option.description)text.append(el('span',option.description,'dialog-desc'));
      item.append(text);list.append(item);
    }
    card.append(list);
    card.append(el('div',live?'Answer in Herdr. The HUD can only send text prompts, so it never picks an option for you.':'This was on screen when the HUD last read the agent.','dialog-note'));
    return card;
  }

  // Builds the chat view: one turn per speaker, tools folded into compact rows,
  // subagents in their own cards, and status lines as quiet footnotes.
  function conversation(out,data,agent,expanded){
    const who=PROVIDERS[agent?.agent]||agent?.agent||'Agent';
    let turn=null,body=null,run=[];
    const flushRun=()=>{
      if(!run.length)return;
      if(run.length>=3){
        const key='run'+run[0].key;const group=el('details',undefined,'tool-run');group.dataset.key=key;group.open=expanded.has(key);
        const names=[...new Set(run.map(r=>r.block.title))].slice(0,4).join(', ');
        group.append(el('summary',`Used ${run.length} tools · ${names}`));
        for(const r of run)group.append(toolRow(r.block,r.key,expanded));
        body.append(group);
      }else for(const r of run)body.append(toolRow(r.block,r.key,expanded));
      run=[];
    };
    const open=kind=>{
      flushRun();
      turn=el('section',undefined,'turn '+kind);
      const head=el('div',undefined,'turn-head');
      head.append(el('span',kind==='user'?'Y':who[0],'avatar'),el('span',kind==='user'?'You':who,'speaker'));
      if(kind==='assistant'&&data.model)head.append(el('span',[data.model,data.reasoning].filter(Boolean).join(' '),'model'));
      body=el('div',undefined,'turn-body');turn.append(head,body);out.append(turn);
    };
    data.blocks.forEach((block,index)=>{
      const key=`${block.kind}:${(block.text||'').split('\n')[0]}:${index}`;
      if(block.kind==='prompt'){open('user');const bubble=el('div',undefined,'bubble');markdown(block.text,bubble);body.append(bubble);if(block.result)body.append(el('div',block.result,'note'));turn=null;return;}
      if(!turn||turn.classList.contains('user'))open('assistant');
      if(block.kind==='tool'){run.push({block,key});return;}
      flushRun();
      if(block.kind==='agent')body.append(agentCard(block,key,expanded));
      else if(block.kind==='dialog')body.append(dialogCard(block,agent?.agent_status==='blocked'));
      else if(block.kind==='status'){body.append(el('div',block.text,'status-line'));}
      else if(block.kind==='recap'){const recap=el('div',undefined,'recap');recap.append(el('div','Recap','recap-label'));markdown(block.text,recap);body.append(recap);}
      else{const reply=el('div',undefined,'reply'+(block.kind==='context'?' context':''));markdown(block.text,reply);body.append(reply);}
    });
    flushRun();
  }

  const api={inline,markdown,conversation};root.HUDRender=api;
})(globalThis);
