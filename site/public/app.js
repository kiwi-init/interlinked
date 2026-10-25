// The copy buttons next to each brew line, as on Channels' site. A file of its
// own, so the CSP stays script-src 'self'.
for (const button of document.querySelectorAll("button[data-copy]")) {
  button.addEventListener("click", async () => {
    const source = document.getElementById(button.getAttribute("data-copy"));
    const text = source ? source.textContent.trim() : "";
    if (!text) return;
    const done = button.textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "copied";
    } catch {
      // Clipboard needs a secure context and permission; select the text instead.
      const range = document.createRange();
      if (source) range.selectNodeContents(source);
      const selection = getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    }
    setTimeout(() => (button.textContent = done), 1500);
  });
}
