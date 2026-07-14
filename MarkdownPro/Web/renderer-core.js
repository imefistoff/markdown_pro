// Markdown rendering: marked + highlight.js + mermaid. Lives in its own file
// (not inline) so renderer.html's CSP can use script-src 'self' — without
// 'unsafe-inline', which would also re-enable injected onerror/onload handlers.
(function () {
  'use strict';

  var darkQuery = window.matchMedia('(prefers-color-scheme: dark)');
  var lastMarkdown = null;
  var lastBase = '';
  var renderSeq = 0;

  function initMermaid() {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: darkQuery.matches ? 'dark' : 'default'
    });
  }
  initMermaid();

  // In-page anchor links (#heading) scroll within the document instead of
  // navigating the web view away (the <base> tag would otherwise break them).
  document.getElementById('content').addEventListener('click', function (e) {
    var a = e.target.closest ? e.target.closest('a[href^="#"]') : null;
    if (!a) return;
    var id = decodeURIComponent(a.getAttribute('href').slice(1));
    var target = id ? document.getElementById(id) : document.body;
    if (target) { e.preventDefault(); target.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
  });

  // Re-theme mermaid diagrams when the system appearance flips.
  darkQuery.addEventListener('change', function () {
    initMermaid();
    if (lastMarkdown !== null) window.renderMarkdown(lastMarkdown, lastBase);
  });

  window.renderMarkdown = async function (markdown, baseHref) {
    lastMarkdown = markdown;
    lastBase = baseHref || '';
    var seq = ++renderSeq;

    // Relative image/link paths resolve against the source file's folder.
    var base = document.getElementById('docbase');
    base.href = lastBase ? (lastBase.endsWith('/') ? lastBase : lastBase + '/') : '';

    var content = document.getElementById('content');
    content.innerHTML = marked.parse(markdown, { gfm: true });

    // Give headings GitHub-style slug ids so "#anchor" links have targets.
    var usedSlugs = {};
    content.querySelectorAll('h1, h2, h3, h4, h5, h6').forEach(function (h) {
      if (h.id) return;
      var slug = h.textContent.toLowerCase().trim()
        .replace(/[^\w\s-]/g, '').replace(/\s+/g, '-') || 'section';
      if (usedSlugs[slug] != null) { usedSlugs[slug]++; slug += '-' + usedSlugs[slug]; }
      else { usedSlugs[slug] = 0; }
      h.id = slug;
    });

    // Task lists: nicer checkboxes.
    content.querySelectorAll('li').forEach(function (li) {
      if (li.querySelector(':scope > input[type="checkbox"]')) li.classList.add('task-item');
    });

    // Syntax highlighting for fenced code blocks (skip mermaid).
    content.querySelectorAll('pre code').forEach(function (block) {
      if (block.classList.contains('language-mermaid')) return;
      try { hljs.highlightElement(block); } catch (e) { /* unknown language */ }
    });

    // Mermaid: swap ```mermaid blocks for rendered diagrams.
    var mermaidBlocks = content.querySelectorAll('pre code.language-mermaid');
    var targets = [];
    mermaidBlocks.forEach(function (block) {
      var holder = document.createElement('pre');
      holder.className = 'mermaid';
      holder.textContent = block.textContent;
      block.parentElement.replaceWith(holder);
      targets.push(holder);
    });
    for (var i = 0; i < targets.length; i++) {
      if (seq !== renderSeq) return; // a newer render superseded this one
      try {
        var result = await mermaid.render('mmd-' + seq + '-' + i, targets[i].textContent);
        targets[i].innerHTML = result.svg;
      } catch (err) {
        var msg = document.createElement('div');
        msg.className = 'mermaid-error';
        msg.textContent = 'mermaid: ' + (err && err.message ? err.message : err);
        targets[i].replaceChildren(msg);
      }
    }
    if (window.__reviewRepaint) window.__reviewRepaint();
  };
})();
