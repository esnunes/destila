
/* ==== src/mocks.jsx ==== */
// Shared mock product UIs. Aesthetic-neutral — variations pass theme via props/CSS vars.
// Each component is a small, self-contained snippet of Destila's UI.

const {
  useState,
  useEffect,
  useRef
} = React;

// ---------- tiny primitives ----------

function Dot({
  color = '#10b981',
  pulse = true,
  size = 8
}) {
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-block',
      width: size,
      height: size,
      borderRadius: '50%',
      background: color,
      boxShadow: pulse ? `0 0 0 0 ${color}66` : 'none',
      animation: pulse ? 'destila-pulse 2s ease-in-out infinite' : 'none',
      flexShrink: 0
    }
  });
}
function TypeCaret() {
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: 'inline-block',
      width: '1ch',
      background: 'currentColor',
      animation: 'destila-blink 1s step-end infinite',
      marginLeft: 2
    }
  }, "\xA0");
}

// ---------- Drafts Kanban ----------
// Three columns: High / Medium / Low. Each card has a title, project tag, priority dot.

function DraftsBoard({
  theme = 'dark'
}) {
  const drafts = {
    High: [{
      t: 'Streaming responses from OpenAI-compatible providers',
      p: 'llmgateway'
    }, {
      t: 'Fix race when worktree cache evicts an active session',
      p: 'destila-core'
    }],
    Medium: [{
      t: 'Project picker: recent projects on top',
      p: 'destila-core'
    }, {
      t: 'Add Gherkin scenario diff view to review phase',
      p: 'destila-core'
    }, {
      t: 'Skills registry — per-phase override file',
      p: 'destila-core'
    }],
    Low: [{
      t: 'Dark terminal background toggle',
      p: 'destila-core'
    }, {
      t: 'Oban dashboard deep links',
      p: 'destila-core'
    }]
  };
  const priColors = {
    High: '#ef4444',
    Medium: '#f59e0b',
    Low: '#6b7280'
  };
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.06)' : 'rgba(0,0,0,.05)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      padding: 14,
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      marginBottom: 12
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12,
      fontWeight: 600,
      letterSpacing: '.04em'
    }
  }, "DRAFTS"), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 11,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "7 \xB7 filter: all projects")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: '1fr 1fr 1fr',
      gap: 10
    }
  }, Object.entries(drafts).map(([col, items]) => /*#__PURE__*/React.createElement("div", {
    key: col
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 6,
      marginBottom: 8,
      fontSize: 11,
      letterSpacing: '.04em',
      color: muted
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: priColors[col],
    pulse: false,
    size: 6
  }), /*#__PURE__*/React.createElement("span", null, col.toUpperCase()), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, items.length)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6
    }
  }, items.map((d, i) => /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      background: chip,
      border: `1px solid ${border}`,
      borderRadius: 6,
      padding: '8px 10px'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12,
      lineHeight: 1.4,
      marginBottom: 6
    }
  }, d.t), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 10,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, d.p))))))));
}

// ---------- Workflow Runner (phase bar + chat excerpt) ----------

function WorkflowRunner({
  theme = 'dark',
  accent = '#d4ff3a',
  kind = 'implement'
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chipBg = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  const phases = kind === 'implement' ? ['Plan', 'Deepen', 'Implement', 'Review', 'Browser test', 'Record video', 'Adjust'] : ['Context', 'Gherkin', 'Approach', 'Prompt'];
  const active = kind === 'implement' ? 3 : 2;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      color: fg,
      fontFamily: 'Inter,sans-serif',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '10px 14px',
      borderBottom: `1px solid ${border}`
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: "#10b981"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      fontWeight: 500
    }
  }, "Extract billing module into a service"), /*#__PURE__*/React.createElement("div", {
    style: {
      marginLeft: 'auto',
      fontSize: 11,
      fontFamily: 'JetBrains Mono,monospace',
      color: muted
    }
  }, kind === 'implement' ? 'implement_prompt' : 'brainstorm_idea')), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 4,
      padding: '10px 14px'
    }
  }, phases.map((p, i) => /*#__PURE__*/React.createElement("div", {
    key: p,
    style: {
      flex: 1,
      display: 'flex',
      flexDirection: 'column',
      gap: 4
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      height: 3,
      background: i <= active ? accent : chipBg,
      borderRadius: 2,
      opacity: i === active ? 1 : i < active ? .8 : .5
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 10,
      fontFamily: 'JetBrains Mono,monospace',
      color: i === active ? fg : muted,
      letterSpacing: '.02em'
    }
  }, String(i + 1).padStart(2, '0'), " ", p)))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '14px',
      display: 'flex',
      flexDirection: 'column',
      gap: 10
    }
  }, kind === 'implement' ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(ChatBubble, {
    role: "assistant",
    theme: theme,
    accent: accent
  }, "Running ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "mix test test/destila/billing_test.exs"), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 6,
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11,
      color: muted
    }
  }, "\u2192 14 tests, 0 failures (2.3s)")), /*#__PURE__*/React.createElement(ChatBubble, {
    role: "assistant",
    theme: theme,
    accent: accent
  }, "Review pass complete. Fixed an N+1 on ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "Billing.list_invoices/1"), " with a preload. Moving to browser test."), /*#__PURE__*/React.createElement(ToolCall, {
    theme: theme,
    label: "browser_test",
    sub: "navigating http://localhost:4821/billing"
  })) : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(ChatBubble, {
    role: "assistant",
    theme: theme,
    accent: accent
  }, "I've drafted 3 Gherkin scenarios for this feature. Pick the ones that match what you want:"), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6
    }
  }, ['Given a user with an expired invoice, when they load /billing, then a banner appears', 'Given an admin, when they mark an invoice paid, then the customer is emailed', 'Given a failed webhook, when retries exhaust, then an alert fires'].map((s, i) => /*#__PURE__*/React.createElement("label", {
    key: i,
    style: {
      display: 'flex',
      gap: 8,
      alignItems: 'flex-start',
      fontSize: 12,
      padding: '8px 10px',
      background: chipBg,
      border: `1px solid ${border}`,
      borderRadius: 6
    }
  }, /*#__PURE__*/React.createElement("input", {
    type: "checkbox",
    defaultChecked: i < 2,
    style: {
      accentColor: accent,
      marginTop: 2
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      lineHeight: 1.4
    }
  }, s)))))));
}
function ChatBubble({
  role,
  theme,
  accent,
  children
}) {
  const dark = theme === 'dark';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 10,
      alignItems: 'flex-start'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 20,
      height: 20,
      borderRadius: '50%',
      border: `1px solid ${border}`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      flexShrink: 0,
      marginTop: 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 6,
      height: 6,
      borderRadius: '50%',
      background: accent
    }
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12.5,
      lineHeight: 1.55,
      flex: 1
    }
  }, children));
}
function ToolCall({
  theme,
  label,
  sub
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 8,
      alignItems: 'center',
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 6,
      padding: '6px 10px',
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      opacity: .6
    }
  }, "\u25B8"), /*#__PURE__*/React.createElement("span", {
    style: {
      fontWeight: 600
    }
  }, label), /*#__PURE__*/React.createElement("span", {
    style: {
      color: muted
    }
  }, sub), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      color: muted
    }
  }, "running\u2026"));
}

// ---------- Terminal (xterm-like) ----------

function TerminalPanel({
  theme = 'dark',
  compact = false
}) {
  const dark = theme === 'dark';
  const bg = dark ? '#0a0a0a' : '#0f0f10';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const lines = [{
    c: '#8a8a8a',
    t: '~/projects/destila-core on feat/billing-svc'
  }, {
    c: '#d4ff3a',
    t: '$ ',
    tail: 'mix phx.server'
  }, {
    c: '#aaa',
    t: '[info] Running DestilaWeb.Endpoint with Bandit 1.5 at 0.0.0.0:4821 (http)'
  }, {
    c: '#aaa',
    t: '[info] Access DestilaWeb.Endpoint at http://localhost:4821'
  }, {
    c: '#8a8a8a',
    t: '[watch] build finished, watching for changes...'
  }, {
    c: '#d4ff3a',
    t: '$ ',
    tail: 'git status'
  }, {
    c: '#aaa',
    t: 'On branch feat/billing-svc'
  }, {
    c: '#10b981',
    t: 'nothing to commit, working tree clean'
  }, {
    c: '#d4ff3a',
    t: '$ ',
    tail: ''
  }];
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      fontFamily: 'JetBrains Mono,monospace',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 6,
      padding: '8px 12px',
      borderBottom: `1px solid ${border}`,
      background: 'rgba(255,255,255,.02)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 10,
      height: 10,
      borderRadius: '50%',
      background: '#ff5f57'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 10,
      height: 10,
      borderRadius: '50%',
      background: '#febc2e'
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 10,
      height: 10,
      borderRadius: '50%',
      background: '#28c840'
    }
  })), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 11,
      color: '#8a8a8a',
      marginLeft: 8
    }
  }, "zsh \u2014 destila-core \xB7 worktree: feat/billing-svc"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontSize: 10,
      color: '#8a8a8a'
    }
  }, "80\xD724")), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '12px 14px',
      fontSize: 12,
      lineHeight: 1.6,
      minHeight: compact ? 160 : 220
    }
  }, lines.map((l, i) => /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      color: l.c,
      whiteSpace: 'pre'
    }
  }, l.t, l.tail && /*#__PURE__*/React.createElement("span", {
    style: {
      color: '#e8e8e8'
    }
  }, l.tail), i === lines.length - 1 && /*#__PURE__*/React.createElement(TypeCaret, null)))));
}

// ---------- Dev server / service card ----------

function ServiceCard({
  theme = 'dark',
  accent = '#d4ff3a'
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      padding: 14,
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      marginBottom: 10
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: "#10b981"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      fontWeight: 500
    }
  }, "Dev server"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontSize: 11,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "tmux:9")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 6,
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11.5
    }
  }, /*#__PURE__*/React.createElement(Row, {
    label: "PORT",
    value: "4821",
    muted: muted,
    chip: chip,
    border: border,
    accent: accent
  }), /*#__PURE__*/React.createElement(Row, {
    label: "URL",
    value: "http://localhost:4821",
    link: true,
    muted: muted,
    chip: chip,
    border: border,
    accent: accent
  }), /*#__PURE__*/React.createElement(Row, {
    label: "CMD",
    value: "mix phx.server",
    muted: muted,
    chip: chip,
    border: border,
    accent: accent
  }), /*#__PURE__*/React.createElement(Row, {
    label: "UP",
    value: "00:04:12",
    muted: muted,
    chip: chip,
    border: border,
    accent: accent
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6,
      marginTop: 12
    }
  }, ['Restart', 'Stop', 'Logs'].map((a, i) => /*#__PURE__*/React.createElement("button", {
    key: a,
    style: {
      flex: 1,
      padding: '7px 10px',
      border: `1px solid ${border}`,
      background: i === 0 ? accent : chip,
      color: i === 0 ? '#0a0a0a' : fg,
      borderRadius: 6,
      fontSize: 11,
      fontFamily: 'JetBrains Mono,monospace',
      fontWeight: 600,
      cursor: 'pointer'
    }
  }, a))));
}
function Row({
  label,
  value,
  link,
  muted,
  chip,
  border,
  accent
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10,
      padding: '6px 10px',
      background: chip,
      border: `1px solid ${border}`,
      borderRadius: 6
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: muted,
      width: 40,
      fontSize: 10,
      letterSpacing: '.05em'
    }
  }, label), /*#__PURE__*/React.createElement("span", {
    style: {
      color: link ? accent : 'inherit'
    }
  }, value));
}

// ---------- Video / feature clip card ----------

function VideoCard({
  theme = 'dark',
  accent = '#d4ff3a'
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      overflow: 'hidden',
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      aspectRatio: '16/9',
      background: 'linear-gradient(135deg,#111 0%,#1a1a1a 100%)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      background: 'repeating-linear-gradient(135deg, rgba(255,255,255,.02) 0 12px, rgba(255,255,255,.05) 12px 24px)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      display: 'flex',
      alignItems: 'center',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 44,
      height: 44,
      borderRadius: '50%',
      background: accent,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "14",
    height: "16",
    viewBox: "0 0 14 16",
    fill: "#0a0a0a"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M0 0l14 8-14 8z"
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 12,
      color: '#e8e8e8'
    }
  }, "feature.mp4 \xB7 00:47")), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 10,
      left: 10,
      display: 'flex',
      gap: 6,
      alignItems: 'center',
      padding: '4px 8px',
      background: 'rgba(0,0,0,.6)',
      border: `1px solid rgba(255,255,255,.08)`,
      borderRadius: 4,
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 10,
      color: '#e8e8e8'
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: "#ef4444",
    size: 6
  }), /*#__PURE__*/React.createElement("span", null, "RECORDED BY PHASE 6"))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '10px 14px',
      display: 'flex',
      alignItems: 'center',
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12
    }
  }, "Billing service extraction \u2014 walkthrough"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontSize: 10,
      fontFamily: 'JetBrains Mono,monospace',
      color: muted
    }
  }, "implement_prompt \xB7 phase 6")));
}

// ---------- Aliveness strip ----------

function AlivenessStrip({
  theme = 'dark'
}) {
  const dark = theme === 'dark';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const chip = dark ? 'rgba(255,255,255,.03)' : 'rgba(0,0,0,.03)';
  const items = [{
    dot: '#10b981',
    label: 'billing-svc',
    sub: 'running · 3 turns · $0.42'
  }, {
    dot: '#10b981',
    label: 'gherkin-review',
    sub: 'running · 1 turn · $0.08'
  }, {
    dot: '#6b7280',
    label: 'readme-pass',
    sub: 'idle · auto-resume ready'
  }, {
    dot: '#6b7280',
    label: 'invoice-refactor',
    sub: 'idle · 14m since'
  }, {
    dot: '#ef4444',
    label: 'llmgateway-spike',
    sub: 'stopped · exit 1'
  }];
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'grid',
      gridTemplateColumns: 'repeat(auto-fit,minmax(220px,1fr))',
      gap: 8
    }
  }, items.map((x, i) => /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      display: 'flex',
      gap: 10,
      alignItems: 'center',
      padding: '10px 12px',
      background: chip,
      border: `1px solid ${border}`,
      borderRadius: 8,
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: x.dot,
    pulse: x.dot === '#10b981'
  }), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12,
      fontWeight: 500
    }
  }, x.label), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 10.5,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace',
      marginTop: 2
    }
  }, x.sub)))));
}

// ---------- Code Chat snippet ----------

function CodeChat({
  theme = 'dark',
  accent = '#d4ff3a'
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      padding: 14,
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 8,
      marginBottom: 12
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: "#10b981"
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      fontWeight: 500
    }
  }, "Code chat \xB7 destila-core"), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontSize: 10.5,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "read \xB7 write \xB7 edit \xB7 search \xB7 bash")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12.5,
      lineHeight: 1.55,
      padding: '8px 10px',
      background: chip,
      borderRadius: 6,
      border: `1px solid ${border}`
    }
  }, "Where does session aliveness get broadcast? I see the dot on the card but can't find the PubSub."), /*#__PURE__*/React.createElement(ChatBubble, {
    role: "assistant",
    theme: theme,
    accent: accent
  }, "It's in ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "Destila.AI.Session"), " \u2014 the ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "handle_info(:tick, \u2026)"), " clause broadcasts ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, `{:aliveness, state}`), " to ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "\"session:#", '{', "id", '}', "\""), " every 5s. The card subscribes in its mount."), /*#__PURE__*/React.createElement(ToolCall, {
    theme: theme,
    label: "read",
    sub: "lib/destila/ai/session.ex"
  })));
}

// ---------- Metadata sidebar snippet ----------

function MetadataList({
  theme = 'dark',
  accent = '#d4ff3a'
}) {
  const dark = theme === 'dark';
  const bg = dark ? 'rgba(255,255,255,.02)' : '#fff';
  const border = dark ? 'rgba(255,255,255,.08)' : 'rgba(0,0,0,.08)';
  const fg = dark ? '#e8e8e8' : '#111';
  const muted = dark ? '#8a8a8a' : '#6b7280';
  const chip = dark ? 'rgba(255,255,255,.04)' : 'rgba(0,0,0,.03)';
  const items = [{
    phase: 'plan',
    kind: 'md',
    name: 'initial-plan.md'
  }, {
    phase: 'plan',
    kind: 'md',
    name: 'deepened-plan.md'
  }, {
    phase: 'implement',
    kind: 'txt',
    name: 'diff-summary.txt'
  }, {
    phase: 'review',
    kind: 'md',
    name: 'review-notes.md'
  }, {
    phase: 'record',
    kind: 'mp4',
    name: 'feature.mp4'
  }, {
    phase: 'adjust',
    kind: 'md',
    name: 'adjustments.md'
  }];
  const iconColor = {
    md: '#60a5fa',
    txt: '#e8e8e8',
    mp4: accent
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `1px solid ${border}`,
      borderRadius: 10,
      padding: 14,
      color: fg,
      fontFamily: 'Inter,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      marginBottom: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12,
      fontWeight: 600,
      letterSpacing: '.04em'
    }
  }, "EXPORTED"), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 10.5,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, items.length, " artifacts")), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 4
    }
  }, items.map((x, i) => /*#__PURE__*/React.createElement("div", {
    key: i,
    style: {
      display: 'flex',
      gap: 10,
      alignItems: 'center',
      padding: '8px 10px',
      background: chip,
      border: `1px solid ${border}`,
      borderRadius: 6
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 9,
      fontWeight: 700,
      color: iconColor[x.kind],
      width: 28,
      textAlign: 'center',
      padding: '2px 4px',
      background: 'rgba(0,0,0,.3)',
      border: `1px solid ${border}`,
      borderRadius: 3
    }
  }, x.kind.toUpperCase()), /*#__PURE__*/React.createElement("span", {
    style: {
      fontSize: 12,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, x.name), /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 'auto',
      fontSize: 10,
      color: muted,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "phase: ", x.phase)))));
}

// Expose to global scope for other files
Object.assign(window, {
  Dot,
  TypeCaret,
  DraftsBoard,
  WorkflowRunner,
  ChatBubble,
  ToolCall,
  TerminalPanel,
  ServiceCard,
  VideoCard,
  AlivenessStrip,
  CodeChat,
  MetadataList
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

/* ==== src/shot.jsx ==== */
// Shared screenshot helpers for all variations
// Screenshots are already macOS browser windows — don't re-frame them.

function Shot({
  src,
  caption,
  shadow = true,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("figure", {
    style: {
      margin: 0,
      ...style
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: src,
    alt: caption || '',
    loading: "lazy",
    decoding: "async",
    style: {
      display: 'block',
      width: '100%',
      height: 'auto',
      borderRadius: 10,
      boxShadow: shadow ? '0 30px 60px -20px rgba(0,0,0,.35), 0 12px 24px -12px rgba(0,0,0,.25)' : 'none'
    }
  }), caption && /*#__PURE__*/React.createElement("figcaption", {
    style: {
      marginTop: 12,
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11,
      letterSpacing: '.04em',
      color: 'currentColor',
      opacity: .55
    }
  }, caption));
}

// A cluster of overlapping shots for the hero
function ShotStack({
  main,
  secondary,
  accent
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      transform: 'rotate(-1deg)',
      boxShadow: '0 40px 80px -20px rgba(0,0,0,.5)',
      borderRadius: 12
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: main,
    style: {
      display: 'block',
      width: '100%',
      height: 'auto',
      borderRadius: 10
    }
  })), secondary && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      right: '-6%',
      bottom: '-8%',
      width: '52%',
      transform: 'rotate(3deg)',
      boxShadow: '0 30px 60px -15px rgba(0,0,0,.6)',
      borderRadius: 10,
      border: `2px solid ${accent}`
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: secondary,
    style: {
      display: 'block',
      width: '100%',
      height: 'auto',
      borderRadius: 8
    }
  })));
}
window.Shot = Shot;
window.ShotStack = ShotStack;

/* ==== src/variation-minimal.jsx ==== */
// Variation 1 — Dev-tool minimalism (REAL SCREENSHOTS)
// Dark hero, light body. Tight grid. Accent highlights. Real Destila screenshots.

function VariationMinimal({
  accent
}) {
  const A = accent;
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: '#fafaf9',
      color: '#0a0a0a',
      fontFamily: 'Inter,system-ui,sans-serif'
    }
  }, /*#__PURE__*/React.createElement("style", null, `
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
      `), /*#__PURE__*/React.createElement("section", {
    style: {
      background: '#0a0a0a',
      color: '#fff',
      position: 'relative',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      backgroundImage: 'linear-gradient(rgba(255,255,255,.035) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.035) 1px, transparent 1px)',
      backgroundSize: '48px 48px',
      maskImage: 'radial-gradient(ellipse at 50% 30%, black 30%, transparent 75%)'
    }
  }), /*#__PURE__*/React.createElement("nav", {
    className: "min-wrap",
    style: {
      position: 'relative',
      display: 'flex',
      alignItems: 'center',
      padding: '22px 32px',
      gap: 24
    }
  }, /*#__PURE__*/React.createElement(LogoM, {
    accent: A
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 22,
      fontSize: 13.5,
      color: '#a8a8a8',
      marginLeft: 8
    }
  }, /*#__PURE__*/React.createElement("a", {
    style: {
      color: 'inherit',
      textDecoration: 'none'
    }
  }, "Workflows"), /*#__PURE__*/React.createElement("a", {
    style: {
      color: 'inherit',
      textDecoration: 'none'
    }
  }, "Environment"), /*#__PURE__*/React.createElement("a", {
    style: {
      color: 'inherit',
      textDecoration: 'none'
    }
  }, "Lifecycle"), /*#__PURE__*/React.createElement("a", {
    style: {
      color: 'inherit',
      textDecoration: 'none'
    }
  }, "Docs")), /*#__PURE__*/React.createElement("div", {
    style: {
      marginLeft: 'auto',
      display: 'flex',
      gap: 10,
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11,
      color: '#888'
    }
  }, "v0.12.3"), /*#__PURE__*/React.createElement("a", {
    className: "min-btn min-btn-primary",
    href: "#"
  }, /*#__PURE__*/React.createElement(GhIconM, null), " View on GitHub"))), /*#__PURE__*/React.createElement("div", {
    className: "min-wrap",
    style: {
      position: 'relative',
      padding: '64px 32px 40px',
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 20,
      display: 'inline-flex',
      alignItems: 'center',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: A
  }), /*#__PURE__*/React.createElement("span", null, "The Agentic IDE \xB7 built on Claude Code")), /*#__PURE__*/React.createElement("h1", {
    className: "min-h1",
    style: {
      maxWidth: '18ch',
      margin: '0 auto'
    }
  }, "Your AI does the work.", /*#__PURE__*/React.createElement("br", null), /*#__PURE__*/React.createElement("span", {
    style: {
      color: A
    }
  }, "Destila handles the lifecycle.")), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      color: '#a8a8a8',
      margin: '24px auto 0',
      maxWidth: '62ch',
      textAlign: 'center',
      fontSize: 18
    }
  }, "An agentic IDE that takes you from rough ideas to shipped code. Autonomous, multi-phase pipelines that plan, implement, review, and ship \u2014 pausing for human judgment only when it actually helps."), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 10,
      marginTop: 30,
      flexWrap: 'wrap',
      justifyContent: 'center'
    }
  }, /*#__PURE__*/React.createElement("a", {
    className: "min-btn min-btn-primary",
    href: "#"
  }, /*#__PURE__*/React.createElement(GhIconM, null), " View on GitHub"), /*#__PURE__*/React.createElement("a", {
    className: "min-btn min-btn-ghost",
    href: "#"
  }, "Read the docs \u2192"))), /*#__PURE__*/React.createElement("div", {
    className: "min-wrap",
    style: {
      position: 'relative',
      padding: '24px 32px 96px'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      borderRadius: 14,
      overflow: 'hidden',
      boxShadow: '0 60px 120px -20px rgba(0,0,0,.8), 0 0 0 1px rgba(255,255,255,.06)'
    }
  }, /*#__PURE__*/React.createElement("img", {
    src: "assets/implement-video.png",
    alt: "Destila \u2014 Implement workflow with feature video",
    style: {
      display: 'block',
      width: '100%',
      height: 'auto'
    }
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 28,
      marginTop: 36,
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11.5,
      color: '#888',
      justifyContent: 'center',
      flexWrap: 'wrap'
    }
  }, /*#__PURE__*/React.createElement(StatM, {
    label: "WORKTREES",
    value: "per-session"
  }), /*#__PURE__*/React.createElement(StatM, {
    label: "RESUME",
    value: "one keystroke"
  }), /*#__PURE__*/React.createElement(StatM, {
    label: "PIPELINES",
    value: "4 + 1 + 7 phases"
  }), /*#__PURE__*/React.createElement(StatM, {
    label: "POLLING",
    value: "zero"
  })))), /*#__PURE__*/React.createElement(SectionL, null, /*#__PURE__*/React.createElement(TwoCol, {
    eyebrow: "01 / Ideation",
    title: /*#__PURE__*/React.createElement(React.Fragment, null, "Capture loose ideas.", /*#__PURE__*/React.createElement("br", null), "Launch them into code."),
    body: "A kanban for drafts \u2014 High, Medium, Low \u2014 with fractional positions so reordering never re-numbers the list. Each draft is a prompt + project + priority. Hit launch and it becomes a session; the draft auto-archives on successful kick-off.",
    bullets: ['Drag-and-drop with persistent fractional ordering', 'Project filter for noisy context switches', 'Launch directly into Brainstorm or Implement', 'Soft-discard — nothing is ever gone'],
    accent: A
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/drafts.png",
    caption: "destila / drafts"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 56,
      maxWidth: 680
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/drafts-edit.png",
    caption: "edit draft \xB7 prompt, priority, project"
  }))), /*#__PURE__*/React.createElement(SectionL, {
    bg: "#f2efe8"
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      textAlign: 'center',
      maxWidth: 760,
      margin: '0 auto'
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 14
    }
  }, "02 / The Core Product"), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2"
  }, "Three workflows. One surface."), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      margin: '18px auto 0',
      fontSize: 17
    }
  }, "Every path from rough idea to shipped code fits one of three shapes. They share context, artifacts, and the same supervised AI session. An Implement run can consume the prompt from a completed Brainstorm \u2014 ideation and execution are connected, not siloed.")), /*#__PURE__*/React.createElement("div", {
    className: "min-grid-3",
    style: {
      marginTop: 40
    }
  }, /*#__PURE__*/React.createElement(WorkflowCardM, {
    badge: "BRAINSTORM",
    title: "Idea \u2192 production-ready prompt",
    body: "Four conversational phases: context gathering, Gherkin/BDD review, technical approach, final prompt. Structured questions \u2014 single, multi, or free-text.",
    phases: ['Task Description', 'Gherkin', 'Technical Concerns', 'Prompt'],
    accent: A
  }), /*#__PURE__*/React.createElement(WorkflowCardM, {
    badge: "CODE CHAT",
    title: "Open-ended Q&A over your code",
    body: "Free-form AI chat with full tool access \u2014 read, write, edit, search, bash. Single-phase, open-ended \u2014 for exploration and debugging.",
    phases: ['Chat'],
    accent: A
  }), /*#__PURE__*/React.createElement(WorkflowCardM, {
    badge: "IMPLEMENT",
    title: "Prompt \u2192 shippable code",
    body: "Seven phases, mostly autonomous: plan, deepen, work, review, browser tests, feature video, adjustments. Consumes prompts from completed Brainstorms.",
    phases: ['Plan', 'Deepen', 'Work', 'Review', 'Tests', 'Video', 'Adjust'],
    accent: A,
    featured: true
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 40
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/workflow-new.png",
    caption: "new session \xB7 pick a workflow"
  }))), /*#__PURE__*/React.createElement(SectionL, null, /*#__PURE__*/React.createElement(TwoCol, {
    eyebrow: "03 / Brainstorm",
    title: /*#__PURE__*/React.createElement(React.Fragment, null, "The AI asks.", /*#__PURE__*/React.createElement("br", null), "You answer structured questions."),
    body: "Instead of dumping a wall of prose, Brainstorm decomposes clarifying context into single-select, multi-select, and free-text prompts. Locked answers stay editable mid-form. When all four phases resolve, you export a production-ready prompt \u2014 Markdown with rendered & raw tabs.",
    bullets: ['Four phases: Task Description · Gherkin · Technical Concerns · Prompt Generation', 'Reads project features/*.feature when present', 'Skips Gherkin cleanly when no scenarios exist', 'Output is a reusable prompt for Implement'],
    accent: A,
    reverse: true
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/brainstorm-questions.png",
    caption: "phase 1 \xB7 structured questions"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 48
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/brainstorm-prompt.png",
    caption: "phase 4 \xB7 generated prompt (rendered markdown)"
  }))), /*#__PURE__*/React.createElement(SectionL, {
    bg: "#f2efe8"
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 760
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 14
    }
  }, "04 / Implement"), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2"
  }, "Seven phases from prompt to PR."), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      marginTop: 18,
      fontSize: 17
    }
  }, "Pick a prompt \u2014 write your own, or select a completed Brainstorm. Destila links a project, spins up a worktree, and runs the pipeline end-to-end. You only interact when you choose to.")), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 32
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/implement-new.png",
    caption: "implement \xB7 choose a prompt, link a project"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 48,
      display: 'grid',
      gridTemplateColumns: 'repeat(7, 1fr)',
      gap: 6
    }
  }, ['Plan', 'Deepen Plan', 'Work', 'Review', 'Browser Tests', 'Feature Video', 'Adjustments'].map((p, i) => /*#__PURE__*/React.createElement("div", {
    key: p,
    style: {
      padding: '14px 10px',
      background: '#fff',
      border: '1px solid rgba(0,0,0,.08)',
      borderRadius: 6,
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 10,
      letterSpacing: '.08em',
      color: '#888'
    }
  }, "PHASE ", i + 1), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 6,
      fontSize: 13,
      fontWeight: 500
    }
  }, p)))), /*#__PURE__*/React.createElement("div", {
    className: "min-grid-2",
    style: {
      marginTop: 48
    }
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 10
    }
  }, "Phase 6 \xB7 records the demo"), /*#__PURE__*/React.createElement("h3", {
    style: {
      fontSize: 28,
      fontWeight: 600,
      margin: 0,
      letterSpacing: '-.02em',
      lineHeight: 1.1
    }
  }, "Every run ships with a feature video."), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      marginTop: 14
    }
  }, "During browser tests, Destila captures a walkthrough MP4. It streams in the metadata sidebar next to the plan, diff summary, review notes, and adjustments. Hand-off becomes a link, not a meeting.")), /*#__PURE__*/React.createElement(Shot, {
    src: "assets/implement-video-modal.png",
    caption: "phase 6 \xB7 feature video \xB7 modal playback"
  })), /*#__PURE__*/React.createElement("div", {
    className: "min-grid-2",
    style: {
      marginTop: 48,
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/implement-finished.png",
    caption: "phase 7 \xB7 adjustments \xB7 PR opened"
  }), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 10
    }
  }, "Phase 7 \xB7 adjustments"), /*#__PURE__*/React.createElement("h3", {
    style: {
      fontSize: 28,
      fontWeight: 600,
      margin: 0,
      letterSpacing: '-.02em',
      lineHeight: 1.1
    }
  }, "Commit, push, PR. Then iterate in place."), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      marginTop: 14
    }
  }, "When implementation is clean, Destila opens the PR and shares the worktree path. Any adjustment you type is committed and pushed to the branch \u2014 the PR updates automatically.")))), /*#__PURE__*/React.createElement(SectionL, null, /*#__PURE__*/React.createElement(TwoCol, {
    eyebrow: "05 / Code Chat",
    title: /*#__PURE__*/React.createElement(React.Fragment, null, "A chat that reads your", /*#__PURE__*/React.createElement("br", null), "actual codebase."),
    body: "Free-form AI chat with full tool access over the session's worktree \u2014 read, write, edit, search, bash. No snippets, no stale files. Ask where something lives, why it broke, or run a one-off command to confirm.",
    bullets: ['Tools: read · write · edit · search · bash', 'Single-phase, open-ended conversation', 'Token & cost totals per session', 'Service start / stop right from chat'],
    accent: A
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/chat.png",
    caption: "code chat \xB7 destila"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 48,
      maxWidth: 820
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/chat-service.png",
    caption: "the agent can start the dev server and return the live URL"
  }))), /*#__PURE__*/React.createElement(SectionD, null, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 780
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 14
    }
  }, "06 / Environment"), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2",
    style: {
      color: '#fff'
    }
  }, "A real terminal. A real server.", /*#__PURE__*/React.createElement("br", null), /*#__PURE__*/React.createElement("span", {
    style: {
      color: A
    }
  }, "Scoped to each session.")), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      color: '#a8a8a8',
      marginTop: 18,
      fontSize: 17
    }
  }, "Destila clones your repo once into a cache, then creates an isolated git worktree per session. An ephemeral port is allocated and injected into your run command. A full xterm.js terminal lives in the sidebar, always scoped to the right directory, surviving navigation via a background GenServer.")), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 40
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/terminal.png",
    caption: "inline xterm.js \xB7 attached to the session worktree"
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 32,
      maxWidth: 820
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/service-starting.png",
    caption: "dev server boots via tmux \xB7 live URL lands in the sidebar"
  }))), /*#__PURE__*/React.createElement(SectionL, {
    bg: "#f2efe8"
  }, /*#__PURE__*/React.createElement(TwoCol, {
    eyebrow: "07 / Projects",
    title: /*#__PURE__*/React.createElement(React.Fragment, null, "Name it. Point it at a repo.", /*#__PURE__*/React.createElement("br", null), "Done."),
    body: "A project needs a name plus either a git URL or a local folder \u2014 or both. Optional setup command runs pre-worktree. An optional run command plus service env var name makes the project a webservice, and Destila will inject an ephemeral port on every session.",
    bullets: ['Git URL · local folder · or both', 'Setup command runs once pre-worktree', 'Run command + env var → managed dev server', 'Safe-delete: blocked while sessions are linked'],
    accent: A,
    reverse: true
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/projects-edit.png",
    caption: "project config \xB7 everything optional except name"
  }))), /*#__PURE__*/React.createElement(SectionD, {
    bg: "#0a0a0a",
    featured: true,
    accent: A
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: 900
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 18,
      display: 'flex',
      gap: 10,
      alignItems: 'center'
    }
  }, /*#__PURE__*/React.createElement(Dot, {
    color: A
  }), " ", /*#__PURE__*/React.createElement("span", null, "08 / Signature \xB7 Managed Claude Code Lifecycle")), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2",
    style: {
      color: '#fff'
    }
  }, "Start a workflow. Walk away.", /*#__PURE__*/React.createElement("br", null), /*#__PURE__*/React.createElement("span", {
    style: {
      color: A
    }
  }, "Come back hours later. It just resumes.")), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      color: '#b0b0b0',
      marginTop: 18,
      fontSize: 18
    }
  }, "Every Claude Code session runs under a supervised GenServer that auto-terminates after 5 minutes of inactivity and transparently resumes from the persisted ", /*#__PURE__*/React.createElement("code", {
    style: {
      color: A
    }
  }, "claude_session_id"), " the moment you interact again. You never manage processes. Idle sessions never burn resources. Context is intact.")), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 36
    }
  }, /*#__PURE__*/React.createElement(AlivenessStrip, {
    theme: "dark"
  })), /*#__PURE__*/React.createElement("div", {
    className: "min-grid-3",
    style: {
      marginTop: 24
    }
  }, /*#__PURE__*/React.createElement(TinyStatM, {
    label: "INACTIVITY TIMEOUT",
    value: "5m",
    sub: "configurable per project",
    accent: A
  }), /*#__PURE__*/React.createElement(TinyStatM, {
    label: "RESUME",
    value: "1 keystroke",
    sub: "claude_session_id persisted",
    accent: A
  }), /*#__PURE__*/React.createElement(TinyStatM, {
    label: "TAB SHARING",
    value: "N \u2192 1",
    sub: "tabs share one process",
    accent: A
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 40
    }
  }, /*#__PURE__*/React.createElement(Shot, {
    src: "assets/crafting-board.png",
    caption: "the crafting board \xB7 live status across every session"
  }))), /*#__PURE__*/React.createElement("section", {
    style: {
      background: '#0a0a0a',
      color: '#fff',
      position: 'relative',
      overflow: 'hidden'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      background: `radial-gradient(ellipse at 50% 0%, ${A}14 0%, transparent 60%)`
    }
  }), /*#__PURE__*/React.createElement("div", {
    className: "min-wrap",
    style: {
      position: 'relative',
      padding: '96px 32px 64px',
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 18,
      color: A
    }
  }, "OPEN SOURCE \xB7 MIT"), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2",
    style: {
      color: '#fff',
      maxWidth: '18ch',
      margin: '0 auto'
    }
  }, "Ship without babysitting the robot."), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 10,
      justifyContent: 'center',
      marginTop: 32,
      flexWrap: 'wrap'
    }
  }, /*#__PURE__*/React.createElement("a", {
    className: "min-btn min-btn-primary",
    href: "#"
  }, /*#__PURE__*/React.createElement(GhIconM, null), " View on GitHub"), /*#__PURE__*/React.createElement("a", {
    className: "min-btn min-btn-ghost",
    href: "#"
  }, "Read the docs \u2192")), /*#__PURE__*/React.createElement("div", {
    style: {
      marginTop: 48,
      paddingTop: 28,
      borderTop: '1px solid rgba(255,255,255,.08)',
      display: 'flex',
      justifyContent: 'space-between',
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 11,
      color: '#666',
      flexWrap: 'wrap',
      gap: 12
    }
  }, /*#__PURE__*/React.createElement("span", null, "destila \xB7 elixir \xB7 phoenix liveview \xB7 claude code"), /*#__PURE__*/React.createElement("span", null, "MIT \xB7 \xA9 2026")))));
}

// ---- helpers for this variation ----
function LogoM({
  accent
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      gap: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 26,
      height: 26,
      borderRadius: 7,
      background: accent,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      color: 'var(--accent-ink)',
      fontWeight: 700,
      fontSize: 13,
      fontFamily: 'JetBrains Mono,monospace'
    }
  }, "D"), /*#__PURE__*/React.createElement("span", {
    style: {
      fontWeight: 600,
      letterSpacing: '-.01em',
      fontSize: 16
    }
  }, "destila"));
}
function GhIconM() {
  return /*#__PURE__*/React.createElement("svg", {
    width: "14",
    height: "14",
    viewBox: "0 0 16 16",
    fill: "currentColor"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8 0C3.58 0 0 3.58 0 8a8 8 0 005.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2 .37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.42 7.42 0 014 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"
  }));
}
function StatM({
  label,
  value
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      textAlign: 'center'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 10,
      letterSpacing: '.12em'
    }
  }, label), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13,
      color: '#e8e8e8',
      marginTop: 3
    }
  }, value));
}
function TinyStatM({
  label,
  value,
  sub,
  accent
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '20px 22px',
      border: '1px solid rgba(255,255,255,.08)',
      borderRadius: 10,
      background: 'rgba(255,255,255,.02)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 10.5,
      letterSpacing: '.12em',
      color: '#888'
    }
  }, label), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 34,
      fontWeight: 600,
      letterSpacing: '-.02em',
      marginTop: 6,
      color: accent
    }
  }, value), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 12.5,
      color: '#a8a8a8',
      marginTop: 4
    }
  }, sub));
}
function SectionL({
  children,
  bg = '#fafaf9'
}) {
  return /*#__PURE__*/React.createElement("section", {
    style: {
      background: bg,
      padding: '96px 0'
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "min-wrap"
  }, children));
}
function SectionD({
  children,
  bg = '#111',
  featured,
  accent
}) {
  return /*#__PURE__*/React.createElement("section", {
    style: {
      background: bg,
      color: '#fff',
      padding: '96px 0',
      position: 'relative',
      overflow: 'hidden'
    }
  }, featured && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 0,
      left: 0,
      right: 0,
      height: 1,
      background: `linear-gradient(90deg, transparent, ${accent}, transparent)`
    }
  }), /*#__PURE__*/React.createElement("div", {
    className: "min-wrap",
    style: {
      position: 'relative'
    }
  }, children));
}
function TwoCol({
  eyebrow,
  title,
  body,
  bullets,
  accent,
  reverse,
  children
}) {
  const textCol = /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "min-eyebrow",
    style: {
      marginBottom: 14
    }
  }, eyebrow), /*#__PURE__*/React.createElement("h2", {
    className: "min-h2"
  }, title), /*#__PURE__*/React.createElement("p", {
    className: "min-body",
    style: {
      marginTop: 18
    }
  }, body), bullets && /*#__PURE__*/React.createElement("ul", {
    style: {
      marginTop: 22,
      paddingLeft: 0,
      listStyle: 'none',
      display: 'flex',
      flexDirection: 'column',
      gap: 10
    }
  }, bullets.map((t, i) => /*#__PURE__*/React.createElement("li", {
    key: i,
    style: {
      display: 'flex',
      gap: 10,
      alignItems: 'flex-start',
      fontSize: 14.5,
      color: '#3a3a3a'
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      color: accent,
      fontFamily: 'JetBrains Mono,monospace',
      marginTop: 1
    }
  }, "\u25B8"), t))));
  return /*#__PURE__*/React.createElement("div", {
    className: "min-grid-2",
    style: {
      alignItems: 'center'
    }
  }, reverse ? /*#__PURE__*/React.createElement(React.Fragment, null, children, textCol) : /*#__PURE__*/React.createElement(React.Fragment, null, textCol, children));
}
function WorkflowCardM({
  badge,
  title,
  body,
  phases,
  accent,
  featured
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: featured ? '#0a0a0a' : '#fff',
      color: featured ? '#fff' : '#0a0a0a',
      border: featured ? 'none' : '1px solid rgba(0,0,0,.08)',
      borderRadius: 12,
      padding: 26,
      display: 'flex',
      flexDirection: 'column',
      gap: 14,
      position: 'relative',
      overflow: 'hidden'
    }
  }, featured && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 0,
      left: 0,
      right: 0,
      height: 3,
      background: accent
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 10.5,
      letterSpacing: '.12em',
      color: featured ? accent : '#888'
    }
  }, badge), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 20,
      fontWeight: 600,
      letterSpacing: '-.01em',
      lineHeight: 1.2
    }
  }, title), /*#__PURE__*/React.createElement("div", {
    style: {
      fontSize: 13.5,
      color: featured ? '#a8a8a8' : '#525252',
      lineHeight: 1.55
    }
  }, body), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexWrap: 'wrap',
      gap: 4,
      marginTop: 'auto',
      paddingTop: 10
    }
  }, phases.map(p => /*#__PURE__*/React.createElement("span", {
    key: p,
    style: {
      fontFamily: 'JetBrains Mono,monospace',
      fontSize: 10,
      padding: '4px 8px',
      border: featured ? '1px solid rgba(255,255,255,.12)' : '1px solid rgba(0,0,0,.08)',
      borderRadius: 4,
      color: featured ? '#e8e8e8' : '#0a0a0a'
    }
  }, p))));
}
window.VariationMinimal = VariationMinimal;

/* ==== src/app.jsx ==== */
// App entry — picks variation based on TWEAKS
// (React hooks re-used from mocks.jsx)
function App() {
  const [tick, setTick] = useState(0);
  useEffect(() => {
    window.__renderApp = () => setTick(t => t + 1);
  }, []);
  const T = window.TWEAKS || {
    variation: 'minimal',
    accent: 'lime'
  };
  const accent = window.ACCENT_COLORS && window.ACCENT_COLORS[T.accent] || '#d4ff3a';

  // Luminance-based ink color for text-on-accent
  function inkFor(hex) {
    const h = hex.replace('#', '');
    const r = parseInt(h.slice(0, 2), 16) / 255;
    const g = parseInt(h.slice(2, 4), 16) / 255;
    const b = parseInt(h.slice(4, 6), 16) / 255;
    const lum = 0.299 * r + 0.587 * g + 0.114 * b;
    return lum > 0.62 ? '#0a0a0a' : '#ffffff';
  }
  const ink = inkFor(accent);

  // Apply accent + ink as CSS vars globally
  useEffect(() => {
    document.documentElement.style.setProperty('--accent', accent);
    document.documentElement.style.setProperty('--accent-ink', ink);
  }, [accent, ink]);
  let Comp = window.VariationMinimal;
  if (T.variation === 'terminal') Comp = window.VariationTerminal;else if (T.variation === 'editorial') Comp = window.VariationEditorial;
  return /*#__PURE__*/React.createElement("div", {
    "data-screen-label": `Variation ${T.variation}`,
    style: {
      ['--accent']: accent,
      ['--accent-ink']: ink
    }
  }, /*#__PURE__*/React.createElement(Comp, {
    accent: accent,
    ink: ink,
    key: T.variation + '-' + tick
  }));
}
ReactDOM.createRoot(document.getElementById('root')).render(/*#__PURE__*/React.createElement(App, null));
