// Review Center annotation layer: selection capture, quote anchoring, and
// highlight painting, bridged over the "review" script-message handler.
// External file (not inline) so the CSP can keep script-src 'self'.
(function () {
  'use strict';

  var annotations = [];   // [{id, quote, prefix, suffix}] — current round, open
  var anchorRanges = {};  // id -> {start, end} offsets into content.textContent
  var pendingSelection = null;
  var content = document.getElementById('content');
  var btn = document.getElementById('annotate-btn');

  function post(msg) {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.review) {
      window.webkit.messageHandlers.review.postMessage(msg);
    }
  }

  function contentText() { return content.textContent; }

  // Convert [start, end) offsets over content.textContent to a DOM Range.
  function textRange(start, end) {
    var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var pos = 0, node, haveStart = false;
    while ((node = walker.nextNode())) {
      var next = pos + node.data.length;
      if (!haveStart && start < next) { range.setStart(node, start - pos); haveStart = true; }
      if (haveStart && end <= next) { range.setEnd(node, end - pos); return range; }
      pos = next;
    }
    return null;
  }

  // W3C TextQuoteSelector matching: prefer the quote occurrence whose
  // surrounding text matches prefix/suffix; fall back to first occurrence.
  function findAnchor(a) {
    if (!a.quote) return null;
    var text = contentText();
    var from = 0, idx, best = null;
    while ((idx = text.indexOf(a.quote, from)) !== -1) {
      var score = 0;
      if (a.prefix && text.slice(Math.max(0, idx - a.prefix.length), idx) === a.prefix) score++;
      if (a.suffix && text.slice(idx + a.quote.length, idx + a.quote.length + a.suffix.length) === a.suffix) score++;
      if (!best || score > best.score) best = { start: idx, score: score };
      if (score === 2) break;
      from = idx + 1;
    }
    return best ? { start: best.start, end: best.start + a.quote.length } : null;
  }

  function repaint() {
    anchorRanges = {};
    var anchored = {};
    var ranges = [];
    annotations.forEach(function (a) {
      var pos = findAnchor(a);
      anchored[a.id] = !!pos;
      if (pos) {
        anchorRanges[a.id] = pos;
        var r = textRange(pos.start, pos.end);
        if (r) ranges.push(r);
      }
    });
    // CSS Custom Highlight API (Safari 17.2+). Without it, comments still
    // work from the side panel — graceful degradation per spec.
    if (window.Highlight && CSS.highlights) {
      CSS.highlights.delete('review');
      if (ranges.length) CSS.highlights.set('review', new Highlight(...ranges));
    }
    post({ type: 'anchors', anchored: anchored });
  }
  window.__reviewRepaint = repaint;

  window.setReviewAnnotations = function (list) {
    annotations = list || [];
    repaint();
  };

  // Click on a painted highlight -> select its comment in the panel.
  content.addEventListener('click', function (e) {
    var caret = document.caretRangeFromPoint(e.clientX, e.clientY);
    if (!caret) return;
    var probe = document.createRange();
    probe.selectNodeContents(content);
    probe.setEnd(caret.startContainer, caret.startOffset);
    var offset = probe.toString().length;
    for (var id in anchorRanges) {
      if (offset >= anchorRanges[id].start && offset <= anchorRanges[id].end) {
        post({ type: 'annotationClicked', id: Number(id) });
        return;
      }
    }
  });

  function hideButton() {
    btn.style.display = 'none';
    pendingSelection = null;
  }

  function captureSelection() {
    // Only in the Review Center (which installs the handler); the plain
    // reader never shows the comment button.
    if (!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.review)) return;
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) { hideButton(); return; }
    var range = sel.getRangeAt(0);
    if (!content.contains(range.commonAncestorContainer)) { hideButton(); return; }
    var quote = range.toString();
    if (!quote.trim()) { hideButton(); return; }
    var probe = document.createRange();
    probe.selectNodeContents(content);
    probe.setEnd(range.startContainer, range.startOffset);
    var start = probe.toString().length;
    var text = contentText();
    pendingSelection = {
      quote: quote,
      prefix: text.slice(Math.max(0, start - 32), start),
      suffix: text.slice(start + quote.length, start + quote.length + 32)
    };
    var rect = range.getBoundingClientRect();
    btn.style.left = (window.scrollX + rect.left) + 'px';
    btn.style.top = (window.scrollY + rect.bottom + 6) + 'px';
    btn.style.display = 'block';
  }

  function sendPending() {
    if (!pendingSelection) return;
    post({ type: 'selection', quote: pendingSelection.quote,
           prefix: pendingSelection.prefix, suffix: pendingSelection.suffix });
    hideButton();
    window.getSelection().removeAllRanges();
  }

  document.addEventListener('mouseup', function () { setTimeout(captureSelection, 0); });
  // mousedown (not click) so we act before the selection collapses.
  btn.addEventListener('mousedown', function (e) { e.preventDefault(); sendPending(); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'c' && pendingSelection && !e.metaKey && !e.ctrlKey && !e.altKey) {
      e.preventDefault();
      sendPending();
    }
  });
})();
