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
  /// The page reports how tall its content is: the larger of the root's
  /// in-flow height and the lowest point of anything that shows, plus the
  /// body's bottom padding. Not the body's scroll height, which also counts
  /// content clipped out of sight, such as a table kept only for screen
  /// readers.
  ///
  /// The frame takes the height the page reports, and that height is the
  /// page's viewport, so nothing measured may follow the viewport. The root
  /// and body keep their content's height whatever the page asks (a
  /// percentage height or minimum on them would resolve against the frame and
  /// grow with it), so their padding, margins and borders count once, in
  /// either box sizing. The root is the containing block for absolutely
  /// positioned content, so `bottom` and percentage heights on it resolve
  /// against the content rather than the viewport, and a box at `top:0;
  /// left:0` stays where it was. Content fixed to the viewport never counts.
  ///
  /// The lowest point comes from one walk down from the body that carries
  /// the clip each box sets: a box that clips its overflow cuts off what is
  /// inside it, except absolutely positioned content that escapes to a
  /// containing block outside it; `clip` and `clip-path` cut off everything
  /// inside. Hidden boxes, boxes clipped to nothing and 1px boxes that clip
  /// (the usual way to keep content only for screen readers) add nothing.
  /// Images, canvases, SVG and embedded frames count as one box. The walk
  /// stops after a few thousand elements and keeps what it found, and it
  /// runs at most once a frame, whenever a box resizes, the page changes, an
  /// image or font loads, or the theme changes.
  ///
  /// A page whose own rules or scripts follow the viewport's height (a height
  /// media query, a viewport unit, a canvas sized to the window, even through
  /// a delayed resize handler) can still swing between two heights or keep
  /// growing. When the height keeps changing soon after each change of the
  /// viewport, the page stops reporting for a moment, so the frame stays
  /// still, and watches: a page that keeps changing is followed; one that
  /// settles was answering the frame, and its height is held. Heights that
  /// come round again, however slowly the page answers, hold the tallest of
  /// them until the page shows a height outside them; when the page stays at
  /// a shorter one for a second, the frame tries it once, and holds again
  /// for good only if the page answers by changing back. A change while
  /// the frame is still, a new width, or the reader pressing a pointer or key
  /// in the page lets a held height go. The first measurement is always
  /// reported.
  /// The size message also carries `lead`: the page's first visible text when
  /// it is a heading or a table's caption, else empty.
  ///
  /// `wovenReadText(id)` asks the page for its text as the reader sees it, read
  /// inside the frame, so what scripts draw counts; it answers with a `text`
  /// message carrying the same `id`.
  public static func render(html: String) -> String {
    let bootstrap = #"""
    <style id="woven-theme">html{margin:0;padding:0}body{margin:0;padding:12px 14px}:root,:root>body{height:auto!important;min-height:0!important;max-height:none!important}:root{position:relative!important}html,body{background:transparent;font-family:var(--font-sans,system-ui);color:var(--foreground)}*{box-sizing:border-box}img,svg,canvas{max-width:100%}::-webkit-scrollbar{display:none}</style>
    <script>
    (()=>{
      const base=document.getElementById('woven-theme').textContent;
      addEventListener('message',e=>{if(e.source!==parent)return;
        if(e.data?.kind==='text'){parent.postMessage({kind:'text',id:e.data.id,text:(document.body?.innerText||'').slice(0,200000)},'*');return;}
        if(e.data?.kind!=='theme')return;
        const t=e.data;document.getElementById('woven-theme').textContent=':root{color-scheme:'+t.appearance+';'+Object.entries(t.variables).map(([k,v])=>k+':'+v+';').join('')+'}'+base;
        document.documentElement.dataset.theme=t.appearance;
        schedule();
      });
      const shown=e=>e.checkVisibility?e.checkVisibility({visibilityProperty:true,opacityProperty:true}):e.getClientRects().length>0;
      const lead=()=>{const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
        for(let n=w.nextNode();n;n=w.nextNode()){const p=n.parentElement;if(!n.data.trim()||!p||!shown(p))continue;
          const h=p.closest('h1,h2,h3,h4,h5,h6,caption');return h?h.innerText.trim().slice(0,200):'';}
        return '';};
      // The bottom a box's own `clip` or `clip-path` lets show, or -1 when
      // they leave nothing showing.
      const len=(x,full)=>x.endsWith('%')?parseFloat(x)*full/100:parseFloat(x)||0;
      const cut=(s,r)=>{let b=Infinity;
        if((s.position==='absolute'||s.position==='fixed')&&s.clip&&s.clip!=='auto'){
          const v=s.clip.match(/-?[\d.]+px|auto/g)||[],n=(x,d)=>x&&x!=='auto'?parseFloat(x):d;
          const t=n(v[0],0),right=n(v[1],r.width),bottom=n(v[2],r.height),left=n(v[3],0);
          if(bottom-t<=1||right-left<=1)return -1;b=r.top+bottom;}
        const p=s.clipPath;if(!p||p==='none')return b;
        const m=/^([\w-]+)\((.*)\)/.exec(p),f=m?.[1],a=(m?.[2]||'').split(/\s+round\s+/)[0].trim();
        if(f==='inset'){const v=a.split(/\s+/),t=len(v[0],r.height),right=len(v[1]??v[0],r.width),
            bottom=len(v[2]??v[0],r.height),left=len(v[3]??v[1]??v[0],r.width);
          if(t+bottom>=r.height-1||left+right>=r.width-1)return -1;return Math.min(b,r.bottom-bottom);}
        if(f==='circle'||f==='ellipse'){if(a.split(/\s+at\s+/)[0].split(/\s+/).some(x=>x&&parseFloat(x)===0))return -1;}
        if(f==='polygon'){const q=a.replace(/^(nonzero|evenodd)\s*,/,'').split(',').map(x=>x.trim().split(/\s+/));
          const xs=q.map(x=>len(x[0]||'0',r.width)),ys=q.map(x=>len(x[1]||'0',r.height));
          if(Math.max(...xs)-Math.min(...xs)<=1||Math.max(...ys)-Math.min(...ys)<=1)return -1;
          return Math.min(b,r.top+Math.max(...ys));}
        return Math.min(b,r.bottom);};
      // Layout containment makes a box hold positioned content; only paint
      // containment (`paint`, `strict`, `content`) also clips it.
      const leaf=/^(svg|canvas|img|video|iframe|object|embed)$/i,holder=/paint|layout|strict|content/,clipper=/paint|strict|content/;
      const text=document.createRange();
      // The lowest point that shows, in page coordinates. Each box keeps the
      // clip its in-flow content gets (`flow`), the clip everything inside it
      // gets (`paint`), and whether it holds absolutely positioned content
      // (`abs`) or content fixed in place (`fixed`). A wrapper with no box of
      // its own (`display:contents`) passes its parent's on to its children.
      const lowest=()=>{const root=document.documentElement,body=document.body;
        const kept=new Map([[root,{flow:Infinity,paint:Infinity,abs:true,fixed:false}]]);
        const holds=s=>s.transform!=='none'||s.filter!=='none'||s.perspective!=='none'||holder.test(s.contain);
        const bs=getComputedStyle(body);kept.set(body,{flow:Infinity,paint:Infinity,abs:bs.position!=='static'||holds(bs),fixed:holds(bs)});
        let low=0,seen=0;const stack=[...body.children].reverse();
        const enter=e=>{for(let c=e.lastElementChild;c;c=c.previousElementSibling)stack.push(c);};
        while(stack.length&&++seen<=3000){const e=stack.pop(),s=getComputedStyle(e);
          let inside=kept.get(e.parentElement);if(!inside)continue;
          if(s.display==='contents'){kept.set(e,{...inside,abs:false,fixed:false});enter(e);continue;}
          if(s.display==='none'||s.opacity==='0'||s.contentVisibility==='hidden'||e.checkVisibility?.()===false)continue;
          const paint=inside.paint;
          if(s.position==='absolute'||s.position==='fixed'){let a=e.parentElement;
            for(;a;a=a.parentElement){inside=kept.get(a);if(s.position==='absolute'?inside.abs:inside.fixed)break;}
            if(!a)continue;}
          const r=e.getBoundingClientRect(),own=cut(s,r);if(own<0)continue;
          const clips=s.overflowY!=='visible'||clipper.test(s.contain);
          if((r.width<=1||r.height<=1)&&(clips||own!==Infinity))continue;
          const limit=Math.min(inside.flow,paint,own);
          if(s.visibility==='visible'&&r.height>0)low=Math.max(low,Math.min(r.bottom,limit));
          if(leaf.test(e.localName))continue;
          // Text that spills out of a box with a set height.
          if(!clips&&e.clientHeight>0&&e.scrollHeight>e.clientHeight+1)for(const n of e.childNodes)
            if(n.nodeType===3&&n.data.trim()){text.selectNodeContents(n);const q=text.getBoundingClientRect();
              if(q.height>0)low=Math.max(low,Math.min(q.bottom,limit));}
          kept.set(e,{flow:Math.min(inside.flow,clips?r.bottom-(parseFloat(s.borderBottomWidth)||0):Infinity),
            paint:Math.min(paint,own),abs:s.position!=='static'||holds(s),fixed:holds(s)});
          enter(e);}
        return low?low+scrollY:0;};
      // Heights that follow the viewport. A change measured less than `calm`
      // after the viewport last changed may be the page answering the height
      // we reported. After three such changes in a row the page stops
      // reporting, so the viewport stays still, and keeps measuring:
      // - if the height changes twice more, or once the viewport has been
      //   still for `calm`, the page is changing on its own: report it;
      // - if it settles, the changes were feedback and the height is held.
      //   Heights that went back and forth keep the tallest reported. Heights
      //   that went one way keep the settled one, and once more, when the
      //   viewport has been still for `calm`, the height the page then shows
      //   (real growth may have ended there).
      // A held height is let go by a change while the viewport is still, a
      // new width, or the reader pressing a pointer or key in the page.
      // However slowly a page answers, heights that come round again (two or
      // three of them, twice over) are a cycle: the frame holds the tallest
      // and stops moving, and while it is still the page can only show those
      // same heights unless it changes on its own; any other height is
      // followed. A cycle may also be the page's own and over, so once the
      // page has shown one height for `rest` the frame takes that height,
      // once; if the page answers with another height of the cycle, the
      // frame holds the tallest again and stays. The first measurement is
      // always reported.
      const calm=350,rest=1000;
      let last=-1,lastLead='',queued=false,ran=-1e9,width=0,tall=0,resized=-1e9,run=[],quiet=null,held=null,sent=[];
      const near=(a,b)=>Math.abs(a-b)<=1;
      const cycle=h=>{const r=[...sent,h],n=r.length;
        for(const p of [2,3])if(n>=2*p&&r.slice(n-p).every((x,i)=>near(x,r[n-2*p+i])))return r.slice(n-p);
        return null;};
      const settle=h=>{const t=performance.now();
        if(innerHeight!==tall){if(tall)resized=t;tall=innerHeight;}
        const still=t-resized>=calm;
        if(last<0)return h;
        if(held?.cycle){
          if(!held.cycle.some(x=>near(x,h))){held=null;run=[];sent=[];return h;}
          if(held.out){if(near(h,held.seen))return h;held.out=false;return held.h;}
          if(!near(h,held.seen)){held.seen=h;held.at=t;}
          if(held.probed||near(held.seen,held.h))return held.h;
          if(t-held.at<rest){setTimeout(schedule,held.at+rest-t+5);return held.h;}
          held.probed=held.out=true;return held.seen;}
        if(held){
          if(h!==held.seen){if(still){held=null;run=[];sent=[];return h;}held.seen=h;}
          if(h!==held.h&&held.spare){if(still){held.spare=false;return held.h=h;}setTimeout(schedule,resized+calm-t+5);}
          return held.h;}
        if(quiet){
          if(h!==quiet.h){if(!still&&++quiet.moves<2){quiet.h=h;setTimeout(schedule,25);return null;}
            quiet=null;run=[];return h;}
          if(!still){setTimeout(schedule,25);return null;}
          const q=quiet;quiet=null;run=[];
          held=q.turned?{h:Math.max(q.peak,last),seen:h,spare:false}:{h,seen:h,spare:true};return held.h;}
        if(h===last)return h;
        const round=cycle(h);if(round){run=[];held={h:Math.max(...round),cycle:round,seen:h,at:t,probed:false,out:false};
          if(!near(h,held.h))setTimeout(schedule,rest+5);return held.h;}
        if(still){run=[];return h;}
        if(!run.length)run=[last];run.push(h);
        if(run.length<4)return h;
        const turned=run.some((x,i)=>i>1&&(x-run[i-1])*(run[i-1]-run[i-2])<0);
        quiet={h,moves:0,peak:Math.max(...run.slice(0,-1)),turned};setTimeout(schedule,25);return null;};
      const release=()=>{held=null;run=[];quiet=null;sent=[];};
      const measure=()=>{if(!queued)return;queued=false;ran=performance.now();const b=document.body;if(!b)return;
        if(innerWidth!==width){width=innerWidth;release();}
        const flow=document.documentElement.getBoundingClientRect().height,low=lowest();
        const h=settle(Math.ceil(Math.max(flow,low?low+(parseFloat(getComputedStyle(b).paddingBottom)||0):0))),l=lead();
        if(h!==null&&h!==last)sent=[...sent.slice(-11),h];
        if(h!==null&&(h!==last||l!==lastLead)){last=h;lastLead=l;parent.postMessage({kind:'size',height:h,lead:l},'*');}};
      const schedule=()=>{if(queued)return;queued=true;const wait=ran+16-performance.now();
        if(wait>0)setTimeout(measure,wait);else{requestAnimationFrame(measure);setTimeout(measure,0);}};
      for(const kind of ['pointerdown','keydown'])addEventListener(kind,()=>{release();schedule();},true);
      new MutationObserver(schedule).observe(document.documentElement,{subtree:true,childList:true,attributes:true,characterData:true});
      document.addEventListener('load',schedule,true);
      document.fonts?.addEventListener?.('loadingdone',schedule);
      addEventListener('resize',schedule,true);
      addEventListener('DOMContentLoaded',()=>{const o=new ResizeObserver(schedule);o.observe(document.documentElement);o.observe(document.body);schedule();});
      addEventListener('load',()=>{schedule();parent.postMessage({kind:'ready'},'*');});
      document.addEventListener('click',e=>{const a=e.composedPath().find(x=>x?.matches?.('a[href]'));if(!a||!e.isTrusted)return;
        const u=new URL(a.href,document.baseURI);if(/^https?:$/.test(u.protocol)){e.preventDefault();parent.postMessage({kind:'link',url:u.href},'*');}},true);
      for(const level of ['log','info','warn','error']){const old=console[level];console[level]=(...args)=>{old.apply(console,args);parent.postMessage({kind:'console',level,text:args.map(String).join(' ').slice(0,2000)},'*');};}
      addEventListener('error',e=>parent.postMessage({kind:'console',level:'error',text:String(e.message).slice(0,2000)},'*'));
    })();
    </script>
    """#
    // The bootstrap goes before anything the page wrote, right after its
    // doctype when the page opens with one (past leading comments), so no
    // element of the page can hold it as text and no policy of the page can
    // block it. A page without a doctype gets one, so every page uses
    // standards mode.
    let opening = try! NSRegularExpression(pattern: #"(?i)^(?:[\s\x{FEFF}]|<!--[\s\S]*?-->|<\?[^>]*>)*<!doctype\b(?:"[^"]*"|'[^']*'|[^'">])*>"#)
    let source = html as NSString
    let doctype = opening.firstMatch(in: html, range: NSRange(location: 0, length: source.length))
    let insertion = doctype.map { NSMaxRange($0.range) } ?? 0
    let authored = (doctype == nil ? "<!doctype html>" : "")
      + source.substring(to: insertion) + bootstrap + source.substring(from: insertion)
    let encoded = Data(authored.utf8).base64EncodedString()
    return #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src about: http: https:; script-src 'unsafe-inline' 'unsafe-eval' http: https: blob:; style-src 'unsafe-inline' http: https:; img-src data: blob: http: https:; font-src data: http: https:; media-src data: blob: http: https:; connect-src http: https: ws: wss:; object-src 'none'; base-uri 'none'; form-action http: https:">
    <style>html,body{margin:0;height:100%;overflow:hidden;background:transparent}iframe{display:block;width:100%;height:100%;border:0}</style></head>
    <body><iframe id="page" title="Visual reply" sandbox="allow-scripts allow-forms" allow="camera 'none'; microphone 'none'; geolocation 'none'"></iframe><script>
    const frame=document.getElementById('page');let theme;
    window.wovenSetTheme=t=>{theme=t;frame.contentWindow.postMessage({kind:'theme',...t},'*');};
    window.wovenReadText=id=>frame.contentWindow.postMessage({kind:'text',id},'*');
    addEventListener('message',e=>{if(e.source!==frame.contentWindow||!e.data)return;
      if(e.data.kind==='ready'&&theme)wovenSetTheme(theme);
      if(['size','link','console','ready','text'].includes(e.data.kind))window.webkit?.messageHandlers.wovenHTML.postMessage(e.data);
    });
    frame.srcdoc=new TextDecoder().decode(Uint8Array.from(atob('\#(encoded)'),c=>c.charCodeAt(0)));
    </script></body></html>
    """#
  }
}
