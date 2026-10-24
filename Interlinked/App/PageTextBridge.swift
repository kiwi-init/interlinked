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
      let siteMenuNode, siteMenuPrevious, siteMenuSpacer;
      let siteMenuExtras=[];
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
        siteMenu() {
          try {
            const vw=innerWidth, origin=location.origin;
            const httpURL=value=>{ try { const href=new URL(value,location.href); return ['http:','https:'].includes(href.protocol)?href:null; } catch { return null; } };
            const visible=el=>{ const r=el.getBoundingClientRect(); return r.width>8 && r.height>8 && r.bottom>0 && r.top<innerHeight && r.left<vw && r.right>0; };
            const visibleLabel=el=>{
              if (el.matches('input,textarea,select')) return '';
              const copy=el.cloneNode(true);
              copy.querySelectorAll('svg,img,style,script,[aria-hidden="true"],.sr-only,[class*="octicon"]').forEach(n=>n.remove());
              const text=clean(copy.innerText);
              return text.length>=2 && text.length<=28 && !/^\d+$/.test(text) ? text : '';
            };
            const a11y=el=>clean(el.getAttribute('aria-label')||el.getAttribute('title')||el.getAttribute('placeholder')||'');
            // Many sites spell search only in their own language, or expose it
            // as a link to /search rather than a field. Both still count.
            const searchWord=/(^|[\s\/?&=._-])(search|busca|buscar|pesquisa|pesquisar|recherche|rechercher|suche|suchen|buscador|cerca|ricerca|zoeken|szukaj|sok|haku|поиск|搜索|搜尋|検索|검색)([\s\/?&=._-]|$)/i;
            const isSearch=el=>el.matches('input[type="search"],input[name="q"],textarea[name="q"],[role="combobox"]')
              || /jump to/i.test(a11y(el))
              || searchWord.test((el.getAttribute('name')||'')+' '+a11y(el)+' '+(el.getAttribute('placeholder')||''))
              || (el.matches('a[href]') && searchWord.test(el.getAttribute('href')||''));
            const inBar=(el,top,bottom)=>{ const b=el.getBoundingClientRect(); const mid=b.top+b.height/2; return mid>=top-2 && mid<=bottom+2; };
            const mark=(el,kind,href,label,current,children=[])=>{
              const id='m'+(++next);
              el.setAttribute('data-interlinked-menu-id',id);
              return {id,label,title:a11y(el)||label,href:href||'',kind,icon:'',iconKind:'',side:'leading',current:!!current,children};
            };
            const siteName=()=>{
              const meta=clean(document.querySelector('meta[property="og:site_name"]')?.getAttribute('content')||'');
              if (meta && meta.length>=2 && meta.length<=24 && !meta.includes('/')) return meta;
              return location.hostname.replace(/^www\./,'').toLowerCase();
            };
            const readSearch=el=>{
              if (!el || !visible(el) || !isSearch(el)) return null;
              if (el.getBoundingClientRect().top>innerHeight*0.62) return null;
              const form=el.closest('form');
              const action=httpURL((form && (form.getAttribute('action')||form.action)) || origin+'/search');
              if (!action) return null;
              return {action:action.href,placeholder:'Search',queryParam:el.getAttribute('name')||'q'};
            };
            const itemsFrom=(root,top,bottom)=>{
              if (!root || root===document.body || root===document.documentElement) return [];
              const controls=[...root.querySelectorAll('a[href],button,[role="button"],[role="link"],[role="tab"]')]
                .filter(el=>inBar(el,top,bottom) && visible(el) && !isSearch(el) && !el.querySelector('a[href],button,[role="button"],[role="tab"]'))
                .sort((a,b)=>a.getBoundingClientRect().left-b.getBoundingClientRect().left);
              const items=[], seen=new Set();
              for (const el of controls) {
                if (items.length>=16) break;
                const label=visibleLabel(el);
                if (!label) continue;
                const href=el.matches('a[href]') ? (httpURL(el.href)?.href || '') : '';
                const key=label+'|'+href;
                if (seen.has(key)) continue; seen.add(key);
                const kids=[];
                const host=el.closest('li,[role="menuitem"]');
                if (host) for (const a of host.querySelectorAll('a[href]')) {
                  if (a===el) continue;
                  const childHref=httpURL(a.href); if (!childHref) continue;
                  const childLabel=visibleLabel(a); if (!childLabel) continue;
                  if (kids.some(kid=>kid.href===childHref.href)) continue;
                  kids.push(mark(a,'link',childHref.href,childLabel,false));
                  if (kids.length>=12) break;
                }
                items.push(mark(el, href?'link':'button', href, label, el.getAttribute('aria-current')==='page'||href===location.href, kids));
              }
              return items;
            };
            const scoreNode=node=>{
              if (!node || node===document.body || node===document.documentElement) return null;
              const described=((node.getAttribute('aria-label')||'')+' '+(node.id||'')).toLowerCase();
              if (/player|playback|cookie|consent|advert/.test(described)) return null;
              if (!node.matches('header,[role="banner"],nav,[role="navigation"]') && node.querySelector('video')) return null;
              const r=node.getBoundingClientRect();
              if (!r.width || r.width<vw*0.45 || r.top>80 || r.bottom<16) return null;
              const password=[...node.querySelectorAll('input[type="password"]')].some(el=>{ const b=el.getBoundingClientRect(); return b.height>8 && b.top<180; });
              if (password) return null;
              const top=Math.max(r.top,0);
              let search=readSearch(node.querySelector('input[type="search"],input[name="q"],textarea[name="q"],[role="combobox"]'));
              const bottom=Math.min(top+(search?150:96), search?176:128);
              if (!search) {
                const control=[...node.querySelectorAll('a[href],button,[role="combobox"],[role="search"]')]
                  .find(el=>isSearch(el) && visible(el) && inBar(el, top-8, bottom));
                if (control) {
                  // A search that is only a link or a button: query its own
                  // destination when it has one, otherwise the site's /search.
                  const target=control.matches('a[href]') ? httpURL(control.href) : null;
                  search={action:(target?target.href:origin+'/search'),placeholder:'Search',queryParam:'q'};
                }
              }
              const items=itemsFrom(node, top-8, bottom);
              if (items.length && items.every(item=>/^(accept|reject|agree|decline|allow|deny|got it|dismiss)$/i.test(item.label))) return null;
              let score=0;
              if (node.matches('header,[role="banner"]')) score+=6;
              else if (node.matches('nav,[role="navigation"],[role="tablist"]')) score+=2;
              const st=getComputedStyle(node);
              if (st.position==='fixed'||st.position==='sticky') score+=3;
              if (search) score+=3;
              if (items.length>=2 && items.length<=8) score+=4;
              if (items.length>10) score-=6;
              if (r.top<=4) score+=2;
              score+=Math.min(items.length,8)*0.15;
              if (!items.length && !search && score<4) return null;
              return {node,items,search,height:Math.min(Math.max(r.height,44),72),score};
            };
            const candidates=[];
            document.querySelectorAll('header,[role="banner"],nav,[role="navigation"],[role="tablist"]').forEach(node=>candidates.push(node));
            const roots=[document.body,...Array.from(document.body?document.body.children:[]).slice(0,12)];
            for (const el of roots) {
              if (!el) continue;
              const s=getComputedStyle(el);
              if (s.position==='fixed'||s.position==='sticky') candidates.push(el);
              for (const child of Array.from(el.children||[]).slice(0,8)) {
                const cs=getComputedStyle(child);
                if (cs.position==='fixed'||cs.position==='sticky') candidates.push(child);
              }
            }
            let best=null; const seenNodes=new Set();
            for (const node of candidates) {
              if (!node || seenNodes.has(node)) continue; seenNodes.add(node);
              const next=scoreNode(node);
              if (next && (!best || next.score>best.score)) best=next;
            }
            if (!best) {
              const field=document.querySelector('input[name="q"],textarea[name="q"],input[type="search"]');
              let node=field;
              for (let depth=0; node && depth<8; depth++) {
                const parent=node.parentElement;
                if (!parent || parent===document.body) break;
                const r=parent.getBoundingClientRect();
                if (r.top>80 || r.height>=260) break;
                node=parent;
                if (r.width<vw*0.6) continue;
                const found=scoreNode(node);
                if (found && (found.items.length || found.search)) best=found;
              }
            }
            let items=best?best.items.slice():[];
            let search=best?best.search:null;
            const extras=[];
            if (items.length<2 && best) {
              const pools=[];
              const sib=best.node.nextElementSibling;
              if (sib) pools.push(sib, ...Array.from(sib.children||[]).slice(0,6));
              for (const node of candidates) if (node && node!==best.node) pools.push(node);
              const used=new Set(items.map(item=>item.label+'|'+item.href));
              const chromeBottom=best.node.getBoundingClientRect().bottom;
              const fixed=getComputedStyle(best.node).position==='fixed';
              for (const node of pools) {
                if (!node || node===best.node) continue;
                const aria=(node.getAttribute('aria-label')||'').toLowerCase();
                if (/repository|breadcrumb/.test(aria)) continue;
                const r=node.getBoundingClientRect();
                if (r.top>120 || r.height<16 || r.height>70 || r.width<vw*0.3) continue;
                if (fixed && r.top>chromeBottom+8) continue;
                const row=itemsFrom(node, r.top-4, r.bottom+4).filter(item=>!used.has(item.label+'|'+item.href));
                if (row.length<2) continue;
                for (const item of row) {
                  if (items.length>=16) break;
                  items.push(item);
                  used.add(item.label+'|'+item.href);
                }
                extras.push(node);
                break;
              }
            }
            if (!search) search=readSearch(document.querySelector('input[name="q"],textarea[name="q"],input[type="search"]'));
            const replacesChrome=!!(best && (items.length || (best && best.search)));
            siteMenuNode=replacesChrome ? best.node : null;
            siteMenuExtras=replacesChrome ? extras : [];
            let home=origin+'/';
            const logo=document.querySelector('header a[href="/"],a[href="/"],a[href="'+origin+'/"],a[href="'+origin+'"]');
            if (logo) { const href=httpURL(logo.href); if (href) home=href.href; }
            return {home,name:siteName(),items,search,height:best?best.height:44,replacesChrome};
          } catch { siteMenuNode=null; siteMenuExtras=[]; return null; }
        },
        hideSiteMenu() {
          const extras=Array.isArray(siteMenuExtras)?siteMenuExtras:[];
          const nodes=[siteMenuNode, ...extras].filter(node=>node?.isConnected);
          if (!nodes.length) return false;
          if (!siteMenuPrevious) {
            siteMenuPrevious=nodes.map(node=>({
              node,
              visibility:node.style.getPropertyValue('visibility'),
              visibilityPriority:node.style.getPropertyPriority('visibility'),
              pointer:node.style.getPropertyValue('pointer-events'),
              pointerPriority:node.style.getPropertyPriority('pointer-events')
            }));
          }
          const primary=nodes[0], s=getComputedStyle(primary), box=primary.getBoundingClientRect();
          if (s.position==='fixed' && !siteMenuSpacer) {
            const barHeight=Math.min(Math.ceil(box.height),72);
            siteMenuSpacer=document.createElement('div');
            siteMenuSpacer.id='interlinked-site-menu-spacer';
            siteMenuSpacer.style.cssText='height:'+barHeight+'px;width:100%;pointer-events:none;flex:none;';
            document.body.insertBefore(siteMenuSpacer, document.body.firstChild);
          }
          for (const node of nodes) {
            node.style.setProperty('visibility','hidden','important');
            node.style.setProperty('pointer-events','none','important');
            node.dataset.interlinkedSiteMenu='true';
          }
          return true;
        },
        // After the page re-lays itself out, for example on resize: restore,
        // read again, and hide the header now on screen, all in one task so the
        // site's own header never paints in between.
        refreshSiteMenu() {
          this.showSiteMenu();
          const menu=this.siteMenu();
          if (menu && menu.replacesChrome) this.hideSiteMenu();
          return menu;
        },
        showSiteMenu() {
          const saved=Array.isArray(siteMenuPrevious)?siteMenuPrevious:[];
          for (const prev of saved) {
            const node=prev.node;
            if (!node?.isConnected) continue;
            if (!prev.visibility && !prev.visibilityPriority) node.style.removeProperty('visibility');
            else node.style.setProperty('visibility',prev.visibility,prev.visibilityPriority);
            if (!prev.pointer && !prev.pointerPriority) node.style.removeProperty('pointer-events');
            else node.style.setProperty('pointer-events',prev.pointer,prev.pointerPriority);
            delete node.dataset.interlinkedSiteMenu;
          }
          siteMenuSpacer?.remove();
          siteMenuNode=null; siteMenuPrevious=null; siteMenuSpacer=null; siteMenuExtras=[];
          return true;
        },
        activateSiteMenuItem(id) {
          const el=document.querySelector('[data-interlinked-menu-id="'+id+'"]');
          if (!el?.isConnected) return false;
          el.click();
          return true;
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
    static func siteMenu<View: PageJavaScriptEvaluating>(_ view: View) async -> SiteMenu? {
        try? await value(view, call: "return interlinkedContext.siteMenu();", type: SiteMenu.self)
    }
    static func refreshSiteMenu<View: PageJavaScriptEvaluating>(_ view: View) async -> SiteMenu? {
        try? await value(view, call: "return interlinkedContext.refreshSiteMenu();", type: SiteMenu.self)
    }
    static func hideSiteMenu<View: PageJavaScriptEvaluating>(_ view: View) async -> Bool {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.hideSiteMenu() ?? false;")) as? Bool ?? false
    }
    static func showSiteMenu<View: PageJavaScriptEvaluating>(_ view: View?) async {
        guard let view else { return }
        _ = try? await execute(view, body: "return globalThis.interlinkedContext?.showSiteMenu() ?? false;")
    }
    /// The person clicked this item in the browser's menu bar, so the page
    /// receives it as their click.
    static func activateSiteMenuItem<View: PageJavaScriptEvaluating>(_ view: View, id: String) async -> Bool {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.activateSiteMenuItem(id) ?? false;",
                            arguments: ["id": id], userGesture: true)) as? Bool ?? false
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
