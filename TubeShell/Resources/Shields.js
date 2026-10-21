// TubeShell Shields
//
// Runs at document start, in the page world, before any YouTube code.
// It reproduces what Brave Shields injects on youtube.com / music.youtube.com
// (see the default Brave + uBlock Origin filter lists) and adds the page side of the app:
//
//    1. ad data      -> ytInitialPlayerResponse / playerResponse arrive without ad fields;
//                       JSON.parse, Response.json() and XHR JSON lose adPlacements /
//                       playerAds / adSlots and Shorts ad entries
//    2. fallback     -> if an ad still plays: mute it, jump to its end, press "Skip"
//    3. speed and quality, with the data saver
//    4. background   -> Brave's MediaBackgroundingScript + brave-video-bg-play-update
//    5. app reports  -> a video or song started, its position, the pause on reopening,
//                       the sleep timer at the end of a song
//    6. lock screen  -> Music: next / previous instead of -10 s / +10 s
//    7. Music edge to edge (iOS 26+)
//    8. cosmetic     -> hide ad slots, Premium pop-ups and Shorts; Shorts links open as videos
//    9. SponsorBlock -> skip sponsor / self-promo / "subscribe" segments
//   10. page commands -> no page headers; the app's capsule runs window.__tubeShell.*
//   11. Music history -> the full player is not a page of its own
//   12. Music player gestures
//   13. YouTube      -> captions off, mini player mode, drag the video down to minimize
//   14. YouTube      -> fullscreen follows the iPhone's rotation
//   15. YouTube list -> tapped videos open in the app's player
//
// Frames other than the page itself (embeds, iframes) only get sections 1 and 2.
//
// When YouTube changes something, this is the file to update.

(function () {
  'use strict';

  if (!/^(m|music)\.youtube\.com$/.test(location.hostname)) return;
  if (window.__tubeShellInstalled) return;
  try {
    Object.defineProperty(window, '__tubeShellInstalled', { value: true });
  } catch (e) {
    return;
  }

  const isTopFrame = window === window.top;
  const isMusicHost = location.hostname === 'music.youtube.com';

  // Device language (set by the app): Spanish or English. Labels of the SponsorBlock
  // toast and of the Music gesture hints.
  const es = String(window.__tubeShellLang || navigator.language || '').toLowerCase().indexOf('es') === 0;
  const T = es
    ? {
        prev: 'Anterior', next: 'Siguiente', back: 'Atrás', lyrics: 'Toca: letra',
        skipped: 'Saltado',
        categories: {
          sponsor: 'patrocinio',
          selfpromo: 'autopromoción',
          interaction: 'recordatorio de suscripción',
          music_offtopic: 'parte sin música',
        },
      }
    : {
        prev: 'Previous', next: 'Next', back: 'Back', lyrics: 'Tap: lyrics',
        skipped: 'Skipped',
        categories: {
          sponsor: 'sponsor',
          selfpromo: 'self-promotion',
          interaction: 'subscribe reminder',
          music_offtopic: 'non-music part',
        },
      };

  // Windows after the page starts (ms).
  const LAUNCH_WINDOW_MS = 15000; // a page reopened by the app: paused, folded (sections 5, 12)
  const START_WINDOW_MS = 10000; // seeking back to the saved second; forcing a tapped video to play
  const SLEEP_WINDOW_MS = 10000; // after the sleep timer: what the next track starts is paused

  // State shared between sections. The app's commands (window.__tubeShell, section 10) set some.
  let holdUntil = 0; // reopened page: anything that starts is paused until then (section 5)
  let playRequested = false; // the app asked to play (tapped video, Siri): lifts that pause
  let sleepAtEnd = false; // sleep timer "at the end of the song" (sleepAtEnd command)
  let cellular = false; // mobile data / Low Data Mode (network command): data saver

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  // Tells the app something. False when the page has no message handler (not in the app).
  const post = function (message) {
    try {
      window.webkit.messageHandlers.tubeshell.postMessage(message);
      return true;
    } catch (e) {
      return false;
    }
  };
  // A light tap of the iPhone's haptic engine (the app plays it).
  const haptic = function () {
    post({ type: 'haptic' });
  };

  // Adds a stylesheet as soon as the document exists.
  const addCss = function (text, id) {
    const add = function () {
      const style = document.createElement('style');
      if (id) style.id = id;
      style.textContent = text;
      (document.head || document.documentElement).appendChild(style);
    };
    if (document.documentElement) add();
    else document.addEventListener('DOMContentLoaded', add, { once: true });
  };

  // Clicks the first element matching the selector; whether there was one.
  const press = function (selector) {
    const target = document.querySelector(selector);
    if (target) target.click();
    return Boolean(target);
  };

  // The current page, without the #fragment (opening m.youtube.com's search only changes that).
  const page = function () {
    return location.pathname + location.search;
  };

  // Settings kept per site in localStorage (speed, quality, captions, last search...).
  const pref = function (key, fallback) {
    try {
      return localStorage.getItem(key) || fallback;
    } catch (e) {
      return fallback;
    }
  };
  const setPref = function (key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (e) {}
  };

  // YouTube Music's full player (the page the artwork opens) is showing.
  const isMusicPlayerOpen = function () {
    return Boolean(document.querySelector('ytmusic-app-layout[player-page-open]'));
  };

  // Fold Music's full player into its mini player, as its ⌄ button does: the inner button
  // is the one that reacts; if the player is still open, try the button's host, then
  // Escape (which Music also handles).
  const foldMusicPlayer = function () {
    const attempts = [
      function () {
        press('ytmusic-player-page #collapse-button button');
      },
      function () {
        press('ytmusic-player-page #collapse-button');
      },
      function () {
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true }));
      },
    ];
    let i = 0;
    const next = function () {
      if (!isMusicPlayerOpen() || i >= attempts.length) return;
      attempts[i++]();
      setTimeout(next, 120);
    };
    next();
  };

  // ---------------------------------------------------------------------------
  // 1. Remove ad data before the player sees it
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
  // 2. Fallback: an ad slipped through anyway
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

  // Poll only while an ad shows: the player (YouTube and Music share the element) puts
  // `ad-showing` in its class list, so a MutationObserver on that attribute starts a
  // 300 ms poll that stops itself when the class goes. The player is found when media
  // starts loading (it can be replaced as the single-page app navigates).
  let adPlayer = null;
  let adTimer = 0;
  const adShowing = function () {
    return Boolean(adPlayer && adPlayer.classList.contains('ad-showing'));
  };
  const adTick = function () {
    handleAds();
    if (!adShowing()) {
      clearInterval(adTimer);
      adTimer = 0;
    }
  };
  const adClassChanged = function () {
    if (adShowing()) {
      if (!adTimer) {
        adTimer = setInterval(adTick, 300);
        handleAds();
      }
    } else if (mutedForAd) {
      handleAds(); // the ad is over: sound back
    }
  };
  const adObserver = new MutationObserver(adClassChanged);
  const watchAdPlayer = function () {
    const player = document.querySelector('.html5-video-player');
    if (player === adPlayer) return;
    adPlayer = player;
    adObserver.disconnect();
    if (player) adObserver.observe(player, { attributes: true, attributeFilter: ['class'] });
    adClassChanged();
  };
  for (const type of ['play', 'playing', 'loadstart']) {
    document.addEventListener(type, watchAdPlayer, true);
  }

  // The rest is for the page itself, not for embeds and other frames.
  if (!isTopFrame) return;

  // ---------------------------------------------------------------------------
  // 3. Speed and quality
  // ---------------------------------------------------------------------------

  // Speed and quality chosen in the app's menu (stored per site in localStorage).
  // m.youtube.com's Auto picks 360p in the small portrait player even on fast wifi, which
  // looks soft on a 3x screen, so the default is 720p. Applied once per video (a quality
  // picked by hand later in the same video is left alone); the player falls back to the
  // best it has.
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
      const saving = cellular && pref('tubeShellSaver', 'on') === 'on';
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

  // ---------------------------------------------------------------------------
  // 5. Reports to the app: a video starts, its position, the pause on reopening,
  //    the sleep timer
  // ---------------------------------------------------------------------------

  // Tell the app a video or song started with sound, so it can pause the other tab.
  // Muted previews (feed, Shorts thumbnails) are ignored: they must not stop the music,
  // but a muted video that gets its sound while playing counts as starting.
  if (isTopFrame) {
    const reportPlay = function (event) {
      const media = event.target;
      if (!(media instanceof HTMLMediaElement) || media.paused || media.muted || media.volume === 0) return;
      // A page reopened by the app starts by itself and is paused at once (the hold
      // below): that must not stop what is playing in the other tab.
      if (Date.now() < holdUntil && !playRequested) return;
      post({ type: 'play' });
    };
    for (const type of ['play', 'volumechange']) {
      document.addEventListener(type, reportPlay, true);
    }

    // Whether media is playing here, so the app can hide a covered web view that is not
    // (WebKit pauses media in a hidden one). Feed previews (muted, outside the player page
    // and Music) do not count. "Stopped" comes after a second of quiet, so the gap between
    // two songs is not reported.
    let reportedPlaying = false;
    let idleTimer = 0;
    const playingNow = function () {
      return Array.prototype.some.call(document.querySelectorAll('video, audio'), function (m) {
        return !m.paused && !m.ended && (!m.muted || isMusicHost || window.__tubeShellPlayerPage);
      });
    };
    const reportState = function () {
      clearTimeout(idleTimer);
      if (playingNow()) {
        if (!reportedPlaying) {
          reportedPlaying = true;
          post({ type: 'media', playing: true });
        }
        return;
      }
      idleTimer = setTimeout(function () {
        if (reportedPlaying && !playingNow()) {
          reportedPlaying = false;
          post({ type: 'media', playing: false });
        }
      }, 1000);
    };
    for (const type of ['play', 'playing', 'pause', 'ended', 'volumechange']) {
      document.addEventListener(type, reportState, true);
    }
  }

  // Remember the second the song or video is at (the app stores it), and on reopening
  // jump back to it once (the hold below keeps it paused).
  if (isTopFrame) {
    const resumeAt = window.__tubeShellResumeAt;
    let resumed = false;
    // Music resets the song to 0:00 while it sets itself up: keep putting it back for the
    // first seconds (until it sticks or the user touches the page), and do not save the
    // position meanwhile, or the 0:00 would overwrite the second to restore.
    const resumeUntil = Date.now() + START_WINDOW_MS;
    document.addEventListener(
      'touchstart',
      function () {
        resumed = true;
      },
      { capture: true, passive: true, once: true }
    );
    let lastReport = 0;
    // Saved every 30 s, on pause, and when the page is hidden or left (force).
    const track = function (media, force) {
      if (!(media instanceof HTMLMediaElement) || media.closest('.ad-showing')) return;
      // On Music the song keeps playing folded, under another page: ask the player.
      let id = new URLSearchParams(location.search).get('v');
      if (!id && location.hostname === 'music.youtube.com') {
        try {
          id = document.getElementById('movie_player').getVideoData().video_id;
        } catch (e) {}
      }
      if (!id || !isFinite(media.duration)) return;

      if (resumeAt && !resumed && resumeAt.v === id) {
        const wanted = resumeAt.t > 5 && resumeAt.t < media.duration - 5;
        if (!wanted || Date.now() > resumeUntil) {
          resumed = true;
        } else if (media.currentTime < resumeAt.t - 2) {
          media.currentTime = resumeAt.t;
          return;
        } else if (media.currentTime < resumeAt.t + 3) {
          return; // in place; confirm on a later event before saving again
        } else {
          resumed = true;
        }
      }
      const now = Date.now();
      if (!force && now - lastReport < 30000) return;
      lastReport = now;
      post({ type: 'position', v: id, t: Math.floor(media.currentTime) });
    };
    for (const type of ['loadedmetadata', 'timeupdate', 'pause']) {
      document.addEventListener(
        type,
        function (event) {
          track(event.target, event.type === 'pause');
        },
        true
      );
    }
    const saveNow = function () {
      track(document.querySelector('video, audio'), true);
    };
    window.addEventListener('pagehide', saveNow);
    document.addEventListener(
      'visibilitychange',
      function () {
        if (realVisibility() === 'hidden') saveNow();
      },
      true
    );
  }

  // Reopening the app restores the last song or video: it must wait paused.
  // A new web view starts with empty sessionStorage; until the first tap (or for
  // 15 s, so lock screen controls still work) anything that starts is paused.
  if (isTopFrame) {
    try {
      if (!sessionStorage.getItem('tubeShellStarted')) {
        sessionStorage.setItem('tubeShellStarted', '1');
        // A video tapped in the list plays at once.
        if (!window.__tubeShellAutoplay) holdUntil = Date.now() + LAUNCH_WINDOW_MS;
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
          if (Date.now() < holdUntil && !playRequested && event.target instanceof HTMLMediaElement) {
            event.target.pause();
          }
        },
        true
      );
    }
  }

  // Sleep timer "at the end of the song": the app sets the flag (sleepAtEnd command), we
  // pause just before the track ends. YouTube Music still loads and starts the next track,
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
        if (!sleepAtEnd || !(media instanceof HTMLMediaElement)) return;
        if (!isFinite(media.duration) || media.currentTime < media.duration - 0.6) return;
        if (media.closest('.ad-showing')) return;
        sleepAtEnd = false;
        sleepingUntil = Date.now() + SLEEP_WINDOW_MS;
        media.pause();
        post({ type: 'slept' });
      },
      true
    );
  }

  // ---------------------------------------------------------------------------
  // 6. Lock screen on YouTube Music: next / previous track instead of -10 s / +10 s
  // ---------------------------------------------------------------------------
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
  // 7. YouTube Music edge to edge
  // ---------------------------------------------------------------------------
  // iOS 26+, flag set by the app. Music's web app is not built for it, so: viewport-fit=cover,
  // then move its bars clear of the island and the home indicator. Relies on Music's own
  // element names; revisit when Music changes layout.
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
      // variable. Normally the bar is hidden (section 10) and only the island's height
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
    addCss(edgeCss);
  }

  // ---------------------------------------------------------------------------
  // 8. Cosmetic: ad slots, Premium pop-ups, Shorts, Picture in Picture
  // ---------------------------------------------------------------------------

  // Per host: m.youtube.com and music.youtube.com share no markup.
  const css = (isMusicHost
    ? [
        // music.youtube.com
        'ad-slot-renderer',
        'ytmusic-mealbar-promo-renderer',
      ]
    : [
        // m.youtube.com (rules from Brave's iOS list)
        'ytm-rich-item-renderer:has(> ad-slot-renderer)',
        'ytm-companion-slot[data-content-type] > ytm-companion-ad-renderer',
        'ytm-promoted-sparkles-web-renderer',
        'ytm-promoted-video-renderer',
        'ad-slot-renderer',
        // "Get the app" / Premium banners on m.youtube.com
        'ytm-mealbar-promo-renderer',
        'ytm-app-promo-renderer',
        'ytm-upsell-dialog-renderer',
        // Shorts on m.youtube.com: shelves, single entries and the bottom bar tab. The
        // containers that hold a Short are marked by the sweep (SHORT_MARK): :has() over
        // every feed entry is expensive.
        'ytm-reel-shelf-renderer',
        'ytm-shorts-lockup-view-model',
        'ytm-shorts-lockup-view-model-v2',
        '[data-tubeshell-short]',
        'ytm-pivot-bar-item-renderer:has(.pivot-shorts)',
      ]
  ).join(',\n') + ' { display: none !important; }';

  addCss(css);

  // Brave hides these YouTube Music dialogs by their text (English and Spanish), plus the
  // "Open in the YouTube Music app" modal.
  const PROMO_TEXT =
    /premium|ad-free|without the ads|background play|kept playing|month free|family plan|try youtube music|in the youtube music app|sin anuncios|segundo plano|mes gratis|plan familiar|prueba youtube music|abrir en la aplicaci[oó]n youtube music|en la app youtube music/i;
  const NOT_NOW_TEXT = /^(not now|no thanks|ahora no|no, gracias)$/i;

  const OPEN_APP_TEXT = /^(open( the)? app|get the app|abrir( la)? app(licación)?|obtener la app|usar la app)$/i;

  // "Open App" entries (Music's side menu, YouTube's menus): useless inside the app.
  const OPEN_APP_ENTRIES = isMusicHost
    ? 'ytmusic-guide-entry-renderer, ytmusic-nav-bar :is(yt-button-renderer, ytmusic-button-renderer, a.app-bar-button, button)'
    : 'ytm-compact-link-renderer, ytm-menu-service-item-renderer';

  // Marks what the stylesheet hides for Shorts (see the css above): the entry or section
  // that holds a Short.
  const SHORT_MARK = 'data-tubeshell-short';
  const markShorts = function (selector, container) {
    document.querySelectorAll(selector).forEach(function (el) {
      const box = el.closest(container);
      if (box && !box.hasAttribute(SHORT_MARK)) box.setAttribute(SHORT_MARK, '');
    });
  };

  let savedSearch = '';
  const sweep = function () {
    if (isMusicHost) {
      let hidPromo = false;
      document.querySelectorAll('tp-yt-paper-dialog').forEach(function (dialog) {
        if (dialog.style.display === 'none' || !PROMO_TEXT.test((dialog.textContent || '').replace(/\s+/g, ' '))) return;
        // Dismiss it the way the user would, then hide what is left (and the backdrop).
        const dismiss = Array.prototype.find.call(
          dialog.querySelectorAll('button, tp-yt-paper-button, yt-button-renderer, ytmusic-button-renderer, a'),
          function (b) {
            return NOT_NOW_TEXT.test((b.textContent || '').trim());
          }
        );
        dialog.style.setProperty('display', 'none', 'important');
        if (dismiss) dismiss.click();
        hidPromo = true;
      });
      if (hidPromo) {
        // Remove the dark overlay left behind by the hidden dialog.
        document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach(function (backdrop) {
          backdrop.style.setProperty('display', 'none', 'important');
        });
      }

      // "Are you still there?" on YouTube Music: answer yes.
      document
        .querySelectorAll('ytmusic-you-there-renderer button, ytmusic-you-there-renderer tp-yt-paper-button')
        .forEach(function (button) {
          button.click();
        });
    } else {
      markShorts('a[href^="/shorts/"]', 'ytm-rich-item-renderer, ytm-video-with-context-renderer');
      markShorts(
        'ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2, ytm-reel-shelf-renderer',
        'grid-shelf-view-model'
      );
      markShorts(
        'ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2, ytm-reel-shelf-renderer',
        'ytm-rich-section-renderer'
      );

      // A Shorts link (shared, or from a page we did not clean): open it as a normal video.
      const short = location.pathname.match(/^\/shorts\/([\w-]{11})/);
      if (short) location.replace('/watch?v=' + short[1]);
    }

    document.querySelectorAll(OPEN_APP_ENTRIES).forEach(function (entry) {
      if (entry.style.display !== 'none' && OPEN_APP_TEXT.test((entry.textContent || '').trim())) {
        entry.style.setProperty('display', 'none', 'important');
      }
    });

    // Last search (/results on YouTube, /search on Music): where "back" goes when there
    // is no page behind. Written only when it changed.
    if (location.pathname === '/results' || location.pathname === '/search') {
      const here = page();
      if (here !== savedSearch) {
        savedSearch = here;
        setPref('tubeShellLastSearch', here);
      }
    }

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
  // 9. SponsorBlock (sponsor.ajay.app, community-submitted segments)
  // ---------------------------------------------------------------------------

  if (isTopFrame) {
    const SB_CATEGORIES =
      location.hostname === 'music.youtube.com'
        ? ['music_offtopic']
        : ['sponsor', 'selfpromo', 'interaction', 'music_offtopic'];

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
            toast(T.skipped + ': ' + (T.categories[s.category] || s.category));
            return;
          }
        }
      },
      true
    );
  }

  // ---------------------------------------------------------------------------
  // 10. No page headers: the app's island capsule runs these commands instead
  // ---------------------------------------------------------------------------
  // On Music the header comes back (html.tubeshell-header) only while searching; the next
  // page change hides it again. (On m.youtube.com the search is the app's own screen.) All commands press the page's own buttons, so the
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
              'ytm-pivot-bar-renderer { padding-bottom: calc(env(safe-area-inset-bottom) - 28px) !important; }',
              // Side drawer (compass button): its top clear of the island.
              '.ytmDrawerLayoutContainerDrawerLayout { padding-top: ' + island + ' !important; box-sizing: border-box !important; }',
            ]
          : []
      )
      .join('\n');
    if (!onMusic) {
      let lastY = 0;
      let scrollQueued = false;
      // scrollY is read at most once per frame.
      window.addEventListener(
        'scroll',
        function () {
          if (scrollQueued) return;
          scrollQueued = true;
          requestAnimationFrame(function () {
            scrollQueued = false;
            const y = window.scrollY;
            if (Math.abs(y - lastY) < 8) return;
            root.classList.toggle('tubeshell-chips-hidden', y > lastY && y > 80);
            lastY = y;
          });
        },
        { passive: true }
      );
    }

    addCss(headerCss);

    let headerTimer = 0;
    // Music: shows the header until the page changes or its search box closes again
    // (at most 60 s).
    const showHeaderUntilNavigation = function () {
      const shownAt = page();
      const until = Date.now() + 60000;
      let searchWasOpen = false;
      root.classList.add('tubeshell-header');
      clearInterval(headerTimer);
      headerTimer = setInterval(function () {
        const searchOpen = Boolean(document.querySelector('ytmusic-search-box[opened]'));
        if (searchOpen) searchWasOpen = true;
        const searchClosed = searchWasOpen && !searchOpen;
        if (page() === shownAt && !searchClosed && Date.now() < until) return;
        root.classList.remove('tubeshell-header');
        clearInterval(headerTimer);
      }, 500);
    };

    window.__tubeShell = {
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
      // Music: type into its own search box (no reload, so the music keeps playing). Music
      // ignores a press on its search button while the bar is still hidden, so the header is
      // shown first and the button pressed again if the box did not open.
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
        playRequested = true;
        const until = Date.now() + START_WINDOW_MS;
        const play = function () {
          const video = document.querySelector('video');
          if (Date.now() > until || !video || !video.currentSrc || video.ended) return;
          // YouTube may already be playing it muted ("Tap to unmute"): give it sound too.
          const player = document.getElementById('movie_player');
          try {
            if (player && player.isMuted && player.isMuted() && player.unMute) player.unMute();
          } catch (e) {}
          if (video.muted) video.muted = false;
          if (!video.paused) return;
          const result = nativePlay.call(video);
          if (result && result.catch) result.catch(function () {});
        };
        const events = ['loadedmetadata', 'canplay', 'playing'];
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
        setTimeout(stop, START_WINDOW_MS);
        [0, 500, 1500, 3000].forEach(function (delay) {
          setTimeout(play, delay);
        });
      },
      // Opens a video in this page without reloading it: YouTube's own router follows a
      // link clicked inside ytm-app. False when the page cannot (the app then loads it).
      watch: function (href) {
        const app = document.querySelector('ytm-app');
        if (!app || typeof href !== 'string' || href.indexOf('/watch?') !== 0) return false;
        const link = document.createElement('a');
        link.href = href;
        link.hidden = true;
        app.appendChild(link);
        link.click();
        setTimeout(function () {
          link.remove();
        }, 1000);
        return true;
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
      // Back, called by the app only when the page has nothing behind it (reopened straight
      // on this page): the last search on YouTube, home otherwise. On Music an open full
      // player is first folded down into the mini player, like its ⌄ button.
      back: function () {
        if (isMusicPlayerOpen()) return void foldMusicPlayer();
        const lastSearch = onMusic ? '' : pref('tubeShellLastSearch', '');
        if (lastSearch && lastSearch !== page()) location.assign(lastSearch);
        else window.__tubeShell.home();
      },
      // Tapping the tab you are on in the app: back to the site's home page.
      // In-app navigation first (the music keeps playing): Music's logo link, then its
      // side menu; only if the page did not change, load the home page.
      home: function () {
        const before = page();
        if (onMusic) {
          if (!press('ytmusic-nav-bar ytmusic-logo a, ytmusic-nav-bar a[href="/"]')) window.__tubeShell.go(0);
          setTimeout(function () {
            if (page() !== before || location.pathname === '/') return;
            window.__tubeShell.go(0);
            setTimeout(function () {
              if (page() === before && location.pathname !== '/') location.assign('/');
            }, 400);
          }, 300);
          return;
        }
        press('ytm-pivot-bar-item-renderer:first-of-type .pivot-bar-item-tab, ytm-home-logo button');
        setTimeout(function () {
          if (page() === before && location.pathname !== '/') location.assign('/');
        }, 800);
      },
      // Playback speed and video quality from the app's menu, remembered per site.
      speed: function (rate) {
        setPref('tubeShellSpeed', String(rate));
        document.querySelectorAll('video, audio').forEach(applySpeed);
      },
      quality: function (quality) {
        setPref('tubeShellQuality', quality);
        const player = document.getElementById('movie_player');
        if (player && player.setPlaybackQualityRange) applyQuality(player);
      },
      // The app reports the connection (mobile data / Low Data Mode or not) and the
      // data saver switch; the video on screen follows at once.
      network: function (onCellular) {
        cellular = onCellular;
        const player = document.getElementById('movie_player');
        if (player && player.setPlaybackQualityRange && location.pathname === '/watch') applyQuality(player);
      },
      saver: function (on) {
        setPref('tubeShellSaver', on ? 'on' : 'off');
        window.__tubeShell.network(cellular);
      },
      // Sleep timer "at the end of the song" on or off (section 5).
      sleepAtEnd: function (on) {
        sleepAtEnd = on;
      },
      // Siri / Shortcuts "play my music": resume the song on screen, else the first
      // "Play all" on the page (Home's quick picks).
      play: function () {
        playRequested = true;
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
        setPref('tubeShellCaptions', on ? 'on' : 'off');
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
  // 11. Music history: the full player is not a page of its own
  // ---------------------------------------------------------------------------
  // Music pushes /watch when a song opens and, on closing the player, pushes the page
  // underneath again: Home, Playlist, Song, Playlist. Back from the playlist then reopened
  // the song. The song now takes the place of the page it was opened from, and that page
  // takes its place back on closing: Home, Playlist; back goes Home.

  if (isTopFrame && location.hostname === 'music.youtube.com') {
    const nativePush = history.pushState.bind(history);
    const nativeReplace = history.replaceState.bind(history);
    const isWatch = function (url) {
      try {
        return new URL(url, location.href).pathname === '/watch';
      } catch (e) {
        return false;
      }
    };
    let openedFrom = null; // the page a song replaced in the history
    history.pushState = function (state, title, url) {
      if (url != null && isWatch(url) && !isWatch(page())) {
        openedFrom = { state: history.state, url: page() };
        return nativeReplace(state, title, url);
      }
      if (url != null && !isWatch(url) && isWatch(page())) {
        const from = openedFrom;
        openedFrom = null;
        const target = new URL(url, location.href);
        if (!from || from.url === target.pathname + target.search) return nativeReplace(state, title, url);
        // Closed into a different page (an artist from the player): keep where it came from.
        nativeReplace(from.state, '', from.url);
        return nativePush(state, title, url);
      }
      return nativePush(state, title, url);
    };
  }

  // ---------------------------------------------------------------------------
  // 12. Music player gestures: swipe the artwork for next / previous, tap it for lyrics
  // ---------------------------------------------------------------------------

  if (isTopFrame && location.hostname === 'music.youtube.com') {
    const lyricsCss =
      // Lyrics large and easy to read, like the native apps.
      'ytmusic-player-page ytmusic-description-shelf-renderer :is(.description, .non-expandable-description)' +
      ' { font-size: 24px !important; line-height: 1.45 !important; font-weight: 600 !important; }\n' +
      // Moves on the artwork are ours: sideways = next/previous, down = fold the player.
      'ytmusic-player-page ytmusic-player#player { touch-action: none !important; }';
    addCss(lyricsCss);

    // Music's own in-app navigation (no reload, the song keeps its place in the mini
    // player): the endpoint its links carry, built from a page address.
    const navigateMusic = function (path) {
      let url;
      try {
        url = new URL(path, location.origin);
      } catch (e) {
        return;
      }
      const p = url.pathname;
      let endpoint = null;
      if (p === '/playlist' && url.searchParams.get('list')) {
        endpoint = { browseEndpoint: { browseId: 'VL' + url.searchParams.get('list') } };
      } else if (/^\/(browse|channel)\//.test(p)) {
        endpoint = { browseEndpoint: { browseId: decodeURIComponent(p.split('/')[2]) } };
      } else if (p === '/explore') {
        endpoint = { browseEndpoint: { browseId: 'FEmusic_explore' } };
      } else if (p === '/library') {
        endpoint = { browseEndpoint: { browseId: 'FEmusic_library_landing' } };
      } else if (p === '/search' && url.searchParams.get('q')) {
        endpoint = { searchEndpoint: { query: url.searchParams.get('q') } };
      }
      const app = document.querySelector('ytmusic-app');
      if (!endpoint || !app) return;
      app.dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: endpoint } }));
    };

    // The app reopens the last song's page at launch (remember where you were): its
    // player opens full screen by itself, which is not where the user left things.
    // Only the first page of the web view is the app reopening; later loads of a song
    // (a link from outside, a reload) open it full size.
    let firstPage = true;
    try {
      firstPage = !sessionStorage.getItem('tubeshell-started');
      sessionStorage.setItem('tubeshell-started', '1');
    } catch (e) {}
    const launchedOnSong = firstPage && location.pathname === '/watch';
    const launchedAt = Date.now();
    let touchedSinceLaunch = false;
    document.addEventListener(
      'touchstart',
      function () {
        touchedSinceLaunch = true;
      },
      { capture: true, passive: true, once: true }
    );
    const restoringSong = function () {
      return launchedOnSong && !touchedSinceLaunch && Date.now() - launchedAt < LAUNCH_WINDOW_MS;
    };

    // Tell the app while the full player is open (see WebTab.setMusicPlayerOpen).
    let playerOpen = null;
    const reportPlayer = function () {
      const open = isMusicPlayerOpen();
      if (open === playerOpen) return;
      playerOpen = open;
      post({ type: 'musicPlayer', open });
      if (!open && window.__tubeShellReturnTo) {
        // Folded at launch: back to the page the song was playing over.
        const back = window.__tubeShellReturnTo;
        window.__tubeShellReturnTo = null;
        setTimeout(function () {
          navigateMusic(back);
        }, 150);
      }
      if (open && restoringSong()) {
        // Reopened at launch on the last song: fold it into the mini player, paused.
        // Music ignores the fold until its player has finished setting up: keep trying.
        let tries = 0;
        const fold = function () {
          if (!playerOpen || !restoringSong() || tries++ > 12) return;
          foldMusicPlayer();
          setTimeout(fold, 600);
        };
        setTimeout(fold, 500);
      } else if (open) {
        hintTries = 0;
        lastArtTop = null;
        setTimeout(showGestureHints, 150);
      }
    };

    // For about three seconds after the full player opens: what each gesture does.
    // Arrows on the artwork (sideways = previous / next song), "drag down" (Back) above
    // it, and "from the edge: back" low on the left, where the edge swipe is meant.
    // Liquid Glass look: translucent, blurred and saturated, with a light rim.
    // Motion, iOS style: each pill settles in (slight zoom out of a blur), a specular
    // sheen sweeps across the glass, then the whole pill gives one soft nudge the way
    // its gesture goes. On the way out it melts back into a blur. Nothing moves with
    // Reduce Motion.
    const hintCss =
      '.tubeshell-hints { position: fixed; inset: 0; z-index: 2147483646; pointer-events: none;' +
      ' font: 600 13px -apple-system, sans-serif; color: #fff; }' +
      '.tubeshell-hints > div { position: absolute; display: flex; align-items: center; gap: 7px;' +
      ' padding: 7px 13px; border-radius: 999px; white-space: nowrap; line-height: 1; overflow: hidden;' +
      ' background: rgba(255,255,255,.10); border: .5px solid rgba(255,255,255,.28);' +
      ' box-shadow: inset 0 .5px 0 rgba(255,255,255,.5), inset 0 -.5px 0 rgba(255,255,255,.12), 0 4px 14px rgba(0,0,0,.22);' +
      ' text-shadow: 0 1px 2px rgba(0,0,0,.35);' +
      ' -webkit-backdrop-filter: blur(16px) saturate(140%) brightness(.9); backdrop-filter: blur(16px) saturate(140%) brightness(.9); }' +
      // The sheen is a wide gradient strip slid across with transform (GPU only): moving
      // background-position or blending repaints the pill on every frame.
      '.tubeshell-hints > div::after { content: ""; position: absolute; top: 0; bottom: 0; left: -100%; width: 300%;' +
      ' background: linear-gradient(110deg, transparent 42%, rgba(255,255,255,.20) 47.5%, rgba(255,255,255,.45) 50%, rgba(255,255,255,.20) 52.5%, transparent 58%);' +
      ' translate: -40% 0; opacity: 0; will-change: translate, opacity; }' +
      // Chevrons drawn in CSS, centred on the text (glyphs like ⌄ sit low).
      '.tubeshell-hints i { width: 7px; height: 7px; border: solid #fff; border-width: 0 2px 2px 0;' +
      ' display: inline-block; flex: none; }' +
      '.tubeshell-hints i.left { transform: rotate(135deg); margin-left: 2px; }' +
      '.tubeshell-hints i.right { transform: rotate(-45deg); margin-right: 2px; }' +
      '.tubeshell-hints i.down { transform: rotate(45deg); margin-top: -4px; }' +
      '.tubeshell-hints i.tap { width: 8px; height: 8px; border: 2px solid #fff; border-radius: 50%; transform: none; }' +
      '.tubeshell-hints > div { opacity: 0; }' +
      '.tubeshell-hints.on > div { opacity: 1; }' +
      // Motion (reviewed against iOS): the glass itself fades in (backdrop blur 0 → 16,
      // never filter: blur, which switches the frost off), with a slight spring; a soft
      // sheen crosses each pill once; then the whole pill gives one crisp nudge the way
      // its gesture goes (the tap pill a little press). Out: glass melts away.
      '@media (prefers-reduced-motion: no-preference) {' +
      ' .tubeshell-hints > div { will-change: opacity, scale, translate; }' +
      ' .tubeshell-hints.on > div { animation: tsh-in .55s cubic-bezier(.34,1.25,.64,1) var(--d) both,' +
      '   tsh-nudge .8s calc(var(--d) + 1.15s) both; }' +
      ' .tubeshell-hints.on > div.tap { animation: tsh-in .55s cubic-bezier(.34,1.25,.64,1) var(--d) both,' +
      '   tsh-press .7s cubic-bezier(.4,0,.2,1) calc(var(--d) + 1.15s) both; }' +
      ' .tubeshell-hints.on > div::after { animation: tsh-sheen .9s cubic-bezier(.45,.05,.55,.95) calc(var(--d) + .3s) both; }' +
      ' .tubeshell-hints.out > div, .tubeshell-hints.out > div.tap { animation: tsh-out .24s cubic-bezier(.4,0,.6,1) both; }' +
      '}' +
      '.tubeshell-hints > div.left { --nx: -4px; --ny: 0px; }' +
      '.tubeshell-hints > div.right { --nx: 4px; --ny: 0px; }' +
      '.tubeshell-hints > div.down { --nx: 0px; --ny: 4px; }' +
      // Only opacity and scale animate: animating the backdrop blur re-renders the glass
      // every frame and stutters on the phone.
      '@keyframes tsh-in { from { opacity: 0; scale: .92; } to { opacity: 1; scale: 1; } }' +
      '@keyframes tsh-sheen { 0% { opacity: 0; translate: -40% 0; } 8% { opacity: 1; }' +
      ' 94% { opacity: 1; } 100% { opacity: 0; translate: 40% 0; } }' +
      '@keyframes tsh-nudge { 0% { translate: 0 0; animation-timing-function: cubic-bezier(.3,0,.2,1); }' +
      ' 35% { translate: var(--nx) var(--ny); animation-timing-function: cubic-bezier(.4,0,.2,1); }' +
      ' 60% { translate: calc(var(--nx) * -.2) calc(var(--ny) * -.2); } 80%, 100% { translate: 0 0; } }' +
      '@keyframes tsh-press { 0% { scale: 1; animation-timing-function: cubic-bezier(.3,0,.2,1); }' +
      ' 25% { scale: .93; animation-timing-function: cubic-bezier(.3,0,.2,1); }' +
      ' 55% { scale: 1.02; animation-timing-function: cubic-bezier(.3,0,.2,1); } 80%, 100% { scale: 1; } }' +
      '@keyframes tsh-out { 0% { opacity: 1; scale: 1; } 60% { opacity: .1; } 100% { opacity: 0; scale: .96; } }';
    let hintsShown = null;
    let hintTries = 0;
    let lastArtTop = null;
    // The player slides up as it opens: wait (up to ~2 s) until the artwork is in place.
    const showGestureHints = function () {
      if (hintsShown || !playerOpen) return;
      const art = document.querySelector('ytmusic-player-page ytmusic-player#player');
      const box = art && art.getBoundingClientRect();
      // Placed only once the artwork has stopped moving (same spot two polls running) and
      // sits in the top half: measured mid-slide, the hints landed on the song controls.
      const settled = box && lastArtTop !== null && Math.abs(box.top - lastArtTop) < 1;
      lastArtTop = box ? box.top : null;
      const ready = settled && box.height > 80 && box.top >= 0 && box.top < innerHeight * 0.45;
      if (!ready) {
        if (hintTries++ < 20) setTimeout(showGestureHints, 100);
        return;
      }
      if (!document.getElementById('tubeshell-hint-style')) addCss(hintCss, 'tubeshell-hint-style');
      const layer = document.createElement('div');
      layer.className = 'tubeshell-hints';
      // Built node by node: Music's Trusted Types policy rejects innerHTML.
      const pill = function (parts, css) {
        const el = document.createElement('div');
        const lead = parts.find(function (p) { return p.chevron; });
        if (lead) el.className = lead.chevron;
        parts.forEach(function (part) {
          if (part.chevron) {
            const i = document.createElement('i');
            i.className = part.chevron;
            el.appendChild(i);
          } else {
            const span = document.createElement('span');
            span.textContent = part.text;
            el.appendChild(span);
          }
        });
        el.style.cssText = css + '; --d:' + layer.childElementCount * 0.05 + 's';
        layer.appendChild(el);
      };
      const midY = box.top + box.height / 2 - 15;
      // Narrow artwork (iPhone SE): the side pills would touch; arrows alone there.
      const roomy = box.width >= 340;
      // Order of appearance: top, sides, centre, bottom. "Back" sits clear above the art.
      pill([{ chevron: 'down' }, { text: T.back }], 'left:50%; transform:translateX(-50%); top:' + Math.max(box.top - 38, 66) + 'px');
      pill(roomy ? [{ chevron: 'left' }, { text: T.prev }] : [{ chevron: 'left' }], 'left:' + (box.left + 10) + 'px; top:' + midY + 'px');
      pill(roomy ? [{ text: T.next }, { chevron: 'right' }] : [{ chevron: 'right' }], 'right:' + (innerWidth - box.right + 10) + 'px; top:' + midY + 'px');
      pill([{ chevron: 'tap' }, { text: T.lyrics }], 'left:50%; transform:translateX(-50%); top:' + (midY + 46) + 'px');
      // "Back" hint in the gap between the song controls and the Up next / Lyrics tabs.
      let backCss = 'left:10px; bottom:calc(env(safe-area-inset-bottom) + 90px)';
      const controls = document.querySelector('ytmusic-player-page ytmusic-player-controls');
      const tab = Array.prototype.find.call(
        document.querySelectorAll('ytmusic-player-page tp-yt-paper-tab.tab-header'),
        function (t) {
          const r = t.getBoundingClientRect();
          return r.height > 0 && r.top < innerHeight;
        }
      );
      if (controls && tab) {
        const gapTop = controls.getBoundingClientRect().bottom;
        const gapBottom = tab.getBoundingClientRect().top;
        if (gapBottom - gapTop >= 34) backCss = 'left:10px; top:' + ((gapTop + gapBottom) / 2 - 16) + 'px';
      }
      pill([{ chevron: 'left' }, { text: T.back }], backCss);
      document.body.appendChild(layer);
      hintsShown = layer;
      requestAnimationFrame(function () {
        layer.classList.add('on');
      });
      const hide = function () {
        layer.classList.add('out');
        setTimeout(function () {
          layer.remove();
          if (hintsShown === layer) hintsShown = null;
        }, 400);
        document.removeEventListener('touchstart', hide, true);
      };
      setTimeout(hide, 3200);
      document.addEventListener('touchstart', hide, true);
    };
    const watchPlayer = function () {
      new MutationObserver(reportPlayer).observe(document.documentElement, {
        subtree: true,
        attributes: true,
        attributeFilter: ['player-page-open'],
      });
      reportPlayer();
    };
    if (document.documentElement) watchPlayer();
    else document.addEventListener('DOMContentLoaded', watchPlayer, { once: true });

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
    const pageAt = function (target) {
      if (!(target instanceof Element) || !isMusicPlayerOpen()) return null;
      const page = target.closest('ytmusic-player-page');
      // Anywhere on the player except its controls, progress bar and Up next panel.
      if (!page || target.closest('#side-panel, ytmusic-player-controls, tp-yt-paper-slider, #progress-bar, button, a')) return null;
      return page;
    };
    let fold = null;
    document.addEventListener(
      'touchstart',
      function (event) {
        const touch = event.touches[0];
        const page = event.touches.length === 1 ? pageAt(event.target) : null;
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
        fold.page.style.willChange = 'transform';
        fold.page.style.transition = 'none';
        fold.page.style.transform = 'translateY(' + fold.dy + 'px)';
      },
      { capture: true, passive: true }
    );
    const drop = function (event) {
      if (!fold) return;
      const { page, dy, active } = fold;
      fold = null;
      if (!active) return;
      if (dy > 120) {
        // Fold at once from where the finger left it: Music slides the player down
        // itself; the drag offset is dropped as soon as it starts closing.
        haptic();
        foldMusicPlayer();
        const settle = function () {
          if (isMusicPlayerOpen() && Date.now() - releasedAt < 1200) return void setTimeout(settle, 30);
          page.style.transition = 'transform 0.25s ease-out';
          page.style.transform = '';
          setTimeout(function () {
            page.style.transition = page.style.willChange = '';
          }, 300);
        };
        const releasedAt = Date.now();
        settle();
      } else {
        page.style.transition = 'transform 0.2s ease';
        page.style.transform = '';
        setTimeout(function () {
          page.style.transition = page.style.willChange = '';
        }, 250);
      }
    };
    document.addEventListener('touchend', drop, { capture: true, passive: true });
    document.addEventListener('touchcancel', drop, { capture: true, passive: true });
  }

  // ---------------------------------------------------------------------------
  // 13. YouTube: mini player mode, captions off by default, drag the video down to minimize
  // ---------------------------------------------------------------------------

  if (isTopFrame && location.hostname === 'm.youtube.com') {
    const root = document.documentElement;
    if (pref('tubeShellCaptions', 'off') === 'on') root.classList.add('tubeshell-captions');

    // Mini player mode (set by the app): the video fills the small floating page.
    const miniCss =
      'html.tubeshell-mini #player-container-id { position: fixed !important; top: 0 !important; left: 0 !important;' +
      ' width: 100vw !important; height: 100vh !important; z-index: 2147483647 !important; transform: none !important;' +
      ' opacity: 1 !important; box-shadow: none !important; background: #000 !important; padding: 0 !important; }\n' +
      'html.tubeshell-mini :is(#player-container-id #player, #movie_player, video.html5-main-video)' +
      ' { width: 100vw !important; height: 100vh !important; left: 0 !important; top: 0 !important; object-fit: contain !important; }\n';
    addCss(miniCss);

    // Captions: hidden everywhere (feed previews included) unless turned on from the
    // app's menu; on the watch page the captions module is also unloaded.
    const captionCss =
      'html:not(.tubeshell-captions) :is(.ytp-caption-window-container, .caption-window, .captions-text)' +
      ' { display: none !important; }\n';
    addCss(captionCss);
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

    // Drag the watch-page video down to minimize it, like the YouTube app. The player
    // follows the finger; past a third of its height the app shrinks it into the mini
    // player, otherwise it springs back. Vertical drags on the video are ours (no scrolling).
    addCss('#player-container-id { touch-action: pan-x !important; }');
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
      box.style.transform = box.style.opacity = '';
      // The app shrinks this whole page into a floating mini player and opens a second
      // YouTube page underneath (leaving the watch page would stop the video). Going
      // back is the left-edge swipe.
      if (dy > box.offsetHeight / 3) post({ type: 'minimize' });
    };
    document.addEventListener('touchend', release, { capture: true, passive: true });
    document.addEventListener('touchcancel', release, { capture: true, passive: true });
  }

  // ---------------------------------------------------------------------------
  // 14. Fullscreen: leave it when the iPhone is upright again, keep playing on exit
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
  // 15. YouTube list: tapped videos open in the app's player, over the list
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
        if (!post({ type: 'openVideo', url: url.href })) return;
        event.preventDefault();
        event.stopImmediatePropagation();
      },
      true
    );
  }

})();
