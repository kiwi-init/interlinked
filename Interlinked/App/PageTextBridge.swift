import Foundation

@MainActor
protocol PageJavaScriptEvaluating: AnyObject {
    /// `userGesture` lets the page treat the script as a click. Only a user
    /// action in the browser's own chrome may pass it.
    func interlinkedEvaluate(_ body: String, arguments: [String: Any], userGesture: Bool) async throws -> Any?
    /// Whether Interlinked is darkening this page.
    var rendersDark: Bool { get }
}

extension PageJavaScriptEvaluating {
    var rendersDark: Bool { false }

    func interlinkedEvaluate(_ body: String, arguments: [String: Any]) async throws -> Any? {
        try await interlinkedEvaluate(body, arguments: arguments, userGesture: false)
    }
}

/// Runs on demand in the page. Reading annotations track only their source nodes.
@MainActor enum PageTextBridge {
    static let install = #"""
    if (!globalThis.interlinkedContext) {
      // crypto.randomUUID exists only on secure (https) pages; plain http
      // sites still get a random ID from getRandomValues, which works anywhere.
      const documentID = crypto.randomUUID?.()
        ?? Array.from(crypto.getRandomValues(new Uint8Array(16)), b => b.toString(16).padStart(2, '0')).join('');
      const ids = new WeakMap(), nodes = new Map(); let next = 0;
      let lastLink;
      // Dark pages, whether darkened by Interlinked or dark by design, get a
      // deep amber mark with cream text, so the text never turns white on
      // yellow. A page Interlinked inverts turns the light mark into that
      // same amber, so it keeps the light one.
      let darkened=false;
      const inverted = () => /invert/.test(getComputedStyle(document.documentElement).filter);
      const darkSurface = node => {
        for (let el=node; el; el=el.parentElement) {
          const m=getComputedStyle(el).backgroundColor.match(/[\d.]+/g);
          if (m && (m.length<4 || +m[3]>0.5)) return (0.2126*m[0]+0.7152*m[1]+0.0722*m[2])/255 < 0.4;
        }
        return matchMedia('(prefers-color-scheme: dark)').matches;
      };
      const markColors = dark => dark && !inverted()
        ? {mark:'#6b5200',current:'#8f6c00',text:'#fff4cc'}
        : {mark:'#ffe66a',current:'#ffcc32',text:'#151515'};
      const clean = value => (value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
      // Typed text never leaves the page: not inside a field, and not in a
      // cell or paragraph that holds one, whose innerText would include it.
      const editable = 'textarea,[contenteditable]:not([contenteditable="false"])';
      const excluded = node => node.closest('form,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"],script,style') || node.querySelector(editable);
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
            sensitive:!!document.querySelector('input[type="password"],'+editable)};
        },
        contacts() {
          const out={structuredAddresses:[],addressElements:[],phones:[],emails:[],text:''};
          const add=(list,value)=>{ value=clean(value); if (value && list.length<8 && !list.includes(value)) list.push(value); };
          const lines=node=>(node.innerText||node.textContent||'').split('\n').map(clean).filter(Boolean).join(', ');
          const postal=a=>typeof a==='string' ? a : a && typeof a==='object'
            ? [a.streetAddress,a.addressLocality,a.addressRegion,a.postalCode,typeof a.addressCountry==='string'?a.addressCountry:a.addressCountry?.name]
                .filter(v=>typeof v==='string' && v.trim()).join(', ')
            : '';
          const visit=(node,depth)=>{
            if (!node || typeof node!=='object' || depth>6) return;
            if (Array.isArray(node)) { node.forEach(n=>visit(n,depth+1)); return; }
            if (node['@type']==='PostalAddress') add(out.structuredAddresses,postal(node));
            else if (node.address) [].concat(node.address).forEach(a=>add(out.structuredAddresses,postal(a)));
            [].concat(node.telephone||[]).forEach(t=>typeof t==='string' && add(out.phones,t));
            [].concat(node.email||[]).forEach(e=>typeof e==='string' && add(out.emails,e.replace(/^mailto:/i,'')));
            for (const key in node) if (key!=='address' && node[key] && typeof node[key]==='object') visit(node[key],depth+1);
          };
          document.querySelectorAll('script[type="application/ld+json"]').forEach(s=>{ try { visit(JSON.parse(s.textContent),0); } catch {} });
          document.querySelectorAll('[itemtype*="PostalAddress"]').forEach(n=>add(out.structuredAddresses,lines(n)));
          document.querySelectorAll('[itemprop="telephone"]').forEach(n=>add(out.phones,n.getAttribute('content')||n.textContent));
          document.querySelectorAll('[itemprop="email"]').forEach(n=>add(out.emails,(n.getAttribute('content')||n.textContent).replace(/^mailto:/i,'')));
          document.querySelectorAll('a[href^="tel:" i]').forEach(a=>{ try { add(out.phones,decodeURIComponent(a.getAttribute('href').slice(4))); } catch {} });
          document.querySelectorAll('a[href^="mailto:" i]').forEach(a=>{ try { add(out.emails,decodeURIComponent(a.getAttribute('href').slice(7).split('?')[0])); } catch {} });
          document.querySelectorAll('address').forEach(n=>{ if (!excluded(n)) add(out.addressElements,lines(n)); });
          const regions=document.querySelectorAll('footer,address,[class*="contact" i],[id*="contact" i],[class*="address" i],[class*="location" i],[itemtype*="LocalBusiness"],[itemtype*="Organization"]');
          const seen=new Set(); let text='';
          for (const node of regions) {
            if (excluded(node) || [...seen].some(s=>s.contains(node))) continue;
            seen.add(node); text+=(node.innerText||'')+'\n';
            if (text.length>8000) break;
          }
          out.text=text.slice(0,8000);
          return out;
        },
        navigationLink(destination) {
          if (!lastLink || Date.now()-lastLink.at>5000) return null;
          try { if (new URL(lastLink.href,location.href).href!==new URL(destination,location.href).href) return null; }
          catch { return null; }
          return lastLink.text || null;
        },
        extract() {
          const root = document.body;
          const passages = [];
          const elements = Array.from(root.querySelectorAll('p,li,h1,h2,h3,h4,h5,h6,[role="heading"],blockquote,pre,td,a,button,[role="button"],[role="link"],img,video'));
          const seen = new Set();
          // A list item or cell is prose when most of its text is its own. One
          // that is mostly links is navigation, and its links are read instead.
          const mostlyControls = node => {
            const controls = node.querySelectorAll('a,button');
            if (!controls.length) return false;
            let inner = 0; for (const control of controls) inner += clean(control.textContent).length;
            return inner >= clean(node.textContent).length * 0.6;
          };
          for (const node of elements) {
            if (excluded(node) || !node.getClientRects().length) continue;
            if (!node.matches('p,blockquote') &&
                (node.querySelector('p,li,blockquote,pre') || (node.matches('li,td') && mostlyControls(node)) ||
                 (!node.matches('li,td') && node.querySelector('a,button')))) continue;
            const role = node.matches('img') ? 'image' : node.matches('video') ? 'video' : node.matches('a,[role="link"]') ? 'link' : node.matches('button,[role="button"]') ? 'button' : node.matches('h1,h2,h3,h4,h5,h6,[role="heading"]') ? 'heading' : 'passage';
            const text = nodeText(node), media = role==='image' || role==='video';
            if (!text.length || (!media && seen.has(text))) continue;
            if (!ids.has(node)) ids.set(node, 'p'+(++next));
            const id = ids.get(node); nodes.set(id,node); if (!media) seen.add(text);
            passages.push({id,text,role});
          }
          return {document:documentID,url:location.href,passages};
        },
        highlight(items, current, document, scroll = true, dark) {
          if (document!==documentID) return false;
          if (dark!==undefined) darkened=!!dark;
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
            this.paintMarks(darkened || darkSurface(active.node));
            CSS.highlights.set(name,new Highlight(...ranges));
            CSS.highlights.set(selected,new Highlight(active.range));
          } else {
            // The fallback changes only presentation, never rewrites source text.
            for (const item of items) {
              const node=nodes.get(item.id);
              if (!node.dataset.interlinkedMarked) node.dataset.interlinkedPreviousBackground=node.style.backgroundColor;
              node.style.backgroundColor=markColors(darkened || darkSurface(node)).mark;node.dataset.interlinkedMarked='true';
            }
          }
          if (scroll) active.node.scrollIntoView({block:'center',behavior:'instant'});
          return true;
        },
        paintMarks(dark) {
          const name='interlinked-'+documentID, selected=name+'-current', c=markColors(dark);
          const style=window.document.getElementById(name);
          if (style) style.textContent='::highlight('+name+'){background-color:'+c.mark+';color:'+c.text+'}::highlight('+selected+'){background-color:'+c.current+';color:'+c.text+';text-decoration:underline}';
          return true;
        },
        appearance(dark) {
          darkened=!!dark;
          const marked=[...nodes.values()].find(node=>node.isConnected && node.dataset.interlinkedMarked);
          for (const node of nodes.values()) if (node.dataset?.interlinkedMarked) node.style.backgroundColor=markColors(darkened || darkSurface(node)).mark;
          return this.paintMarks(darkened || (marked ? darkSurface(marked) : false));
        },
        clear() {
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
        try await value(view, call: "return interlinkedContext.metadata();", type: PageMetadata.self)
    }
    static func contacts<View: PageJavaScriptEvaluating>(_ view: View) async throws -> PageContactSignals {
        try await value(view, call: "return interlinkedContext.contacts();", type: PageContactSignals.self)
    }
    static func extract<View: PageJavaScriptEvaluating>(_ view: View) async throws -> PageExtract {
        try await value(view, call: "return interlinkedContext.extract();", type: PageExtract.self)
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
        (try? await execute(view, body: "return globalThis.interlinkedContext?.highlight(items, current, document, true, dark) ?? false;",
            arguments: ["items": passages.map { ["id": $0.id, "text": $0.text] },
                        "current": current, "document": document, "dark": view.rendersDark])) as? Bool ?? false
    }
    /// Recolors marks already on the page after Dark Page is switched.
    static func appearanceChanged<View: PageJavaScriptEvaluating>(_ view: View) {
        let dark = view.rendersDark
        Task { _ = try? await execute(view, body: "return globalThis.interlinkedContext?.appearance(dark) ?? false;", arguments: ["dark": dark]) }
    }
    static func clear<View: PageJavaScriptEvaluating>(_ view: View?) {
        guard let view else { return }
        Task { _ = try? await view.interlinkedEvaluate("globalThis.interlinkedContext?.clear()", arguments: [:]) }
    }

    private static func execute<View: PageJavaScriptEvaluating>(
        _ view: View,
        body: String,
        arguments: [String: Any] = [:],
        userGesture: Bool = false
    ) async throws -> Any? {
        try await view.interlinkedEvaluate(body, arguments: arguments, userGesture: userGesture)
    }
}
