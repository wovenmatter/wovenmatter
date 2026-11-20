import Foundation

/// A page an agent published in the chat: its item's identifier, title and
/// starting height. The page itself is in the content store, by `digest`.
public struct ConversationHTMLRenderReference: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let height: Int
  public let digest: String
  public init(id: String, title: String, height: Int, digest: String) {
    self.id = id; self.title = title; self.height = height; self.digest = digest
  }
}

/// A visual reply an agent rendered, once its content has arrived.
public struct ConversationHTMLPage: Equatable, Sendable {
  public let html: String
  public let title: String
  public let height: Int
}

/// Authored content runs in an opaque sandboxed child frame. Only the
/// app-owned outer document has a native handler; it verifies message sources.
public enum ConversationHTMLDocument {
  public static func render(html: String) -> String {
    let bootstrap = #"""
    <style id="woven-theme">html,body{margin:0;padding:0;background:transparent;font-family:var(--font-sans,system-ui);color:var(--foreground)}*{box-sizing:border-box}img,svg,canvas{max-width:100%}::-webkit-scrollbar{display:none}</style>
    <script>
    (()=>{
      const base=document.getElementById('woven-theme').textContent;
      addEventListener('message',e=>{if(e.source!==parent||e.data?.kind!=='theme')return;
        const t=e.data;document.getElementById('woven-theme').textContent=':root{color-scheme:'+t.appearance+';'+Object.entries(t.variables).map(([k,v])=>k+':'+v+';').join('')+'}'+base;
        document.documentElement.dataset.theme=t.appearance;
        schedule();
      });
      let last=0,queued=false;
      const measure=()=>{queued=false;const b=document.body;if(!b)return;
        const h=Math.ceil(Math.max(b.getBoundingClientRect().height,b.scrollHeight));
        if(h!==last){last=h;parent.postMessage({kind:'size',height:h},'*');}};
      const schedule=()=>{if(!queued){queued=true;requestAnimationFrame(measure);setTimeout(measure,0);}};
      addEventListener('DOMContentLoaded',()=>{new ResizeObserver(schedule).observe(document.body);measure();});
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
