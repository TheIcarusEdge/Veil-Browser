import Foundation

/// JavaScript injected into every frame. It reports video files the page loads
/// (video tags, plus fetch and XHR requests for media files) back to the app.
/// Blob and MediaSource streams cannot be downloaded, so they are skipped.
enum VideoSniffer {
    static let source = #"""
    (function () {
      if (window.__veilSniffer) return;
      window.__veilSniffer = true;
      var seen = {};
      var media = /\.(mp4|m4v|mov|webm|m3u8)(\?|#|$)/i;

      function report(u) {
        try {
          if (!u || typeof u !== 'string') return;
          if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
          var abs = new URL(u, location.href).href;
          if (seen[abs]) return;
          seen[abs] = true;
          window.webkit.messageHandlers.veilVideo.postMessage({
            url: abs, page: location.href, title: document.title || ''
          });
        } catch (e) {}
      }

      function scan() {
        var els = document.querySelectorAll('video, video source');
        for (var i = 0; i < els.length; i++) {
          report(els[i].currentSrc || els[i].src);
        }
      }

      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        try { if (media.test(String(url))) report(String(url)); } catch (e) {}
        return origOpen.apply(this, arguments);
      };

      if (window.fetch) {
        var origFetch = window.fetch;
        window.fetch = function (input) {
          try {
            var u = typeof input === 'string' ? input : (input && input.url);
            if (u && media.test(u)) report(u);
          } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      function onMedia(e) {
        var t = e.target;
        if (t && t.tagName === 'VIDEO') report(t.currentSrc || t.src);
      }
      document.addEventListener('play', onMedia, true);
      document.addEventListener('loadedmetadata', onMedia, true);

      function start() {
        scan();
        new MutationObserver(scan).observe(document.documentElement, {
          childList: true, subtree: true, attributes: true, attributeFilter: ['src']
        });
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#
}
