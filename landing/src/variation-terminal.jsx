// Variation 2 — Technical Terminal (REAL SCREENSHOTS)
// Heavy monospace, dark, ASCII accents, real Destila screenshots.

function VariationTerminal({ accent }) {
  const A = accent;
  return (
    <div style={{background:'#0c0c0d', color:'#e8e8e8', fontFamily:'JetBrains Mono,ui-monospace,monospace'}}>
      <style>{`
        .term-wrap { max-width: 1280px; margin:0 auto; padding: 0 28px; }
        .term-h1 { font-family:'JetBrains Mono',monospace; font-size: clamp(40px, 6vw, 72px); line-height:1.02; letter-spacing:-.02em; font-weight:700; margin:0; }
        .term-h2 { font-family:'JetBrains Mono',monospace; font-size: clamp(28px, 3.8vw, 44px); line-height:1.05; letter-spacing:-.015em; font-weight:600; margin:0; }
        .term-body { font-family:'Inter',sans-serif; font-size:15.5px; line-height:1.6; color:#a8a8a8; max-width:64ch; }
        .term-btn { display:inline-flex; align-items:center; gap:8px; padding:10px 16px; border-radius:4px; font-family:'JetBrains Mono',monospace; font-weight:600; font-size:12.5px; text-decoration:none; cursor:pointer; border:1px solid transparent; letter-spacing:.02em; }
        .term-btn-primary { background: var(--accent); color: var(--accent-ink); }
        .term-btn-ghost { background: transparent; color:#e8e8e8; border-color: rgba(255,255,255,.15); }
        .term-eyebrow { font-family:'JetBrains Mono',monospace; font-size:11px; letter-spacing:.1em; color:var(--accent); text-transform:uppercase; }
        .term-grid-2 { display:grid; grid-template-columns:1fr 1fr; gap:32px; }
        .term-grid-3 { display:grid; grid-template-columns:repeat(3,1fr); gap:16px; }
        @media (max-width: 860px){ .term-grid-2, .term-grid-3 { grid-template-columns:1fr; } }
        .term-card { background:rgba(255,255,255,.02); border:1px solid rgba(255,255,255,.08); border-radius:6px; padding:22px; }
      `}</style>

      {/* Top bar */}
      <div style={{borderBottom:'1px solid rgba(255,255,255,.08)', background:'#0c0c0d', position:'sticky', top:0, zIndex:5}}>
        <div className="term-wrap" style={{display:'flex', alignItems:'center', gap:18, padding:'12px 28px', fontSize:12}}>
          <div style={{display:'flex', alignItems:'center', gap:8}}>
            <div style={{width:24, height:24, borderRadius:4, background:A, color:'var(--accent-ink)', fontWeight:800, fontSize:13, display:'flex', alignItems:'center', justifyContent:'center'}}>D</div>
            <span style={{fontWeight:700}}>destila</span>
            <span style={{color:'#555'}}>/</span>
            <span style={{color:'#888'}}>v0.12.3</span>
          </div>
          <div style={{display:'flex', gap:18, color:'#888', marginLeft:18}}>
            <a style={{color:'inherit', textDecoration:'none'}}>./workflows</a>
            <a style={{color:'inherit', textDecoration:'none'}}>./env</a>
            <a style={{color:'inherit', textDecoration:'none'}}>./lifecycle</a>
            <a style={{color:'inherit', textDecoration:'none'}}>./docs</a>
          </div>
          <div style={{marginLeft:'auto', display:'flex', gap:10, alignItems:'center'}}>
            <span style={{color:'#555', fontSize:11}}>main · clean</span>
            <Dot color="#10b981" size={6}/>
            <a className="term-btn term-btn-primary" href="#">$ github</a>
          </div>
        </div>
      </div>

      {/* HERO */}
      <section style={{padding:'72px 0 48px', position:'relative', overflow:'hidden'}}>
        <div className="term-wrap" style={{position:'relative'}}>
          <div style={{fontSize:11.5, color:'#666', marginBottom:18, display:'flex', gap:10, alignItems:'center'}}>
            <span>~/destila</span><span style={{color:'#555'}}>on</span><span style={{color:A}}>main</span>
            <span style={{color:'#555'}}>·</span><span>an agentic IDE · built on claude code</span>
          </div>
          <h1 className="term-h1">
            your ai does the work.<br/>
            <span style={{color:A}}>destila handles the lifecycle.</span><TypeCaret/>
          </h1>
          <p className="term-body" style={{marginTop:28, maxWidth:'62ch', fontSize:17}}>
            Destila wraps Claude Code in a supervised workflow engine. Isolated git worktrees per session, managed dev servers, an inline xterm.js terminal, and a self-healing session lifecycle that auto-terminates idle processes and transparently resumes them on demand.
          </p>
          <div style={{display:'flex', gap:10, marginTop:28, flexWrap:'wrap', alignItems:'center'}}>
            <a className="term-btn term-btn-primary" href="#">$ view on github</a>
            <a className="term-btn term-btn-ghost" href="#">./docs →</a>
          </div>
        </div>

        <div className="term-wrap" style={{position:'relative', marginTop:56}}>
          <div style={{borderRadius:10, overflow:'hidden', boxShadow:`0 50px 100px -20px rgba(0,0,0,.8), 0 0 0 1px ${A}22`}}>
            <img src="assets/implement-video.png" alt="Implement workflow with feature video" style={{display:'block', width:'100%'}}/>
          </div>
          <div style={{fontSize:11, color:'#666', marginTop:12, textAlign:'center'}}>→ implement_prompt · phase 6/7 · feature video exported</div>
        </div>
      </section>

      {/* LIFECYCLE */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)', background:'#0a0a0b'}}>
        <div className="term-wrap">
          <div style={{display:'flex', alignItems:'baseline', gap:14, marginBottom:14}}>
            <span className="term-eyebrow" style={{color:A}}>§01 · signature</span>
            <span style={{color:'#555', fontSize:11}}>ai/claude_session.ex · ai/session.ex</span>
          </div>
          <h2 className="term-h2">sessions that manage themselves.</h2>
          <p className="term-body" style={{marginTop:16, fontSize:17}}>
            Every Claude Code session runs under a supervised GenServer. After <span style={{color:A}}>5 min</span> of inactivity it auto-terminates. When you interact again it transparently resumes from the persisted <code style={{color:A}}>claude_session_id</code>. Zero lifecycle management. Zero wasted tokens. Context intact.
          </p>

          <div style={{marginTop:36, border:'1px solid rgba(255,255,255,.08)', borderRadius:6, background:'rgba(255,255,255,.02)', padding:'22px 24px', fontSize:13, lineHeight:1.7, whiteSpace:'pre', overflowX:'auto'}}>
{`  ┌─ your tab ──────────┐       ┌─ supervisor tree ────────────────────────┐
  │ open workflow       │──────▶│  DynamicSupervisor                       │
  │ type → stream → type │       │   └── Destila.AI.Session (#a12)          │
  └─────────────────────┘       │         ├─ claude_session_id: cs_3fAk…   │
           │                    │         ├─ last_activity: 03:42Z          │
      idle 5 min                │         └─ status: running                │
           ▼                    └──────────────────────────────────────────┘
  ┌─────────────────────┐
  │ auto-terminate      │   process exits cleanly · memory freed
  └─────────────────────┘
           │
      return later
           ▼
  ┌─────────────────────┐
  │ resume transparently│   claude_session_id restored · context intact
  └─────────────────────┘`}
          </div>

          <div style={{marginTop:28}}>
            <AlivenessStrip theme="dark"/>
          </div>

          <div className="term-grid-3" style={{marginTop:24}}>
            <StatBlockT accent={A} k="inactivity.timeout" v="5m" n="configurable per project"/>
            <StatBlockT accent={A} k="resume.latency" v="1 keystroke" n="claude_session_id persisted"/>
            <StatBlockT accent={A} k="process.sharing" v="N→1" n="tabs share one genserver"/>
          </div>

          <div style={{marginTop:40}}>
            <Shot src="assets/crafting-board.png" caption="→ crafting board · live status across every session"/>
          </div>
        </div>
      </section>

      {/* DRAFTS */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§02 · ideation</div>
          <h2 className="term-h2" style={{marginTop:12}}>drafts ─┬─ high ─ medium ─ low</h2>
          <p className="term-body" style={{marginTop:14}}>
            Capture a loose idea in under five seconds. Drag to reorder — fractional positions, no renumbering. Launch a draft straight into a workflow; it auto-archives on successful kick-off. Discard is soft. Nothing is ever gone.
          </p>
          <div style={{marginTop:32}}>
            <Shot src="assets/drafts.png" caption="→ drafts · high / medium / low kanban"/>
          </div>
          <div style={{marginTop:24, maxWidth:720}}>
            <Shot src="assets/drafts-edit.png" caption="→ edit draft · prompt · priority · project"/>
          </div>
        </div>
      </section>

      {/* THREE WORKFLOWS */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)', background:'#0a0a0b'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§03 · core product</div>
          <h2 className="term-h2" style={{marginTop:12}}>three workflows. one surface.</h2>
          <p className="term-body" style={{marginTop:14}}>
            Every path from rough idea to shipped code fits one of three shapes. They share context, artifacts, and the same supervised session. <code style={{color:A}}>implement_prompt</code> can consume the output of a completed <code style={{color:A}}>brainstorm_idea</code> — ideation and execution are one flow, not two.
          </p>

          <div className="term-grid-3" style={{marginTop:32}}>
            <WorkflowCardT num="01" name="brainstorm_idea" accent={A}
              body="Four conversational phases that turn a rough idea into a production-ready implementation prompt."
              phases={['task','gherkin','concerns','prompt']}/>
            <WorkflowCardT num="02" name="code_chat" accent={A}
              body="Free-form AI chat with full tool access (read, write, edit, search, bash) over your codebase."
              phases={['chat']}/>
            <WorkflowCardT num="03" name="implement_prompt" accent={A} highlight
              body="Seven phases. Mostly autonomous. Plan → shippable code, with a recorded feature video as the artifact."
              phases={['plan','deepen','work','review','tests','video','adjust']}/>
          </div>

          <div style={{marginTop:36}}>
            <Shot src="assets/workflow-new.png" caption="→ new session · pick a workflow"/>
          </div>
        </div>
      </section>

      {/* BRAINSTORM */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§04 · brainstorm_idea</div>
          <h2 className="term-h2" style={{marginTop:12}}>the ai asks. you answer.</h2>
          <p className="term-body" style={{marginTop:14}}>
            Structured questions — single-select, multi-select, free-text. Locked answers remain editable mid-form. Four phases: task description → Gherkin review → technical concerns → prompt generation.
          </p>
          <div className="term-grid-2" style={{marginTop:32}}>
            <Shot src="assets/brainstorm-questions.png" caption="→ phase 1 · structured questions"/>
            <Shot src="assets/brainstorm-prompt.png" caption="→ phase 4 · generated prompt (markdown)"/>
          </div>
        </div>
      </section>

      {/* IMPLEMENT */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)', background:'#0a0a0b'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§05 · implement_prompt</div>
          <h2 className="term-h2" style={{marginTop:12}}>seven phases. prompt → PR.</h2>

          <div style={{marginTop:24, fontSize:13, lineHeight:1.7, whiteSpace:'pre', overflowX:'auto', padding:'18px 20px', background:'rgba(255,255,255,.02)', border:'1px solid rgba(255,255,255,.08)', borderRadius:6}}>
{`  ┌─ 1 ─┐   ┌─ 2 ─┐   ┌─ 3 ─┐   ┌─ 4 ─┐   ┌─ 5 ─┐   ┌─ 6 ─┐   ┌─ 7 ─┐
  │ plan│ ▸ │deep │ ▸ │work │ ▸ │rev. │ ▸ │tests│ ▸ │video│ ▸ │adj. │
  └─────┘   └─────┘   └─────┘   └─────┘   └─────┘   └─────┘   └─────┘
  planning    impl    autonomous    human ← handles branch, PR, push`}
          </div>

          <div style={{marginTop:32}}>
            <Shot src="assets/implement-new.png" caption="→ new implement session · pick a prompt, link a project"/>
          </div>

          <div className="term-grid-2" style={{marginTop:32}}>
            <Shot src="assets/implement-video.png" caption="→ phase 6 · recorded feature video · inline"/>
            <Shot src="assets/implement-video-modal.png" caption="→ modal playback · 12s walkthrough"/>
          </div>

          <div style={{marginTop:24}}>
            <Shot src="assets/implement-finished.png" caption="→ phase 7 · PR opened · adjust in place, commits push automatically"/>
          </div>
        </div>
      </section>

      {/* CODE CHAT */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§06 · code_chat</div>
          <h2 className="term-h2" style={{marginTop:12}}>chat that reads your actual codebase.</h2>
          <p className="term-body" style={{marginTop:14}}>
            Full tool access on the session's worktree. No snippets, no stale files. Ask where something lives, why it broke, or run a one-off command to confirm.
          </p>
          <div className="term-grid-2" style={{marginTop:32}}>
            <Shot src="assets/chat.png" caption="→ open-ended chat · full tool access"/>
            <Shot src="assets/chat-service.png" caption="→ the agent can start the dev server and return the URL"/>
          </div>
        </div>
      </section>

      {/* TERMINAL + SERVICE */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)', background:'#0a0a0b'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§07 · environment</div>
          <h2 className="term-h2" style={{marginTop:12}}>a real terminal. inside the worktree.</h2>
          <p className="term-body" style={{marginTop:14}}>
            Toggle a full xterm.js shell in the sidebar. It runs inside the session's git worktree, survives navigation via a background GenServer, and tears down cleanly when you close it. Works with TUIs — nvim, lazygit, netrw, all fine.
          </p>
          <div style={{marginTop:32}}>
            <Shot src="assets/terminal.png" caption="→ inline xterm.js · attached to session worktree · TUIs work"/>
          </div>
          <div style={{marginTop:24}}>
            <Shot src="assets/service-starting.png" caption="→ dev server boots via tmux · port injected · live URL surfaces in sidebar"/>
          </div>
        </div>
      </section>

      {/* PROJECTS */}
      <section style={{padding:'88px 0', borderTop:'1px solid rgba(255,255,255,.08)'}}>
        <div className="term-wrap">
          <div className="term-eyebrow" style={{color:A}}>§08 · projects</div>
          <h2 className="term-h2" style={{marginTop:12}}>name · repo · optional everything else.</h2>
          <p className="term-body" style={{marginTop:14}}>
            Git URL or local folder (or both). Optional setup command. Optional run command + env var → managed dev server. Safe-delete: blocked while sessions are linked.
          </p>
          <div style={{marginTop:32, maxWidth:860}}>
            <Shot src="assets/projects-edit.png" caption="→ project config"/>
          </div>
        </div>
      </section>

      {/* FINAL CTA */}
      <section style={{padding:'96px 0 56px', borderTop:'1px solid rgba(255,255,255,.08)', position:'relative', overflow:'hidden'}}>
        <div style={{position:'absolute', inset:0, background:`radial-gradient(ellipse at 50% 0%, ${A}14 0%, transparent 55%)`}}/>
        <div className="term-wrap" style={{position:'relative', textAlign:'center'}}>
          <div className="term-eyebrow" style={{color:A, marginBottom:14}}>open source · mit</div>
          <h2 className="term-h2" style={{maxWidth:'22ch', margin:'0 auto'}}>ship without babysitting the robot.</h2>
          <div style={{display:'flex', gap:10, justifyContent:'center', marginTop:28, flexWrap:'wrap'}}>
            <a className="term-btn term-btn-primary" href="#">$ view on github</a>
            <a className="term-btn term-btn-ghost" href="#">./docs →</a>
          </div>
          <div style={{marginTop:48, paddingTop:24, borderTop:'1px solid rgba(255,255,255,.08)', display:'flex', justifyContent:'space-between', fontSize:11, color:'#555', flexWrap:'wrap', gap:12}}>
            <span>destila · elixir · phoenix liveview · claude code</span>
            <span>mit · © 2026</span>
          </div>
        </div>
      </section>
    </div>
  );
}

function StatBlockT({k,v,n,accent}) {
  return (
    <div className="term-card" style={{padding:'20px 22px'}}>
      <div style={{fontSize:11, color:'#666'}}>{k}</div>
      <div style={{fontSize:28, fontWeight:700, color:accent, marginTop:6, letterSpacing:'-.02em'}}>{v}</div>
      <div style={{fontSize:12, color:'#a8a8a8', marginTop:6}}>{n}</div>
    </div>
  );
}
function WorkflowCardT({num, name, body, phases, accent, highlight}) {
  return (
    <div className="term-card" style={{borderColor: highlight ? accent : 'rgba(255,255,255,.08)', position:'relative', overflow:'hidden'}}>
      {highlight && <div style={{position:'absolute', top:0, left:0, right:0, height:2, background:accent}}/>}
      <div style={{display:'flex', alignItems:'center', gap:10, fontSize:11, color:'#666'}}>
        <span>§{num}</span>
        <span style={{color:accent}}>{name}</span>
      </div>
      <p style={{fontFamily:'Inter,sans-serif', fontSize:14.5, color:'#c8c8c8', lineHeight:1.55, marginTop:12}}>{body}</p>
      <div style={{display:'flex', flexWrap:'wrap', gap:4, marginTop:16}}>
        {phases.map(p=>(
          <span key={p} style={{fontSize:10.5, padding:'3px 7px', border:'1px solid rgba(255,255,255,.15)', borderRadius:3, color:'#e8e8e8'}}>{p}</span>
        ))}
      </div>
    </div>
  );
}

window.VariationTerminal = VariationTerminal;
