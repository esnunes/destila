// Variation 1 — Dev-tool minimalism (REAL SCREENSHOTS)
// Dark hero, light body. Tight grid. Accent highlights. Real Destila screenshots.

function VariationMinimal({ accent }) {
  const A = accent;
  return (
    <div style={{background:'#fafaf9', color:'#0a0a0a', fontFamily:'Inter,system-ui,sans-serif'}}>
      <style>{`
        .min-wrap { max-width: 1280px; margin: 0 auto; padding: 0 32px; }
        .min-eyebrow { font-family:'JetBrains Mono',monospace; font-size:11px; letter-spacing:.12em; text-transform:uppercase; color: var(--accent); }
        .min-h1 { font-size: clamp(48px, 7vw, 92px); line-height:.98; letter-spacing:-.035em; font-weight:700; margin:0; }
        .min-h2 { font-size: clamp(32px, 4.6vw, 56px); line-height:1.02; letter-spacing:-.03em; font-weight:600; margin:0; }
        .min-body { font-size:17px; line-height:1.55; color:#525252; max-width:60ch; }
        .min-btn { display:inline-flex; align-items:center; gap:8px; padding:12px 18px; border-radius:8px; font-weight:500; font-size:14px; text-decoration:none; border:1px solid transparent; cursor:pointer; font-family:inherit; }
        .min-btn-primary { background: var(--accent); color: var(--accent-ink); }
        .min-btn-ghost { background: transparent; color:#e8e8e8; border-color: rgba(255,255,255,.18); }
        .min-grid-2 { display:grid; grid-template-columns: 1fr 1fr; gap:32px; }
        .min-grid-3 { display:grid; grid-template-columns: repeat(3,1fr); gap:20px; }
        @media (max-width: 860px){ .min-grid-2, .min-grid-3 { grid-template-columns:1fr; } }
      `}</style>

      {/* ========= HERO ========= */}
      <section style={{background:'#0a0a0a', color:'#fff', position:'relative', overflow:'hidden'}}>
        <div style={{position:'absolute', inset:0, backgroundImage:'linear-gradient(rgba(255,255,255,.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.035) 1px, transparent 1px)', backgroundSize:'48px 48px', maskImage:'radial-gradient(ellipse at 50% 30%, black 30%, transparent 75%)'}}/>
        <nav className="min-wrap" style={{position:'relative', display:'flex', alignItems:'center', padding:'22px 32px', gap:24}}>
          <LogoM accent={A}/>
          <div style={{display:'flex', gap:22, fontSize:13.5, color:'#a8a8a8', marginLeft:8}}>
            <a style={{color:'inherit', textDecoration:'none'}}>Workflows</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Environment</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Lifecycle</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Docs</a>
          </div>
          <div style={{marginLeft:'auto', display:'flex', gap:10, alignItems:'center'}}>
            <span style={{fontFamily:'JetBrains Mono,monospace', fontSize:11, color:'#888'}}>v0.12.3</span>
            <a className="min-btn min-btn-primary" href="https://github.com/esnunes/destila"><GhIconM/> View on GitHub</a>
          </div>
        </nav>

        <div className="min-wrap" style={{position:'relative', padding:'64px 32px 40px', textAlign:'center'}}>
          <div className="min-eyebrow" style={{marginBottom:20, display:'inline-flex', alignItems:'center', gap:10}}>
            <Dot color={A}/><span>The Agentic IDE · built on Claude Code</span>
          </div>
          <h1 className="min-h1" style={{maxWidth:'18ch', margin:'0 auto'}}>
            Your AI does the work.<br/>
            <span style={{color:A}}>Destila handles the lifecycle.</span>
          </h1>
          <p className="min-body" style={{color:'#a8a8a8', margin:'24px auto 0', maxWidth:'62ch', textAlign:'center', fontSize:18}}>
            An agentic IDE that takes you from rough ideas to shipped code. Autonomous, multi-phase pipelines that plan, implement, review, and ship — pausing for human judgment only when it actually helps.
          </p>
          <div style={{display:'flex', gap:10, marginTop:30, flexWrap:'wrap', justifyContent:'center'}}>
            <a className="min-btn min-btn-primary" href="https://github.com/esnunes/destila"><GhIconM/> View on GitHub</a>
            <a className="min-btn min-btn-ghost" href="https://github.com/esnunes/destila">Read the docs →</a>
          </div>
        </div>

        {/* Hero screenshot */}
        <div className="min-wrap" style={{position:'relative', padding:'24px 32px 96px'}}>
          <div style={{borderRadius:14, overflow:'hidden', boxShadow:'0 60px 120px -20px rgba(0,0,0,.8), 0 0 0 1px rgba(255,255,255,.06)'}}>
            <img src="assets/implement-video.png" alt="Destila — Implement workflow with feature video" style={{display:'block', width:'100%', height:'auto'}}/>
          </div>
          <div style={{display:'flex', gap:28, marginTop:36, fontFamily:'JetBrains Mono,monospace', fontSize:11.5, color:'#888', justifyContent:'center', flexWrap:'wrap'}}>
            <StatM label="WORKTREES"  value="per-session"/>
            <StatM label="RESUME"     value="one keystroke"/>
            <StatM label="PIPELINES"  value="4 + 1 + 7 phases"/>
            <StatM label="POLLING"    value="zero"/>
          </div>
        </div>
      </section>

      {/* ========= DRAFTS ========= */}
      <SectionL>
        <TwoCol
          eyebrow="01 / Ideation"
          title={<>Capture loose ideas.<br/>Launch them into code.</>}
          body="A kanban for drafts — High, Medium, Low — with fractional positions so reordering never re-numbers the list. Each draft is a prompt + project + priority. Hit launch and it becomes a session; the draft auto-archives on successful kick-off."
          bullets={[
            'Drag-and-drop with persistent fractional ordering',
            'Project filter for noisy context switches',
            'Launch directly into Brainstorm or Implement',
            'Soft-discard — nothing is ever gone',
          ]}
          accent={A}
        >
          <Shot src="assets/drafts.png" caption="destila / drafts"/>
        </TwoCol>

        <div style={{marginTop:56, maxWidth:680}}>
          <Shot src="assets/drafts-edit.png" caption="edit draft · prompt, priority, project"/>
        </div>
      </SectionL>

      {/* ========= THE THREE WORKFLOWS ========= */}
      <SectionL bg="#f2efe8">
        <div style={{textAlign:'center', maxWidth:760, margin:'0 auto'}}>
          <div className="min-eyebrow" style={{marginBottom:14}}>02 / The Core Product</div>
          <h2 className="min-h2">Three workflows. One surface.</h2>
          <p className="min-body" style={{margin:'18px auto 0', fontSize:17}}>
            Every path from rough idea to shipped code fits one of three shapes. They share context, artifacts, and the same supervised AI session. An Implement run can consume the prompt from a completed Brainstorm — ideation and execution are connected, not siloed.
          </p>
        </div>

        <div className="min-grid-3" style={{marginTop:40}}>
          <WorkflowCardM
            badge="BRAINSTORM"
            title="Idea → production-ready prompt"
            body="Four conversational phases: context gathering, Gherkin/BDD review, technical approach, final prompt. Structured questions — single, multi, or free-text."
            phases={['Task Description','Gherkin','Technical Concerns','Prompt']}
            accent={A}
          />
          <WorkflowCardM
            badge="CODE CHAT"
            title="Open-ended Q&A over your code"
            body="Free-form AI chat with full tool access — read, write, edit, search, bash. Single-phase, open-ended — for exploration and debugging."
            phases={['Chat']}
            accent={A}
          />
          <WorkflowCardM
            badge="IMPLEMENT"
            title="Prompt → shippable code"
            body="Seven phases, mostly autonomous: plan, deepen, work, review, browser tests, feature video, adjustments. Consumes prompts from completed Brainstorms."
            phases={['Plan','Deepen','Work','Review','Tests','Video','Adjust']}
            accent={A}
            featured
          />
        </div>

        <div style={{marginTop:40}}>
          <Shot src="assets/workflow-new.png" caption="new session · pick a workflow"/>
        </div>
      </SectionL>

      {/* ========= BRAINSTORM DETAIL ========= */}
      <SectionL>
        <TwoCol
          eyebrow="03 / Brainstorm"
          title={<>The AI asks.<br/>You answer structured questions.</>}
          body="Instead of dumping a wall of prose, Brainstorm decomposes clarifying context into single-select, multi-select, and free-text prompts. Locked answers stay editable mid-form. When all four phases resolve, you export a production-ready prompt — Markdown with rendered & raw tabs."
          bullets={[
            'Four phases: Task Description · Gherkin · Technical Concerns · Prompt Generation',
            'Reads project features/*.feature when present',
            'Skips Gherkin cleanly when no scenarios exist',
            'Output is a reusable prompt for Implement',
          ]}
          accent={A}
          reverse
        >
          <Shot src="assets/brainstorm-questions.png" caption="phase 1 · structured questions"/>
        </TwoCol>

        <div style={{marginTop:48}}>
          <Shot src="assets/brainstorm-prompt.png" caption="phase 4 · generated prompt (rendered markdown)"/>
        </div>
      </SectionL>

      {/* ========= IMPLEMENT DETAIL — phase chain ========= */}
      <SectionL bg="#f2efe8">
        <div style={{maxWidth:760}}>
          <div className="min-eyebrow" style={{marginBottom:14}}>04 / Implement</div>
          <h2 className="min-h2">Seven phases from prompt to PR.</h2>
          <p className="min-body" style={{marginTop:18, fontSize:17}}>
            Pick a prompt — write your own, or select a completed Brainstorm. Destila links a project, spins up a worktree, and runs the pipeline end-to-end. You only interact when you choose to.
          </p>
        </div>

        <div style={{marginTop:32}}>
          <Shot src="assets/implement-new.png" caption="implement · choose a prompt, link a project"/>
        </div>

        <div style={{marginTop:48, display:'grid', gridTemplateColumns:'repeat(7, 1fr)', gap:6}}>
          {['Plan','Deepen Plan','Work','Review','Browser Tests','Feature Video','Adjustments'].map((p, i) => (
            <div key={p} style={{padding:'14px 10px', background:'#fff', border:'1px solid rgba(0,0,0,.08)', borderRadius:6, textAlign:'center'}}>
              <div style={{fontFamily:'JetBrains Mono,monospace', fontSize:10, letterSpacing:'.08em', color:'#888'}}>PHASE {i+1}</div>
              <div style={{marginTop:6, fontSize:13, fontWeight:500}}>{p}</div>
            </div>
          ))}
        </div>

        <div className="min-grid-2" style={{marginTop:48}}>
          <div>
            <div className="min-eyebrow" style={{marginBottom:10}}>Phase 6 · records the demo</div>
            <h3 style={{fontSize:28, fontWeight:600, margin:0, letterSpacing:'-.02em', lineHeight:1.1}}>
              Every run ships with a feature video.
            </h3>
            <p className="min-body" style={{marginTop:14}}>
              During browser tests, Destila captures a walkthrough MP4. It streams in the metadata sidebar next to the plan, diff summary, review notes, and adjustments. Hand-off becomes a link, not a meeting.
            </p>
          </div>
          <Shot src="assets/implement-video-modal.png" caption="phase 6 · feature video · modal playback"/>
        </div>

        <div className="min-grid-2" style={{marginTop:48, alignItems:'center'}}>
          <Shot src="assets/implement-finished.png" caption="phase 7 · adjustments · PR opened"/>
          <div>
            <div className="min-eyebrow" style={{marginBottom:10}}>Phase 7 · adjustments</div>
            <h3 style={{fontSize:28, fontWeight:600, margin:0, letterSpacing:'-.02em', lineHeight:1.1}}>
              Commit, push, PR. Then iterate in place.
            </h3>
            <p className="min-body" style={{marginTop:14}}>
              When implementation is clean, Destila opens the PR and shares the worktree path. Any adjustment you type is committed and pushed to the branch — the PR updates automatically.
            </p>
          </div>
        </div>
      </SectionL>

      {/* ========= CODE CHAT ========= */}
      <SectionL>
        <TwoCol
          eyebrow="05 / Code Chat"
          title={<>A chat that reads your<br/>actual codebase.</>}
          body="Free-form AI chat with full tool access over the session's worktree — read, write, edit, search, bash. No snippets, no stale files. Ask where something lives, why it broke, or run a one-off command to confirm."
          bullets={[
            'Tools: read · write · edit · search · bash',
            'Single-phase, open-ended conversation',
            'Token & cost totals per session',
            'Service start / stop right from chat',
          ]}
          accent={A}
        >
          <Shot src="assets/chat.png" caption="code chat · destila"/>
        </TwoCol>

        <div style={{marginTop:48, maxWidth:820}}>
          <Shot src="assets/chat-service.png" caption="the agent can start the dev server and return the live URL"/>
        </div>
      </SectionL>

      {/* ========= ENVIRONMENT — terminal + service ========= */}
      <SectionD>
        <div style={{maxWidth:780}}>
          <div className="min-eyebrow" style={{marginBottom:14}}>06 / Environment</div>
          <h2 className="min-h2" style={{color:'#fff'}}>
            A real terminal. A real server.<br/>
            <span style={{color:A}}>Scoped to each session.</span>
          </h2>
          <p className="min-body" style={{color:'#a8a8a8', marginTop:18, fontSize:17}}>
            Destila clones your repo once into a cache, then creates an isolated git worktree per session. An ephemeral port is allocated and injected into your run command. A full xterm.js terminal lives in the sidebar, always scoped to the right directory, surviving navigation via a background GenServer.
          </p>
        </div>

        <div style={{marginTop:40}}>
          <Shot src="assets/terminal.png" caption="inline xterm.js · attached to the session worktree"/>
        </div>

        <div style={{marginTop:32, maxWidth:820}}>
          <Shot src="assets/service-starting.png" caption="dev server boots via tmux · live URL lands in the sidebar"/>
        </div>
      </SectionD>

      {/* ========= PROJECTS ========= */}
      <SectionL bg="#f2efe8">
        <TwoCol
          eyebrow="07 / Projects"
          title={<>Name it. Point it at a repo.<br/>Done.</>}
          body="A project needs a name plus either a git URL or a local folder — or both. Optional setup command runs pre-worktree. An optional run command plus service env var name makes the project a webservice, and Destila will inject an ephemeral port on every session."
          bullets={[
            'Git URL · local folder · or both',
            'Setup command runs once pre-worktree',
            'Run command + env var → managed dev server',
            'Safe-delete: blocked while sessions are linked',
          ]}
          accent={A}
          reverse
        >
          <Shot src="assets/projects-edit.png" caption="project config · everything optional except name"/>
        </TwoCol>
      </SectionL>

      {/* ========= LIFECYCLE (signature) ========= */}
      <SectionD bg="#0a0a0a" featured accent={A}>
        <div style={{maxWidth:900}}>
          <div className="min-eyebrow" style={{marginBottom:18, display:'flex', gap:10, alignItems:'center'}}>
            <Dot color={A}/> <span>08 / Signature · Managed Claude Code Lifecycle</span>
          </div>
          <h2 className="min-h2" style={{color:'#fff'}}>
            Start a workflow. Walk away.<br/>
            <span style={{color:A}}>Come back hours later. It just resumes.</span>
          </h2>
          <p className="min-body" style={{color:'#b0b0b0', marginTop:18, fontSize:18}}>
            Every Claude Code session runs under a supervised GenServer that auto-terminates after 5 minutes of inactivity and transparently resumes from the persisted <code style={{color:A}}>claude_session_id</code> the moment you interact again. You never manage processes. Idle sessions never burn resources. Context is intact.
          </p>
        </div>

        <div style={{marginTop:36}}>
          <AlivenessStrip theme="dark"/>
        </div>

        <div className="min-grid-3" style={{marginTop:24}}>
          <TinyStatM label="INACTIVITY TIMEOUT" value="5m" sub="configurable per project" accent={A}/>
          <TinyStatM label="RESUME" value="1 keystroke" sub="claude_session_id persisted" accent={A}/>
          <TinyStatM label="TAB SHARING" value="N → 1" sub="tabs share one process" accent={A}/>
        </div>

        <div style={{marginTop:40}}>
          <Shot src="assets/crafting-board.png" caption="the crafting board · live status across every session"/>
        </div>
      </SectionD>

      {/* ========= FINAL CTA ========= */}
      <section style={{background:'#0a0a0a', color:'#fff', position:'relative', overflow:'hidden'}}>
        <div style={{position:'absolute', inset:0, background:`radial-gradient(ellipse at 50% 0%, ${A}14 0%, transparent 60%)`}}/>
        <div className="min-wrap" style={{position:'relative', padding:'96px 32px 64px', textAlign:'center'}}>
          <div className="min-eyebrow" style={{marginBottom:18, color:A}}>OPEN SOURCE · MIT</div>
          <h2 className="min-h2" style={{color:'#fff', maxWidth:'18ch', margin:'0 auto'}}>
            Ship without babysitting the robot.
          </h2>
          <div style={{display:'flex', gap:10, justifyContent:'center', marginTop:32, flexWrap:'wrap'}}>
            <a className="min-btn min-btn-primary" href="https://github.com/esnunes/destila"><GhIconM/> View on GitHub</a>
            <a className="min-btn min-btn-ghost" href="https://github.com/esnunes/destila">Read the docs →</a>
          </div>
          <div style={{marginTop:48, paddingTop:28, borderTop:'1px solid rgba(255,255,255,.08)', display:'flex', justifyContent:'space-between', fontFamily:'JetBrains Mono,monospace', fontSize:11, color:'#666', flexWrap:'wrap', gap:12}}>
            <span>destila · elixir · phoenix liveview · claude code</span>
            <span>MIT · © 2026</span>
          </div>
        </div>
      </section>
    </div>
  );
}

// ---- helpers for this variation ----
function LogoM({accent}) {
  return (
    <div style={{display:'flex', alignItems:'center', gap:10}}>
      <div style={{width:26, height:26, borderRadius:7, background:accent, display:'flex', alignItems:'center', justifyContent:'center', color:'var(--accent-ink)', fontWeight:700, fontSize:13, fontFamily:'JetBrains Mono,monospace'}}>D</div>
      <span style={{fontWeight:600, letterSpacing:'-.01em', fontSize:16}}>destila</span>
    </div>
  );
}
function GhIconM() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 005.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2 .37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.42 7.42 0 014 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
  );
}
function StatM({label, value}) {
  return (
    <div style={{textAlign:'center'}}>
      <div style={{fontSize:10, letterSpacing:'.12em'}}>{label}</div>
      <div style={{fontSize:13, color:'#e8e8e8', marginTop:3}}>{value}</div>
    </div>
  );
}
function TinyStatM({label, value, sub, accent}) {
  return (
    <div style={{padding:'20px 22px', border:'1px solid rgba(255,255,255,.08)', borderRadius:10, background:'rgba(255,255,255,.02)'}}>
      <div style={{fontFamily:'JetBrains Mono,monospace', fontSize:10.5, letterSpacing:'.12em', color:'#888'}}>{label}</div>
      <div style={{fontSize:34, fontWeight:600, letterSpacing:'-.02em', marginTop:6, color:accent}}>{value}</div>
      <div style={{fontSize:12.5, color:'#a8a8a8', marginTop:4}}>{sub}</div>
    </div>
  );
}
function SectionL({children, bg='#fafaf9'}) {
  return <section style={{background:bg, padding:'96px 0'}}><div className="min-wrap">{children}</div></section>;
}
function SectionD({children, bg='#111', featured, accent}) {
  return (
    <section style={{background:bg, color:'#fff', padding:'96px 0', position:'relative', overflow:'hidden'}}>
      {featured && <div style={{position:'absolute', top:0, left:0, right:0, height:1, background:`linear-gradient(90deg, transparent, ${accent}, transparent)`}}/>}
      <div className="min-wrap" style={{position:'relative'}}>{children}</div>
    </section>
  );
}
function TwoCol({eyebrow, title, body, bullets, accent, reverse, children}) {
  const textCol = (
    <div>
      <div className="min-eyebrow" style={{marginBottom:14}}>{eyebrow}</div>
      <h2 className="min-h2">{title}</h2>
      <p className="min-body" style={{marginTop:18}}>{body}</p>
      {bullets && (
        <ul style={{marginTop:22, paddingLeft:0, listStyle:'none', display:'flex', flexDirection:'column', gap:10}}>
          {bullets.map((t,i)=>(
            <li key={i} style={{display:'flex', gap:10, alignItems:'flex-start', fontSize:14.5, color:'#3a3a3a'}}>
              <span style={{color:accent, fontFamily:'JetBrains Mono,monospace', marginTop:1}}>▸</span>{t}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
  return (
    <div className="min-grid-2" style={{alignItems:'center'}}>
      {reverse ? <>{children}{textCol}</> : <>{textCol}{children}</>}
    </div>
  );
}
function WorkflowCardM({badge, title, body, phases, accent, featured}) {
  return (
    <div style={{background: featured ? '#0a0a0a' : '#fff', color: featured ? '#fff' : '#0a0a0a', border: featured ? 'none' : '1px solid rgba(0,0,0,.08)', borderRadius:12, padding:26, display:'flex', flexDirection:'column', gap:14, position:'relative', overflow:'hidden'}}>
      {featured && <div style={{position:'absolute', top:0, left:0, right:0, height:3, background:accent}}/>}
      <div style={{fontFamily:'JetBrains Mono,monospace', fontSize:10.5, letterSpacing:'.12em', color: featured ? accent : '#888'}}>{badge}</div>
      <div style={{fontSize:20, fontWeight:600, letterSpacing:'-.01em', lineHeight:1.2}}>{title}</div>
      <div style={{fontSize:13.5, color: featured ? '#a8a8a8' : '#525252', lineHeight:1.55}}>{body}</div>
      <div style={{display:'flex', flexWrap:'wrap', gap:4, marginTop:'auto', paddingTop:10}}>
        {phases.map(p=>(
          <span key={p} style={{fontFamily:'JetBrains Mono,monospace', fontSize:10, padding:'4px 8px', border: featured ? '1px solid rgba(255,255,255,.12)' : '1px solid rgba(0,0,0,.08)', borderRadius:4, color: featured ? '#e8e8e8' : '#0a0a0a'}}>{p}</span>
        ))}
      </div>
    </div>
  );
}

window.VariationMinimal = VariationMinimal;
