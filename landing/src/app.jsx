// App entry — picks variation based on TWEAKS
const { useState, useEffect } = React;

function App() {
  const [tick, setTick] = useState(0);
  useEffect(()=>{
    window.__renderApp = ()=> setTick(t=>t+1);
  }, []);

  const T = window.TWEAKS || { variation: 'minimal', accent: 'lime' };
  const accent = (window.ACCENT_COLORS && window.ACCENT_COLORS[T.accent]) || '#d4ff3a';

  // Luminance-based ink color for text-on-accent
  function inkFor(hex) {
    const h = hex.replace('#','');
    const r = parseInt(h.slice(0,2),16)/255;
    const g = parseInt(h.slice(2,4),16)/255;
    const b = parseInt(h.slice(4,6),16)/255;
    const lum = 0.299*r + 0.587*g + 0.114*b;
    return lum > 0.62 ? '#0a0a0a' : '#ffffff';
  }
  const ink = inkFor(accent);

  // Apply accent + ink as CSS vars globally
  useEffect(()=>{
    document.documentElement.style.setProperty('--accent', accent);
    document.documentElement.style.setProperty('--accent-ink', ink);
  }, [accent, ink]);

  let Comp = window.VariationMinimal;
  if (T.variation === 'terminal') Comp = window.VariationTerminal;
  else if (T.variation === 'editorial') Comp = window.VariationEditorial;

  return (
    <div data-screen-label={`Variation ${T.variation}`} style={{['--accent']: accent, ['--accent-ink']: ink}}>
      <Comp accent={accent} ink={ink} key={T.variation + '-' + tick}/>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
