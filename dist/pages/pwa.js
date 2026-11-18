// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors
//
// The site as an app (package 95): registers the service worker (sw.js, written by dist/pages/make-pwa.py), offers
// "Install the app" where the browser allows it, and lets a new version in.
//
// A page can say it is busy - a game running - with window.OpenLF2Busy = () => true|false (index.html does). A new
// version then waits for the player ("Update now"); a page nobody has touched yet just reloads into it.
// On the page, optional: a button #install-app (shown when the browser can install the site) and a line
// #install-ios (shown on an iPhone or iPad, where Safari installs from its Share menu).
(() => {
  const standalone = () => window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;

  // "Install the app": Chrome, Edge and Android offer it themselves; this button only brings their offer onto the page.
  let offer = null;
  window.addEventListener('beforeinstallprompt', (event) => {
    event.preventDefault();
    offer = event;
    const button = document.getElementById('install-app');
    if (button) button.hidden = false;
  });
  window.addEventListener('appinstalled', () => {
    offer = null;
    const button = document.getElementById('install-app');
    if (button) button.hidden = true;
  });
  document.addEventListener('DOMContentLoaded', () => {
    const button = document.getElementById('install-app');
    if (button) {
      button.addEventListener('click', async () => {
        if (!offer) return;
        const event = offer;
        offer = null;
        button.hidden = true;
        event.prompt();
        try { await event.userChoice; } catch (error) { /* closed */ }
      });
    }
    const ios = document.getElementById('install-ios');
    const apple = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    if (ios && apple && !standalone()) ios.hidden = false;
  });

  if (!('serviceWorker' in navigator)) return;
  const local = location.hostname === 'localhost' || location.hostname === '127.0.0.1';
  if (location.protocol !== 'https:' && !local) return;

  // An installed app keeps what it stored (the browser could otherwise clear it when the disk fills up).
  if (standalone() && navigator.storage && navigator.storage.persist) navigator.storage.persist().catch(() => {});

  let touched = false;
  for (const name of ['pointerdown', 'keydown']) {
    window.addEventListener(name, () => { touched = true; }, { capture: true, once: true });
  }
  const busy = () => typeof window.OpenLF2Busy === 'function' && Boolean(window.OpenLF2Busy());

  // The first version installed takes over without a reload; a later one reloads the page into it.
  const controlled = Boolean(navigator.serviceWorker.controller);
  let reloading = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!controlled || reloading) return;
    reloading = true;
    location.reload();
  });

  function banner(worker) {
    if (document.getElementById('pwa-update')) return;
    const bar = document.createElement('div');
    bar.id = 'pwa-update';
    bar.setAttribute('role', 'status');
    bar.style.cssText = 'position:fixed;left:50%;bottom:1rem;transform:translateX(-50%);z-index:10000;display:flex;'
      + 'flex-wrap:wrap;gap:.6rem;align-items:center;justify-content:center;padding:.6rem .9rem;border-radius:12px;'
      + 'background:#1b2246;color:#f1f3f7;border:1px solid #50c8ef;box-shadow:0 6px 24px rgba(0,0,0,.45);'
      + 'font:15px/1.4 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;max-width:calc(100vw - 2rem)';
    const text = document.createElement('span');
    text.textContent = busy() ? 'A new version of LF2 Online is ready: update when this game is over.'
      : 'A new version of LF2 Online is ready.';
    const now = document.createElement('button');
    now.type = 'button';
    now.textContent = 'Update now';
    now.style.cssText = 'font:inherit;font-weight:600;padding:.35rem .9rem;border-radius:999px;border:0;'
      + 'background:#50c8ef;color:#062231;cursor:pointer';
    now.addEventListener('click', () => {
      now.disabled = true;
      if (worker && worker.state === 'installed') worker.postMessage('skip-waiting');
      else location.reload();
    });
    const later = document.createElement('button');
    later.type = 'button';
    later.textContent = 'Later';
    later.style.cssText = 'font:inherit;padding:.35rem .9rem;border-radius:999px;border:1px solid #2c356b;'
      + 'background:transparent;color:#f1f3f7;cursor:pointer';
    later.addEventListener('click', () => bar.remove());
    bar.append(text, now, later);
    document.body.appendChild(bar);
  }

  function waiting(registration) {
    const worker = registration.waiting;
    if (!worker || !controlled) return;
    if (!busy() && !touched) worker.postMessage('skip-waiting');
    else banner(worker);
  }

  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js', { updateViaCache: 'none' }).then((registration) => {
      waiting(registration);
      registration.addEventListener('updatefound', () => {
        const worker = registration.installing;
        if (!worker) return;
        worker.addEventListener('statechange', () => {
          if (worker.state === 'installed') waiting(registration);
        });
      });
      // An app left open looks for a new version every hour.
      setInterval(() => registration.update().catch(() => {}), 60 * 60 * 1000);
    }).catch(() => {});
  });
})();
