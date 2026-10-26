import Foundation
import WovenMatterCompanion

/// Small enough for transcript summaries; the page itself stays in full activity detail.
public struct ConversationHTMLRenderReference: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let height: Int
  public init(id: String, title: String, height: Int) {
    self.id = id; self.title = title; self.height = height
  }
}

public struct ConversationHTMLPage: Codable, Equatable, Sendable {
  public let html: String
  public let title: String
  public let height: Int
  public static let maximumPageBytes = ConversationHTMLResources.maximumPageBytes

  public init(html: String, title: String, height: Int) throws {
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          html.utf8.count <= Self.maximumPageBytes,
          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          title.count <= 200, title.utf8.count <= 800, (80...2000).contains(height) else {
      throw WorkspaceToolError.invalid("Provide nonempty HTML up to 25 MiB including images, a title up to 200 characters, and a height from 80 to 2000 pixels.")
    }
    // A frame that fits its content cannot itself determine that content's height.
    let css = try NSRegularExpression(pattern: #"(?is)<!--[\s\S]*?(?:-->|$)|<style\b[^>]*>(.*?)</style\s*>|\sstyle\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
    let units = try NSRegularExpression(pattern: #"(?i)(?<![\w.+/])(?:\d+(?:\.\d+)?|\.\d+)[sld]?vh(?![\w-])"#)
    let source = html as NSString
    for match in css.matches(in: html, range: NSRange(location: 0, length: source.length)) {
      for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
        let style = source.substring(with: match.range(at: index))
        if units.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)) != nil {
          throw WorkspaceToolError.invalid("Use content or fixed pixel heights instead of vh units so the page can fit the thread.")
        }
      }
    }
    self.html = html; self.title = title; self.height = height
  }
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
