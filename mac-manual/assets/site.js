(() => {
  const lightbox = document.getElementById('lightbox');
  document.querySelectorAll('figure.diagram').forEach((fig) => {
    fig.addEventListener('click', () => {
      lightbox.innerHTML = '<div class="diagram">' + fig.querySelector('svg').outerHTML + '</div>';
      lightbox.hidden = false;
    });
  });
  lightbox?.addEventListener('click', () => { lightbox.hidden = true; });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && lightbox) lightbox.hidden = true; });

  const menu = document.getElementById('menu-btn');
  const rail = document.getElementById('rail');
  menu?.addEventListener('click', () => {
    const open = rail.classList.toggle('open');
    menu.setAttribute('aria-expanded', String(open));
  });
})();
