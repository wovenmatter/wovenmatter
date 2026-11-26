import Foundation

/// A visual reply an agent published in the chat: its item's identifier,
/// title, starting height and the width it needs (none fills the chat's
/// width). Its HTML is in the content store, by `digest`.
public struct ConversationHTMLRenderReference: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let height: Int
  public let width: Int?
  public let digest: String
  public init(id: String, title: String, height: Int, width: Int? = nil, digest: String) {
    self.id = id; self.title = title; self.height = height; self.width = width; self.digest = digest
  }
}

/// A visual reply an agent rendered, once its content has arrived.
public struct ConversationVisualReply: Equatable, Sendable {
  public let html: String
  public let title: String
  public let height: Int
}

/// Authored content runs in an opaque sandboxed child frame. Only the
/// app-owned outer document has a native handler; it verifies message sources.
public enum ConversationHTMLDocument {
  /// The page reports how tall its content is: the root's in-flow height,
  /// and below it only positioned content that shows. Not the body's scroll
  /// height, which also counts content clipped out of sight, such as a table
  /// kept only for screen readers.
  /// The frame takes the height the page reports, and that height is the
  /// page's viewport, so nothing measured may follow the viewport: the root
  /// and body keep their content's height whatever the page asks (a
  /// percentage height or minimum on them would resolve against the frame and
  /// grow with it), so their padding, margins and borders count once, in
  /// either box sizing. The size message also carries `lead`: the page's first
  /// visible text when it is a heading or a table's caption, else empty.
  public static func render(html: String) -> String {
    let bootstrap = #"""
    <style id="woven-theme">html{margin:0;padding:0}body{margin:0;padding:12px 14px}:root,:root>body{height:auto!important;min-height:0!important;max-height:none!important}html,body{background:transparent;font-family:var(--font-sans,system-ui);color:var(--foreground)}*{box-sizing:border-box}img,svg,canvas{max-width:100%}::-webkit-scrollbar{display:none}</style>
    <script>
    (()=>{
      const base=document.getElementById('woven-theme').textContent;
      addEventListener('message',e=>{if(e.source!==parent||e.data?.kind!=='theme')return;
        const t=e.data;document.getElementById('woven-theme').textContent=':root{color-scheme:'+t.appearance+';'+Object.entries(t.variables).map(([k,v])=>k+':'+v+';').join('')+'}'+base;
        document.documentElement.dataset.theme=t.appearance;
        schedule();
      });
      const shown=e=>e.checkVisibility?e.checkVisibility({visibilityProperty:true,opacityProperty:true}):e.getClientRects().length>0;
      const lead=()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
        for(let n=w.nextNode();n;n=w.nextNode()){const p=n.parentElement;if(!n.data.trim()||!p||!shown(p))continue;
          const h=p.closest('h1,h2,h3,h4,h5,h6,caption');return h?h.innerText.trim().slice(0,200):'';}
        return '';};
      let last=0,lastLead='',queued=false;
      const clipped=s=>(s.clip&&s.clip!=='auto')||(s.clipPath&&s.clipPath!=='none');
      const placed=()=>{let m=0;for(const e of document.body.querySelectorAll('*')){const s=getComputedStyle(e);
          if((s.position!=='absolute'&&s.position!=='fixed')||clipped(s)||!shown(e))continue;
          const r=e.getBoundingClientRect();if(r.width>1&&r.height>1)m=Math.max(m,r.bottom+scrollY);}
        return m;};
      const measure=()=>{queued=false;const b=document.body;if(!b)return;
        const flow=document.documentElement.getBoundingClientRect().height,abs=placed();
        const h=Math.ceil(Math.max(flow,abs?abs+parseFloat(getComputedStyle(b).paddingBottom||'0'):0)),l=lead();
        if(h!==last||l!==lastLead){last=h;lastLead=l;parent.postMessage({kind:'size',height:h,lead:l},'*');}};
      const schedule=()=>{if(!queued){queued=true;requestAnimationFrame(measure);setTimeout(measure,0);}};
      addEventListener('DOMContentLoaded',()=>{const o=new ResizeObserver(schedule);o.observe(document.documentElement);o.observe(document.body);measure();});
      addEventListener('load',()=>{measure();parent.postMessage({kind:'ready'},'*');});
      document.addEventListener('click',e=>{const a=e.composedPath().find(x=>x?.matches?.('a[href]'));if(!a||!e.isTrusted)return;
        const u=new URL(a.href,document.baseURI);if(/^https?:$/.test(u.protocol)){e.preventDefault();parent.postMessage({kind:'link',url:u.href},'*');}},true);
      for(const level of ['log','info','warn','error']){const old=console[level];console[level]=(...args)=>{old.apply(console,args);parent.postMessage({kind:'console',level,text:args.map(String).join(' ').slice(0,2000)},'*');};}
      addEventListener('error',e=>parent.postMessage({kind:'console',level:'error',text:String(e.message).slice(0,2000)},'*'));
    })();
    </script>
    """#
    // Skip comments and script bodies when finding a real head. Preserve a
    // leading doctype so fragments and complete documents use standards mode.
    let scan = try! NSRegularExpression(pattern: #"(?is)<!--[\s\S]*?(?:-->|$)|<script\b(?:"[^"]*"|'[^']*'|[^'">])*>[\s\S]*?(?:</script\s*>|$)|<head\b(?:"[^"]*"|'[^']*'|[^'">])*>|<!doctype\b(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    let source = html as NSString
    var headEnd: Int?, doctypeEnd: Int?
    for match in scan.matches(in: html, range: NSRange(location: 0, length: source.length)) {
      let tag = source.substring(with: match.range).lowercased()
      if tag.hasPrefix("<head") { headEnd = NSMaxRange(match.range); break }
      if tag.hasPrefix("<!doctype") { doctypeEnd = NSMaxRange(match.range) }
    }
    let insertion = headEnd ?? doctypeEnd ?? 0
    let authored = (headEnd == nil && doctypeEnd == nil ? "<!doctype html>" : "")
      + source.substring(to: insertion) + bootstrap + source.substring(from: insertion)
    let encoded = Data(authored.utf8).base64EncodedString()
    return #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src about: http: https:; script-src 'unsafe-inline' 'unsafe-eval' http: https: blob:; style-src 'unsafe-inline' http: https:; img-src data: blob: http: https:; font-src data: http: https:; media-src data: blob: http: https:; connect-src http: https: ws: wss:; object-src 'none'; base-uri 'none'; form-action http: https:">
    <style>html,body{margin:0;height:100%;overflow:hidden;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style></head>
    <body><iframe id="page" title="Visual reply" sandbox="allow-scripts allow-forms" allow="camera 'none'; microphone 'none'; geolocation 'none'"></iframe><script>
    const frame=document.getElementById('page');let theme;
    window.wovenSetTheme=t=>{theme=t;frame.contentWindow.postMessage({kind:'theme',...t},'*');};
    addEventListener('message',e=>{if(e.source!==frame.contentWindow||!e.data)return;
      if(e.data.kind==='ready'&&theme)wovenSetTheme(theme);
      if(['size','link','console','ready'].includes(e.data.kind))window.webkit?.messageHandlers.wovenHTML.postMessage(e.data);
    });
    frame.srcdoc=new TextDecoder().decode(Uint8Array.from(atob('\#(encoded)'),c=>c.charCodeAt(0)));
    </script></body></html>
    """#
  }
}
