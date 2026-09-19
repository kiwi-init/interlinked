import WebKit

/// Runs on demand in an isolated world. Reading annotations track only their source nodes.
@MainActor enum PageTextBridge {
    static let install = #"""
    if (!globalThis.kiwiContext) {
      const documentID = crypto.randomUUID();
      const ids = new WeakMap(), nodes = new Map(); let next = 0;
      let stopReading;
      const clean = value => (value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
      const excluded = node => node.closest('form,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"],script,style');
      globalThis.kiwiContext = {
        metadata() {
          const meta = name => clean(document.querySelector('meta[name="'+name+'"],meta[property="'+name+'"]')?.content).slice(0,240);
          return {document:documentID,url:location.href,title:clean(document.title).slice(0,180),
            heading:clean(document.querySelector('main h1,article h1,h1')?.textContent).slice(0,120),
            summary:meta('description') || meta('og:description'),siteName:meta('og:site_name'),
            breadcrumbs:Array.from(document.querySelectorAll('[aria-label*="readcrumb"] a,[itemprop="itemListElement"] [itemprop="name"]')).slice(0,5).map(n=>clean(n.textContent).slice(0,60)),
            sensitive:!!document.querySelector('input[type="password"],textarea,[contenteditable="true"]')};
        },
        extract() {
          const root = document.body;
          const passages = [];
          const elements = Array.from(root.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,[role="heading"],blockquote,pre,td,a,button,[role="button"],[role="link"]'));
          const seen = new Set();
          for (const node of elements) {
            if (excluded(node) || !node.getClientRects().length) continue;
            if (node.querySelector('p,li,blockquote,pre,a,button') && !node.matches('p,blockquote')) continue;
            const role = node.matches('a,[role="link"]') ? 'link' : node.matches('button,[role="button"]') ? 'button' : node.matches('h1,h2,h3,h4,h5,h6,[role="heading"]') ? 'heading' : 'passage';
            const text = clean(node.innerText);
            if (!text.length || seen.has(text)) continue;
            if (!ids.has(node)) ids.set(node, 'p'+(++next));
            const id = ids.get(node); nodes.set(id,node); seen.add(text);
            passages.push({id,text,role});
          }
          return {document:documentID,url:location.href,passages,truncated:false};
        },
        highlight(items, current, document, scroll = true) {
          if (document!==documentID) return false;
          const ranges=[]; let active;
          for (const item of items) {
            const node=nodes.get(item.id);
            if (!node?.isConnected || clean(node.innerText)!==item.text) return false;
            const range=window.document.createRange(); range.selectNodeContents(node); ranges.push(range);
            if (item.id===current) active={node,range};
          }
          if (!active) return false;
          const name='kiwi-'+documentID, selected=name+'-current';
          if (globalThis.CSS?.highlights && globalThis.Highlight) {
            let style=window.document.getElementById(name);
            if (!style) { style=window.document.createElement('style');style.id=name;window.document.head.append(style); }
            style.textContent='::highlight('+name+'){background-color:#ffe66a;color:#151515}::highlight('+selected+'){background-color:#ffcc32;color:#151515;text-decoration:underline}';
            CSS.highlights.set(name,new Highlight(...ranges));
            CSS.highlights.set(selected,new Highlight(active.range));
          } else {
            // Older WebKit fallback changes only presentation, never rewrites source text.
            for (const item of items) {
              const node=nodes.get(item.id);
              if (!node.dataset.kiwiMarked) node.dataset.kiwiPreviousBackground=node.style.backgroundColor;
              node.style.backgroundColor='#ffe66a';node.dataset.kiwiMarked='true';
            }
          }
          if (scroll) active.node.scrollIntoView({block:'center',behavior:'instant'});
          return true;
        },
        annotate(items, document) {
          if (document!==documentID) return false;
          this.clear();
          if (!items.length) return true;
          const visible = item => { const r=nodes.get(item.id)?.getBoundingClientRect(); return r && r.bottom>0 && r.top<innerHeight-80; };
          let index=Math.max(0,items.findIndex(visible)), pending=0, dismissed=false;
          const itemIndexes=new Map(items.map((item,index)=>[item.id,index]));
          let cardSize;
          if (!this.highlight(items,items[index].id,document,false)) return false;
          const host=window.document.createElement('div'); host.id='kiwi-reading-'+documentID;
          host.style.cssText='all:initial;position:fixed;left:0;top:0;width:0;height:0;overflow:visible;pointer-events:none;z-index:2147483647';
          const root=host.attachShadow({mode:'open'});
          const style=window.document.createElement('style');
          style.textContent=`:host{all:initial}*{box-sizing:border-box}
            aside{position:fixed;left:0;top:0;width:240px;max-width:calc(100vw - 32px);padding:14px;pointer-events:auto;color:#fff;
              background:rgba(35,35,38,.88);backdrop-filter:blur(24px) saturate(1.35);border:1px solid #ffffff30;
              border-radius:14px;box-shadow:0 8px 28px #0003;font:12px/1.45 -apple-system,BlinkMacSystemFont,sans-serif;will-change:transform}
            header{display:flex;align-items:center;gap:8px;margin-bottom:7px}strong{flex:1;font-weight:600}
            p{margin:0;color:#ffffffbd}footer{display:flex;align-items:center;justify-content:flex-end;gap:8px;margin-top:10px}
            small{margin-right:auto;color:#ffffff8c;font:10px -apple-system,sans-serif}
            button{border:0;background:transparent;color:inherit;font:16px -apple-system,sans-serif;padding:2px 5px;cursor:pointer;border-radius:5px}
            button:hover,button:focus-visible{background:#ffffff20}aside[hidden]{display:none}`;
          const card=window.document.createElement('aside'); card.setAttribute('aria-label','Critical reading evaluation');
          card.innerHTML='<header><strong></strong><button aria-label="Hide evaluation">×</button></header><p></p><footer><small></small><button aria-label="Previous finding">‹</button><button aria-label="Next finding">›</button></footer>';
          root.append(style,card); window.document.documentElement.append(host);
          const buttons=card.querySelectorAll('button');
          const select=(next,scroll=false)=>{
            index=(next+items.length)%items.length; dismissed=false;
            const item=items[index];
            if (!this.highlight(items,item.id,document,scroll)) { this.clear();return; }
            card.querySelector('strong').textContent=item.label;
            card.querySelector('p').textContent=item.explanation;
            card.querySelector('small').textContent=(index+1)+' / '+items.length+' · Wording signal';
            cardSize=null;
            position();
          };
          const position=()=>{
            pending=0;
            if (!nodes.get(items[index].id)?.isConnected) { this.clear();return; }
            const r=nodes.get(items[index].id).getBoundingClientRect();
            card.hidden=dismissed || r.bottom<=0 || r.top>=innerHeight-64;
            if (card.hidden) return;
            cardSize ||= {width:card.offsetWidth,height:card.offsetHeight};
            const w=cardSize.width,h=cardSize.height,gap=12;
            const right=r.right+gap,left=r.left-w-gap;
            const beside=right+w<=innerWidth-16 || left>=16;
            const x=right+w<=innerWidth-16 ? right : left>=16 ? left : Math.max(16,innerWidth-w-16);
            const y=beside ? r.top : r.bottom+gap;
            card.style.transform='translate3d('+x+'px,'+Math.max(16,Math.min(y,innerHeight-h-76))+'px,0)';
          };
          const schedule=()=>{ if (!pending) pending=requestAnimationFrame(position); };
          const point=event=>{
            if (event.composedPath().includes(host)) return;
            let target=event.target,found=Infinity;
            while (target) {
              const candidate=itemIndexes.get(ids.get(target));
              if (candidate!==undefined) found=Math.min(found,candidate);
              target=target.parentNode;
            }
            if (found!==Infinity) { if (found!==index || dismissed) select(found); }
            else if (event.type==='click') { dismissed=true;position(); }
          };
          const resized=()=>{cardSize=null;schedule();};
          buttons[0].onclick=()=>{dismissed=true;position();};
          buttons[1].onclick=()=>select(index-1,true);buttons[2].onclick=()=>select(index+1,true);
          window.document.addEventListener('pointerover',point);
          window.document.addEventListener('click',point);
          window.document.addEventListener('scroll',schedule,{passive:true,capture:true});
          window.addEventListener('resize',resized);
          const resize=new ResizeObserver(schedule);resize.observe(window.document.body);
          const mutations=new MutationObserver(()=>{
            if (items.some(item=>!nodes.get(item.id)?.isConnected || clean(nodes.get(item.id).innerText)!==item.text)) this.clear();
            else schedule();
          });
          items.forEach(item=>mutations.observe(nodes.get(item.id),{childList:true,characterData:true,subtree:true}));
          stopReading=()=>{
            host.remove();resize.disconnect();mutations.disconnect();cancelAnimationFrame(pending);
            window.document.removeEventListener('pointerover',point);window.document.removeEventListener('click',point);
            window.document.removeEventListener('scroll',schedule,true);window.removeEventListener('resize',resized);
          };
          select(index,!visible(items[index]));
          return true;
        },
        clear() {
          if (stopReading) { const stop=stopReading;stopReading=null;stop(); }
          const name='kiwi-'+documentID;
          globalThis.CSS?.highlights?.delete(name);globalThis.CSS?.highlights?.delete(name+'-current');
          window.document.getElementById(name)?.remove();
          for (const node of nodes.values()) if (node.dataset.kiwiMarked) {
            node.style.backgroundColor=node.dataset.kiwiPreviousBackground || '';
            delete node.dataset.kiwiMarked;delete node.dataset.kiwiPreviousBackground;
          }
        }

      };
    }
    """#

    static func metadata(_ view: WKWebView) async throws -> PageMetadata {
        try await value(view, call: "return kiwiContext.metadata();", type: PageMetadata.self)
    }
    static func extract(_ view: WKWebView) async throws -> PageExtract {
        try await value(view, call: "return kiwiContext.extract();", type: PageExtract.self)
    }
    private static func value<T: Decodable>(_ view: WKWebView, call: String, type: T.Type) async throws -> T {
        let result: Any?
        do {
            result = try await view.callAsyncJavaScript(call, arguments: [:], in: nil, contentWorld: .defaultClient)
        } catch {
            // Standalone web views (including tests) do not have the document-end user script.
            result = try await view.callAsyncJavaScript(install + call, arguments: [:], in: nil, contentWorld: .defaultClient)
        }
        let data = try JSONSerialization.data(withJSONObject: result as Any)
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func highlight(_ passage: PagePassage, document: String, view: WKWebView) async -> Bool {
        await highlight([passage], current: passage.id, document: document, view: view)
    }
    static func highlight(_ passages: [PagePassage], current: String, document: String, view: WKWebView) async -> Bool {
        (try? await view.callAsyncJavaScript("return globalThis.kiwiContext?.highlight(items, current, document) ?? false;",
            arguments: ["items": passages.map { ["id": $0.id, "text": $0.text] }, "current": current, "document": document],
            in: nil, contentWorld: .defaultClient)) as? Bool ?? false
    }
    static func clear(_ view: WKWebView?) {
        guard let view else { return }
        view.evaluateJavaScript("globalThis.kiwiContext?.clear()", in: nil, in: .defaultClient) { _ in }
    }

    static func annotate(_ findings: [PassageDecisions.Finding], document: String, view: WKWebView) async -> Bool {
        let items = findings.map { ["id": $0.passage.id, "text": $0.passage.text,
                                    "label": $0.signal.label, "explanation": $0.signal.explanation] }
        return (try? await view.callAsyncJavaScript("return globalThis.kiwiContext?.annotate(items, document) ?? false;",
            arguments: ["items": items, "document": document], in: nil, contentWorld: .defaultClient)) as? Bool ?? false
    }
}
