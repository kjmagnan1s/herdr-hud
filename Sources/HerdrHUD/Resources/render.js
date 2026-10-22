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

  // Claude Code draws Markdown tables with box characters and wraps long
  // cells onto extra lines inside the same row. Rebuild the grid so the HUD can
  // show a real table that reflows to the panel width. Returns null for box
  // art that is not a table (single column boxes, ragged rows), which stays
  // preformatted.
  const BOX_RULE=/^\s*[┌├└╞╘╭╰┍┝┕┎┠┖][─━═┬┼┴┯┿┷╤╪╧┰╂┸\s]*[┐┤┘╡╛╮╯┑┥┙┒┨┚]?\s*$/;
  function boxTable(lines){
    const middle=line=>/^\s*[├╞┝┠]/.test(line)&&BOX_RULE.test(line);
    const separators=lines.filter(middle).length;
    const groups=[];let current=null,headEnd=-1;
    for(const line of lines){
      if(BOX_RULE.test(line)){if(middle(line)&&headEnd<0)headEnd=groups.length;current=null;continue;}
      const t=line.trim();
      if(!/^[│┃]/.test(t)||!/[│┃]$/.test(t))return null;
      const cells=t.slice(1,-1).split(/[│┃]/).map(c=>c.trim());
      if(cells.length<2)return null;
      // With a rule between every row, extra lines are wrapped cell text.
      // With only a header rule, each body line is its own row.
      if(!current||(separators<2&&headEnd>=0)){current=[];groups.push(current);}
      current.push(cells);
    }
    if(!groups.length)return null;
    const width=groups[0][0].length;
    if(groups.some(g=>g.some(cells=>cells.length!==width)))return null;
    const rows=groups.map(g=>Array.from({length:width},(_,c)=>g.map(cells=>cells[c]).filter(Boolean).join(' ')));
    return headEnd===1?{head:rows[0],rows:rows.slice(1)}:{head:null,rows};
  }

  function tableNode(head,rows){
    const table=el('table',undefined,'md-table');
    if(head){const tr=el('tr');for(const c of head){const th=el('th');inline(c,th);tr.append(th);}const thead=el('thead');thead.append(tr);table.append(thead);}
    const tbody=el('tbody');
    for(const row of rows){const tr=el('tr');for(const c of row){const td=el('td');inline(c,td);tr.append(td);}tbody.append(tr);}
    table.append(tbody);
    const wrap=el('div',undefined,'md-table-wrap');wrap.append(table);return wrap;
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
        const grid=boxTable(rows);
        if(grid)parent.append(tableNode(grid.head,grid.rows));
        else parent.append(el('pre',rows.join('\n'),'md-code md-art'));
        continue;
      }
      if(/^\s*\|.*\|\s*$/.test(line)){
        breakFlow();const rows=[];while(i<lines.length&&/^\s*\|.*\|\s*$/.test(lines[i]))rows.push(lines[i++]);
        const separator=/^:?-{2,}:?$/,split=row=>row.trim().slice(1,-1).split('|').map(c=>c.trim());
        const hasHead=rows.length>1&&split(rows[1]).every(c=>separator.test(c));
        parent.append(tableNode(hasHead?split(rows[0]):null,rows.filter((_,r)=>!hasHead||r>1).map(split)));continue;
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

  // Rows use Claude Code's own marks: ❯ for what you asked, ⏺ for each step,
  // ⎿ for a result. Long results fold; the first line stays visible.
  function mark(tone){return el('span','⏺','step'+(tone?' '+tone:''));}
  function resultLine(text){const line=el('div',undefined,'result-line');line.append(el('span','⎿','elbow'),el('span',text,'result-text'));return line;}
  function toolRow(block,key,expanded){
    const name=block.title||'Tool',detail=block.detail||'',result=block.result||'',lines=result.split('\n'),first=lines.find(l=>l.trim())||'';
    const failed=/\b(error|failed|not found|denied)\b/i.test(first);
    const head=el('span',undefined,'tool-head');head.append(mark(failed?'fail':'ok'),el('span',name,'tool-name'));
    if(detail)head.append(el('span',`(${detail})`,'tool-detail'));
    // Edits show their diff inline, as Claude Code does: numbered lines, - in red, + in green.
    const DIFF=/^\s*\d+ ([+-]) /;
    if(lines.some(l=>DIFF.test(l))){
      const row=el('div',undefined,'tool');row.append(head,resultLine(first.trim()));
      const pre=el('pre',undefined,'tool-output diff');
      for(const line of lines.slice(lines.indexOf(first)+1)){const m=DIFF.exec(line);pre.append(el('span',line,'diff-line'+(m?m[1]==='+'?' add':' del':'')));}
      row.append(pre);return row;
    }
    const more=lines.filter(l=>l.trim()).length>1;
    if(!more){const row=el('div',undefined,'tool');row.append(head);if(first)row.append(resultLine(first.trim()));return row;}
    const details=el('details',undefined,'tool');details.dataset.key=key;details.open=expanded.has(key);
    const summary=el('summary');summary.append(head,resultLine(`${first.trim()}  +${lines.filter(l=>l.trim()).length-1} lines`));
    details.append(summary,el('pre',result,'tool-output'));return details;
  }

  function agentCard(block,key,expanded){
    const card=el('div',undefined,'subagent');
    const head=el('div',undefined,'tool-head');
    head.append(mark('agent'),el('span',block.title==='Task'||block.title==='Agent'?'Task':block.title,'tool-name'),el('span','subagent','chip'));
    card.append(head);
    if(block.detail)card.append(el('div',block.detail,'subagent-task'));
    if(block.result){
      const lines=block.result.split('\n'),last=lines.find(l=>/tool uses?/.test(l))||lines.at(-1);
      const done=/^Done\b/.test(last),line=resultLine(last.replace(/^Done\s*\((.*)\)$/,'Done · $1'));if(done)line.classList.add('done');card.append(line);
      if(lines.length>1){const d=el('details');d.dataset.key=key;d.open=expanded.has(key);d.append(el('summary','Activity'),el('pre',block.result,'tool-output'));card.append(d);}
    }
    return card;
  }

  // A permission prompt or question Claude is waiting on. While it is live, each
  // option is a button; the host re-checks the screen and presses that number once.
  function dialogCard(block,live){
    const permission=block.type==='permission';
    const card=el('div',undefined,`dialog ${permission?'permission':'question'}${live?' live':''}`);
    const head=el('div',undefined,'dialog-head');
    head.append(el('span',permission?'Permission':'Question','chip'));
    if(block.title)head.append(el('span',block.title,'dialog-title'));
    card.append(head);
    if(block.detail)card.append(el('pre',block.detail,'dialog-detail'));
    if(block.question)card.append(el('div',block.question,'dialog-question'));
    const list=el('ol',undefined,'dialog-options');let keys=0;
    for(const option of block.options||[]){
      const item=el('li',undefined,'dialog-option'+(option.selected?' selected':''));
      // "Type something" and "Chat about this" open a text box the HUD can't fill.
      const pick=live&&!!block.question&&option.n<=9&&!/^(Type something|Chat about this)/i.test(option.label);const row=pick?el('button',undefined,'dialog-answer'):item;
      if(pick){keys++;row.type='button';Object.assign(row.dataset,{n:String(option.n),label:option.label,question:block.question||''});item.append(row);}
      row.append(el('kbd',String(option.n),'dialog-n'));
      const text=el('span',undefined,'dialog-label');text.append(el('span',option.label));
      if(option.description)text.append(el('span',option.description,'dialog-desc'));
      row.append(text);list.append(item);
    }
    card.append(list);
    card.append(el('div',live?(keys?'Press a number or click to answer. The HUD checks the question is still on screen first.':'Answer this one in Herdr.'):'This was on screen when the HUD last read the agent.','dialog-note'));
    return card;
  }

  // Builds the chat view in Claude Code's own shape: your prompts on a ❯ band,
  // every step on a ⏺ row, tools folded to one line plus their first result,
  // subagents and live questions in their own cards.
  function conversation(out,data,agent,expanded){
    let turn=null,run=[];
    const flushRun=()=>{
      if(!run.length)return;
      if(run.length>=4){
        const key='run'+run[0].key;const group=el('details',undefined,'tool-run');group.dataset.key=key;group.open=expanded.has(key);
        const names=[...new Set(run.map(r=>r.block.title))].slice(0,4).join(', '),summary=el('summary');
        summary.append(mark('ok'),el('span',`Used ${run.length} tools`,'tool-name'),el('span',names,'tool-detail'));
        group.append(summary);for(const r of run)group.append(toolRow(r.block,r.key,expanded));
        turn.append(group);
      }else for(const r of run)turn.append(toolRow(r.block,r.key,expanded));
      run=[];
    };
    const open=kind=>{flushRun();turn=el('section',undefined,'turn '+kind);out.append(turn);};
    const blocks=data.blocks.filter((block,index)=>!(data.activity&&index===data.blocks.length-1&&block.kind==='status'));
    blocks.forEach((block,index)=>{
      const key=`${block.kind}:${(block.text||'').split('\n')[0]}:${index}`;
      if(block.kind==='prompt'){open('user');const row=el('div',undefined,'prompt-row');const bubble=el('div',undefined,'bubble');markdown(block.text,bubble);row.append(el('span','❯','caret'),bubble);turn.append(row);if(block.result)turn.append(resultLine(block.result));turn=null;return;}
      if(!turn||turn.classList.contains('user'))open('assistant');
      if(block.kind==='tool'){run.push({block,key});return;}
      flushRun();
      if(block.kind==='agent')turn.append(agentCard(block,key,expanded));
      else if(block.kind==='dialog')turn.append(dialogCard(block,true));
      else if(block.kind==='status'){turn.append(el('div',block.text,'status-line'));}
      else if(block.kind==='recap'){const recap=el('div',undefined,'recap');recap.append(el('div','※ Recap','recap-label'));markdown(block.text,recap);turn.append(recap);}
      else{const reply=el('div',undefined,'entry reply'+(block.kind==='context'?' context':''));const body=el('div',undefined,'entry-body');markdown(block.text,body);reply.append(mark(block.kind==='context'?'dim':''),body);turn.append(reply);}
    });
    if(turn)flushRun();
  }

  const api={inline,markdown,conversation,boxTable};root.HUDRender=api;
})(globalThis);
