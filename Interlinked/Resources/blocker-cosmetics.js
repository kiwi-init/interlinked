// Element hiding for one document. Runs at document start in an isolated
// world; the caller wraps it in a function and defines |cfg| first:
// hide (CSS selectors), procedural (the engine's JSON filters), generic, binding.
const sheet = new CSSStyleSheet();
const hide = selectors => {
  for (const selector of selectors) {
    // One rule per selector: an invalid selector must not void the others.
    try { sheet.insertRule(selector + '{display:none!important}', sheet.cssRules.length); } catch {}
  }
};
hide(cfg.hide);
const adopt = () => {
  if (!document.adoptedStyleSheets.includes(sheet)) {
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
  }
};
adopt();
document.addEventListener('DOMContentLoaded', adopt);
globalThis.__interlinkedHide = selectors => { hide(selectors); adopt(); };

// Procedural filters. Each is {selector: [{type, arg}], action?: {type, arg}}:
// the first operator finds elements, each later one narrows or moves that set,
// and the action applies to what is left (hiding when there is none).
// Brave's content_cosmetic.ts is the reference for the operator semantics.
const procedural = (cfg.procedural ?? []).flatMap(json => {
  try { return [JSON.parse(json)]; } catch { return []; }
});

// "/regex/flags" or plain text. Plain text is a substring, or the whole value
// when |exact|.
const matcher = (arg, exact = false) => {
  const regex = /^\/(.+)\/([dgimsuvy]*)$/.exec(arg);
  if (regex) {
    try { const pattern = new RegExp(regex[1], regex[2]); return value => pattern.test(value); } catch { return () => false; }
  }
  return exact ? value => value === arg : value => value.includes(arg);
};
const unquote = value => {
  value = value.trim();
  return /^(["']).*\1$/.test(value) ? value.slice(1, -1) : value;
};
// Splits `name<separator>value`; a quoted or /regex/ name may hold the separator.
const nameAndValue = (arg, separator) => {
  const quoted = /^\s*(["'/])/.exec(arg);
  const end = quoted ? arg.indexOf(quoted[1], quoted.index + quoted[0].length) + 1 : 0;
  const at = arg.indexOf(separator, end);
  return at < 0 ? [unquote(arg), null] : [unquote(arg.slice(0, at)), unquote(arg.slice(at + 1))];
};

// Each operator takes the current elements and returns the next ones.
const cssSelector = (selector, elements, first) => {
  if (first) return document.querySelectorAll(selector);
  const relative = selector.trimStart();
  const rest = relative.slice(1).trim();
  return elements.flatMap(element => {
    if (relative[0] === '+') {
      const next = element.nextElementSibling;
      return next?.matches(rest) ? [next] : [];
    }
    if (relative[0] === '~') {
      const siblings = [];
      for (let next = element.nextElementSibling; next; next = next.nextElementSibling) {
        if (next.matches(rest)) siblings.push(next);
      }
      return siblings;
    }
    return [...element.querySelectorAll(':scope ' + relative)];
  });
};
const hasText = (arg, elements) => {
  const test = matcher(arg);
  return elements.filter(element => test(element.textContent));
};
const matchesAttr = (arg, elements) => {
  const [name, value] = nameAndValue(arg, '=');
  const testName = matcher(name, true), testValue = value === null ? () => true : matcher(value, true);
  return elements.filter(element =>
    [...element.attributes].some(attribute => testName(attribute.name) && testValue(attribute.value)));
};
const matchesCss = pseudo => (arg, elements) => {
  const [property, value] = nameAndValue(arg, ':');
  const test = matcher(value ?? '', true);
  return elements.filter(element => test(getComputedStyle(element, pseudo).getPropertyValue(property)));
};
const matchesPath = (arg, elements) =>
  matcher(arg)(location.pathname + location.search) ? elements : [];
const minTextLength = (arg, elements) => elements.filter(element => element.textContent.length >= Number(arg));
const upward = (arg, elements) => elements.flatMap(element => {
  if (/^\d+$/.test(arg)) {
    let ancestor = element;
    for (let steps = Number(arg); ancestor && steps > 0; steps -= 1) ancestor = ancestor.parentElement;
    return ancestor ? [ancestor] : [];
  }
  const ancestor = element.parentElement?.closest(arg);
  return ancestor ? [ancestor] : [];
});
const xpath = (arg, elements) => elements.flatMap(element => {
  const found = document.evaluate(arg, element, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
  const nodes = [];
  for (let index = 0; index < found.snapshotLength; index += 1) {
    const node = found.snapshotItem(index);
    if (node.nodeType === Node.ELEMENT_NODE) nodes.push(node);
  }
  return nodes;
});
const operators = {
  'css-selector': cssSelector,
  'has-text': hasText,
  'matches-attr': matchesAttr,
  'matches-css': matchesCss(null),
  'matches-css-before': matchesCss('::before'),
  'matches-css-after': matchesCss('::after'),
  'matches-path': matchesPath,
  'min-text-length': minTextLength,
  'upward': upward,
  'xpath': xpath,
};

// Hidden and restyled elements carry a marker attribute whose tokens name a
// rule in |sheet|; the name is random so the page cannot target it.
const marker = 'il-' + Math.random().toString(36).slice(2, 10);
const styleTokens = new Map();
const mark = (element, declarations) => {
  let token = styleTokens.get(declarations);
  if (!token) {
    token = String(styleTokens.size);
    try {
      sheet.insertRule(`[${marker}~="${token}"]{${declarations}}`, sheet.cssRules.length);
    } catch { return; }
    styleTokens.set(declarations, token);
  }
  const tokens = (element.getAttribute(marker) ?? '').split(' ').filter(Boolean);
  if (!tokens.includes(token)) element.setAttribute(marker, [...tokens, token].join(' '));
};
const actions = {
  'style': (element, arg) => mark(element, arg),
  'remove': element => element.remove(),
  'remove-attr': (element, arg) => element.removeAttribute(arg),
  'remove-class': (element, arg) => element.classList.remove(arg),
};
const hideElement = element => mark(element, 'display:none!important');

const apply = filter => {
  let elements = [document.documentElement];
  filter.selector.forEach((operator, index) => {
    const run = operators[operator.type];
    elements = run ? [...new Set(run(operator.arg, elements, index === 0))] : [];
  });
  const act = filter.action ? actions[filter.action.type] : hideElement;
  if (act) for (const element of elements) act(element, filter.action?.arg);
};

if (procedural.length) {
  // Pages that change constantly would re-run every rule on every mutation;
  // at most one pass per quarter second keeps heavy pages responsive.
  const interval = 250;
  let timer = 0, last = -interval;
  const run = () => {
    timer = 0;
    last = performance.now();
    for (const filter of procedural) {
      try { apply(filter); } catch {}
    }
  };
  const schedule = () => {
    if (!timer) timer = setTimeout(run, Math.max(0, last + interval - performance.now()));
  };
  new MutationObserver(schedule).observe(document, { childList: true, subtree: true, characterData: true });
  document.addEventListener('DOMContentLoaded', schedule);
  schedule();
}

// Generic rules depend on the classes and ids the page uses; report them.
const report = globalThis[cfg.binding];
if (!cfg.generic || typeof report !== 'function') return;
const seenClasses = new Set(), seenIds = new Set();
let classes = [], ids = [], scheduled = false;
const flush = () => {
  scheduled = false;
  if (!classes.length && !ids.length) return;
  report(JSON.stringify({ classes, ids }));
  classes = []; ids = [];
};
const note = element => {
  const id = element.id;
  if (id && typeof id === 'string' && !seenIds.has(id)) { seenIds.add(id); ids.push(id); }
  for (const name of element.classList ?? []) {
    if (!seenClasses.has(name)) { seenClasses.add(name); classes.push(name); }
  }
};
const scan = root => {
  if (root.nodeType !== 1) return;
  note(root);
  for (const element of root.querySelectorAll('[id],[class]')) note(element);
  if (!scheduled && (classes.length || ids.length)) { scheduled = true; setTimeout(flush, 80); }
};
new MutationObserver(records => {
  for (const record of records) {
    if (record.type === 'attributes') scan(record.target);
    else for (const node of record.addedNodes) scan(node);
  }
}).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'id'] });
if (document.documentElement) scan(document.documentElement);
