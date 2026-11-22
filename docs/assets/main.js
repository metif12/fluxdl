// Tiny progressive enhancement. The page is fully readable with JS disabled.
(function () {
  'use strict';

  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var blocks = document.querySelectorAll('.reveal');

  if (reduce || !('IntersectionObserver' in window)) {
    blocks.forEach(function (el) { el.classList.add('in'); });
  } else {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('in');
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12 });
    blocks.forEach(function (el) { observer.observe(el); });
  }

  document.querySelectorAll('.copy').forEach(function (button) {
    button.addEventListener('click', function () {
      var block = button.closest('.code');
      if (!block) return;
      var pre = block.querySelector('pre');
      if (!pre) return;
      var text = pre.textContent;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          button.textContent = 'Copied';
          window.setTimeout(function () { button.textContent = 'Copy'; }, 1500);
        });
      }
    });
  });
}());
