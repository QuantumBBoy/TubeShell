// TubeShell Shields
//
// Runs at document start, in the page world, before any YouTube code.
// It reproduces what Brave Shields injects on youtube.com / music.youtube.com
// (see the default Brave + uBlock Origin filter lists):
//
//   1. set        -> ytInitialPlayerResponse / playerResponse arrive without ad fields
//   2. json-prune -> JSON.parse, Response.json() and XHR JSON lose
//                    adPlacements / playerAds / adSlots and Shorts ad entries
//   3. fallback   -> if an ad still plays: mute it, jump to its end, press "Skip"
//   4. background -> Brave's MediaBackgroundingScript + brave-video-bg-play-update
//   5. cosmetic   -> hide ad slots and the "Get Premium" pop-ups
//
//   6. shorts    -> hide Shorts on m.youtube.com, open Shorts links as normal videos
//   7. sponsors  -> SponsorBlock: skip sponsor / self-promo / "subscribe" segments
//
// When YouTube changes something, this is the file to update.

(function () {
  'use strict';

  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
  if (window.__tubeShellInstalled) return;
  try {
    Object.defineProperty(window, '__tubeShellInstalled', { value: true });
  } catch (e) {
    return;
  }

  const isTopFrame = window === window.top;
  // A light tap of the iPhone's haptic engine (the app plays it).
  const haptic = function () {
    try {
      window.webkit.messageHandlers.tubeshell.postMessage({ type: 'haptic' });
    } catch (e) {}
  };

  // ---------------------------------------------------------------------------
  // 1 + 2. Remove ad data before the player sees it
  // ---------------------------------------------------------------------------

  // Same property list as the Brave / uBO rules for youtube.com.
  const AD_KEYS = ['adPlacements', 'playerAds', 'adSlots'];

  const stripAdKeys = function (target) {
    if (!target || typeof target !== 'object') return;
    for (const key of AD_KEYS) {
      if (Object.prototype.hasOwnProperty.call(target, key)) {
        delete target[key];
      }
    }
  };

  const isShortsAd = function (entry) {
    try {
      return Boolean(entry.command.reelWatchEndpoint.adClientParams.isAd);
    } catch (e) {
      return false;
    }
  };

  const pruneEntries = function (holder) {
    if (holder && Array.isArray(holder.entries)) {
      holder.entries = holder.entries.filter(function (entry) {
        return !isShortsAd(entry);
      });
    }
  };

  // Mutates in place and returns the same object.
  const prune = function (data) {
    if (!data || typeof data !== 'object') return data;
    const items = Array.isArray(data) ? data : [data];
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      stripAdKeys(item);
      stripAdKeys(item.playerResponse);
      pruneEntries(item);
      pruneEntries(item.reelWatchSequenceResponse);
    }
    return data;
  };

  const safePrune = function (data) {
    try {
      return prune(data);
    } catch (e) {
      return data;
    }
  };

  // set: trap the globals YouTube assigns its first player response to.
  for (const name of ['ytInitialPlayerResponse', 'playerResponse']) {
    try {
      let stored;
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get: function () {
          return stored;
        },
        set: function (value) {
          stored = safePrune(value);
        },
      });
    } catch (e) {}
  }

  // json-prune: every JSON.parse result is cleaned.
  try {
    JSON.parse = new Proxy(JSON.parse, {
      apply: function (target, thisArg, args) {
        return safePrune(Reflect.apply(target, thisArg, args));
      },
    });
  } catch (e) {}

  // json-prune-fetch-response: fetch(...).then(r => r.json()).
  try {
    Response.prototype.json = new Proxy(Response.prototype.json, {
      apply: function (target, thisArg, args) {
        return Reflect.apply(target, thisArg, args).then(safePrune);
      },
    });
  } catch (e) {}

  // json-prune-xhr-response: XHR with responseType = 'json'.
  try {
    const descriptor = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response');
    if (descriptor && descriptor.get) {
      const nativeGet = descriptor.get;
      Object.defineProperty(XMLHttpRequest.prototype, 'response', {
        configurable: true,
        enumerable: descriptor.enumerable,
        get: function () {
          const value = nativeGet.call(this);
          return this.responseType === 'json' ? safePrune(value) : value;
        },
      });
    }
  } catch (e) {}

  // ---------------------------------------------------------------------------
  // 3. Fallback: an ad slipped through anyway
  // ---------------------------------------------------------------------------

  let mutedForAd = null;

  const handleAds = function () {
    const player = document.querySelector('.html5-video-player');
    const video = player ? player.querySelector('video') : null;
    const adShowing = Boolean(player && player.classList.contains('ad-showing'));

    if (adShowing && video) {
      const skip = player.querySelector(
        '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern'
      );
      if (skip) skip.click();
      if (!mutedForAd) {
        mutedForAd = { video: video, wasMuted: video.muted };
        video.muted = true;
      }
      // Only jump to the end of short, separate ad videos. If the ad is stitched
      // into the song or video itself, the duration is long and jumping to the
      // end would skip the real content too, so then the ad just plays muted.
      const isSeparateAd = isFinite(video.duration) && video.duration > 0 && video.duration < 90;
      if (isSeparateAd && video.currentTime < video.duration - 0.2) {
        try {
          video.currentTime = video.duration;
        } catch (e) {}
      }
    } else if (mutedForAd) {
      // The ad is over: give the real video its sound back.
      mutedForAd.video.muted = mutedForAd.wasMuted;
      mutedForAd = null;
    }
  };

  // Poll only while something plays: an ad is a playing video, so media events wake the
  // timer and it stops itself after ~6 s with nothing playing (no wakeups when idle,
  // paused, or on pages without video).
  let adTimer = 0;
  let idleTicks = 0;
  const adTick = function () {
    handleAds();
    const playing = Array.prototype.some.call(document.querySelectorAll('video, audio'), function (m) {
      return !m.paused && !m.ended;
    });
    idleTicks = playing ? 0 : idleTicks + 1;
    if (idleTicks >= 20) {
      clearInterval(adTimer);
      adTimer = 0;
    }
  };
  const wakeAdTimer = function () {
    idleTicks = 0;
    if (!adTimer) {
      adTimer = setInterval(adTick, 300);
      handleAds();
    }
  };
  for (const type of ['play', 'playing', 'loadstart']) {
    document.addEventListener(type, wakeAdTimer, true);
  }

  // Speed and quality chosen in the app's menu (stored per site in localStorage).
  // m.youtube.com's Auto picks 360p in the small portrait player even on fast wifi, which
  // looks soft on a 3x screen, so the default is 720p. Applied once per video (a quality
  // picked by hand later in the same video is left alone); the player falls back to the
  // best it has.
  const pref = function (key, fallback) {
    try {
      return localStorage.getItem(key) || fallback;
    } catch (e) {
      return fallback;
    }
  };
  const applySpeed = function (media) {
    const rate = Number(pref('tubeShellSpeed', '1')) || 1;
    if (media.playbackRate !== rate) media.playbackRate = rate;
  };
  // Data saver: on mobile data (or iOS Low Data Mode, told by the app) videos are capped
  // at 480p; on wifi the chosen quality applies. On by default, switchable in the menu.
  const QUALITY_ORDER = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'highres'];
  const SAVER_QUALITY = 'large';
  const applyQuality = function (player) {
    let quality = pref('tubeShellQuality', 'hd720');
    try {
      // "max": the best this video has (up to 2160p60 HDR on an iPhone 15 Pro).
      if (quality === 'max') quality = (player.getAvailableQualityLevels() || [])[0] || 'hd1080';
      const saving = window.__tubeShellCellular && pref('tubeShellSaver', 'on') === 'on';
      if (saving && (quality === 'auto' || QUALITY_ORDER.indexOf(quality) > QUALITY_ORDER.indexOf(SAVER_QUALITY))) {
        quality = SAVER_QUALITY;
      }
      if (quality === 'auto') player.setPlaybackQualityRange('auto');
      else player.setPlaybackQualityRange(quality, quality);
    } catch (e) {}
  };
  if (isTopFrame) {
    document.addEventListener(
      'playing',
      function (event) {
        const media = event.target;
        if (media instanceof HTMLMediaElement && !media.closest('.ad-showing')) applySpeed(media);
      },
      true
    );
  }
  if (isTopFrame && location.hostname === 'm.youtube.com') {
    let qualityFor = null;
    document.addEventListener(
      'playing',
      function (event) {
        const media = event.target;
        const id = new URLSearchParams(location.search).get('v');
        if (!(media instanceof HTMLVideoElement) || !id || id === qualityFor) return;
        const player = media.closest('.html5-video-player');
        if (!player || player.classList.contains('ad-showing') || !player.setPlaybackQualityRange) return;
        qualityFor = id;
        applyQuality(player);
      },
      true
    );
  }

  // ---------------------------------------------------------------------------
  // 4. Background playback (ported from Brave for iOS)
  // ---------------------------------------------------------------------------

  const visibilityDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
  const realVisibility = function () {
    try {
      return visibilityDescriptor.get.call(document);
    } catch (e) {
      return 'visible';
    }
  };

  // The page always believes it is visible, so YouTube never pauses itself.
  try {
    Object.defineProperty(Document.prototype, 'visibilityState', {
      configurable: true,
      enumerable: true,
      get: function () {
        return 'visible';
      },
    });
    Object.defineProperty(Document.prototype, 'hidden', {
      configurable: true,
      enumerable: true,
      get: function () {
        return false;
      },
    });
  } catch (e) {}

  // Remember pauses requested by page code (a tap on pause, lock screen controls
  // routed through YouTube's MediaSession handlers). Those must be respected.
  const pausedByPage = new WeakMap();
  const nativePause = HTMLMediaElement.prototype.pause;
  const nativePlay = HTMLMediaElement.prototype.play;

  HTMLMediaElement.prototype.pause = function () {
    pausedByPage.set(this, true);
    return nativePause.call(this);
  };
  HTMLMediaElement.prototype.play = function () {
    pausedByPage.set(this, false);
    return nativePlay.apply(this, arguments);
  };

  const resume = function (media) {
    if (media.paused && !media.ended && !pausedByPage.get(media)) {
      const result = nativePlay.call(media);
      if (result && typeof result.catch === 'function') result.catch(function () {});
    }
  };

  let lastVisibility = realVisibility();
  document.addEventListener(
    'visibilitychange',
    function () {
      lastVisibility = realVisibility();
    },
    true
  );

  // A pause nobody asked for, right as the app goes to the background, is WebKit
  // suspending the media: play it again (same logic as Brave's script).
  document.addEventListener(
    'pause',
    function (event) {
      const media = event.target;
      if (!(media instanceof HTMLMediaElement) || pausedByPage.get(media) || media.ended) return;

      if (realVisibility() === 'visible') {
        const onHidden = function () {
          document.removeEventListener('visibilitychange', onHidden, true);
          if (realVisibility() !== 'visible') resume(media);
        };
        document.addEventListener('visibilitychange', onHidden, true);
        setTimeout(function () {
          document.removeEventListener('visibilitychange', onHidden, true);
        }, 2000);
      } else if (lastVisibility === 'visible') {
        resume(media);
      }
    },
    true
  );

  // Keep YouTube's "last activity" timestamp fresh (avoids "Are you still there?").
  setInterval(function () {
    try {
      if ('_lact' in window) window._lact = Date.now();
    } catch (e) {}
  }, 5 * 60 * 1000);

  // Tell the app a video or song started with sound, so it can pause the other tab.
  // Muted previews (feed, Shorts thumbnails) are ignored: they must not stop the music.
  if (isTopFrame) {
    document.addEventListener(
      'play',
      function (event) {
        const media = event.target;
        if (!(media instanceof HTMLMediaElement) || media.muted || media.volume === 0) return;
        try {
          window.webkit.messageHandlers.tubeshell.postMessage({ type: 'play' });
        } catch (e) {}
      },
      true
    );
  }

  // YouTube Music edge to edge (iOS 26+, flag set by the app). Its web app is not built
  // for it, so: viewport-fit=cover, then move its bars clear of the island and the home
  // indicator. Relies on Music's own element names; revisit when Music changes layout.
  if (isTopFrame && location.hostname === 'music.youtube.com' && window.__tubeShellEdgeToEdge) {
    // m.youtube.com already asks for viewport-fit=cover; Music does not.
    const coverViewport = function () {
      const meta = document.querySelector('meta[name="viewport"]');
      if (meta && !/viewport-fit/.test(meta.content)) meta.content += ', viewport-fit=cover';
      return Boolean(meta);
    };
    if (!coverViewport()) document.addEventListener('DOMContentLoaded', coverViewport, { once: true });

    const TOP = 'env(safe-area-inset-top)';
    const BOTTOM = 'env(safe-area-inset-bottom)';
    // Bottom bars sit lower than the full home-indicator inset, like the native apps.
    const LIFT = 'calc(env(safe-area-inset-bottom) - 28px)';
    const edgeCss = [
      // Top bar: Music sizes the bar, its background and the page offset from this
      // variable. Normally the bar is hidden (section 8) and only the island's height
      // is left; while searching it comes back below the island.
      'ytmusic-app, ytmusic-app-layout { --ytmusic-nav-bar-height: ' + TOP + ' !important; }',
      // While searching the bar comes back over the page (which does not move), with a
      // solid backdrop from the top edge.
      'ytmusic-nav-bar { padding-top: ' + TOP + ' !important; box-sizing: border-box !important;' +
        ' height: calc(64px + ' + TOP + ') !important; }',
      // Music's open search box (~58 pt) is taller than the 64 pt bar's content area.
      'html.tubeshell-header ytmusic-nav-bar { background: #030303 !important;' +
        ' height: calc(80px + ' + TOP + ') !important; }',
      'html.tubeshell-header #nav-bar-background { visibility: hidden !important; }',
      'html:not(.tubeshell-header) :is(ytmusic-nav-bar, #nav-bar-divider) { visibility: hidden !important; }',
      // Mini player (ytmusic-miniplayer, or ytmusic-player-bar on older builds) and the
      // small artwork (ytmusic-player, 8 px off the edge) sit just above the home
      // indicator; their background is frosted glass down to the edge.
      'ytmusic-app-layout[player-visible]:not([player-page-open]) :is(ytmusic-miniplayer, ytmusic-player-bar)' +
        ' { bottom: ' + LIFT + ' !important; background: transparent !important; }',
      'ytmusic-app-layout[player-visible]:not([player-page-open]) ytmusic-player#player' +
        ' { bottom: calc(8px + ' + LIFT + ') !important; }',
      'ytmusic-app-layout[player-visible]:not([player-page-open]) #player-bar-background' +
        ' { bottom: 0 !important; height: calc(64px + ' + LIFT + ') !important;' +
        ' background-color: rgba(33, 33, 33, 0.6) !important;' +
        ' -webkit-backdrop-filter: blur(24px) saturate(180%); backdrop-filter: blur(24px) saturate(180%); }',
      // Full player and side menu: keep their contents off both strips.
      'ytmusic-player-page, #guide-wrapper { padding-top: ' + TOP + ' !important;' +
        ' padding-bottom: ' + BOTTOM + ' !important; box-sizing: border-box !important; }',
    ].join('\n');
    const addEdgeStyle = function () {
      const style = document.createElement('style');
      style.textContent = edgeCss;
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) addEdgeStyle();
    else document.addEventListener('DOMContentLoaded', addEdgeStyle, { once: true });
  }

  // Remember the second the song or video is at (the app stores it), and on reopening
  // jump back to it once (the hold below keeps it paused).
  if (isTopFrame) {
    const resumeAt = window.__tubeShellResumeAt;
    let resumed = false;
    let lastReport = 0;
    const track = function (event) {
      const media = event.target;
      if (!(media instanceof HTMLMediaElement) || media.closest('.ad-showing')) return;
      const id = new URLSearchParams(location.search).get('v');
      if (!id || !isFinite(media.duration)) return;

      if (resumeAt && !resumed && resumeAt.v === id) {
        resumed = true;
        if (resumeAt.t > 5 && resumeAt.t < media.duration - 5 && media.currentTime < resumeAt.t - 2) {
          media.currentTime = resumeAt.t;
        }
        return;
      }
      const now = Date.now();
      if (event.type !== 'pause' && now - lastReport < 5000) return;
      lastReport = now;
      try {
        window.webkit.messageHandlers.tubeshell.postMessage({
          type: 'position',
          v: id,
          t: Math.floor(media.currentTime),
        });
      } catch (e) {}
    };
    for (const type of ['loadedmetadata', 'timeupdate', 'pause']) {
      document.addEventListener(type, track, true);
    }
  }

  // Reopening the app restores the last song or video: it must wait paused.
  // A new web view starts with empty sessionStorage; until the first tap (or for
  // 15 s, so lock screen controls still work) anything that starts is paused.
  if (isTopFrame) {
    let holdUntil = 0;
    try {
      if (!sessionStorage.getItem('tubeShellStarted')) {
        sessionStorage.setItem('tubeShellStarted', '1');
        // A video tapped in the list plays at once.
        if (!window.__tubeShellAutoplay) holdUntil = Date.now() + 15000;
      }
    } catch (e) {}
    if (holdUntil) {
      document.addEventListener(
        'touchstart',
        function () {
          holdUntil = 0;
        },
        { capture: true, once: true }
      );
      document.addEventListener(
        'playing',
        function (event) {
          if (Date.now() < holdUntil && !window.__tubeShellPlayRequested && event.target instanceof HTMLMediaElement) {
            event.target.pause();
          }
        },
        true
      );
    }
  }

  // Sleep timer "at the end of the song": the app sets the flag, we pause just
  // before the track ends. YouTube Music still loads and starts the next track,
  // so anything that starts playing in the next few seconds is paused too.
  if (isTopFrame) {
    let sleepingUntil = 0;
    document.addEventListener(
      'playing',
      function (event) {
        if (Date.now() < sleepingUntil && event.target instanceof HTMLMediaElement) event.target.pause();
      },
      true
    );
    document.addEventListener(
      'timeupdate',
      function (event) {
        const media = event.target;
        if (!window.__tubeShellSleepAtEnd || !(media instanceof HTMLMediaElement)) return;
        if (!isFinite(media.duration) || media.currentTime < media.duration - 0.6) return;
        if (media.closest('.ad-showing')) return;
        window.__tubeShellSleepAtEnd = false;
        sleepingUntil = Date.now() + 10000;
        media.pause();
        try {
          window.webkit.messageHandlers.tubeshell.postMessage({ type: 'slept' });
        } catch (e) {}
      },
      true
    );
  }

  // Lock screen on YouTube Music: next / previous track instead of -10 s / +10 s.
  // iOS shows the skip-10 buttons whenever seek actions are available, so drop
  // YouTube's seek handlers and wire next / previous (and play / pause) if the
  // page did not.
  if (isTopFrame && location.hostname === 'music.youtube.com' && window.MediaSession) {
    const nativeSetActionHandler = MediaSession.prototype.setActionHandler;
    const pageActions = new Set();
    MediaSession.prototype.setActionHandler = function (action, handler) {
      if (action === 'seekforward' || action === 'seekbackward') handler = null;
      else if (handler) pageActions.add(action);
      return nativeSetActionHandler.call(this, action, handler);
    };

    const press = function (selector) {
      const button = document.querySelector(selector);
      if (button) button.click();
    };
    const currentMedia = function () {
      return document.querySelector('video, audio');
    };
    const fallbacks = {
      nexttrack: function () {
        press('.next-button');
      },
      previoustrack: function () {
        press('.previous-button');
      },
      play: function () {
        const media = currentMedia();
        if (media) media.play();
      },
      pause: function () {
        const media = currentMedia();
        if (media) media.pause();
      },
    };

    document.addEventListener(
      'play',
      function () {
        for (const action in fallbacks) {
          if (pageActions.has(action)) continue;
          try {
            nativeSetActionHandler.call(navigator.mediaSession, action, fallbacks[action]);
          } catch (e) {}
        }
        for (const action of ['seekforward', 'seekbackward']) {
          try {
            nativeSetActionHandler.call(navigator.mediaSession, action, null);
          } catch (e) {}
        }
      },
      true
    );
  }

  // ---------------------------------------------------------------------------
  // 5. Cosmetic: ad slots, Premium pop-ups, Picture in Picture
  // ---------------------------------------------------------------------------

  const css = [
    // m.youtube.com (rules from Brave's iOS list)
    'ytm-rich-item-renderer:has(> ad-slot-renderer)',
    'ytm-companion-slot[data-content-type] > ytm-companion-ad-renderer',
    'ytm-promoted-sparkles-web-renderer',
    'ytm-promoted-video-renderer',
    'ad-slot-renderer',
    // music.youtube.com
    'ytmusic-mealbar-promo-renderer',
    // "Get the app" / Premium banners on m.youtube.com
    'ytm-mealbar-promo-renderer',
    'ytm-app-promo-renderer',
    'ytm-upsell-dialog-renderer',
    // 6. Shorts on m.youtube.com: shelves, single entries and the bottom bar tab
    'ytm-reel-shelf-renderer',
    'ytm-shorts-lockup-view-model',
    'ytm-shorts-lockup-view-model-v2',
    'grid-shelf-view-model:has(ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2)',
    'ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2, ytm-reel-shelf-renderer)',
    'ytm-rich-item-renderer:has(a[href^="/shorts/"])',
    'ytm-video-with-context-renderer:has(a[href^="/shorts/"])',
    'ytm-pivot-bar-item-renderer:has(.pivot-shorts)',
  ].join(',\n') + ' { display: none !important; }';

  const addStyle = function () {
    const style = document.createElement('style');
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  };
  if (document.documentElement) {
    addStyle();
  } else {
    document.addEventListener('DOMContentLoaded', addStyle, { once: true });
  }

  // Brave hides these YouTube Music dialogs by their text (English and Spanish).
  const PROMO_TEXT =
    /premium|ad-free|without the ads|background play|kept playing|month free|family plan|try youtube music|sin anuncios|segundo plano|mes gratis|plan familiar|prueba youtube music/i;

  const OPEN_APP_TEXT = /^(open( the)? app|get the app|abrir( la)? app(licación)?|obtener la app|usar la app)$/i;

  const sweep = function () {
    let hidPromo = false;
    document.querySelectorAll('tp-yt-paper-dialog.ytmusic-popup-container').forEach(function (dialog) {
      if (dialog.style.display !== 'none' && PROMO_TEXT.test(dialog.textContent || '')) {
        dialog.style.setProperty('display', 'none', 'important');
        hidPromo = true;
      }
    });
    if (hidPromo) {
      // Remove the dark overlay left behind by the hidden dialog.
      document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach(function (backdrop) {
        backdrop.style.setProperty('display', 'none', 'important');
      });
    }

    // "Open App" entries (Music's side menu, YouTube's menus): useless inside the app.
    document
      .querySelectorAll(
        'ytmusic-guide-entry-renderer, ytm-compact-link-renderer, ytm-menu-service-item-renderer,' +
          ' ytmusic-nav-bar :is(yt-button-renderer, ytmusic-button-renderer, a.app-bar-button, button)'
      )
      .forEach(function (entry) {
        if (entry.style.display !== 'none' && OPEN_APP_TEXT.test((entry.textContent || '').trim())) {
          entry.style.setProperty('display', 'none', 'important');
        }
      });

    // "Are you still there?" on YouTube Music: answer yes.
    document
      .querySelectorAll('ytmusic-you-there-renderer button, ytmusic-you-there-renderer tp-yt-paper-button')
      .forEach(function (button) {
        button.click();
      });

    // A Shorts link (shared, or from a page we did not clean): open it as a normal video.
    // Last search (/results on YouTube, /search on Music): where "back" goes when there
    // is no page behind.
    if (isTopFrame && (location.pathname === '/results' || location.pathname === '/search')) {
      try {
        localStorage.setItem('tubeShellLastSearch', location.pathname + location.search);
      } catch (e) {}
    }

    const short = isTopFrame && location.pathname.match(/^\/shorts\/([\w-]{11})/);
    if (short) location.replace('/watch?v=' + short[1]);

    // m.youtube.com disables Picture in Picture on its videos.
    document.querySelectorAll('video[disablepictureinpicture]').forEach(function (video) {
      video.removeAttribute('disablepictureinpicture');
    });
  };

  let sweepScheduled = false;
  const scheduleSweep = function () {
    if (sweepScheduled) return;
    sweepScheduled = true;
    // setTimeout instead of requestAnimationFrame: it also runs in the background.
    setTimeout(function () {
      sweepScheduled = false;
      sweep();
    }, 250);
  };

  const startObserver = function () {
    // Text-only changes (clocks, progress labels) never need a sweep: only new elements.
    new MutationObserver(function (records) {
      for (const record of records) {
        for (const node of record.addedNodes) {
          if (node.nodeType === 1) return scheduleSweep();
        }
      }
    }).observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
    scheduleSweep();
  };
  if (document.documentElement) {
    startObserver();
  } else {
    document.addEventListener('DOMContentLoaded', startObserver, { once: true });
  }

  // ---------------------------------------------------------------------------
  // 7. SponsorBlock (sponsor.ajay.app, community-submitted segments)
  // ---------------------------------------------------------------------------

  if (isTopFrame) {
    const SB_CATEGORIES =
      location.hostname === 'music.youtube.com'
        ? ['music_offtopic']
        : ['sponsor', 'selfpromo', 'interaction', 'music_offtopic'];
    const SB_NAMES = {
      sponsor: 'patrocinio',
      selfpromo: 'autopromoción',
      interaction: 'recordatorio de suscripción',
      music_offtopic: 'parte sin música',
    };

    let sbVideo = null; // video id the segments below belong to
    let sbSegments = [];

    // Only the first 4 hex characters of the id's hash leave the phone, so
    // SponsorBlock never learns which video is playing.
    const loadSegments = async function (id) {
      sbVideo = id;
      sbSegments = [];
      try {
        const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(id));
        const prefix = Array.from(new Uint8Array(digest).slice(0, 2), function (b) {
          return b.toString(16).padStart(2, '0');
        }).join('');
        const response = await fetch(
          'https://sponsor.ajay.app/api/skipSegments/' +
            prefix +
            '?categories=' +
            encodeURIComponent(JSON.stringify(SB_CATEGORIES))
        );
        if (!response.ok) return; // 404: no segments for any video with this prefix
        const videos = await response.json();
        const entry = videos.find(function (v) {
          return v.videoID === id;
        });
        if (entry && sbVideo === id) {
          sbSegments = entry.segments.filter(function (s) {
            return s.actionType === 'skip';
          });
        }
      } catch (e) {}
    };

    const toast = function (text) {
      const el = document.createElement('div');
      el.textContent = text;
      el.style.cssText =
        'position:fixed;left:50%;bottom:72px;transform:translateX(-50%);z-index:2147483647;' +
        'background:rgba(40,40,40,.92);color:#fff;font:500 14px -apple-system,sans-serif;' +
        'padding:8px 14px;border-radius:16px;pointer-events:none;white-space:nowrap;';
      (document.body || document.documentElement).appendChild(el);
      setTimeout(function () {
        el.remove();
      }, 2500);
    };

    document.addEventListener(
      'timeupdate',
      function (event) {
        const media = event.target;
        if (!(media instanceof HTMLVideoElement)) return;
        if (media.closest('.ad-showing')) return; // ad times are not the video's

        // Only on a watch page: elsewhere the playing video is a feed preview.
        const id = new URLSearchParams(location.search).get('v');
        if (!id) return;
        if (id !== sbVideo) {
          loadSegments(id);
          return;
        }

        const t = media.currentTime;
        for (const s of sbSegments) {
          const start = s.segment[0];
          const end = s.segment[1];
          if (end - start > 1 && t >= start && t < end - 0.5) {
            media.currentTime = end;
            toast('Saltado: ' + (SB_NAMES[s.category] || s.category));
            return;
          }
        }
      },
      true
    );
  }

  // ---------------------------------------------------------------------------
  // 8. No page headers: the app's island capsule runs these commands instead
  // ---------------------------------------------------------------------------
  // The header comes back (html.tubeshell-header) only while searching; the next
  // page change hides it again. All commands press the page's own buttons, so the
  // single-page app navigates without reloading (and the music keeps playing).

  if (isTopFrame) {
    const onMusic = location.hostname === 'music.youtube.com';
    const root = document.documentElement;

    // m.youtube.com: header, its backdrop, the page offset, the watch page player and the
    // sticky filter chips all assume a 48 px header. Edge to edge (iOS 26+, flag set by
    // the app) the page also clears the island: content scrolls under it, and only the
    // watch page player gets a black band behind it (a shadow, so an empty player
    // container elsewhere paints nothing). The bottom bar pads itself for the home
    // indicator (viewport-fit=cover); it is pulled lower, like the native app.
    const edge = Boolean(window.__tubeShellEdgeToEdge);
    const island = edge ? 'env(safe-area-inset-top)' : '0px';
    const headerCss = [
      'html:not(.tubeshell-header) :is(ytm-mobile-topbar-renderer#header-bar, .mobile-topbar-header-background)' +
        ' { visibility: hidden !important; }',
      'html:not(.tubeshell-header) ytm-app { padding-top: ' + island + ' !important; }',
      'html:not(.tubeshell-header) ytm-feed-filter-chip-bar-renderer { top: ' + island + ' !important;' +
        ' transition: transform 0.25s ease, opacity 0.25s ease; }',
      // Scrolling down slides the filter chips away; scrolling up brings them back.
      'html.tubeshell-chips-hidden ytm-feed-filter-chip-bar-renderer' +
        ' { transform: translateY(-120%) !important; opacity: 0 !important; pointer-events: none !important; }',
      'html:not(.tubeshell-header) #player-container-id.player-container' +
        ' { top: ' + island + ' !important; box-shadow: 0 calc(-1 * ' + island + ') 0 0 #000 !important; }',
    ]
      .concat(
        edge
          ? [
              // While searching the header comes back below the island, its backdrop
              // filling the island strip too; the page underneath does not move.
              'html.tubeshell-header ytm-mobile-topbar-renderer#header-bar { top: ' + island + ' !important; }',
              'html.tubeshell-header .mobile-topbar-header-background' +
                ' { top: 0 !important; height: calc(48px + ' + island + ') !important; background: #0f0f0f !important; }',
              'html.tubeshell-header ytm-app { padding-top: ' + island + ' !important; }',
              'html.tubeshell-header ytm-feed-filter-chip-bar-renderer { visibility: hidden !important; }',
              'ytm-pivot-bar-renderer { padding-bottom: calc(env(safe-area-inset-bottom) - 28px) !important; }',
              // Side drawer (compass button): its top clear of the island.
              '.ytmDrawerLayoutContainerDrawerLayout { padding-top: ' + island + ' !important; box-sizing: border-box !important; }',
            ]
          : []
      )
      .join('\n');
    if (!onMusic) {
      let lastY = 0;
      window.addEventListener(
        'scroll',
        function () {
          const y = window.scrollY;
          if (Math.abs(y - lastY) < 8) return;
          root.classList.toggle('tubeshell-chips-hidden', y > lastY && y > 80);
          lastY = y;
        },
        { passive: true }
      );
    }

    const addHeaderStyle = function () {
      const style = document.createElement('style');
      style.textContent = headerCss;
      (document.head || root).appendChild(style);
    };
    if (root) addHeaderStyle();
    else document.addEventListener('DOMContentLoaded', addHeaderStyle, { once: true });

    let headerTimer = 0;
    // Opening search only changes the #fragment; a new page changes path or query.
    const page = function () {
      return location.pathname + location.search;
    };
    // m.youtube.com marks the open search with a #fragment: closing it (back arrow)
    // drops the fragment, which hides the header too.
    const showHeaderUntilNavigation = function () {
      const shownAt = page();
      let searchWasOpen = false;
      root.classList.add('tubeshell-header');
      clearInterval(headerTimer);
      headerTimer = setInterval(function () {
        // Open search: a #fragment on m.youtube.com, [opened] on Music's search box.
        const searchOpen = onMusic
          ? Boolean(document.querySelector('ytmusic-search-box[opened]'))
          : Boolean(location.hash);
        if (searchOpen) searchWasOpen = true;
        const searchClosed = searchWasOpen && !searchOpen;
        if (page() === shownAt && !searchClosed) return;
        root.classList.remove('tubeshell-header');
        clearInterval(headerTimer);
      }, 500);
    };
    const press = function (selector) {
      const target = document.querySelector(selector);
      if (target) target.click();
      return Boolean(target);
    };

    window.__tubeShell = {
      // Music ignores a press on its search button while the bar is still hidden, so
      // press once the bar is shown, and again if the box did not open.
      search: function () {
        showHeaderUntilNavigation();
        const selector = onMusic
          ? 'ytmusic-search-box .search-button button, ytmusic-search-box .search-button'
          : 'button.topbar-button-search-button';
        if (!onMusic) return void press(selector);
        let tries = 0;
        const open = function () {
          if (document.querySelector('ytmusic-search-box[opened]') || tries++ > 4) return;
          press(selector);
          setTimeout(open, 250);
        };
        setTimeout(open, 80);
      },
      account: function () {
        if (onMusic) {
          press('ytmusic-settings-button button, ytmusic-settings-button, ytmusic-nav-bar #menu-button button, ytmusic-nav-bar a.sign-in-link');
        } else {
          // m.youtube.com keeps account and settings in the bottom bar's last tab ("You").
          // If its tab ignores a scripted click, open that page directly.
          const before = page();
          press('ytm-pivot-bar-item-renderer:last-of-type .pivot-bar-item-tab, ytm-pivot-bar-item-renderer:last-of-type');
          setTimeout(function () {
            if (page() === before) location.assign('/feed/you');
          }, 800);
        }
      },
      // Rotating the iPhone on a watch page: YouTube's own fullscreen player in
      // landscape, back to the page in portrait.
      fullscreen: function (on) {
        const current = document.fullscreenElement || document.webkitFullscreenElement;
        if (!on) {
          const exit = document.exitFullscreen || document.webkitExitFullscreen;
          if (current && exit) exit.call(document);
          return;
        }
        const video = document.querySelector('video');
        if (current || location.pathname !== '/watch' || !video) return;
        const box = document.getElementById('movie_player') || document.getElementById('player-container-id');
        const request = box && (box.requestFullscreen || box.webkitRequestFullscreen);
        const fallback = function () {
          if (video.webkitEnterFullscreen) video.webkitEnterFullscreen();
        };
        if (!request) return fallback();
        const result = request.call(box);
        if (result && result.catch) result.catch(fallback);
      },
      // Search from the app's own search screen. YouTube: open the results page.
      // Music: type into its own search box (no reload, so the music keeps playing).
      searchFor: function (query) {
        if (!onMusic) return void location.assign('/results?search_query=' + encodeURIComponent(query));
        showHeaderUntilNavigation();
        let tries = 0;
        const type = function () {
          const box = document.querySelector('ytmusic-search-box');
          const input = box && box.querySelector('input');
          if (!input) return void location.assign('/search?q=' + encodeURIComponent(query));
          if (!box.hasAttribute('opened') && tries++ < 5) {
            press('ytmusic-search-box .search-button button, ytmusic-search-box .search-button');
            return void setTimeout(type, 200);
          }
          input.focus();
          input.value = query;
          input.dispatchEvent(new Event('input', { bubbles: true }));
          for (const kind of ['keydown', 'keypress', 'keyup']) {
            input.dispatchEvent(new KeyboardEvent(kind, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true }));
          }
          input.blur();
        };
        setTimeout(type, 80);
      },
      // A video tapped in the list, opened in the app's player: YouTube does not always
      // start a freshly loaded page (or starts it muted), and right after starting it
      // swaps the video source (quality) and waits. For a few seconds, until the user
      // touches the page, every time the video can play it is played, with sound.
      startPlayback: function () {
        window.__tubeShellPlayRequested = true;
        const until = Date.now() + 10000;
        const play = function () {
          const video = document.querySelector('video');
          if (Date.now() > until || !video || !video.currentSrc || !video.paused || video.ended) return;
          const player = document.getElementById('movie_player');
          try {
            if (player && player.unMute) player.unMute();
          } catch (e) {}
          video.muted = false;
          const result = nativePlay.call(video);
          if (result && result.catch) result.catch(function () {});
        };
        const events = ['loadedmetadata', 'canplay'];
        const stop = function () {
          events.forEach(function (type) {
            document.removeEventListener(type, play, true);
          });
          document.removeEventListener('touchstart', stop, true);
        };
        events.forEach(function (type) {
          document.addEventListener(type, play, true);
        });
        document.addEventListener('touchstart', stop, true);
        setTimeout(stop, 10000);
        [0, 500, 1500, 3000].forEach(function (delay) {
          setTimeout(play, delay);
        });
      },
      // The app's floating mini player.
      // Back to full size, the player still holds the mini window's size: tell it the
      // page was resized once the web view has its full frame again.
      // The player also kept the mini window's offsets on the video element (it showed
      // lower down, over the list): those are cleared before each resize.
      mini: function (on) {
        root.classList.toggle('tubeshell-mini', on);
        if (on) return;
        window.scrollTo(0, 0);
        [50, 300, 800].forEach(function (delay) {
          setTimeout(function () {
            const box = document.getElementById('player-container-id');
            if (box) box.style.transform = box.style.opacity = box.style.transformOrigin = '';
            document.querySelectorAll('#player-container-id video').forEach(function (video) {
              video.style.top = video.style.left = '';
            });
            window.dispatchEvent(new Event('resize'));
          }, delay);
        });
      },
      // Back, also when there is nothing behind (the app reopened straight on this page):
      // then the last search, or the home page. On Music an open full player is first
      // folded down into the mini player, like its ⌄ button.
      back: function () {
        if (onMusic && document.querySelector('ytmusic-app-layout[player-page-open]')) {
          press('ytmusic-player-page #collapse-button button, ytmusic-player-page #collapse-button');
          return;
        }
        const before = location.href;
        history.back();
        setTimeout(function () {
          if (location.href !== before) return;
          const lastSearch = pref('tubeShellLastSearch', '');
          if (lastSearch && lastSearch !== location.pathname + location.search) location.assign(lastSearch);
          else window.__tubeShell.home();
        }, 400);
      },
      // Tapping the tab you are on in the app: back to the site's home page.
      home: function () {
        if (onMusic) {
          window.__tubeShell.go(0);
          return;
        }
        const before = page();
        press('ytm-pivot-bar-item-renderer:first-of-type .pivot-bar-item-tab, ytm-home-logo button');
        setTimeout(function () {
          if (page() === before && location.pathname !== '/') location.assign('/');
        }, 800);
      },
      // Playback speed and video quality from the app's menu, remembered per site.
      speed: function (rate) {
        try {
          localStorage.setItem('tubeShellSpeed', String(rate));
        } catch (e) {}
        document.querySelectorAll('video, audio').forEach(applySpeed);
      },
      quality: function (quality) {
        try {
          localStorage.setItem('tubeShellQuality', quality);
        } catch (e) {}
        const player = document.getElementById('movie_player');
        if (player && player.setPlaybackQualityRange) applyQuality(player);
      },
      // The app reports the connection (mobile data / Low Data Mode or not) and the
      // data saver switch; the video on screen follows at once.
      network: function (cellular) {
        window.__tubeShellCellular = cellular;
        const player = document.getElementById('movie_player');
        if (player && player.setPlaybackQualityRange && location.pathname === '/watch') applyQuality(player);
      },
      saver: function (on) {
        try {
          localStorage.setItem('tubeShellSaver', on ? 'on' : 'off');
        } catch (e) {}
        window.__tubeShell.network(window.__tubeShellCellular);
      },
      // Siri / Shortcuts "play my music": resume the song on screen, else the first
      // "Play all" on the page (Home's quick picks).
      play: function () {
        window.__tubeShellPlayRequested = true;
        const media = document.querySelector('video, audio');
        if (media && media.currentSrc) {
          media.play();
          return;
        }
        press('ytmusic-play-button-renderer, ytmusic-shelf-renderer button[aria-label], a[aria-label*="Play all"], a[aria-label*="Reproducir todo"]');
      },
      // Captions on or off for the video on screen.
      // Remembered: captions stay off on every video unless turned on here.
      subtitles: function () {
        const on = pref('tubeShellCaptions', 'off') !== 'on';
        try {
          localStorage.setItem('tubeShellCaptions', on ? 'on' : 'off');
        } catch (e) {}
        root.classList.toggle('tubeshell-captions', on);
        const player = document.getElementById('movie_player');
        if (!player) return;
        try {
          if (on) {
            player.loadModule('captions');
            player.setOption('captions', 'reload', true);
          } else {
            player.unloadModule('captions');
          }
        } catch (e) {
          if (typeof player.toggleSubtitles === 'function') player.toggleSubtitles();
        }
      },
      // Music's side menu: 0 home, 1 explore, 2 library.
      go: function (index) {
        const entry = document.querySelectorAll('ytmusic-guide-entry-renderer')[index];
        if (entry) (entry.querySelector('tp-yt-paper-item, a') || entry).click();
      },
      history: function () {
        press('ytmusic-nav-bar #history-link, ytmusic-nav-bar .history-button');
      },
    };
  }

  // ---------------------------------------------------------------------------
  // 9. Music player gestures: swipe the artwork for next / previous, tap it for lyrics
  // ---------------------------------------------------------------------------

  if (isTopFrame && location.hostname === 'music.youtube.com') {
    const lyricsCss =
      // Lyrics large and easy to read, like the native apps.
      'ytmusic-player-page ytmusic-description-shelf-renderer :is(.description, .non-expandable-description)' +
      ' { font-size: 24px !important; line-height: 1.45 !important; font-weight: 600 !important; }\n' +
      // Moves on the artwork are ours: sideways = next/previous, down = fold the player.
      'ytmusic-player-page ytmusic-player#player { touch-action: none !important; }';
    const addLyricsStyle = function () {
      const style = document.createElement('style');
      style.textContent = lyricsCss;
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) addLyricsStyle();
    else document.addEventListener('DOMContentLoaded', addLyricsStyle, { once: true });

    const artworkAt = function (target) {
      return target instanceof Element ? target.closest('ytmusic-player-page ytmusic-player#player') : null;
    };
    // Track the finger on every move: if iOS takes the gesture over for scrolling it
    // sends touchcancel instead of touchend, and the swipe is judged on the last move.
    let start = null;
    let last = null;
    document.addEventListener(
      'touchstart',
      function (event) {
        const touch = event.touches[0];
        start = event.touches.length === 1 && artworkAt(event.target) ? { x: touch.clientX, y: touch.clientY, t: Date.now() } : null;
        last = start;
      },
      { capture: true, passive: true }
    );
    document.addEventListener(
      'touchmove',
      function (event) {
        if (start) last = { x: event.touches[0].clientX, y: event.touches[0].clientY };
      },
      { capture: true, passive: true }
    );
    const finish = function (event) {
      if (!start) return;
      const end = event.changedTouches && event.changedTouches[0];
      const point = end ? { x: end.clientX, y: end.clientY } : last;
      const dx = point.x - start.x;
      const dy = point.y - start.y;
      const elapsed = Date.now() - start.t;
      start = null;
      if (elapsed < 1200 && Math.abs(dx) > 45 && Math.abs(dx) > 1.2 * Math.abs(dy)) {
        // The player's own API; a scripted click on Music's button is ignored at times.
        const player = document.getElementById('movie_player');
        const method = dx < 0 ? 'nextVideo' : 'previousVideo';
        haptic();
        if (player && typeof player[method] === 'function') {
          player[method]();
        } else {
          const button = document.querySelector(dx < 0 ? '.next-button button' : '.previous-button button');
          if (button) button.click();
        }
      } else if (event.type === 'touchend' && elapsed < 500 && Math.abs(dx) < 10 && Math.abs(dy) < 10) {
        // Second tab of the player page is the lyrics (labels change with the language).
        const tab = document.querySelectorAll('ytmusic-player-page tp-yt-paper-tab.tab-header')[1];
        if (tab) tab.click();
      }
    };
    document.addEventListener('touchend', finish, { capture: true, passive: true });
    document.addEventListener('touchcancel', finish, { capture: true, passive: true });

    // Drag the full player down (from the artwork or the space above it) to fold it into
    // the mini player, like the app: it follows the finger; past 120 pt it folds.
    const pageAt = function (target, y) {
      if (!(target instanceof Element) || !document.querySelector('ytmusic-app-layout[player-page-open]')) return null;
      const page = target.closest('ytmusic-player-page');
      if (!page || target.closest('#side-panel, ytmusic-player-controls, tp-yt-paper-slider, #progress-bar')) return null;
      return y < innerHeight * 0.6 ? page : null;
    };
    let fold = null;
    document.addEventListener(
      'touchstart',
      function (event) {
        const touch = event.touches[0];
        const page = event.touches.length === 1 ? pageAt(event.target, touch.clientY) : null;
        fold = page ? { page, x: touch.clientX, y: touch.clientY, dy: 0, active: false } : null;
      },
      { capture: true, passive: true }
    );
    document.addEventListener(
      'touchmove',
      function (event) {
        if (!fold) return;
        const dx = event.touches[0].clientX - fold.x;
        const dy = event.touches[0].clientY - fold.y;
        if (!fold.active) {
          if (dy > 12 && dy > 1.5 * Math.abs(dx)) fold.active = true;
          else if (Math.abs(dx) > 12 || dy < -12) return void (fold = null);
          else return;
        }
        fold.dy = Math.max(0, dy);
        fold.page.style.transition = 'none';
        fold.page.style.transform = 'translateY(' + fold.dy + 'px)';
      },
      { capture: true, passive: true }
    );
    const drop = function () {
      if (!fold) return;
      const { page, dy, active } = fold;
      fold = null;
      if (!active) return;
      page.style.transition = 'transform 0.2s ease';
      if (dy > 120) {
        page.style.transform = 'translateY(100vh)';
        setTimeout(function () {
          const collapse = document.querySelector('ytmusic-player-page #collapse-button button, ytmusic-player-page #collapse-button');
          if (collapse) collapse.click();
          haptic();
        }, 180);
        setTimeout(function () {
          page.style.transition = page.style.transform = '';
        }, 700);
      } else {
        page.style.transform = '';
      }
    };
    document.addEventListener('touchend', drop, { capture: true, passive: true });
    document.addEventListener('touchcancel', drop, { capture: true, passive: true });
  }

  // ---------------------------------------------------------------------------
  // 11. YouTube: captions off by default; drag the video down to go back
  // ---------------------------------------------------------------------------

  if (isTopFrame && location.hostname === 'm.youtube.com') {
    const root = document.documentElement;
    if (pref('tubeShellCaptions', 'off') === 'on') root.classList.add('tubeshell-captions');

    // Captions: hidden everywhere (feed previews included) unless turned on from the
    // app's menu; on the watch page the captions module is also unloaded.
    // Mini player mode (set by the app): the video fills the small floating page.
    const miniCss =
      'html.tubeshell-mini #player-container-id { position: fixed !important; top: 0 !important; left: 0 !important;' +
      ' width: 100vw !important; height: 100vh !important; z-index: 2147483647 !important; transform: none !important;' +
      ' opacity: 1 !important; box-shadow: none !important; background: #000 !important; padding: 0 !important; }\n' +
      'html.tubeshell-mini :is(#player-container-id #player, #movie_player, video.html5-main-video)' +
      ' { width: 100vw !important; height: 100vh !important; left: 0 !important; top: 0 !important; object-fit: contain !important; }\n';
    const captionCss = miniCss +
      'html:not(.tubeshell-captions) :is(.ytp-caption-window-container, .caption-window, .captions-text)' +
      ' { display: none !important; }\n' +
      // Vertical drags on the watch-page video are ours (drag down to go back).
      '#player-container-id { touch-action: pan-x !important; }';
    const addCaptionStyle = function () {
      const style = document.createElement('style');
      style.textContent = captionCss;
      (document.head || root).appendChild(style);
    };
    if (root) addCaptionStyle();
    else document.addEventListener('DOMContentLoaded', addCaptionStyle, { once: true });
    document.addEventListener(
      'playing',
      function () {
        if (pref('tubeShellCaptions', 'off') === 'on' || location.pathname !== '/watch') return;
        const player = document.getElementById('movie_player');
        try {
          if (player && player.unloadModule) player.unloadModule('captions');
        } catch (e) {}
      },
      true
    );

    // Drag the watch-page video down to go back, like the YouTube app. The player follows
    // the finger; past a third of its height it goes back, otherwise it springs back.
    const playerBox = function (target) {
      return location.pathname === '/watch' && !document.fullscreenElement && target instanceof Element
        ? target.closest('#player-container-id')
        : null;
    };
    let drag = null;
    document.addEventListener(
      'touchstart',
      function (event) {
        const box = event.touches.length === 1 ? playerBox(event.target) : null;
        drag = box ? { box, x: event.touches[0].clientX, y: event.touches[0].clientY, dy: 0, active: false } : null;
      },
      { capture: true, passive: true }
    );
    document.addEventListener(
      'touchmove',
      function (event) {
        if (!drag) return;
        const dx = event.touches[0].clientX - drag.x;
        const dy = event.touches[0].clientY - drag.y;
        if (!drag.active) {
          // Straight down or diagonally down towards the corner, like the app.
          if (dy > 12 && dy >= 0.5 * Math.abs(dx)) drag.active = true;
          else if (Math.abs(dx) > 12 || dy < -12) return void (drag = null);
          else return;
        }
        drag.dy = Math.max(0, dy);
        drag.box.style.transition = 'none';
        drag.box.style.transformOrigin = 'bottom right';
        drag.box.style.transform =
          'translate(' + Math.max(0, dx) + 'px, ' + drag.dy + 'px) scale(' + Math.max(0.45, 1 - drag.dy / 700) + ')';
        drag.box.style.opacity = String(1 - drag.dy / 900);
      },
      { capture: true, passive: true }
    );
    const release = function () {
      if (!drag) return;
      const { box, dy, active } = drag;
      drag = null;
      if (!active) return;
      box.style.transition = 'transform 0.2s ease, opacity 0.2s ease';
      if (dy > box.offsetHeight / 3) {
        // The app shrinks this whole page into a floating mini player and opens a second
        // YouTube page underneath (leaving the watch page would stop the video). Going
        // back is the left-edge swipe.
        box.style.transform = box.style.opacity = '';
        try {
          window.webkit.messageHandlers.tubeshell.postMessage({
            type: 'minimize',
          });
        } catch (e) {}
      } else {
        box.style.transform = box.style.opacity = '';
      }
    };
    document.addEventListener('touchend', release, { capture: true, passive: true });
    document.addEventListener('touchcancel', release, { capture: true, passive: true });
  }

  // ---------------------------------------------------------------------------
  // 12. Fullscreen: leave it when the iPhone is upright again, keep playing on exit
  // ---------------------------------------------------------------------------
  // While a video is fullscreen iOS does not tell the app about rotations, so the page
  // watches them itself. Leaving fullscreen (rotation, swipe down, button) pauses the
  // video on iOS; if it was playing a moment before, it is resumed.

  if (isTopFrame && location.hostname === 'm.youtube.com') {
    let lastPlaying = 0;
    document.addEventListener(
      'timeupdate',
      function (event) {
        if (event.target instanceof HTMLVideoElement && !event.target.paused) lastPlaying = Date.now();
      },
      true
    );
    const fullscreenElement = function () {
      return document.fullscreenElement || document.webkitFullscreenElement;
    };
    const nativeFullscreenVideo = function () {
      const video = document.querySelector('video');
      return video && video.webkitDisplayingFullscreen ? video : null;
    };
    const keepPlaying = function () {
      if (Date.now() - lastPlaying > 1500) return;
      [150, 600].forEach(function (delay) {
        setTimeout(function () {
          const video = document.querySelector('video');
          if (video && video.paused && !video.ended) {
            const result = nativePlay.call(video);
            if (result && result.catch) result.catch(function () {});
          }
        }, delay);
      });
    };
    const onExit = function () {
      if (!fullscreenElement() && !nativeFullscreenVideo()) keepPlaying();
    };
    document.addEventListener('fullscreenchange', onExit);
    document.addEventListener('webkitfullscreenchange', onExit);
    document.addEventListener('webkitendfullscreen', keepPlaying, true);

    const leaveIfUpright = function () {
      if (innerHeight <= innerWidth) return;
      const exit = document.exitFullscreen || document.webkitExitFullscreen;
      if (fullscreenElement() && exit) exit.call(document);
      const video = nativeFullscreenVideo();
      if (video && video.webkitExitFullscreen) video.webkitExitFullscreen();
    };
    window.addEventListener('resize', function () {
      setTimeout(leaveIfUpright, 250);
    });
    if (screen.orientation) screen.orientation.addEventListener('change', leaveIfUpright);
  }

  // ---------------------------------------------------------------------------
  // 13. YouTube list: tapped videos open in the app's player, over the list
  // ---------------------------------------------------------------------------
  // The list (home, search, channel) never leaves its page, so it is exactly where it
  // was under the mini player. Links inside the player page navigate normally.

  if (isTopFrame && location.hostname === 'm.youtube.com' && !window.__tubeShellPlayerPage) {
    window.addEventListener(
      'click',
      function (event) {
        const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
        if (!link) return;
        let url;
        try {
          url = new URL(link.getAttribute('href'), location.href);
        } catch (e) {
          return;
        }
        if (url.hostname !== location.hostname || url.pathname !== '/watch' || !url.searchParams.get('v')) return;
        try {
          window.webkit.messageHandlers.tubeshell.postMessage({ type: 'openVideo', url: url.href });
        } catch (e) {
          return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
      },
      true
    );
  }
})();
