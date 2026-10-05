// Placeholder agents and transcripts for the mockup. A fake bridge stands in for
// the native app, so the real panel code runs unchanged and nothing is sent anywhere.
(function () {
  const machine = { id: 'local', label: 'MacBook Air', session: 'default', online: true };
  const agent = (pane, workspace, tab, kind, status) => ({
    id: JSON.stringify(['local', pane, kind]), pane_id: pane, terminal_id: 't-' + pane, workspace_id: workspace, workspace_label: workspace,
    tab_id: workspace + ':' + tab, tab_label: tab, agent: kind, agent_status: status, machine_id: 'local', machine_label: machine.label, online: true
  });
  const agents = [
    agent('p1', 'herdr-hud', '1', 'claude', 'working'),
    agent('p2', 'Documents', '1', 'claude', 'blocked'),
    agent('p3', 'Documents', '1', 'claude', 'idle'),
    agent('p4', 'Documents', 'deck audit', 'claude', 'done'),
    agent('p5', 'api-server', '1', 'codex', 'idle')
  ];
  const footer = `
────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────
  Opus 5.5 | 📁Documents | ████░░░░ 40% of 1000k tokens
  ⏵⏵ auto mode on (shift+tab to cycle)`;
  const transcripts = {
    p1: `❯ the overlay text is hard to read. can you look at the parser and the
  stylesheet and tell me what's wrong?

⏺ I'll start with how the panel turns terminal output into messages.

⏺ Read 3 files (ctrl+o to expand)

⏺ Bash(npm test -- --reporter=dot)
  ⎿  ✓ 12 passing (210ms)

⏺ Explore(Find transcript rendering code)
  ⎿  Done (9 tool uses · 31.4k tokens · 48s)

⏺ Here is what I found:

  ## Causes

  1. **Speaker labels** only exist for \`codex\`. Claude output falls back to one
     long monospace block, so prompts, replies and tool calls all look alike.
  2. Status lines like "Brewed for 4m" sit in the same text as the reply.
  3. The roster names come from tab labels, and Herdr names tabs \`1\`, \`2\`…

  | Area | Today | Proposed |
  |---|---|---|
  | Claude chat | Raw terminal | Turns with speakers |
  | Tool calls | Inline text | One folded line each |
  | Subagents | Inline text | Their own card |

  \`\`\`js
  const terminal = mode === 'terminal' || !chatProviders.has(agent);
  \`\`\`

⏺ Update(Sources/HerdrHUD/Resources/model.js)
  ⎿  Updated model.js with 96 additions and 2 removals

⏺ Bash(node --test Tests/*.cjs)
  ⎿  # pass 18

⏺ Read(Sources/HerdrHUD/Resources/style.css)
  ⎿  Read 1 line

✶ Restyling the conversation… (2m 14s · ↓ 8.1k tokens · esc to interrupt)` + footer,
    p2: `❯ audit the deck and fix whatever is wrong with the numbers

⏺ I'll compare every figure in the deck against the source spreadsheet.

⏺ Task(Cross-check figures against the spreadsheet)
  ⎿  Done (14 tool uses · 52.0k tokens · 2m 3s)

⏺ Two numbers on slide 7 don't match the source. Before I change them I need
  to know which quarter you want to report:

  - **Q2 actuals** (what the spreadsheet has today)
  - **Q2 forecast** (what the deck says now)

✻ Cooked for 3m 12s

 Do you want to proceed?
 ❯ 1. Use Q2 actuals
   2. Keep the forecast` + footer,
    p3: `❯ yeah update brain summary files

⏺ Updated the three summary files and pushed them to the brain repo.

  - \`people.md\`: added the two new contacts from Thursday
  - \`projects.md\`: moved the Padovan deck to *done*
  - \`log.md\`: one entry per meeting

✻ Brewed for 4m 38s · done Thursday 8:36 PM

※ recap: You're getting the Seth Opportunity Map deck ready for the 10/5 meeting.
  The deck is audited and fixed. Next: open PRs for both branches.

new task? /clear to save 410.4k tokens` + footer,
    p4: `❯ open PRs for both branches

⏺ Both PRs are open and green:

  1. deck-fixes: corrected slides 4 and 7
  2. brain-padovan: summary updates

⏺ github - create_pull_request (MCP)(owner: "example", repo: "deck", title: "Deck fixes")
  ⎿  Created pull request #12

✻ Worked for 1m 05s` + footer,
    p5: `› add a health check endpoint

• I added GET /healthz and a test for it.

• Ran npm test
  └ 41 passing

• The endpoint returns 200 with the build version. Nothing else changed.

› Ask Codex to do anything
  gpt-6 high · ~/api-server`
  };
  const listeners = [];
  const emit = (type, data) => setTimeout(() => listeners.forEach(fn => fn({ data: { type, data } })), 60);
  window.chrome = { webview: {
    addEventListener: (name, fn) => listeners.push(fn),
    postMessage: message => {
      if (message.op === 'ready') {
        emit('preferences', { selectedAgent: agents[0].id, mode: 'chat', rosterWidth: 0 });
        emit('visibility', { open: true });
        emit('roster', { agents, machines: [{ ...machine, count: agents.length }] });
      } else if (message.op === 'output') {
        const a = agents.find(x => x.id === message.id);
        if (!a) return emit('output', { id: message.id, requestID: message.requestID, error: 'Agent is offline or changed. Refresh and select it again.' });
        emit('output', { id: message.id, requestID: message.requestID, provider: a.agent, text: transcripts[a.pane_id] });
      } else if (message.op === 'prompt') {
        emit('prompt', { requestID: message.requestID, error: 'Mockup only. Nothing was sent.' });
      } else if (message.op === 'refresh') {
        emit('roster', { agents, machines: [{ ...machine, count: agents.length }] });
      }
    }
  } };
})();
