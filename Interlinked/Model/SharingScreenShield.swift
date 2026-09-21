import Foundation

enum SharingScreenModePreference {
    static let key = "privacy.sharingScreenMode"

    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Blurs sensitive text while the screen is being shared. It runs at the
/// start of every document, before the page paints, and never leaves the
/// page: nothing it finds is reported to Interlinked or any model.
///
/// Text is covered with a CSS custom highlight rather than wrapped in new
/// elements, so pages built on frameworks that own their DOM keep working.
/// Form fields that hold sensitive values are blurred as whole elements.
enum SharingScreenShield {
    static let stopScript = "globalThis.__interlinkedShield?.stop();"

    static let script = #"""
    (() => {
      if (globalThis.__interlinkedShield) return;
      const NAME = 'interlinked-shield', ATTR = 'data-interlinked-shield';
      const digits = s => s.replace(/\D/g, '');
      const luhn = s => {
        const d = digits(s); if (d.length < 13 || d.length > 19) return false;
        let sum = 0, alt = false;
        for (let i = d.length - 1; i >= 0; i--) { let n = +d[i]; if (alt) { n *= 2; if (n > 9) n -= 9; } sum += n; alt = !alt; }
        return sum % 10 === 0;
      };
      const cpf = s => {
        const d = digits(s); if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false;
        const check = n => { let sum = 0; for (let i = 0; i < n; i++) sum += +d[i] * (n + 1 - i); return sum * 10 % 11 % 10 === +d[n]; };
        return check(9) && check(10);
      };
      const cnpj = s => {
        const d = digits(s); if (d.length !== 14 || /^(\d)\1+$/.test(d)) return false;
        const check = (n, weights) => { let sum = 0; for (let i = 0; i < n; i++) sum += +d[i] * weights[i]; const r = sum % 11; return (r < 2 ? 0 : 11 - r) === +d[n]; };
        return check(12, [5,4,3,2,9,8,7,6,5,4,3,2]) && check(13, [6,5,4,3,2,9,8,7,6,5,4,3,2]);
      };
      const iban = s => {
        const v = s.replace(/\s/g, '').toUpperCase(); if (v.length < 15 || v.length > 34) return false;
        let rest = 0;
        for (const c of v.slice(4) + v.slice(0, 4)) { const n = c >= 'A' ? String(c.charCodeAt(0) - 55) : c; for (const x of n) rest = (rest * 10 + +x) % 97; }
        return rest === 1;
      };
      const phone = s => { const n = digits(s).length; return n >= 8 && n <= 15; };
      // [pattern, validator, capture group holding the secret]
      const rules = [
        [/[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}/gi],
        [/\b(?:\d[ -]?){12,18}\d\b/g, luhn],
        [/\b\d{3}\.\d{3}\.\d{3}-\d{2}\b|\b\d{11}\b/g, cpf],
        [/\b\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}\b/g, cnpj],
        [/\b\d{3}-\d{2}-\d{4}\b/g],
        [/\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b/g, iban],
        [/(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)[\s.-]?|\b\d{2,4}[\s.-])\d{3,5}[\s.-]?\d{4}\b/g, phone],
        [/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{20,}|\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}|\bAKIA[0-9A-Z]{16}\b|\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAIza[0-9A-Za-z_-]{35}|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g],
        [/(?:passport|passaporte|pasaporte|\bRG\b|identity card|id (?:no|number)|n[uú]mero do documento|document number|driver'?s licen[cs]e|\bCNH\b|\bNIF\b|\bDNI\b|\bNIE\b|tax id|password|senha|contraseña|passcode|\bPIN\b)\s*(?:n[ºo°.]*|number|#)?\s*[:#]\s*([A-Z0-9][A-Z0-9.\-\/ ]{2,24}[A-Z0-9])/gi, null, 1],
      ];
      const matches = text => {
        const found = [];
        for (const [pattern, valid, group] of rules) {
          pattern.lastIndex = 0;
          for (let m; (m = pattern.exec(text));) {
            const value = group ? m[group] : m[0];
            if (!value || (valid && !valid(value))) continue;
            const start = m.index + (group ? m[0].lastIndexOf(value) : 0);
            found.push([start, start + value.length]);
          }
        }
        found.sort((a, b) => a[0] - b[0]);
        const merged = [];
        for (const span of found) {
          const last = merged[merged.length - 1];
          if (last && span[0] <= last[1]) last[1] = Math.max(last[1], span[1]); else merged.push(span);
        }
        return merged;
      };

      const sheet = new CSSStyleSheet();
      sheet.replaceSync('::highlight(' + NAME + '){color:transparent;background-color:rgba(128,128,128,.28);text-shadow:0 0 .5em rgba(128,128,128,.95);text-decoration:none}'
        + '[' + ATTR + ']{filter:blur(6px)!important}');
      const adopt = () => { if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet]; };
      adopt();
      const highlight = new Highlight(); highlight.priority = 100;
      CSS.highlights.set(NAME, highlight);
      const byNode = new Map();

      const editable = el => el && el.closest('script,style,noscript,template,textarea,[contenteditable=""],[contenteditable="true"]');
      const scanText = node => {
        const old = byNode.get(node);
        if (old) { old.forEach(r => highlight.delete(r)); byNode.delete(node); }
        const text = node.data;
        if (text.length < 4 || !/[\d@:]/.test(text) || editable(node.parentElement)) return;
        const ranges = matches(text).map(([start, end]) => { const r = new Range(); r.setStart(node, start); r.setEnd(node, end); return r; });
        if (!ranges.length) return;
        ranges.forEach(r => highlight.add(r));
        byNode.set(node, ranges);
      };
      const sensitiveField = el => {
        if (el.matches('input[type="password"]')) return true;
        const hint = (el.getAttribute('autocomplete') || '') + ' ' + (el.getAttribute('type') || '') + ' ' + (el.getAttribute('name') || '');
        if (/cc-|email|tel|one-time-code|password|\bcpf\b|\bssn\b|passport|iban/i.test(hint)) return true;
        return !!el.value && matches(el.value).length > 0;
      };
      const markField = el => {
        if (el.matches('input[type="hidden"],input[type="checkbox"],input[type="radio"],input[type="button"],input[type="submit"]')) return;
        if (sensitiveField(el)) el.setAttribute(ATTR, ''); else el.removeAttribute(ATTR);
      };
      const scan = root => {
        if (root.nodeType === Node.TEXT_NODE) { scanText(root); return; }
        if (root.nodeType !== Node.ELEMENT_NODE && root.nodeType !== Node.DOCUMENT_NODE) return;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let node; (node = walker.nextNode());) scanText(node);
        if (root.matches?.('input,textarea')) markField(root);
        root.querySelectorAll?.('input,textarea').forEach(markField);
      };
      const prune = () => {
        for (const [node, ranges] of byNode) {
          if (!node.isConnected) { ranges.forEach(r => highlight.delete(r)); byNode.delete(node); }
        }
      };
      // Mutation callbacks run before the next paint, so new text is covered
      // before anyone watching the screen can read it.
      const observer = new MutationObserver(records => {
        adopt();
        for (const record of records) {
          if (record.type === 'characterData') scanText(record.target);
          else record.addedNodes.forEach(scan);
        }
        if (records.some(r => r.removedNodes.length)) prune();
      });
      observer.observe(document, {childList: true, subtree: true, characterData: true});
      const onInput = event => { if (event.target?.matches?.('input,textarea')) markField(event.target); };
      document.addEventListener('input', onInput, true);
      scan(document);

      globalThis.__interlinkedShield = {
        covered: () => [...highlight].map(r => r.toString()).concat([...document.querySelectorAll('[' + ATTR + ']')].map(el => '#' + (el.id || el.tagName.toLowerCase()))),
        stop() {
          observer.disconnect();
          document.removeEventListener('input', onInput, true);
          CSS.highlights.delete(NAME);
          document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
          document.querySelectorAll('[' + ATTR + ']').forEach(el => el.removeAttribute(ATTR));
          byNode.clear();
          delete globalThis.__interlinkedShield;
        },
      };
    })();
    """#
}
