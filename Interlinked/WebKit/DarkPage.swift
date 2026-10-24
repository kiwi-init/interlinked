import WebKit

/// Dark pages for sites without a dark theme. WebKit asks every page for its
/// dark theme through `prefers-color-scheme`; a page whose own background
/// stays light is inverted instead, with images and video inverted back.
///
/// It runs at document start in a world the page cannot see, and reads only
/// the page's computed colors, which the filter leaves alone. It decides again
/// as the page changes, so a theme that arrives late is still respected.
enum DarkPage {
    static let world = WKContentWorld.world(name: "interlinked-dark")
    static let stopScript = "globalThis.__interlinkedDark?.stop();"

    static let script = #"""
    (() => {
      const control = globalThis.__interlinkedDark ??= (() => {
        const sheet = new CSSStyleSheet();
        const flip = 'filter:invert(1) hue-rotate(180deg)!important';
        sheet.replaceSync(`html{${flip}}img,video,picture,canvas,iframe,embed,object,svg image,[style*="background-image"]{${flip}}`);
        let active = false, inverted = false, timer = 0;
        const luminance = color => {
          const m = color.match(/[\d.]+/g);
          if (!m || (m.length > 3 && +m[3] < 0.5)) return null;
          return (0.2126 * m[0] + 0.7152 * m[1] + 0.0722 * m[2]) / 255;
        };
        const light = () => {
          const root = document.documentElement;
          if (!root) return false;
          const layers = [];
          for (let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2); el; el = el.parentElement) layers.push(el);
          // The body's background fills the canvas when the root has none.
          if (document.body) layers.push(document.body);
          for (const el of layers) {
            const value = luminance(getComputedStyle(el).backgroundColor);
            if (value !== null) return value > 0.5;
          }
          // Transparent all the way down: the canvas follows the page's color
          // scheme, from CSS or a meta tag, and so does its default text,
          // which is light on a dark canvas.
          const text = luminance(getComputedStyle(document.body ?? root).color);
          return text === null || text < 0.5;
        };
        const adopted = () => document.adoptedStyleSheets.includes(sheet);
        const update = () => {
          timer = 0;
          inverted = active && light();
          // The page may replace its adopted sheets at any time.
          if (inverted && !adopted()) document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          if (!inverted && adopted()) document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
        };
        const schedule = () => { if (active && !timer) timer = setTimeout(update, 250); };
        const observer = new MutationObserver(schedule);
        addEventListener('DOMContentLoaded', schedule);
        addEventListener('load', schedule);
        return {
          start() {
            if (active) return;
            active = true;
            update();
            // At document start the page has no styles yet. The first frame
            // comes after its stylesheets and before anything is painted.
            requestAnimationFrame(update);
            observer.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
          },
          stop() {
            active = false;
            observer.disconnect();
            clearTimeout(timer);
            update();
          },
        };
      })();
      control.start();
    })();
    """#
}
