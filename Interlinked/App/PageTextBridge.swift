import Foundation

@MainActor
protocol PageJavaScriptEvaluating: AnyObject {
    func interlinkedEvaluate(_ body: String, arguments: [String: Any]) async throws -> Any?
    func httpOnlyCookieNames() async -> [String]
}

extension PageJavaScriptEvaluating {
    func httpOnlyCookieNames() async -> [String] { [] }
}

/// Runs on demand in the page. Reading annotations track only their source nodes.
@MainActor enum PageTextBridge {
    static let install = #"""
    if (!globalThis.interlinkedContext) {
      const documentID = crypto.randomUUID();
      const ids = new WeakMap(), nodes = new Map(), filterCandidates = new Map(); let next = 0;
      let stopReading, filterStyle; let lastLink;
      const filteredNodes = new Set(), previousDisplays = new WeakMap();
      const filterHighlightNames = new Set();
      const clean = value => (value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
      const excluded = node => node.closest('form,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"],script,style');
      const filterTarget = source => {
        if (source.matches('img')) return source.closest('picture') || source;
        if (source.matches('video')) return source;
        let node=source, best=source;
        for (let depth=0; node && depth<9; depth++,node=node.parentElement) {
          if (node===document.body || node===document.documentElement || node.matches('main,[role="main"]')) break;
          const r=node.getBoundingClientRect(), text=clean(node.innerText), style=getComputedStyle(node);
          if (!r.width || !r.height || r.height>innerHeight*.92 || r.width*r.height>innerWidth*innerHeight*.78 || text.length>8000) break;
          best=node;
          const bordered=parseFloat(style.borderTopWidth)>0 || parseFloat(style.borderLeftWidth)>0;
          const rounded=parseFloat(style.borderTopLeftRadius)>2;
          const semantic=node.matches('article,section,aside,[role="region"],[data-testid]');
          if (depth>0 && node.childElementCount>1 && (bordered || rounded || semantic)) return node;
        }
        return best;
      };
      const nodeText = node => {
        if (node.matches('img')) return clean(node.getAttribute('alt') || node.getAttribute('aria-label') || node.getAttribute('title')) || 'Image';
        if (node.matches('video')) return clean(node.getAttribute('aria-label') || node.getAttribute('title')) || 'Video';
        return clean(node.innerText);
      };
      document.addEventListener('pointerdown',event=>{
        const link=event.target?.closest?.('a[href]');
        lastLink=link ? {href:link.href,text:clean(link.innerText||link.getAttribute('aria-label')||link.title).slice(0,160),at:Date.now()} : null;
      },true);
      globalThis.interlinkedContext = {
        metadata() {
          const meta = name => clean(document.querySelector('meta[name="'+name+'"],meta[property="'+name+'"]')?.content).slice(0,240);
          return {document:documentID,url:location.href,title:clean(document.title).slice(0,180),
            heading:clean(document.querySelector('main h1,article h1,h1')?.textContent).slice(0,120),
            summary:meta('description') || meta('og:description'),siteName:meta('og:site_name'),
            breadcrumbs:Array.from(document.querySelectorAll('[aria-label*="readcrumb"] a,[itemprop="itemListElement"] [itemprop="name"]')).slice(0,5).map(n=>clean(n.textContent).slice(0,60)),
            sensitive:!!document.querySelector('input[type="password"],textarea,[contenteditable="true"]'),
            cookieNames:document.cookie.split(';').map(part=>part.split('=')[0].trim()).filter(Boolean).slice(0,40),
            hasLogoutControl:Array.from(document.querySelectorAll('a,button,[role="button"],[role="link"]')).slice(0,200).some(node=>/\b(log\s*out|sign\s*out|sign\s*off)\b/i.test(clean(node.innerText||node.getAttribute('aria-label')||node.title)))};
        },
        navigationLink(destination) {
          if (!lastLink || Date.now()-lastLink.at>5000) return null;
          try { if (new URL(lastLink.href,location.href).href!==new URL(destination,location.href).href) return null; }
          catch { return null; }
          return lastLink.text || null;
        },
        extract() {
          const root = document.body;
          const passages = [], limit = 1000; let truncated = false;
          const elements = Array.from(root.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,[role="heading"],blockquote,pre,td,a,button,[role="button"],[role="link"],img,video'));
          const seen = new Set();
          for (const node of elements) {
            if (excluded(node) || !node.getClientRects().length) continue;
            if (node.querySelector('p,li,blockquote,pre,a,button') && !node.matches('p,blockquote')) continue;
            const role = node.matches('img') ? 'image' : node.matches('video') ? 'video' : node.matches('a,[role="link"]') ? 'link' : node.matches('button,[role="button"]') ? 'button' : node.matches('h1,h2,h3,h4,h5,h6,[role="heading"]') ? 'heading' : 'passage';
            const text = nodeText(node), media = role==='image' || role==='video';
            if (!text.length || (!media && seen.has(text))) continue;
            if (passages.length>=limit) { truncated=true; continue; }
            if (!ids.has(node)) ids.set(node, 'p'+(++next));
            const id = ids.get(node); nodes.set(id,node); if (!media) seen.add(text);
            passages.push({id,text,role});
          }
          return {document:documentID,url:location.href,passages,truncated};
        },
        extractFilterCandidates() {
          filterCandidates.clear();
          let serial=0;
          const groups={media:[],phrases:[],elements:[],tokens:[]};
          const stage=(bucket,target,text,role,context='')=>{
            text=clean(text).slice(0,320);context=clean(context).slice(0,360);
            if (!text) return;
            const id='f'+(++serial);
            groups[bucket].push({id,text,role,context,target});
          };
          const mediaSelector='img,picture,video,canvas,svg,[role="img"],[role="video"],object[type^="image/"],object[type^="video/"],embed[type^="image/"],embed[type^="video/"],iframe[src*="youtube"],iframe[src*="vimeo"]';
          for (const node of document.querySelectorAll(mediaSelector)) {
            if (excluded(node) || !node.getClientRects().length || node.closest(mediaSelector)!==node) continue;
            const role=node.matches('video,[role="video"],object[type^="video/"],embed[type^="video/"],iframe')?'video':'image';
            const label=nodeText(node)==='Image'||nodeText(node)==='Video' ? '' : nodeText(node);
            stage('media',{kind:'element',node,role},label || role,role,label);
          }
          for (const node of document.querySelectorAll('body,body *')) {
            if (excluded(node) || !node.getClientRects().length || getComputedStyle(node).backgroundImage==='none') continue;
            stage('media',{kind:'element',node,role:'image'},clean(node.getAttribute('aria-label')||node.getAttribute('title'))||'background image','image','background image');
          }
          const blockSelector='article,section,aside,li,h1,h2,h3,h4,h5,h6,[role="heading"],blockquote,pre,td,a,button,[role="button"],[role="link"],p';
          for (const node of document.querySelectorAll(blockSelector)) {
            if (excluded(node) || !node.getClientRects().length || node.matches(mediaSelector)) continue;
            if (node.querySelector('article,section,aside,li,h1,h2,h3,h4,h5,h6,blockquote,pre,td,p') && !node.matches('article,section,aside')) continue;
            const text=nodeText(node);if (!text) continue;
            const role=node.matches('a,[role="link"]')?'link':node.matches('button,[role="button"]')?'button':node.matches('h1,h2,h3,h4,h5,h6,[role="heading"]')?'heading':node.matches('article,section,aside')?'section':'content block';
            stage('elements',{kind:'element',node,role},text,role,text);
          }
          const sentenceSegmenter=globalThis.Intl?.Segmenter ? new Intl.Segmenter(undefined,{granularity:'sentence'}) : null;
          const wordSegmenter=globalThis.Intl?.Segmenter ? new Intl.Segmenter(undefined,{granularity:'word'}) : null;
          const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
          let textNode;
          while (textNode=walker.nextNode()) {
            const parent=textNode.parentElement,raw=textNode.data;
            if (!parent || excluded(parent) || !parent.getClientRects().length || !clean(raw)) continue;
            const sentences=sentenceSegmenter ? Array.from(sentenceSegmenter.segment(raw)) : [{segment:raw,index:0}];
            for (const sentence of sentences) {
              const source=sentence.segment,start=sentence.index;
              const leading=source.search(/\S/);if (leading<0) continue;
              const trailing=source.length-(source.match(/\s*$/)?.[0].length||0);
              const from=start+leading,to=start+trailing,visible=raw.slice(from,to);
              if (!clean(visible)) continue;
              const range=document.createRange();range.setStart(textNode,from);range.setEnd(textNode,to);
              stage('phrases',{kind:'range',range,role:'text range'},visible,'text range',visible);
              if (!wordSegmenter) continue;
              for (const word of wordSegmenter.segment(visible)) {
                if (!word.isWordLike) continue;
                const token=word.segment;
                if (token.length<2 && !/\d/.test(token)) continue;
                const wordRange=document.createRange(),wordStart=from+word.index;
                wordRange.setStart(textNode,wordStart);wordRange.setEnd(textNode,wordStart+token.length);
                stage('tokens',{kind:'range',range:wordRange,role:'text token'},token,'text token',visible);
              }
            }
          }
          const limits={media:400,phrases:700,elements:700,tokens:700};
          const chosen=[];
          for (const key of ['media','phrases','elements','tokens']) chosen.push(...groups[key].slice(0,limits[key]));
          for (const item of chosen) filterCandidates.set(item.id,item.target);
          return {document:documentID,url:location.href,
            candidates:chosen.map(({id,text,role,context})=>({id,text,role,context})),
            truncated:Object.keys(groups).some(key=>groups[key].length>limits[key])};
        },
        highlight(items, current, document, scroll = true) {
          if (document!==documentID) return false;
          const ranges=[]; let active;
          for (const item of items) {
            const node=nodes.get(item.id);
            if (!node?.isConnected || nodeText(node)!==item.text) return false;
            const range=window.document.createRange(); range.selectNodeContents(node); ranges.push(range);
            if (item.id===current) active={node,range};
          }
          if (!active) return false;
          const name='interlinked-'+documentID, selected=name+'-current';
          if (globalThis.CSS?.highlights && globalThis.Highlight) {
            let style=window.document.getElementById(name);
            if (!style) { style=window.document.createElement('style');style.id=name;window.document.head.append(style); }
            style.textContent='::highlight('+name+'){background-color:#ffe66a;color:#151515}::highlight('+selected+'){background-color:#ffcc32;color:#151515;text-decoration:underline}';
            CSS.highlights.set(name,new Highlight(...ranges));
            CSS.highlights.set(selected,new Highlight(active.range));
          } else {
            // The fallback changes only presentation, never rewrites source text.
            for (const item of items) {
              const node=nodes.get(item.id);
              if (!node.dataset.interlinkedMarked) node.dataset.interlinkedPreviousBackground=node.style.backgroundColor;
              node.style.backgroundColor='#ffe66a';node.dataset.interlinkedMarked='true';
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
          const host=window.document.createElement('div'); host.id='interlinked-reading-'+documentID;
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
          const select=next=>{
            index=(next+items.length)%items.length; dismissed=false;
            const item=items[index];
            if (!this.highlight(items,item.id,document,false)) { this.clear();return; }
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
          buttons[1].onclick=()=>select(index-1);buttons[2].onclick=()=>select(index+1);
          window.document.addEventListener('pointerover',point);
          window.document.addEventListener('click',point);
          window.document.addEventListener('scroll',schedule,{passive:true,capture:true});
          window.addEventListener('resize',resized);
          const resize=new ResizeObserver(schedule);resize.observe(window.document.body);
          const mutations=new MutationObserver(()=>{
            if (items.some(item=>!nodes.get(item.id)?.isConnected || nodeText(nodes.get(item.id))!==item.text)) this.clear();
            else schedule();
          });
          items.forEach(item=>mutations.observe(nodes.get(item.id),{childList:true,characterData:true,subtree:true}));
          stopReading=()=>{
            host.remove();resize.disconnect();mutations.disconnect();cancelAnimationFrame(pending);
            window.document.removeEventListener('pointerover',point);window.document.removeEventListener('click',point);
            window.document.removeEventListener('scroll',schedule,true);window.removeEventListener('resize',resized);
          };
          select(index);
          return true;
        },
        clearFilters() {
          for (const node of filteredNodes) if (node?.isConnected) {
            const previous=previousDisplays.get(node);
            if (!previous || (!previous.value && !previous.priority)) node.style.removeProperty('display');
            else node.style.setProperty('display',previous.value,previous.priority);
            delete node.dataset.interlinkedFiltered;
          }
          filteredNodes.clear();
          filterStyle?.remove();filterStyle=null;
          for (const name of filterHighlightNames) globalThis.CSS?.highlights?.delete(name);
          filterHighlightNames.clear();
          return true;
        },
        applyFilters(groups, documentToken) {
          if (documentToken!==documentID) return null;
          this.clearFilters();
          const counts={},css=[];
          const resolved=groups.map(group=>{
            const targets=new Set();
            for (const item of group.items || []) {
              const node=nodes.get(item.id);
              if (!node?.isConnected || nodeText(node)!==item.text) continue;
              targets.add(filterTarget(node));
            }
            const media=new Set(group.media || []);
            if (media.has('image')) {
              document.querySelectorAll('img,picture,canvas,svg,[role="img"],object[type^="image/"],embed[type^="image/"]').forEach(node=>targets.add(node.matches('img') ? node.closest('picture') || node : node));
              for (const node of document.querySelectorAll('body,body *')) if (getComputedStyle(node).backgroundImage!=='none') targets.add(node);
              css.push('img,picture,canvas,svg,[role="img"],object[type^="image/"],embed[type^="image/"]{display:none!important}html body,html body *{background-image:none!important}');
            }
            if (media.has('video')) {
              document.querySelectorAll('video,[role="video"],object[type^="video/"],embed[type^="video/"],iframe[src*="youtube"],iframe[src*="vimeo"]').forEach(node=>targets.add(node));
              css.push('video,[role="video"],object[type^="video/"],embed[type^="video/"],iframe[src*="youtube"],iframe[src*="vimeo"]{display:none!important}');
            }
            let wordCount=0;
            if ((group.words || []).length && globalThis.CSS?.highlights && globalThis.Highlight) {
              const ranges=[];
              for (const word of group.words) {
                const escaped=Array.from(word).map(char=>'\\^$.*+?()[]{}|'.includes(char)?'\\'+char:char).join('');
                const pattern=new RegExp('(?<![\\p{L}\\p{N}_])'+escaped+'(?![\\p{L}\\p{N}_])','giu');
                const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);
                let textNode;
                while (textNode=walker.nextNode()) {
                  const parent=textNode.parentElement;
                  if (!parent || excluded(parent) || !parent.getClientRects().length) continue;
                  pattern.lastIndex=0;let match;
                  while (match=pattern.exec(textNode.data)) {
                    const range=document.createRange();range.setStart(textNode,match.index);range.setEnd(textNode,match.index+match[0].length);
                    ranges.push(range);wordCount++;
                  }
                }
              }
              if (ranges.length) {
                const name='interlinked-word-'+group.rule.toLowerCase();
                CSS.highlights.set(name,new Highlight(...ranges));filterHighlightNames.add(name);
                css.push('::highlight('+name+'){color:transparent!important;text-shadow:none!important}');
              }
            }
            return {rule:group.rule,targets,wordCount};
          });
          if (css.length) {
            filterStyle=document.createElement('style');filterStyle.id='interlinked-personal-filters-'+documentID;
            filterStyle.textContent=css.join('\n');document.head.append(filterStyle);
          }
          for (const group of resolved) {
            const targets=group.targets;
            for (const node of targets) {
              if (!filteredNodes.has(node)) {
                previousDisplays.set(node,{value:node.style.getPropertyValue('display'),priority:node.style.getPropertyPriority('display')});
                node.style.setProperty('display','none','important');
                node.dataset.interlinkedFiltered='true';
                filteredNodes.add(node);
              }
            }
            counts[group.rule]=targets.size+group.wordCount;
          }
          return counts;
        },
        applyFilterCandidates(groups, documentToken) {
          if (documentToken!==documentID) return null;
          this.clearFilters();
          const counts={},css=[];
          const availableRoles=new Map();
          for (const target of filterCandidates.values()) if (target.kind==='element' && (target.role==='image'||target.role==='video'))
            availableRoles.set(target.role,(availableRoles.get(target.role)||0)+1);
          for (const group of groups) {
            const elements=new Set(),ranges=[],selectedRoles=new Map();
            for (const item of group.items || []) {
              const target=filterCandidates.get(item.id);
              if (!target) continue;
              if (target.kind==='range') {
                if (target.range.startContainer?.isConnected) ranges.push(target.range.cloneRange());
              } else if (target.node?.isConnected) {
                elements.add(filterTarget(target.node));
                if (target.role==='image'||target.role==='video') selectedRoles.set(target.role,(selectedRoles.get(target.role)||0)+1);
              }
            }
            if ((selectedRoles.get('image')||0)>=(availableRoles.get('image')||Infinity))
              css.push('img,picture,canvas,svg,[role="img"],object[type^="image/"],embed[type^="image/"]{display:none!important}html body,html body *{background-image:none!important}');
            if ((selectedRoles.get('video')||0)>=(availableRoles.get('video')||Infinity))
              css.push('video,[role="video"],object[type^="video/"],embed[type^="video/"],iframe[src*="youtube"],iframe[src*="vimeo"]{display:none!important}');
            for (const node of elements) {
              if (filteredNodes.has(node)) continue;
              previousDisplays.set(node,{value:node.style.getPropertyValue('display'),priority:node.style.getPropertyPriority('display')});
              node.style.setProperty('display','none','important');node.dataset.interlinkedFiltered='true';filteredNodes.add(node);
            }
            if (ranges.length && globalThis.CSS?.highlights && globalThis.Highlight) {
              const name='interlinked-filter-'+group.rule.toLowerCase();
              CSS.highlights.set(name,new Highlight(...ranges));filterHighlightNames.add(name);
              css.push('::highlight('+name+'){color:transparent!important;text-shadow:none!important}');
            }
            counts[group.rule]=elements.size+ranges.length;
          }
          if (css.length) {
            filterStyle=document.createElement('style');filterStyle.id='interlinked-personal-filters-'+documentID;
            filterStyle.textContent=css.join('\n');document.head.append(filterStyle);
          }
          return counts;
        },
        clear() {
          if (stopReading) { const stop=stopReading;stopReading=null;stop(); }
          const name='interlinked-'+documentID;
          globalThis.CSS?.highlights?.delete(name);globalThis.CSS?.highlights?.delete(name+'-current');
          window.document.getElementById(name)?.remove();
          for (const node of nodes.values()) if (node.dataset.interlinkedMarked) {
            node.style.backgroundColor=node.dataset.interlinkedPreviousBackground || '';
            delete node.dataset.interlinkedMarked;delete node.dataset.interlinkedPreviousBackground;
          }
        }

      };
    }
    """#

    static func metadata<View: PageJavaScriptEvaluating>(_ view: View) async throws -> PageMetadata {
        var page = try await value(view, call: "return interlinkedContext.metadata();", type: PageMetadata.self)
        page.httpOnlyCookieNames = await view.httpOnlyCookieNames()
        return page
    }
    static func extract<View: PageJavaScriptEvaluating>(_ view: View) async throws -> PageExtract {
        try await value(view, call: "return interlinkedContext.extract();", type: PageExtract.self)
    }
    static func extractFilterCandidates<View: PageJavaScriptEvaluating>(_ view: View) async throws -> PageFilterExtract {
        try await value(view, call: "return interlinkedContext.extractFilterCandidates();", type: PageFilterExtract.self)
    }
    static func navigationLinkText<View: PageJavaScriptEvaluating>(_ view: View, destination: URL) async -> String? {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.navigationLink(destination) ?? null;",
                            arguments: ["destination": destination.absoluteString])) as? String
    }
    private static func value<T: Decodable, View: PageJavaScriptEvaluating>(
        _ view: View, call: String, type: T.Type
    ) async throws -> T {
        let result: Any?
        do {
            result = try await execute(view, body: call)
        } catch {
            result = try await execute(view, body: install + call)
        }
        // The page shares this JavaScript world and can replace the bridge, and
        // JSONSerialization raises an uncatchable exception for non-containers.
        guard let result, JSONSerialization.isValidJSONObject(result) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }
    static func highlight<View: PageJavaScriptEvaluating>(
        _ passage: PagePassage, document: String, view: View
    ) async -> Bool {
        await highlight([passage], current: passage.id, document: document, view: view)
    }
    static func highlight<View: PageJavaScriptEvaluating>(
        _ passages: [PagePassage], current: String, document: String, view: View
    ) async -> Bool {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.highlight(items, current, document) ?? false;",
            arguments: ["items": passages.map { ["id": $0.id, "text": $0.text] },
                        "current": current, "document": document])) as? Bool ?? false
    }
    static func clear<View: PageJavaScriptEvaluating>(_ view: View?) {
        guard let view else { return }
        Task { _ = try? await view.interlinkedEvaluate("globalThis.interlinkedContext?.clear()", arguments: [:]) }
    }

    static func clearFilters<View: PageJavaScriptEvaluating>(_ view: View?) async {
        guard let view else { return }
        _ = try? await execute(view, body: "return globalThis.interlinkedContext?.clearFilters() ?? false;")
    }

    static func applyFilters<View: PageJavaScriptEvaluating>(
        _ matches: [UUID: [PagePassage]], document: String, view: View
    ) async -> [UUID: Int]? {
        let groups: [[String: Any]] = matches.map { rule, passages in
            return ["rule": rule.uuidString,
                    "items": passages.map { ["id": $0.id, "text": $0.text] },
                    "media": [], "words": []]
        }
        let raw: Any?
        do {
            raw = try await execute(view,
                body: "return globalThis.interlinkedContext?.applyFilters(groups, document) ?? null;",
                arguments: ["groups": groups, "document": document])
        } catch {
            return nil
        }
        guard let values = raw as? [String: Any] else { return nil }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard let id = UUID(uuidString: key), let count = value as? NSNumber else { return nil }
            return (id, count.intValue)
        })
    }

    static func applyFilterCandidates<View: PageJavaScriptEvaluating>(
        _ matches: [UUID: [PageFilterCandidate]], document: String, view: View
    ) async -> [UUID: Int]? {
        let groups: [[String: Any]] = matches.map { rule, candidates in
            ["rule": rule.uuidString,
             "items": candidates.map { ["id": $0.id, "text": $0.text] }]
        }
        let raw: Any?
        do {
            raw = try await execute(view,
                body: "return globalThis.interlinkedContext?.applyFilterCandidates(groups, document) ?? null;",
                arguments: ["groups": groups, "document": document])
        } catch {
            return nil
        }
        guard let values = raw as? [String: Any] else { return nil }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            guard let id = UUID(uuidString: key), let count = value as? NSNumber else { return nil }
            return (id, count.intValue)
        })
    }

    static func annotate<View: PageJavaScriptEvaluating>(
        _ findings: [PassageDecisions.Finding], document: String, view: View
    ) async -> Bool {
        let items = findings.map { ["id": $0.passage.id, "text": $0.passage.text,
                                    "label": $0.signal.label, "explanation": $0.signal.explanation] }
        return (try? await execute(view,
            body: "return globalThis.interlinkedContext?.annotate(items, document) ?? false;",
            arguments: ["items": items, "document": document])) as? Bool ?? false
    }

    private static func execute<View: PageJavaScriptEvaluating>(
        _ view: View,
        body: String,
        arguments: [String: Any] = [:]
    ) async throws -> Any? {
        try await view.interlinkedEvaluate(body, arguments: arguments)
    }
}
