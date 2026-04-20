// Shared mock product UIs. Aesthetic-neutral — variations pass theme via props/CSS vars.
// Each component is a small, self-contained snippet of Destila's UI.

const { useState, useEffect, useRef } = React;

// ---------- tiny primitives ----------

function Dot({ color = '#10b981', pulse = true, size = 8 }) {
  return (
    <span style={{
      display:'inline-block', width:size, height:size, borderRadius:'50%',
      background:color, boxShadow: pulse ? `0 0 0 0 ${color}66` : 'none',
      animation: pulse ? 'destila-pulse 2s ease-in-out infinite' : 'none',
      flexShrink:0
    }} />
  );
}

function TypeCaret() {
  return <span style={{display:'inline-block', width:'1ch', background:'currentColor', animation:'destila-blink 1s step-end infinite', marginLeft:2}}>&nbsp;</span>;
}

// ---------- Drafts Kanban ----------
// Three columns: High / Medium / Low. Each card has a title, project tag, priority dot.

function DraftsBoard({ theme = 'dark' }) {
  const drafts = {
    High: [
      { t:'Streaming responses from OpenAI-compatible providers', p:'llmgateway' },
      { t:'Fix race when worktree cache evicts an active session', p:'destila-core' },
    ],
    Medium: [
      { t:'Project picker: recent projects on top', p:'destila-core' },
      { t:'Add Gherkin scenario diff view to review phase', p:'destila-core' },
      { t:'Skills registry — per-phase override file', p:'destila-core' },
    ],
    Low: [
      { t:'Dark terminal background toggle', p:'destila-core' },
      { t:'Oban dashboard deep links', p:'destila-core' },
    ],
  };
  const priColors = { High:'#ef4444', Medium:'#f59e0b', Low:'#6b7280' };
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.06)' : 'rgba(0,0,0,.05)';

  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, padding:14, color:fg, fontFamily:'Inter,sans-serif'}}>
      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:12}}>
        <div style={{fontSize:12, fontWeight:600, letterSpacing:'.04em'}}>DRAFTS</div>
        <div style={{fontSize:11, color:muted, fontFamily:'JetBrains Mono,monospace'}}>7 · filter: all projects</div>
      </div>
      <div style={{display:'grid', gridTemplateColumns:'1fr 1fr 1fr', gap:10}}>
        {Object.entries(drafts).map(([col, items]) => (
          <div key={col}>
            <div style={{display:'flex', alignItems:'center', gap:6, marginBottom:8, fontSize:11, letterSpacing:'.04em', color:muted}}>
              <Dot color={priColors[col]} pulse={false} size={6} />
              <span>{col.toUpperCase()}</span>
              <span style={{marginLeft:'auto', fontFamily:'JetBrains Mono,monospace'}}>{items.length}</span>
            </div>
            <div style={{display:'flex', flexDirection:'column', gap:6}}>
              {items.map((d,i)=>(
                <div key={i} style={{background:chip, border:`1px solid ${border}`, borderRadius:6, padding:'8px 10px'}}>
                  <div style={{fontSize:12, lineHeight:1.4, marginBottom:6}}>{d.t}</div>
                  <div style={{fontSize:10, color:muted, fontFamily:'JetBrains Mono,monospace'}}>{d.p}</div>
                </div>
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ---------- Workflow Runner (phase bar + chat excerpt) ----------

function WorkflowRunner({ theme = 'dark', accent = '#d4ff3a', kind = 'implement' }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chipBg = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';

  const phases = kind === 'implement'
    ? ['Plan','Deepen','Implement','Review','Browser test','Record video','Adjust']
    : ['Context','Gherkin','Approach','Prompt'];
  const active = kind === 'implement' ? 3 : 2;

  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, color:fg, fontFamily:'Inter,sans-serif', overflow:'hidden'}}>
      {/* header */}
      <div style={{display:'flex', alignItems:'center', gap:10, padding:'10px 14px', borderBottom:`1px solid ${border}`}}>
        <Dot color="#10b981" />
        <div style={{fontSize:13, fontWeight:500}}>Extract billing module into a service</div>
        <div style={{marginLeft:'auto', fontSize:11, fontFamily:'JetBrains Mono,monospace', color:muted}}>
          {kind === 'implement' ? 'implement_prompt' : 'brainstorm_idea'}
        </div>
      </div>
      {/* phase bar */}
      <div style={{display:'flex', gap:4, padding:'10px 14px'}}>
        {phases.map((p,i)=>(
          <div key={p} style={{flex:1, display:'flex', flexDirection:'column', gap:4}}>
            <div style={{height:3, background: i <= active ? accent : chipBg, borderRadius:2, opacity: i === active ? 1 : (i < active ? .8 : .5)}} />
            <div style={{fontSize:10, fontFamily:'JetBrains Mono,monospace', color: i === active ? fg : muted, letterSpacing:'.02em'}}>
              {String(i+1).padStart(2,'0')} {p}
            </div>
          </div>
        ))}
      </div>
      {/* chat excerpt */}
      <div style={{padding:'14px', display:'flex', flexDirection:'column', gap:10}}>
        {kind === 'implement' ? (
          <>
            <ChatBubble role="assistant" theme={theme} accent={accent}>
              Running <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>mix test test/destila/billing_test.exs</code>
              <div style={{marginTop:6, fontFamily:'JetBrains Mono,monospace', fontSize:11, color:muted}}>
                → 14 tests, 0 failures (2.3s)
              </div>
            </ChatBubble>
            <ChatBubble role="assistant" theme={theme} accent={accent}>
              Review pass complete. Fixed an N+1 on <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>Billing.list_invoices/1</code> with a preload. Moving to browser test.
            </ChatBubble>
            <ToolCall theme={theme} label="browser_test" sub="navigating http://localhost:4821/billing" />
          </>
        ) : (
          <>
            <ChatBubble role="assistant" theme={theme} accent={accent}>
              I've drafted 3 Gherkin scenarios for this feature. Pick the ones that match what you want:
            </ChatBubble>
            <div style={{display:'flex', flexDirection:'column', gap:6}}>
              {['Given a user with an expired invoice, when they load /billing, then a banner appears',
                'Given an admin, when they mark an invoice paid, then the customer is emailed',
                'Given a failed webhook, when retries exhaust, then an alert fires'].map((s,i)=>(
                <label key={i} style={{display:'flex', gap:8, alignItems:'flex-start', fontSize:12, padding:'8px 10px', background:chipBg, border:`1px solid ${border}`, borderRadius:6}}>
                  <input type="checkbox" defaultChecked={i<2} style={{accentColor:accent, marginTop:2}} />
                  <span style={{fontFamily:'JetBrains Mono,monospace', lineHeight:1.4}}>{s}</span>
                </label>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function ChatBubble({ role, theme, accent, children }) {
  const dark = theme === 'dark';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  return (
    <div style={{display:'flex', gap:10, alignItems:'flex-start'}}>
      <div style={{width:20, height:20, borderRadius:'50%', border:`1px solid ${border}`, display:'flex', alignItems:'center', justifyContent:'center', flexShrink:0, marginTop:1}}>
        <div style={{width:6, height:6, borderRadius:'50%', background:accent}} />
      </div>
      <div style={{fontSize:12.5, lineHeight:1.55, flex:1}}>{children}</div>
    </div>
  );
}

function ToolCall({ theme, label, sub }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  return (
    <div style={{display:'flex', gap:8, alignItems:'center', background:bg, border:`1px solid ${border}`, borderRadius:6, padding:'6px 10px', fontFamily:'JetBrains Mono,monospace', fontSize:11}}>
      <span style={{opacity:.6}}>▸</span>
      <span style={{fontWeight:600}}>{label}</span>
      <span style={{color:muted}}>{sub}</span>
      <span style={{marginLeft:'auto', color:muted}}>running…</span>
    </div>
  );
}

// ---------- Terminal (xterm-like) ----------

function TerminalPanel({ theme = 'dark', compact = false }) {
  const dark = theme === 'dark';
  const bg = dark ? '#0a0a0a' : '#0f0f10';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';

  const lines = [
    { c:'#8a8a8a', t:'~/projects/destila-core on feat/billing-svc' },
    { c:'#d4ff3a', t:'$ ', tail:'mix phx.server' },
    { c:'#aaa', t:'[info] Running DestilaWeb.Endpoint with Bandit 1.5 at 0.0.0.0:4821 (http)' },
    { c:'#aaa', t:'[info] Access DestilaWeb.Endpoint at http://localhost:4821' },
    { c:'#8a8a8a', t:'[watch] build finished, watching for changes...' },
    { c:'#d4ff3a', t:'$ ', tail:'git status' },
    { c:'#aaa', t:'On branch feat/billing-svc' },
    { c:'#10b981', t:'nothing to commit, working tree clean' },
    { c:'#d4ff3a', t:'$ ', tail:'' },
  ];
  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, fontFamily:'JetBrains Mono,monospace', overflow:'hidden'}}>
      <div style={{display:'flex', alignItems:'center', gap:6, padding:'8px 12px', borderBottom:`1px solid ${border}`, background:'rgba(255,255,255,.02)'}}>
        <div style={{display:'flex', gap:6}}>
          <span style={{width:10, height:10, borderRadius:'50%', background:'#ff5f57'}}/>
          <span style={{width:10, height:10, borderRadius:'50%', background:'#febc2e'}}/>
          <span style={{width:10, height:10, borderRadius:'50%', background:'#28c840'}}/>
        </div>
        <span style={{fontSize:11, color:'#8a8a8a', marginLeft:8}}>zsh — destila-core · worktree: feat/billing-svc</span>
        <span style={{marginLeft:'auto', fontSize:10, color:'#8a8a8a'}}>80×24</span>
      </div>
      <div style={{padding:'12px 14px', fontSize:12, lineHeight:1.6, minHeight: compact ? 160 : 220}}>
        {lines.map((l,i)=>(
          <div key={i} style={{color:l.c, whiteSpace:'pre'}}>
            {l.t}{l.tail && <span style={{color:'#e8e8e8'}}>{l.tail}</span>}
            {i === lines.length-1 && <TypeCaret/>}
          </div>
        ))}
      </div>
    </div>
  );
}

// ---------- Dev server / service card ----------

function ServiceCard({ theme='dark', accent='#d4ff3a' }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';

  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, padding:14, color:fg, fontFamily:'Inter,sans-serif'}}>
      <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:10}}>
        <Dot color="#10b981" />
        <div style={{fontSize:13, fontWeight:500}}>Dev server</div>
        <span style={{marginLeft:'auto', fontSize:11, color:muted, fontFamily:'JetBrains Mono,monospace'}}>tmux:9</span>
      </div>
      <div style={{display:'flex', flexDirection:'column', gap:6, fontFamily:'JetBrains Mono,monospace', fontSize:11.5}}>
        <Row label="PORT" value="4821" muted={muted} chip={chip} border={border} accent={accent} />
        <Row label="URL"  value="http://localhost:4821" link muted={muted} chip={chip} border={border} accent={accent}/>
        <Row label="CMD"  value="mix phx.server" muted={muted} chip={chip} border={border} accent={accent}/>
        <Row label="UP"   value="00:04:12" muted={muted} chip={chip} border={border} accent={accent}/>
      </div>
      <div style={{display:'flex', gap:6, marginTop:12}}>
        {['Restart','Stop','Logs'].map((a,i)=>(
          <button key={a} style={{flex:1, padding:'7px 10px', border:`1px solid ${border}`, background: i===0?accent:chip, color: i===0?'#0a0a0a':fg, borderRadius:6, fontSize:11, fontFamily:'JetBrains Mono,monospace', fontWeight:600, cursor:'pointer'}}>{a}</button>
        ))}
      </div>
    </div>
  );
}

function Row({ label, value, link, muted, chip, border, accent }) {
  return (
    <div style={{display:'flex', alignItems:'center', gap:10, padding:'6px 10px', background:chip, border:`1px solid ${border}`, borderRadius:6}}>
      <span style={{color:muted, width:40, fontSize:10, letterSpacing:'.05em'}}>{label}</span>
      <span style={{color:link ? accent : 'inherit'}}>{value}</span>
    </div>
  );
}

// ---------- Video / feature clip card ----------

function VideoCard({ theme='dark', accent='#d4ff3a' }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';

  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, overflow:'hidden', color:fg, fontFamily:'Inter,sans-serif'}}>
      <div style={{position:'relative', aspectRatio:'16/9', background:'linear-gradient(135deg,#111 0%,#1a1a1a 100%)', display:'flex', alignItems:'center', justifyContent:'center'}}>
        {/* placeholder stripes */}
        <div style={{position:'absolute', inset:0, background:'repeating-linear-gradient(135deg, rgba(255,255,255,.02) 0 12px, rgba(255,255,255,.05) 12px 24px)'}} />
        <div style={{position:'relative', display:'flex', alignItems:'center', gap:10}}>
          <div style={{width:44, height:44, borderRadius:'50%', background:accent, display:'flex', alignItems:'center', justifyContent:'center'}}>
            <svg width="14" height="16" viewBox="0 0 14 16" fill="#0a0a0a"><path d="M0 0l14 8-14 8z"/></svg>
          </div>
          <div style={{fontFamily:'JetBrains Mono,monospace', fontSize:12, color:'#e8e8e8'}}>feature.mp4 · 00:47</div>
        </div>
        <div style={{position:'absolute', top:10, left:10, display:'flex', gap:6, alignItems:'center', padding:'4px 8px', background:'rgba(0,0,0,.6)', border:`1px solid rgba(255,255,255,.08)`, borderRadius:4, fontFamily:'JetBrains Mono,monospace', fontSize:10, color:'#e8e8e8'}}>
          <Dot color="#ef4444" size={6} />
          <span>RECORDED BY PHASE 6</span>
        </div>
      </div>
      <div style={{padding:'10px 14px', display:'flex', alignItems:'center', gap:8}}>
        <div style={{fontSize:12}}>Billing service extraction — walkthrough</div>
        <span style={{marginLeft:'auto', fontSize:10, fontFamily:'JetBrains Mono,monospace', color:muted}}>implement_prompt · phase 6</span>
      </div>
    </div>
  );
}

// ---------- Aliveness strip ----------

function AlivenessStrip({ theme='dark' }) {
  const dark = theme === 'dark';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const chip = dark ? 'rgba(255,255,255,.03)' : 'rgba(0,0,0,.03)';
  const items = [
    { dot:'#10b981', label:'billing-svc', sub:'running · 3 turns · $0.42' },
    { dot:'#10b981', label:'gherkin-review', sub:'running · 1 turn · $0.08' },
    { dot:'#6b7280', label:'readme-pass', sub:'idle · auto-resume ready' },
    { dot:'#6b7280', label:'invoice-refactor', sub:'idle · 14m since' },
    { dot:'#ef4444', label:'llmgateway-spike', sub:'stopped · exit 1' },
  ];
  return (
    <div style={{display:'grid', gridTemplateColumns:'repeat(auto-fit,minmax(220px,1fr))', gap:8}}>
      {items.map((x,i)=>(
        <div key={i} style={{display:'flex', gap:10, alignItems:'center', padding:'10px 12px', background:chip, border:`1px solid ${border}`, borderRadius:8, color:fg, fontFamily:'Inter,sans-serif'}}>
          <Dot color={x.dot} pulse={x.dot==='#10b981'} />
          <div>
            <div style={{fontSize:12, fontWeight:500}}>{x.label}</div>
            <div style={{fontSize:10.5, color:muted, fontFamily:'JetBrains Mono,monospace', marginTop:2}}>{x.sub}</div>
          </div>
        </div>
      ))}
    </div>
  );
}

// ---------- Code Chat snippet ----------

function CodeChat({ theme='dark', accent='#d4ff3a' }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';

  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, padding:14, color:fg, fontFamily:'Inter,sans-serif'}}>
      <div style={{display:'flex', alignItems:'center', gap:8, marginBottom:12}}>
        <Dot color="#10b981"/>
        <div style={{fontSize:13, fontWeight:500}}>Code chat · destila-core</div>
        <span style={{marginLeft:'auto', fontSize:10.5, color:muted, fontFamily:'JetBrains Mono,monospace'}}>read · write · edit · search · bash</span>
      </div>
      <div style={{display:'flex', flexDirection:'column', gap:10}}>
        <div style={{fontSize:12.5, lineHeight:1.55, padding:'8px 10px', background:chip, borderRadius:6, border:`1px solid ${border}`}}>
          Where does session aliveness get broadcast? I see the dot on the card but can't find the PubSub.
        </div>
        <ChatBubble role="assistant" theme={theme} accent={accent}>
          It's in <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>Destila.AI.Session</code> — the <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>handle_info(:tick, …)</code> clause broadcasts <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>{`{:aliveness, state}`}</code> to <code style={{color:accent, fontFamily:'JetBrains Mono,monospace'}}>"session:#{'{'}id{'}'}"</code> every 5s. The card subscribes in its mount.
        </ChatBubble>
        <ToolCall theme={theme} label="read" sub="lib/destila/ai/session.ex" />
      </div>
    </div>
  );
}

// ---------- Metadata sidebar snippet ----------

function MetadataList({ theme='dark', accent='#d4ff3a' }) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  const items = [
    { phase:'plan', kind:'md', name:'initial-plan.md' },
    { phase:'plan', kind:'md', name:'deepened-plan.md' },
    { phase:'implement', kind:'txt', name:'diff-summary.txt' },
    { phase:'review', kind:'md', name:'review-notes.md' },
    { phase:'record', kind:'mp4', name:'feature.mp4' },
    { phase:'adjust', kind:'md', name:'adjustments.md' },
  ];
  const iconColor = { md:'#60a5fa', txt:'#e8e8e8', mp4:accent };
  return (
    <div style={{background:bg, border:`1px solid ${border}`, borderRadius:10, padding:14, color:fg, fontFamily:'Inter,sans-serif'}}>
      <div style={{display:'flex', alignItems:'center', justifyContent:'space-between', marginBottom:10}}>
        <div style={{fontSize:12, fontWeight:600, letterSpacing:'.04em'}}>EXPORTED</div>
        <div style={{fontSize:10.5, color:muted, fontFamily:'JetBrains Mono,monospace'}}>{items.length} artifacts</div>
      </div>
      <div style={{display:'flex', flexDirection:'column', gap:4}}>
        {items.map((x,i)=>(
          <div key={i} style={{display:'flex', gap:10, alignItems:'center', padding:'8px 10px', background:chip, border:`1px solid ${border}`, borderRadius:6}}>
            <span style={{fontFamily:'JetBrains Mono,monospace', fontSize:9, fontWeight:700, color:iconColor[x.kind], width:28, textAlign:'center', padding:'2px 4px', background:'rgba(0,0,0,.3)', border:`1px solid ${border}`, borderRadius:3}}>{x.kind.toUpperCase()}</span>
            <span style={{fontSize:12, fontFamily:'JetBrains Mono,monospace'}}>{x.name}</span>
            <span style={{marginLeft:'auto', fontSize:10, color:muted, fontFamily:'JetBrains Mono,monospace'}}>phase: {x.phase}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// Expose to global scope for other files
Object.assign(window, {
  Dot, TypeCaret,
  DraftsBoard, WorkflowRunner, ChatBubble, ToolCall,
  TerminalPanel, ServiceCard, VideoCard, AlivenessStrip, CodeChat, MetadataList,
});

// global animations
if (!document.getElementById('destila-anim')) {
  const s = document.createElement('style');
  s.id = 'destila-anim';
  s.textContent = `
    @keyframes destila-pulse { 0%,100%{box-shadow:0 0 0 0 currentColor} 50%{box-shadow:0 0 0 6px transparent} }
    @keyframes destila-blink { 50% { opacity: 0 } }
    @keyframes destila-float { 0%,100%{transform:translateY(0)} 50%{transform:translateY(-4px)} }
    @keyframes destila-sweep { 0%{transform:translateX(-100%)} 100%{transform:translateX(100%)} }
  `;
  document.head.appendChild(s);
}
