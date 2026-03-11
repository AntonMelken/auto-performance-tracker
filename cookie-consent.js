/**
 * Cookie-Einwilligungsbanner – Auto Performance Tracker
 * Rechtsgrundlage: TDDDG §25, DSGVO Art. 6 Abs. 1 lit. a
 * Stand: März 2026
 *
 * Kategorien:
 *  - notwendig:   localStorage (Sprachauswahl) – §25 Abs. 2 Nr. 2 TDDDG, keine Einwilligung nötig
 *  - funktional:  (reserviert – derzeit nicht genutzt)
 *  - analyse:     (reserviert – PostHog opt-in bereits in App; Website aktuell ohne Analytics)
 *
 * Speicherort der Einwilligungsentscheidung: localStorage["apt_cookie_consent"]
 */

(function () {
  'use strict';

  const STORAGE_KEY = 'apt_cookie_consent';
  const EXPIRY_DAYS = 365;

  /* ── Gespeicherte Einwilligung lesen ────────────────────────── */
  function getConsent() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const data = JSON.parse(raw);
      if (!data.timestamp) return null;
      const age = Date.now() - data.timestamp;
      if (age > EXPIRY_DAYS * 86400000) { localStorage.removeItem(STORAGE_KEY); return null; }
      return data;
    } catch { return null; }
  }

  /* ── Einwilligung speichern ─────────────────────────────────── */
  function saveConsent(necessary, functional, analytics) {
    const data = {
      necessary: true,      // immer true – technisch notwendig
      functional: !!functional,
      analytics: !!analytics,
      timestamp: Date.now(),
      version: '1.0'
    };
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(data)); } catch {}
    return data;
  }

  /* ── Banner entfernen ───────────────────────────────────────── */
  function removeBanner() {
    const el = document.getElementById('apt-cookie-banner');
    if (el) {
      el.style.opacity = '0';
      el.style.transform = 'translateY(24px)';
      setTimeout(() => el.remove(), 380);
    }
  }

  /* ── "Nur notwendige" Handler ───────────────────────────────── */
  function acceptNecessary() {
    saveConsent(true, false, false);
    removeBanner();
  }

  /* ── "Alle akzeptieren" Handler ─────────────────────────────── */
  function acceptAll() {
    saveConsent(true, true, true);
    removeBanner();
  }

  /* ── Detail-Panel umschalten ────────────────────────────────── */
  function toggleDetails() {
    const panel = document.getElementById('apt-cookie-details');
    const btn   = document.getElementById('apt-cookie-details-btn');
    if (!panel || !btn) return;
    const open = panel.style.display === 'block';
    panel.style.display = open ? 'none' : 'block';
    btn.textContent = open ? 'Einstellungen anzeigen ▾' : 'Einstellungen ausblenden ▴';
  }

  /* ── "Auswahl speichern" Handler ────────────────────────────── */
  function saveSelection() {
    const fn = document.getElementById('apt-toggle-functional');
    const an = document.getElementById('apt-toggle-analytics');
    saveConsent(true, fn && fn.checked, an && an.checked);
    removeBanner();
  }

  /* ── CSS ────────────────────────────────────────────────────── */
  const CSS = `
    #apt-cookie-banner *{box-sizing:border-box;margin:0;padding:0}
    #apt-cookie-banner{
      position:fixed;bottom:24px;left:50%;transform:translateX(-50%) translateY(0);
      z-index:99999;
      width:min(680px,calc(100vw - 32px));
      background:#111827;
      border:1px solid rgba(34,211,238,0.18);
      border-radius:18px;
      padding:26px 28px 22px;
      box-shadow:0 8px 48px rgba(0,0,0,0.7),0 0 0 1px rgba(34,211,238,0.06);
      font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue','Segoe UI',sans-serif;
      font-size:14px;line-height:1.6;color:#94A3B8;
      transition:opacity .38s ease,transform .38s ease;
    }
    #apt-cookie-banner .apt-header{
      display:flex;align-items:flex-start;gap:14px;margin-bottom:14px;
    }
    #apt-cookie-banner .apt-icon{
      font-size:26px;flex-shrink:0;line-height:1;padding-top:2px;
    }
    #apt-cookie-banner .apt-title{
      font-size:16px;font-weight:700;color:#F1F5F9;margin-bottom:4px;
    }
    #apt-cookie-banner .apt-text a{color:#22D3EE;text-decoration:none}
    #apt-cookie-banner .apt-text a:hover{text-decoration:underline}
    #apt-cookie-banner .apt-badge{
      display:inline-flex;align-items:center;gap:5px;
      background:rgba(34,211,238,0.08);border:1px solid rgba(34,211,238,0.2);
      border-radius:50px;padding:3px 10px;
      font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
      color:#22D3EE;margin-bottom:12px;
    }

    /* buttons row */
    #apt-cookie-banner .apt-actions{
      display:flex;flex-wrap:wrap;gap:8px;margin-top:16px;align-items:center;
    }
    #apt-cookie-banner .apt-btn{
      border:none;cursor:pointer;border-radius:50px;
      font-family:inherit;font-size:13px;font-weight:600;
      padding:9px 22px;transition:all .18s;
    }
    #apt-cookie-banner .apt-btn-primary{
      background:linear-gradient(135deg,#22D3EE,#06B6D4);color:#000;
    }
    #apt-cookie-banner .apt-btn-primary:hover{
      background:linear-gradient(135deg,#67E8F9,#22D3EE);
      box-shadow:0 0 18px rgba(34,211,238,0.35);
    }
    #apt-cookie-banner .apt-btn-secondary{
      background:rgba(255,255,255,0.06);
      border:1px solid rgba(255,255,255,0.12);color:#CBD5E1;
    }
    #apt-cookie-banner .apt-btn-secondary:hover{
      background:rgba(255,255,255,0.1);color:#F1F5F9;
    }
    #apt-cookie-banner .apt-btn-ghost{
      background:transparent;color:#64748B;font-size:12px;padding:9px 10px;
    }
    #apt-cookie-banner .apt-btn-ghost:hover{color:#94A3B8}

    /* detail panel */
    #apt-cookie-details{
      display:none;border-top:1px solid rgba(255,255,255,0.07);
      margin-top:16px;padding-top:16px;
    }
    #apt-cookie-details .apt-cat{
      background:rgba(255,255,255,0.03);
      border:1px solid rgba(255,255,255,0.06);
      border-radius:12px;padding:14px 16px;margin-bottom:10px;
    }
    #apt-cookie-details .apt-cat-row{
      display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;
    }
    #apt-cookie-details .apt-cat-name{
      font-size:13px;font-weight:600;color:#F1F5F9;
    }
    #apt-cookie-details .apt-cat-desc{font-size:12px;color:#64748B}

    /* toggle switch */
    #apt-cookie-banner .apt-toggle{position:relative;display:inline-block;width:38px;height:22px;flex-shrink:0}
    #apt-cookie-banner .apt-toggle input{opacity:0;width:0;height:0}
    #apt-cookie-banner .apt-slider{
      position:absolute;inset:0;cursor:pointer;background:#1E293B;
      border:1px solid rgba(255,255,255,0.1);border-radius:50px;
      transition:.2s;
    }
    #apt-cookie-banner .apt-slider:before{
      content:'';position:absolute;width:16px;height:16px;
      left:2px;bottom:2px;background:#475569;border-radius:50%;transition:.2s;
    }
    #apt-cookie-banner .apt-toggle input:checked + .apt-slider{background:#0E7490;border-color:#22D3EE}
    #apt-cookie-banner .apt-toggle input:checked + .apt-slider:before{transform:translateX(16px);background:#22D3EE}
    #apt-cookie-banner .apt-toggle input:disabled + .apt-slider{opacity:.5;cursor:not-allowed}

    #apt-cookie-banner .apt-save-row{
      display:flex;justify-content:flex-end;margin-top:12px;
    }

    @media(max-width:500px){
      #apt-cookie-banner{padding:20px 18px 18px;bottom:16px;}
      #apt-cookie-banner .apt-actions{flex-direction:column;}
      #apt-cookie-banner .apt-btn{width:100%;text-align:center;}
    }
  `;

  /* ── HTML ───────────────────────────────────────────────────── */
  function buildBanner() {
    const styleEl = document.createElement('style');
    styleEl.textContent = CSS;
    document.head.appendChild(styleEl);

    const div = document.createElement('div');
    div.id = 'apt-cookie-banner';
    div.setAttribute('role', 'dialog');
    div.setAttribute('aria-modal', 'true');
    div.setAttribute('aria-labelledby', 'apt-cookie-title');
    div.innerHTML = `
      <div class="apt-header">
        <div class="apt-icon">🍪</div>
        <div>
          <div class="apt-badge">🇩🇪 TDDDG §25 · DSGVO Art. 6</div>
          <div class="apt-title" id="apt-cookie-title">Cookies &amp; lokaler Speicher</div>
        </div>
      </div>

      <p class="apt-text">
        Diese Website verwendet ausschließlich <strong style="color:#F1F5F9">technisch notwendige</strong>
        Speicherzugriffe (localStorage) – für deine Sprachauswahl (DE/EN).
        Tracking-, Werbe- oder Analyse-Cookies werden auf dieser Website <em>nicht</em> eingesetzt.<br><br>
        Durch Klick auf <strong style="color:#F1F5F9">„Verstanden"</strong> bestätigst du die Kenntnisnahme.
        Mehr Informationen findest du in unserer
        <a href="datenschutz-website.html" target="_blank" rel="noopener">Datenschutzerklärung Website</a>.
      </p>

      <div class="apt-actions">
        <button class="apt-btn apt-btn-primary" id="apt-accept-all">Verstanden &amp; akzeptieren</button>
        <button class="apt-btn apt-btn-secondary" id="apt-accept-necessary">Nur notwendige</button>
        <button class="apt-btn apt-btn-ghost" id="apt-cookie-details-btn">Einstellungen anzeigen ▾</button>
      </div>

      <!-- Detail-Panel -->
      <div id="apt-cookie-details">
        <!-- Notwendig (immer aktiv) -->
        <div class="apt-cat">
          <div class="apt-cat-row">
            <span class="apt-cat-name">🔒 Technisch notwendig</span>
            <label class="apt-toggle">
              <input type="checkbox" checked disabled>
              <span class="apt-slider"></span>
            </label>
          </div>
          <div class="apt-cat-desc">
            localStorage: Sprachauswahl (DE/EN) – gesetzlich zugelassen gem. §25 Abs.&nbsp;2 Nr.&nbsp;2 TDDDG.
            Immer aktiv, kein Opt-out möglich.
          </div>
        </div>

        <!-- Funktional -->
        <div class="apt-cat">
          <div class="apt-cat-row">
            <span class="apt-cat-name">⚙️ Funktional</span>
            <label class="apt-toggle">
              <input type="checkbox" id="apt-toggle-functional">
              <span class="apt-slider"></span>
            </label>
          </div>
          <div class="apt-cat-desc">
            Optionale Komfort-Einstellungen (z.&nbsp;B. Scroll-Position, Präferenzen).
            Derzeit auf dieser Website <em>nicht eingesetzt</em>.
            Rechtsgrundlage: Art.&nbsp;6 Abs.&nbsp;1 lit.&nbsp;a DSGVO (Einwilligung).
          </div>
        </div>

        <!-- Analyse -->
        <div class="apt-cat">
          <div class="apt-cat-row">
            <span class="apt-cat-name">📊 Analyse &amp; Statistik</span>
            <label class="apt-toggle">
              <input type="checkbox" id="apt-toggle-analytics">
              <span class="apt-slider"></span>
            </label>
          </div>
          <div class="apt-cat-desc">
            Anonyme Nutzungsstatistiken zur Website-Verbesserung.
            Derzeit auf dieser Website <em>nicht eingesetzt</em>.
            Rechtsgrundlage: Art.&nbsp;6 Abs.&nbsp;1 lit.&nbsp;a DSGVO (Einwilligung).
          </div>
        </div>

        <div class="apt-save-row">
          <button class="apt-btn apt-btn-secondary" id="apt-save-selection">Auswahl speichern</button>
        </div>
      </div>
    `;

    document.body.appendChild(div);

    // animate in
    requestAnimationFrame(() => {
      div.style.opacity = '0';
      div.style.transform = 'translateX(-50%) translateY(20px)';
      requestAnimationFrame(() => {
        div.style.transition = 'opacity .4s ease, transform .4s ease';
        div.style.opacity = '1';
        div.style.transform = 'translateX(-50%) translateY(0)';
      });
    });

    document.getElementById('apt-accept-all').addEventListener('click', acceptAll);
    document.getElementById('apt-accept-necessary').addEventListener('click', acceptNecessary);
    document.getElementById('apt-cookie-details-btn').addEventListener('click', toggleDetails);
    document.getElementById('apt-save-selection').addEventListener('click', saveSelection);
  }

  /* ── Eintrittspunkt ─────────────────────────────────────────── */
  function init() {
    if (getConsent() !== null) return; // bereits entschieden
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', buildBanner);
    } else {
      buildBanner();
    }
  }

  /* ── Öffentliche API (optional) ─────────────────────────────── */
  window.APTCookieConsent = {
    getConsent,
    reset: function () {
      try { localStorage.removeItem(STORAGE_KEY); } catch {}
      buildBanner();
    }
  };

  init();
})();
