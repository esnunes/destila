// Variation 3 — Bold Editorial (REAL SCREENSHOTS)

function VariationEditorial({ accent }) {
  const A = accent;
  return (
    <div style={{background:'#f4f0e8', color:'#161513', fontFamily:'Inter,system-ui,sans-serif'}}>
      <style>{`
        .ed-wrap { max-width: 1280px; margin:0 auto; padding: 0 40px; }
        .ed-serif { font-family: 'Instrument Serif', 'Times New Roman', serif; font-weight: 400; }
        .ed-h1 { font-size: clamp(64px, 10vw, 140px); line-height:.92; letter-spacing:-.04em; margin:0; }
        .ed-h2 { font-size: clamp(44px, 6.2vw, 92px); line-height:.96; letter-spacing:-.03em; margin:0; }
        .ed-body { font-size:19px; line-height:1.55; color:#3a3633; max-width:62ch; }
        .ed-btn { display:inline-flex; align-items:center; gap:10px; padding:14px 20px; border-radius:2px; font-weight:500; font-size:14px; text-decoration:none; cursor:pointer; border:1px solid transparent; font-family:'Inter',sans-serif; }
        .ed-btn-primary-dark { background: var(--accent); color: var(--accent-ink); }
        .ed-btn-ghost { background:transparent; border-color: rgba(255,255,255,.22); color:#f4f0e8; }
        .ed-eyebrow { font-family:'JetBrains Mono',monospace; font-size:11px; letter-spacing:.16em; text-transform:uppercase; color:#6a635c; }
        .ed-italic { font-style: italic; }
        .ed-grid-2 { display:grid; grid-template-columns:1fr 1fr; gap:48px; align-items:center; }
        @media (max-width: 860px) { .ed-grid-2 { grid-template-columns:1fr; gap:32px; } }
      `}</style>

      {/* HERO */}
      <section style={{background:'#161513', color:'#f4f0e8', position:'relative', overflow:'hidden'}}>
        <nav className="ed-wrap" style={{display:'flex', alignItems:'center', padding:'28px 40px', gap:24}}>
          <div style={{display:'flex', alignItems:'center', gap:12}}>
            <div className="ed-serif ed-italic" style={{fontSize:24, fontWeight:500, letterSpacing:'-.015em'}}>Destila</div>
            <span style={{fontFamily:'JetBrains Mono,monospace', fontSize:10, color:'#6a6560', letterSpacing:'.1em'}}>v0.12.3</span>
          </div>
          <div style={{display:'flex', gap:24, fontSize:13.5, color:'#a8a29a', marginLeft:32}}>
            <a style={{color:'inherit', textDecoration:'none'}}>Workflows</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Environment</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Lifecycle</a>
            <a style={{color:'inherit', textDecoration:'none'}}>Docs</a>
          </div>
          <div style={{marginLeft:'auto'}}>
            <a className="ed-btn ed-btn-primary-dark" href="#">View on GitHub</a>
          </div>
        </nav>

        <div className="ed-wrap" style={{padding:'56px 40px 40px'}}>
          <div className="ed-eyebrow" style={{color:A, marginBottom:24, display:'flex', alignItems:'center', gap:14}}>
            <span>Vol. 01 · №001</span>
            <span style={{width:40, height:1, background:'currentColor', opacity:.4}}/>
            <span>The Agentic IDE</span>
          </div>

          <h1 className="ed-h1 ed-serif">
            Your AI does<br/>
            the <span className="ed-italic" style={{color:A}}>work</span>.<br/>
            <span style={{color:'#a8a29a'}}>Destila handles</span><br/>
            <span style={{color:'#a8a29a'}}>the </span><span className="ed-italic">lifecycle</span><span style={{color:'#a8a29a'}}>.</span>
          </h1>

          <div style={{marginTop:40, maxWidth:'64ch'}}>
            <p style={{color:'#c8c2ba', fontSize:19, lineHeight:1.55, margin:0}}>
              An agentic IDE built on Claude Code. Autonomous, multi-phase pipelines that plan, implement, review, and ship on their own — opening a structured conversation only when human judgment actually helps.
            </p>
            <div style={{display:'flex', gap:12, marginTop:28, flexWrap:'wrap'}}>
              <a className="ed-btn ed-btn-primary-dark" href="#">View on GitHub</a>
              <a className="ed-btn ed-btn-ghost" href="#">Read the manual →</a>
            </div>
          </div>
        </div>

        <div className="ed-wrap" style={{padding:'40px 40px 80px'}}>
          <div style={{borderRadius:6, overflow:'hidden', boxShadow:'0 60px 120px -20px rgba(0,0,0,.7)'}}>
            <img src="assets/implement-video.png" alt="Destila · implement workflow" style={{display:'block', width:'100%'}}/>
          </div>
        </div>
      </section>

      {/* QUOTE / SIGNATURE */}
      <section style={{padding:'120px 0', background:'#f4f0e8'}}>
        <div className="ed-wrap">
          <div style={{display:'grid', gridTemplateColumns:'.6fr 1.4fr', gap:48}}>
            <div>
              <div className="ed-eyebrow" style={{marginBottom:14}}>§ 01 · Signature</div>
              <div style={{fontFamily:'JetBrains Mono,monospace', fontSize:12, color:A}}>on the session lifecycle</div>
            </div>
            <blockquote style={{margin:0}}>
              <div className="ed-serif" style={{fontSize:'clamp(40px, 5.5vw, 72px)', lineHeight:1, letterSpacing:'-.025em'}}>
                <span style={{color:A, fontSize:'1.3em', lineHeight:0}} className="ed-italic">"</span>
                Start a workflow. Walk away. <span className="ed-italic">Come back hours later</span> — it just resumes, with full context intact<span style={{color:A}}>.</span>
              </div>
              <div className="ed-eyebrow" style={{marginTop:32}}>— The promise, simply stated.</div>
            </blockquote>
          </div>

          <div style={{marginTop:80, display:'grid', gridTemplateColumns:'repeat(3,1fr)', gap:32}}>
            {[
              ['5 min', 'Default inactivity timeout. Configurable. Claude processes self-terminate, freeing memory, CPU, and model context.'],
              ['1 keystroke', 'Resume latency. Destila persists the claude_session_id and restores it the moment you type.'],
              ['N → 1', 'Multiple LiveView tabs on one session share a single underlying process via a DynamicSupervisor + registry.'],
            ].map(([v,t],i)=>(
              <div key={i} style={{borderTop:'1px solid rgba(22,21,19,.14)', paddingTop:24}}>
                <div className="ed-serif" style={{fontSize:72, lineHeight:.9, letterSpacing:'-.03em'}}>{v}</div>
                <div style={{fontSize:14, color:'#3a3633', marginTop:14, lineHeight:1.55, maxWidth:'34ch'}}>{t}</div>
              </div>
            ))}
          </div>

          <div style={{marginTop:56}}>
            <Shot src="assets/crafting-board.png" caption="The crafting board · live status across every session"/>
          </div>
        </div>
      </section>

      {/* DRAFTS */}
      <section style={{padding:'120px 0', background:'#ebe5d9', borderTop:'1px solid rgba(22,21,19,.1)'}}>
        <div className="ed-wrap">
          <div className="ed-grid-2">
            <div>
              <div className="ed-eyebrow" style={{marginBottom:14}}>§ 02 · Ideation</div>
              <h2 className="ed-h2 ed-serif">Capture <span className="ed-italic">loose</span> ideas. Launch them into code.</h2>
              <p className="ed-body" style={{marginTop:24}}>
                A kanban for drafts — High, Medium, Low — with fractional positions. When you're ready, launch a draft directly into a workflow; it auto-archives on successful kick-off. Discard is soft. Nothing is ever gone.
              </p>
            </div>
            <Shot src="assets/drafts.png" caption="destila · drafts"/>
          </div>
          <div style={{marginTop:48, maxWidth:760}}>
            <Shot src="assets/drafts-edit.png" caption="Edit draft · prompt, priority, project"/>
          </div>
        </div>
      </section>

      {/* THREE WORKFLOWS */}
      <section style={{padding:'120px 0', background:'#f4f0e8'}}>
        <div className="ed-wrap">
          <div className="ed-eyebrow" style={{marginBottom:14}}>§ 03 · The Core Product</div>
          <h2 className="ed-h2 ed-serif">Three workflows.<br/><span className="ed-italic" style={{color:A}}>One surface</span>.</h2>
          <p className="ed-body" style={{marginTop:24}}>
            Every path from rough idea to shipped code fits one of three shapes. They share context, artifacts, and the same supervised AI session. An Implement run can consume the prompt from a completed Brainstorm.
          </p>

          <div style={{marginTop:56, display:'grid', gridTemplateColumns:'repeat(3,1fr)', gap:24}}>
            <WorkflowCardE num="i" name="Brainstorm" body="Four conversational phases that turn a rough idea into a production-ready implementation prompt." phases={['Task','Gherkin','Concerns','Prompt']} accent={A}/>
            <WorkflowCardE num="ii" name="Code Chat" body="Free-form AI chat with full tool access over your codebase. Single-phase." phases={['Chat']} accent={A}/>
            <WorkflowCardE num="iii" name="Implement" body="Seven-phase, mostly-autonomous pipeline: plan → shippable code with a recorded demo." phases={['Plan','Deepen','Work','Review','Tests','Video','Adjust']} accent={A} featured/>
          </div>

          <div style={{marginTop:56}}>
            <Shot src="assets/workflow-new.png" caption="New session · pick a workflow"/>
          </div>
        </div>
      </section>

      {/* BRAINSTORM */}
      <section style={{padding:'120px 0', background:'#ebe5d9', borderTop:'1px solid rgba(22,21,19,.1)'}}>
        <div className="ed-wrap">
          <div className="ed-grid-2">
            <Shot src="assets/brainstorm-questions.png" caption="Phase 1 · structured questions"/>
            <div>
              <div className="ed-eyebrow" style={{marginBottom:14}}>§ 04 · Brainstorm</div>
              <h2 className="ed-h2 ed-serif">The AI <span className="ed-italic">asks</span>.<br/>You answer.</h2>
              <p className="ed-body" style={{marginTop:24}}>
                Structured questions — single-select, multi-select, free-text. Locked answers stay editable mid-form. After four phases, you export a production-ready prompt.
              </p>
            </div>
          </div>
          <div style={{marginTop:56}}>
            <Shot src="assets/brainstorm-prompt.png" caption="Phase 4 · generated prompt"/>
          </div>
        </div>
      </section>

      {/* IMPLEMENT */}
      <section style={{padding:'120px 0', background:'#f4f0e8'}}>
        <div className="ed-wrap">
          <div className="ed-eyebrow" style={{marginBottom:14}}>§ 05 · Implement</div>
          <h2 className="ed-h2 ed-serif"><span className="ed-italic">Seven</span> phases.<br/>Prompt to PR.</h2>
          <p className="ed-body" style={{marginTop:24}}>
            Pick a prompt, link a project, kick off. Destila spins up a worktree and runs the pipeline end-to-end — planning, coding, reviewing, testing, recording, adjusting. You interact when you choose to.
          </p>

          <div style={{marginTop:48}}>
            <Shot src="assets/implement-new.png" caption="Implement · choose a prompt, link a project"/>
          </div>

          <div className="ed-grid-2" style={{marginTop:56}}>
            <div>
              <div className="ed-eyebrow" style={{marginBottom:10}}>Phase 6 · records the demo</div>
              <h3 className="ed-serif" style={{fontSize:44, margin:0, lineHeight:1, letterSpacing:'-.02em'}}>Every run ships with a <span className="ed-italic">feature video</span>.</h3>
              <p className="ed-body" style={{marginTop:18}}>
                During browser tests, Destila captures a walkthrough MP4. It streams in the metadata sidebar next to the plan, diff summary, review notes, and adjustments.
              </p>
            </div>
            <Shot src="assets/implement-video-modal.png" caption="Phase 6 · modal playback"/>
          </div>

          <div className="ed-grid-2" style={{marginTop:56}}>
            <Shot src="assets/implement-finished.png" caption="Phase 7 · PR opened · adjustments push automatically"/>
            <div>
              <div className="ed-eyebrow" style={{marginBottom:10}}>Phase 7 · adjustments</div>
              <h3 className="ed-serif" style={{fontSize:44, margin:0, lineHeight:1, letterSpacing:'-.02em'}}>Commit, push, PR.<br/>Then <span className="ed-italic">iterate</span> in place.</h3>
              <p className="ed-body" style={{marginTop:18}}>
                When implementation is clean, Destila opens the PR. Any adjustment you type is committed and pushed — the PR updates automatically.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* CODE CHAT */}
      <section style={{padding:'120px 0', background:'#ebe5d9', borderTop:'1px solid rgba(22,21,19,.1)'}}>
        <div className="ed-wrap">
          <div className="ed-grid-2">
            <Shot src="assets/chat.png" caption="Code chat · full tool access"/>
            <div>
              <div className="ed-eyebrow" style={{marginBottom:14}}>§ 06 · Code Chat</div>
              <h2 className="ed-h2 ed-serif">A chat that <span className="ed-italic">reads</span><br/>your actual codebase.</h2>
              <p className="ed-body" style={{marginTop:24}}>
                Full tool access over the session's worktree — read, write, edit, search, bash. No snippets. Ask where something lives, why it broke, or tell the agent to start the dev server.
              </p>
            </div>
          </div>
          <div style={{marginTop:48, maxWidth:860}}>
            <Shot src="assets/chat-service.png" caption="The agent starts the dev server and returns the live URL"/>
          </div>
        </div>
      </section>

      {/* TERMINAL + SERVICE */}
      <section style={{padding:'120px 0', background:'#161513', color:'#f4f0e8'}}>
        <div className="ed-wrap">
          <div className="ed-eyebrow" style={{color:A, marginBottom:14}}>§ 07 · Environment</div>
          <h2 className="ed-h2 ed-serif">A <span className="ed-italic">real</span> terminal.<br/>A <span className="ed-italic">real</span> server.<br/><span style={{color:'#a8a29a'}}>Scoped to each session.</span></h2>
          <p className="ed-body" style={{marginTop:24, color:'#c8c2ba'}}>
            Destila clones your repo once into a cache, then creates an isolated git worktree per session. An ephemeral port is allocated and injected into your run command. A full xterm.js terminal lives in the sidebar, surviving navigation via a background GenServer.
          </p>

          <div style={{marginTop:56}}>
            <Shot src="assets/terminal.png" caption="Inline xterm.js · attached to the session worktree"/>
          </div>
          <div style={{marginTop:32, maxWidth:920}}>
            <Shot src="assets/service-starting.png" caption="Dev server boots via tmux · live URL lands in the sidebar"/>
          </div>

          <div style={{marginTop:56}}>
            <AlivenessStrip theme="dark"/>
          </div>
        </div>
      </section>

      {/* PROJECTS */}
      <section style={{padding:'120px 0', background:'#f4f0e8'}}>
        <div className="ed-wrap">
          <div className="ed-grid-2">
            <div>
              <div className="ed-eyebrow" style={{marginBottom:14}}>§ 08 · Projects</div>
              <h2 className="ed-h2 ed-serif">Name it. Point it<br/>at a <span className="ed-italic">repo</span>. Done.</h2>
              <p className="ed-body" style={{marginTop:24}}>
                A project needs a name plus a git URL or a local folder. Optional setup command runs pre-worktree. An optional run command plus service env var makes it a webservice — Destila injects an ephemeral port every session.
              </p>
            </div>
            <Shot src="assets/projects-edit.png" caption="Project config"/>
          </div>
        </div>
      </section>

      {/* FINAL CTA */}
      <section style={{padding:'140px 0 80px', background:'#161513', color:'#f4f0e8', position:'relative', overflow:'hidden'}}>
        <div style={{position:'absolute', inset:0, background:`radial-gradient(ellipse at 50% 0%, ${A}18 0%, transparent 55%)`}}/>
        <div className="ed-wrap" style={{position:'relative', textAlign:'center'}}>
          <div className="ed-eyebrow" style={{color:A, marginBottom:24}}>Open Source · MIT</div>
          <h2 className="ed-serif" style={{fontSize:'clamp(56px, 8vw, 120px)', lineHeight:.95, letterSpacing:'-.03em', maxWidth:'14ch', margin:'0 auto'}}>
            Ship without <span className="ed-italic" style={{color:A}}>babysitting</span> the robot.
          </h2>
          <div style={{display:'flex', gap:12, justifyContent:'center', marginTop:40, flexWrap:'wrap'}}>
            <a className="ed-btn ed-btn-primary-dark" href="#">View on GitHub</a>
            <a className="ed-btn ed-btn-ghost" href="#">Read the manual →</a>
          </div>
          <div style={{marginTop:80, paddingTop:24, borderTop:'1px solid rgba(255,255,255,.1)', display:'flex', justifyContent:'space-between', fontFamily:'JetBrains Mono,monospace', fontSize:11, color:'#6a6560', flexWrap:'wrap', gap:12}}>
            <span>Destila · Elixir · Phoenix LiveView · Claude Code</span>
            <span>MIT · © 2026 · Issue № 01</span>
          </div>
        </div>
      </section>
    </div>
  );
}

function WorkflowCardE({num, name, body, phases, accent, featured}) {
  return (
    <div style={{
      background: featured ? '#161513' : 'transparent',
      color: featured ? '#f4f0e8' : '#161513',
      padding: '32px 28px',
      border: featured ? 'none' : '1px solid rgba(22,21,19,.14)',
      borderRadius:3,
      display:'flex', flexDirection:'column', gap:16,
      minHeight: 320
    }}>
      <div style={{display:'flex', alignItems:'baseline', gap:10}}>
        <span className="ed-serif ed-italic" style={{fontSize:32, color:accent, letterSpacing:'-.02em'}}>{num}.</span>
        <span className="ed-serif" style={{fontSize:32, letterSpacing:'-.02em'}}>{name}</span>
      </div>
      <p style={{fontSize:15, lineHeight:1.6, color: featured ? '#c8c2ba' : '#3a3633', margin:0}}>{body}</p>
      <div style={{display:'flex', flexWrap:'wrap', gap:6, marginTop:'auto'}}>
        {phases.map(p=>(
          <span key={p} style={{
            fontFamily:'JetBrains Mono,monospace', fontSize:10.5,
            padding:'3px 8px',
            border: featured ? '1px solid rgba(255,255,255,.18)' : '1px solid rgba(22,21,19,.2)',
            borderRadius:2,
            color: featured ? '#e8e8e8' : '#161513'
          }}>{p}</span>
        ))}
      </div>
    </div>
  );
}

window.VariationEditorial = VariationEditorial;
