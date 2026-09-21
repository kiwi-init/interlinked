import Foundation

@MainActor
protocol PageJavaScriptEvaluating: AnyObject {
    func interlinkedEvaluate(_ body: String, arguments: [String: Any]) async throws -> Any?
    /// Whether Interlinked is darkening this page.
    var rendersDark: Bool { get }
}

extension PageJavaScriptEvaluating {
    var rendersDark: Bool { false }
}

/// Runs on demand in the page. Reading annotations track only their source nodes.
@MainActor enum PageTextBridge {
    static let install = #"""
    if (!globalThis.interlinkedContext) {
      const documentID = crypto.randomUUID();
      const ids = new WeakMap(), nodes = new Map(); let next = 0;
      let stopReading, lastLink;
      let siteMenuNode, siteMenuPrevious, siteMenuSpacer;
      let siteMenuExtras=[];
      // Dark pages, whether darkened by Interlinked or dark by design, get a
      // deep amber mark with cream text. Chromium's auto dark mode leaves
      // colors like these alone, so the text never turns white on yellow.
      let darkened=false;
      const darkSurface = node => {
        for (let el=node; el; el=el.parentElement) {
          const m=getComputedStyle(el).backgroundColor.match(/[\d.]+/g);
          if (m && (m.length<4 || +m[3]>0.5)) return (0.2126*m[0]+0.7152*m[1]+0.0722*m[2])/255 < 0.4;
        }
        return matchMedia('(prefers-color-scheme: dark)').matches;
      };
      const markColors = dark => dark
        ? {mark:'#6b5200',current:'#8f6c00',text:'#fff4cc'}
        : {mark:'#ffe66a',current:'#ffcc32',text:'#151515'};
      const clean = value => (value || '').replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
      const excluded = node => node.closest('form,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"],script,style');
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
            sensitive:!!document.querySelector('input[type="password"],textarea,[contenteditable="true"]')};
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
        annotate(items, document, dark) {
          if (document!==documentID) return false;
          darkened=!!dark;
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
        try await value(view, call: "return interlinkedContext.metadata();", type: PageMetadata.self)
    }
    static func siteMenu<View: PageJavaScriptEvaluating>(_ view: View) async -> SiteMenu? {
        try? await value(view, call: "return interlinkedContext.siteMenu();", type: SiteMenu.self)
    }
    static func hideSiteMenu<View: PageJavaScriptEvaluating>(_ view: View) async -> Bool {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.hideSiteMenu() ?? false;")) as? Bool ?? false
    }
    static func showSiteMenu<View: PageJavaScriptEvaluating>(_ view: View?) async {
        guard let view else { return }
        _ = try? await execute(view, body: "return globalThis.interlinkedContext?.showSiteMenu() ?? false;")
    }
    static func activateSiteMenuItem<View: PageJavaScriptEvaluating>(_ view: View, id: String) async -> Bool {
        (try? await execute(view, body: "return globalThis.interlinkedContext?.activateSiteMenuItem(id) ?? false;",
                            arguments: ["id": id])) as? Bool ?? false
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

    static func annotate<View: PageJavaScriptEvaluating>(
        _ findings: [PassageDecisions.Finding], document: String, view: View
    ) async -> Bool {
        let items = findings.map { ["id": $0.passage.id, "text": $0.passage.text,
                                    "label": $0.signal.label, "explanation": $0.signal.explanation] }
        return (try? await execute(view,
            body: "return globalThis.interlinkedContext?.annotate(items, document, dark) ?? false;",
            arguments: ["items": items, "document": document, "dark": view.rendersDark])) as? Bool ?? false
    }

    private static func execute<View: PageJavaScriptEvaluating>(
        _ view: View,
        body: String,
        arguments: [String: Any] = [:]
    ) async throws -> Any? {
        try await view.interlinkedEvaluate(body, arguments: arguments)
    }
}
