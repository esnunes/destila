// Shared screenshot helpers for all variations
// Screenshots are already macOS browser windows — don't re-frame them.

function Shot({ src, caption, shadow = true, style = {} }) {
  return (
    <figure style={{margin:0, ...style}}>
      <img
        src={src}
        alt={caption || ''}
        loading="lazy"
        decoding="async"
        style={{
          display:'block', width:'100%', height:'auto',
          borderRadius:10,
          boxShadow: shadow ? '0 30px 60px -20px rgba(0,0,0,.35), 0 12px 24px -12px rgba(0,0,0,.25)' : 'none'
        }}
      />
      {caption && (
        <figcaption style={{
          marginTop:12, fontFamily:'JetBrains Mono,monospace', fontSize:11,
          letterSpacing:'.04em', color:'currentColor', opacity:.55
        }}>
          {caption}
        </figcaption>
      )}
    </figure>
  );
}

// A cluster of overlapping shots for the hero
function ShotStack({ main, secondary, accent }) {
  return (
    <div style={{position:'relative'}}>
      <div style={{transform:'rotate(-1deg)', boxShadow:'0 40px 80px -20px rgba(0,0,0,.5)', borderRadius:12}}>
        <img src={main} style={{display:'block', width:'100%', height:'auto', borderRadius:10}}/>
      </div>
      {secondary && (
        <div style={{
          position:'absolute', right:'-6%', bottom:'-8%', width:'52%',
          transform:'rotate(3deg)', boxShadow:'0 30px 60px -15px rgba(0,0,0,.6)',
          borderRadius:10, border: `2px solid ${accent}`
        }}>
          <img src={secondary} style={{display:'block', width:'100%', height:'auto', borderRadius:8}}/>
        </div>
      )}
    </div>
  );
}

window.Shot = Shot;
window.ShotStack = ShotStack;
