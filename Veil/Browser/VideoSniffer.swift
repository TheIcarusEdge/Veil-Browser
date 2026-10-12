import Foundation

/// JavaScript injected into every frame. It reports video files the page loads
/// (video tags, plus fetch and XHR requests for media files) back to the app.
/// Blob and MediaSource streams cannot be downloaded, so they are skipped.
/// A long press on a video sends that one video to the app with kind "pick".
enum VideoSniffer {
    static let source = #"""
    (function () {
      if (window.__veilSniffer) return;
      window.__veilSniffer = true;
      var seen = {};
      var media = /(\.(mp4|m4v|mov|webm|m3u8)(\?|#|$))|applehttp|\/playManifest\//i;

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
      // Long press on a video: find the video under the finger, even when a player
      // draws its controls on top of it.
      function videoAt(x, y) {
        var els = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
        for (var i = 0; i < els.length; i++) {
          if (els[i].tagName === 'VIDEO') return els[i];
        }
        var vids = document.querySelectorAll('video');
        for (var j = 0; j < vids.length; j++) {
          var r = vids[j].getBoundingClientRect();
          if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return vids[j];
        }
        return null;
      }

      var press = null;
      function cancelPress() {
        if (press) { clearTimeout(press.timer); press = null; }
      }
      document.addEventListener('touchstart', function (e) {
        cancelPress();
        if (!e.touches || e.touches.length !== 1) return;
        var t = e.touches[0];
        var x = t.clientX, y = t.clientY;
        press = { x: x, y: y, timer: setTimeout(function () {
          press = null;
          var v = videoAt(x, y);
          if (!v) return;
          var src = v.currentSrc || v.src || '';
          if (!src) {
            var s = v.querySelector('source');
            if (s) src = s.src || '';
          }
          if (src && src.indexOf('blob:') !== 0 && src.indexOf('data:') !== 0) {
            try { src = new URL(src, location.href).href; } catch (err) {}
          }
          try {
            window.webkit.messageHandlers.veilVideo.postMessage({
              kind: 'pick', url: src, page: location.href, title: document.title || ''
            });
          } catch (err) {}
        }, 550) };
      }, { passive: true, capture: true });
      document.addEventListener('touchmove', function (e) {
        if (!press || !e.touches || !e.touches.length) return;
        var t = e.touches[0];
        if (Math.abs(t.clientX - press.x) > 10 || Math.abs(t.clientY - press.y) > 10) cancelPress();
      }, { passive: true, capture: true });
      document.addEventListener('touchend', cancelPress, { passive: true, capture: true });
      document.addEventListener('touchcancel', cancelPress, { passive: true, capture: true });

      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
    })();
    """#
}
