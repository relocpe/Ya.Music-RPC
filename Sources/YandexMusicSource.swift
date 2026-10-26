import AppKit
import Foundation

// SIGUSR1 заставляет electron (fuse node_cli_inspect) открыть инспектор на 9229:
// перезапуск не нужен, музыка не прерывается
actor YandexMusicSource {
    private let bundleID = "ru.yandex.desktop.music"

    private var config: Config
    private var connection: CDPConnection?
    private var connectedPID: pid_t?
    private var lastSignalAt = Date.distantPast
    private var lastSeedAt = Date.distantPast
    private var seedReport = "ещё не искал <audio>"

    private(set) var status: SourceStatus = .notRunning

    init(config: Config) {
        self.config = config
    }

    func apply(config: Config) {
        self.config = config
    }

    var diagnostics: String { seedReport }


    func send(_ command: PlayerCommand) async {
        guard let app = runningApp() else { return }
        do {
            let connection = try await ensureConnection(pid: app.processIdentifier, executablePath: app.executableURL?.path)
            let body: String
            switch command {
            case .toggle:
                body = "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.toggleJS)), true);"
            case .next:
                body = Self.skipBody(next: true)
            case .prev:
                body = Self.skipBody(next: false)
            case .seek(let seconds):
                body = "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.seekJS(seconds))), true);"
            case .like:
                body = "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.likeJS)), true);"
            case .shuffle:
                body = "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.shuffleJS)), true);"
            case .cycleRepeat:
                body = "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.repeatJS)), true);"
            }
            let result = try await connection.evaluate(Self.mainProcessWrapper(isAsync: true, body: body))
            Log.info("плеер \(command.logName): \(String(describing: result))")
        } catch {
            Log.warn("плеер \(command.logName): \(error.localizedDescription)")
        }
    }


    // MARK: - Опрос

    func poll() async -> TrackState? {
        guard let app = runningApp() else {
            teardown()
            status = .notRunning
            return nil
        }
        let pid = app.processIdentifier

        if connectedPID != pid { teardown() }

        do {
            let connection = try await ensureConnection(pid: pid, executablePath: app.executableURL?.path)
            var state = try await readState(connection)

            // Метаданные есть, а <audio> ещё не найден — просканируем кучу.
            if state?.position == nil, Date().timeIntervalSince(lastSeedAt) > 8 {
                lastSeedAt = Date()
                seedReport = await seedAudioPool(connection)
                Log.debug("посев пула <audio>: \(seedReport)")
                state = try await readState(connection)
            }

            status = .connected
            return state
        } catch let error as CDPError {
            handle(error)
            return nil
        } catch {
            handle(CDPError.remote(error.localizedDescription))
            return nil
        }
    }

    private func handle(_ error: CDPError) {
        switch error {
        case .remote(let text) where text.contains("no-window"):
            status = .noPlayerWindow
        default:
            Log.debug("сорвался опрос: \(error.localizedDescription)")
            teardown()
            status = .inspectorUnavailable(error.localizedDescription)
        }
    }

    private func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    // MARK: - Соединение

    private func teardown() {
        connection?.close()
        connection = nil
        connectedPID = nil
    }

    private func ensureConnection(pid: pid_t, executablePath: String?) async throws -> CDPConnection {
        if let connection { return connection }

        var lastError: Error = CDPError.disconnected
        // Две попытки: первая — вдруг инспектор уже открыт; вторая — после SIGUSR1.
        for attempt in 0..<2 {
            do {
                let candidate = try await CDPConnection.connect(port: config.inspectorPort)
                guard try await belongsToYandexMusic(candidate, executablePath: executablePath) else {
                    candidate.close()
                    throw CDPError.remote("порт \(config.inspectorPort) занят другим Node-процессом")
                }
                // actor реентерабелен на await: параллельный tick() мог подключиться раньше
                if let existing = connection, connectedPID == pid {
                    candidate.close()
                    return existing
                }
                connection?.close()
                connection = candidate
                connectedPID = pid
                Log.info("подключился к инспектору Яндекс Музыки (pid \(pid))")
                return candidate
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await armInspector(pid: pid)
                }
            }
        }
        throw lastError
    }

    // SIGUSR1 не чаще раза в 5с
    private func armInspector(pid: pid_t) async throws {
        if Date().timeIntervalSince(lastSignalAt) < 5 {
            try await Task.sleep(nanoseconds: 400_000_000)
            return
        }
        lastSignalAt = Date()
        Log.info("открываю инспектор: SIGUSR1 -> pid \(pid)")
        if kill(pid, SIGUSR1) != 0 {
            let code = errno
            throw CDPError.remote("SIGUSR1 не прошёл (errno \(code))")
        }
        // Node поднимает слушателя не мгновенно.
        try await Task.sleep(nanoseconds: 1_200_000_000)
    }

    // на 9229 мог сесть чужой node
    private func belongsToYandexMusic(_ connection: CDPConnection, executablePath: String?) async throws -> Bool {
        guard let expected = executablePath else { return true }
        let actual = try await connection.evaluate("String(process.execPath || '')", awaitPromise: false)
        guard let actual = actual as? String, !actual.isEmpty else { return false }
        return URL(fileURLWithPath: actual).standardized.path == URL(fileURLWithPath: expected).standardized.path
    }

    // MARK: - Чтение состояния

    private func readState(_ connection: CDPConnection) async throws -> TrackState? {
        let expression = Self.mainProcessWrapper(body: "return wc.executeJavaScript(\(CDPConnection.jsLiteral(Self.agentJS)), true);")
        guard let raw = try await connection.evaluate(expression) as? String else {
            throw CDPError.badResponse("агент вернул не строку")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw CDPError.badResponse(String(raw.prefix(200)))
        }
        guard object["ok"] as? Bool == true else {
            throw CDPError.remote(object["reason"] as? String ?? "агент не смог прочитать плеер")
        }

        let title = object["title"] as? String ?? ""
        let artist = object["artist"] as? String ?? ""
        guard !(title.isEmpty && artist.isEmpty) else { return nil }

        let position = object["position"] as? Double ?? -1
        let duration = object["duration"] as? Double ?? -1

        let repeatRaw = object["repeat"] as? String ?? "off"
        return TrackState(
            title: title,
            artist: artist,
            album: object["album"] as? String ?? "",
            coverURL: (object["cover"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isPlaying: object["playing"] as? Bool ?? false,
            position: position >= 0 ? position : nil,
            duration: duration > 0 ? duration : nil,
            liked: object["liked"] as? Bool ?? false,
            shuffle: object["shuffle"] as? Bool ?? false,
            repeatMode: RepeatMode(rawValue: repeatRaw) ?? .off,
            hasShuffle: object["hasShuffle"] as? Bool ?? false,
            hasRepeat: object["hasRepeat"] as? Bool ?? false,
            url: object["url"] as? String ?? ""
        )
    }

    // <audio> вне DOM — ищем через Runtime.queryObjects
    private func seedAudioPool(_ connection: CDPConnection) async -> String {
        let expression = Self.mainProcessWrapper(isAsync: true, body: Self.seedBody)
        do {
            let result = try await connection.evaluate(expression, timeout: 10)
            return (result as? String) ?? "непонятный ответ"
        } catch {
            return "не вышло: \(error.localizedDescription)"
        }
    }

    // MARK: - JS

    private static func mainProcessWrapper(isAsync: Bool = false, body: String) -> String {
        let prefix = isAsync ? "(async function () {" : "(function () {"
        return """
        \(prefix)
          var electron = process.mainModule.require('electron');
          var all = electron.webContents.getAllWebContents().filter(function (w) {
            return !w.isDestroyed() && String(w.getURL()).indexOf('music-application://') === 0;
          });
          var wc = all[0];
          // Всегда отдаём промис: Runtime.evaluate вызывается с awaitPromise.
          if (!wc) { return Promise.resolve(JSON.stringify({ ok: false, reason: 'no-window' })); }
          \(body)
        })()
        """
    }

    private static let seedBody = #"""
      var dbg = wc.debugger;
      var attachedByUs = false;
      try {
        if (!dbg.isAttached()) { dbg.attach('1.3'); attachedByUs = true; }
      } catch (e) {
        return 'отладчик занят: ' + e.message;
      }
      var added = 0;
      var problems = [];
      try {
        await dbg.sendCommand('Runtime.enable', {});
        var protos = ['HTMLAudioElement', 'HTMLVideoElement'];
        for (var i = 0; i < protos.length; i++) {
          try {
            var ev = await dbg.sendCommand('Runtime.evaluate', {
              expression: protos[i] + '.prototype', objectGroup: 'ymrpc'
            });
            if (!ev.result || !ev.result.objectId) { continue; }
            var found = await dbg.sendCommand('Runtime.queryObjects', {
              prototypeObjectId: ev.result.objectId, objectGroup: 'ymrpc'
            });
            var fn = 'function () {' +
              '  var A = window.__ymrpc; if (!A) { return -1; }' +
              '  var n = 0, arr = Array.from(this);' +
              '  for (var i = 0; i < arr.length; i++) { if (!A.hasEl(arr[i])) { A.add(arr[i]); n++; } }' +
              '  return n;' +
              '}';
            var r = await dbg.sendCommand('Runtime.callFunctionOn', {
              objectId: found.objects.objectId, functionDeclaration: fn, returnByValue: true
            });
            added += (r.result && typeof r.result.value === 'number' && r.result.value > 0) ? r.result.value : 0;
          } catch (e) {
            problems.push(protos[i] + ': ' + e.message);
          }
        }
        try { await dbg.sendCommand('Runtime.releaseObjectGroup', { objectGroup: 'ymrpc' }); } catch (e) {}
      } finally {
        if (attachedByUs) { try { dbg.detach(); } catch (e) {} }
      }
      return 'найдено элементов: ' + added + (problems.length ? ' | ' + problems.join('; ') : '');
    """#

    // агент в рендерере: метаданные из Media Session, время из активного <audio>
    private static let agentJS = #"""
    (function () {
     try {
      var KEY = '__ymrpc';
      var VERSION = 7;
      var A = window[KEY];

      if (!A || A.v !== VERSION) {
        A = { v: VERSION, refs: [] };
        window[KEY] = A;

        A.playerBar = function () {
          return document.querySelector('[class*="VibePlayerBar"], [class*="PlayerBar"], [class*="SonataControls"], [class*="player-controls"]') || document.body;
        };
        A.btnLabel = function (el) {
          return ((el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title'))) || '').trim();
        };
        A.barButton = function (pred) {
          var roots = [A.playerBar(), document];
          for (var r = 0; r < roots.length; r++) {
            var nodes = roots[r].querySelectorAll('button, [role="button"]');
            for (var i = 0; i < nodes.length; i++) {
              if (pred(nodes[i], A.btnLabel(nodes[i]))) { return nodes[i]; }
            }
          }
          return null;
        };
        A.reactTrackId = function () {
          var el = document.querySelector('[class*="PlayerbarMeta_trackName"], [class*="trackNameText"]');
          if (!el) { return ''; }
          var keys = Object.keys(el);
          for (var i = 0; i < keys.length; i++) {
            try {
              if (keys[i].indexOf('__reactProps') === 0 && el[keys[i]] && el[keys[i]].trackId) {
                return String(el[keys[i]].trackId);
              }
              if (keys[i].indexOf('__reactFiber') === 0) {
                var memo = el[keys[i]].memoizedProps;
                if (memo && memo.trackId) { return String(memo.trackId); }
              }
            } catch (err) {}
          }
          return '';
        };
        A.albumId = function () {
          var a = A.playerBar().querySelector('a[href*="albumId="]') || document.querySelector('a[href*="albumId="]');
          if (!a) { return ''; }
          var m = /albumId=(\d+)/.exec(a.getAttribute('href') || '');
          return m ? m[1] : '';
        };
        A.lsValue = function (key) {
          try {
            var o = JSON.parse(localStorage.getItem(key) || 'null');
            return o && o.value;
          } catch (err) { return null; }
        };

        // Runtime.queryObjects возвращает в том числе сами объекты-прототипы,
        // а обращение к их геттерам бросает «Illegal invocation». Пускаем в пул
        // только настоящие элементы.
        A.isRealMedia = function (el) {
          try {
            return !!el && el.nodeType === 1 && typeof el.readyState === 'number'
              && typeof el.play === 'function';
          } catch (err) {
            return false;
          }
        };

        A.hasEl = function (el) {
          for (var i = 0; i < A.refs.length; i++) { if (A.refs[i].deref() === el) { return true; } }
          return false;
        };

        A.add = function (el) {
          if (A.isRealMedia(el) && !A.hasEl(el)) { A.refs.push(new WeakRef(el)); }
          return A.refs.length;
        };

        A.live = function () {
          var alive = [], kept = [];
          for (var i = 0; i < A.refs.length; i++) {
            var el = A.refs[i].deref();
            if (el && A.isRealMedia(el)) { kept.push(A.refs[i]); alive.push(el); }
          }
          A.refs = kept;
          return alive;
        };

        A.active = function () {
          var usable = A.live().filter(function (e) {
            try {
              return !!(e.currentSrc || e.src) && e.readyState > 0;
            } catch (err) {
              return false;
            }
          });
          var playing = usable.filter(function (e) { return !e.paused; });
          if (playing.length) {
            // При кроссфейде играют сразу два элемента — нужен тот, который
            // запустили последним: Media Session уже описывает именно его.
            return playing.sort(function (a, b) {
              var byStart = (b.__ymrpcStartedAt || 0) - (a.__ymrpcStartedAt || 0);
              return byStart !== 0 ? byStart : (b.currentTime - a.currentTime);
            })[0];
          }
          return usable.sort(function (a, b) { return b.readyState - a.readyState; })[0] || null;
        };

        // Приложение переиспользует пул <audio>; новые ловим на play()
        // и заодно запоминаем момент запуска. Оригинал храним на прототипе,
        // чтобы обновление агента не наращивало цепочку обёрток.
        var proto = HTMLMediaElement.prototype;
        if (!proto.__ymrpcOrigPlay) { proto.__ymrpcOrigPlay = proto.play; }
        if (proto.play.__ymrpc !== VERSION) {
          var origPlay = proto.__ymrpcOrigPlay;
          var patched = function () {
            try {
              this.__ymrpcStartedAt = Date.now();
              // Ищем агента в window, а не в замыкании: иначе старая обёртка
              // после обновления кормила бы уже мёртвый объект.
              var current = window[KEY];
              if (current && current.add) { current.add(this); }
            } catch (err) {}
            return origPlay.apply(this, arguments);
          };
          patched.__ymrpc = VERSION;
          proto.play = patched;
        }

        A.state = function () {
          var ms = navigator.mediaSession || {};
          var md = ms.metadata;
          var cover = '';
          if (md && md.artwork && md.artwork.length) {
            var best = null, bestArea = -1;
            for (var i = 0; i < md.artwork.length; i++) {
              var art = md.artwork[i];
              var m = /(\d+)x(\d+)/.exec(art.sizes || '');
              var area = m ? (parseInt(m[1], 10) * parseInt(m[2], 10)) : 0;
              if (area >= bestArea) { bestArea = area; best = art; }
            }
            cover = best ? best.src : md.artwork[0].src;
          }
          var el = A.active();
          var pos = (el && isFinite(el.currentTime)) ? el.currentTime : -1;
          var dur = (el && isFinite(el.duration) && el.duration > 0) ? el.duration : -1;
          var likeBtn = A.barButton(function (node, label) { return label === 'Нравится' || label === 'Like'; });
          var shBtn = A.barButton(function (node, label) { return /перемеш|случайн|поряд|shuffle/i.test(label) && !/повтор/i.test(label); });
          var rpBtn = A.barButton(function (node, label) { return /повтор|repeat/i.test(label); });
          var liked = likeBtn ? (likeBtn.getAttribute('aria-pressed') === 'true') : false;
          var shuffle = shBtn ? (shBtn.getAttribute('aria-pressed') === 'true') : !!A.lsValue('ymPlayerShuffle');
          var repeat = 'off';
          if (rpBtn) {
            var rl = A.btnLabel(rpBtn).toLowerCase();
            if (/трек|one/.test(rl)) { repeat = 'one'; }
            else if (rpBtn.getAttribute('aria-pressed') === 'true' || /все|всё|all/.test(rl)) { repeat = 'all'; }
          } else {
            var rv = A.lsValue('ymPlayerRepeatMode');
            if (rv === 'one' || rv === 'track') { repeat = 'one'; }
            else if (rv && rv !== 'none' && rv !== false) { repeat = 'all'; }
          }
          var trackId = A.reactTrackId();
          var albumId = A.albumId();
          var url = '';
          if (trackId && albumId) { url = 'https://music.yandex.ru/album/' + albumId + '/track/' + trackId; }
          else if (trackId) { url = 'https://music.yandex.ru/track/' + trackId; }
          else if (albumId) { url = 'https://music.yandex.ru/album/' + albumId; }
          return JSON.stringify({
            ok: true,
            title: md ? String(md.title || '') : '',
            artist: md ? String(md.artist || '') : '',
            album: md ? String(md.album || '') : '',
            cover: cover,
            playing: el ? !el.paused : (String(ms.playbackState) === 'playing'),
            position: pos,
            duration: dur,
            liked: liked,
            shuffle: shuffle,
            repeat: repeat,
            hasShuffle: !!shBtn,
            hasRepeat: !!rpBtn,
            url: url,
            pool: A.refs.length
          });
        };
      }

      return window[KEY].state();
     } catch (e) {
      // Ошибку возвращаем значением: Electron наружу отдаёт только «Script failed to execute».
      var where = (e && e.stack) ? String(e.stack).split('\n').slice(0, 3).join(' | ') : '';
      return JSON.stringify({
        ok: false,
        reason: 'агент упал: ' + ((e && e.message) ? e.message : String(e)) + (where ? ' [' + where + ']' : '')
      });
     }
    })()
    """#


    private static let likeJS = #"""
    (function () {
      try {
        var roots = document.querySelectorAll('[class*="PlayerBar"], [class*="player-controls"], [class*="SonataControls"]');
        if (!roots.length) { roots = [document]; }
        for (var r = 0; r < roots.length; r++) {
          var nodes = roots[r].querySelectorAll('button, [role="button"]');
          for (var i = 0; i < nodes.length; i++) {
            var label = (nodes[i].getAttribute('aria-label') || '').trim();
            if (label === 'Нравится' || label === 'Like') { nodes[i].click(); return 'click'; }
          }
        }
        return 'no-button';
      } catch (e) {
        return 'error: ' + (e && e.message ? e.message : String(e));
      }
    })()
    """#

    private static let shuffleJS = #"""
    (function () {
      try {
        var nodes = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < nodes.length; i++) {
          var label = (nodes[i].getAttribute('aria-label') || '').trim();
          if (/перемеш|случайн|поряд|shuffle/i.test(label) && !/повтор/i.test(label)) {
            nodes[i].click(); return 'click';
          }
        }
        return 'no-button';
      } catch (e) {
        return 'error: ' + (e && e.message ? e.message : String(e));
      }
    })()
    """#

    private static let repeatJS = #"""
    (function () {
      try {
        var nodes = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < nodes.length; i++) {
          var label = (nodes[i].getAttribute('aria-label') || '').trim();
          if (/повтор|repeat/i.test(label)) { nodes[i].click(); return 'click'; }
        }
        return 'no-button';
      } catch (e) {
        return 'error: ' + (e && e.message ? e.message : String(e));
      }
    })()
    """#

    private static let toggleJS = #"""
    (function () {
      try {
        var A = window.__ymrpc;
        if (A && A.active) {
          var el = A.active();
          if (el && el.paused) { el.play(); return 'play'; }
          if (el) { el.pause(); return 'pause'; }
        }
        var labels = ['Пауза', 'Играть', 'Play', 'Pause', 'Воспроизведение'];
        var nodes = document.querySelectorAll('button, [role="button"]');
        for (var i = 0; i < nodes.length; i++) {
          var label = (nodes[i].getAttribute('aria-label') || nodes[i].getAttribute('title') || '').trim();
          for (var j = 0; j < labels.length; j++) {
            if (label.indexOf(labels[j]) !== -1) { nodes[i].click(); return 'click'; }
          }
        }
        var fallback = document.querySelector('.player-controls__btn_play, .player-controls__btn_pause, .sonata-controls__play');
        if (fallback) { fallback.click(); return 'click'; }
        return 'no-control';
      } catch (e) {
        return 'error: ' + (e && e.message ? e.message : String(e));
      }
    })()
    """#


    private static func skipBody(next: Bool) -> String {
        let key = next ? "MediaTrackNext" : "MediaTrackPrevious"
        return """
          var clicked = wc.executeJavaScript(\(CDPConnection.jsLiteral(clickJS(next: next))), true);
          return Promise.resolve(clicked).then(function (result) {
            if (result === 'click') { return result; }
            try {
              wc.sendInputEvent({ type: 'keyDown', keyCode: '\(key)' });
              wc.sendInputEvent({ type: 'keyUp', keyCode: '\(key)' });
            } catch (e) {}
            return result || 'key';
          });
        """
    }

    private static func seekJS(_ seconds: Double) -> String {
        let t = String(format: "%.3f", max(seconds, 0))
        return """
        (function () {
          try {
            var t = \(t);
            var A = window.__ymrpc;
            if (A && A.active) {
              var el = A.active();
              if (el && isFinite(el.duration) && el.duration > 0) {
                var next = Math.max(0, Math.min(t, el.duration - 0.05));
                try { if (typeof el.fastSeek === 'function') { el.fastSeek(next); } } catch (e) {}
                el.currentTime = next;
                return 'seek';
              }
            }
            return 'no-audio';
          } catch (e) {
            return 'error: ' + (e && e.message ? e.message : String(e));
          }
        })()
        """
    }

    private static func clickJS(next: Bool) -> String {
        let needles: String
        let classes: String
        if next {
            needles = "['Следующ','Next']"
            classes = ".player-controls__btn_next, .sonata-controls__next, [data-test-id='next']"
        } else {
            needles = "['Предыдущ','Previous']"
            classes = ".player-controls__btn_prev, .sonata-controls__prev, [data-test-id='prev']"
        }
        return """
        (function () {
          try {
            var needles = \(needles);
            var nodes = document.querySelectorAll('button, [role="button"]');
            for (var i = 0; i < nodes.length; i++) {
              var label = (nodes[i].getAttribute('aria-label') || nodes[i].getAttribute('title') || '').trim();
              for (var j = 0; j < needles.length; j++) {
                if (label.indexOf(needles[j]) !== -1) { nodes[i].click(); return 'click'; }
              }
            }
            var fallback = document.querySelector("\(classes)");
            if (fallback) { fallback.click(); return 'click'; }
            return 'no-button';
          } catch (e) {
            return 'error: ' + (e && e.message ? e.message : String(e));
          }
        })()
        """
    }

}
