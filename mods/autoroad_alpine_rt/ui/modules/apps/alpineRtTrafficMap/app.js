// Alpine Roadtrip Map (Traffic Overlay)
// UI App: renders a simple map-like polyline view with low/medium/high traffic colouring.
angular.module('beamng.apps').directive('alpinerttrafficmap', [function () {
  var tpl = ''
    + '<div class="artm">'
    + '  <style>'
    + '  .artm{font-family:"Cairo","Overpass",system-ui,sans-serif;color:#dfe2e6;background:rgba(18,20,24,0.90);'
    + '       border:1px solid rgba(255,255,255,0.07);border-top:2px solid #ff6600;border-radius:5px;'
    + '       height:100%;width:100%;box-sizing:border-box;display:flex;flex-direction:column;'
    + '       overflow:hidden;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);}'
    + '  .artm *{box-sizing:border-box;}'
    + '  .artm-head{display:flex;align-items:center;justify-content:space-between;padding:10px 11px;'
    + '            border-bottom:1px solid rgba(255,255,255,0.06);}'
    + '  .artm-brand{display:flex;align-items:center;min-width:0;}'
    + '  .artm-slash{width:6px;height:16px;background:#ff6600;transform:skewX(-16deg);margin-right:9px;flex:none;}'
    + '  .artm-title{font-style:italic;font-weight:800;font-size:13px;letter-spacing:.3px;color:#f4f6f8;white-space:nowrap;}'
    + '  .artm-sub{padding:7px 11px 0;color:#8b9198;font-size:11px;display:flex;flex-wrap:wrap;}'
    + '  .artm-sub span{margin:0 10px 4px 0;}'
    + '  .artm-sub b{color:#dfe2e6;font-weight:700;}'
    + '  .artm-body{padding:10px 11px 11px;display:flex;flex-direction:column;gap:8px;flex:1;min-height:0;}'
    + '  .artm-can{width:100%;flex:1;border:1px solid rgba(255,255,255,0.08);border-radius:4px;background:rgba(0,0,0,0.18);}'
    + '  .artm-leg{display:flex;align-items:center;gap:10px;font-size:11px;color:#9aa3ae;}'
    + '  .artm-dot{width:9px;height:9px;border-radius:2px;display:inline-block;margin-right:6px;transform:skewX(-12deg);}'
    + '  .artm-row{display:flex;align-items:center;justify-content:space-between;gap:10px;}'
    + '  .artm-btn{font-family:inherit;font-size:11px;font-weight:700;letter-spacing:.5px;border-radius:3px;padding:7px 10px;'
    + '           cursor:pointer;border:1px solid rgba(255,255,255,0.11);background:rgba(255,255,255,0.06);color:#dfe2e6;transition:all .12s;margin-left:6px;}'
    + '  .artm-btn:hover{background:rgba(255,255,255,0.12);}'
    + '  .artm-tools{display:flex;flex-wrap:wrap;gap:6px;}'
    + '  .artm-form{display:flex;flex-direction:column;gap:6px;}'
    + '  .artm-form input{font:inherit;font-size:12px;padding:6px 8px;border-radius:3px;'
    + '       border:1px solid rgba(255,255,255,0.12);background:rgba(0,0,0,0.28);color:#dfe2e6;width:100%;}'
    + '  .artm-q{font-size:11px;color:#c5cad1;line-height:1.35;}'
    + '  .artm-note{font-size:11px;color:#ffb020;min-height:14px;line-height:1.35;}'
    + '  .artm-list{max-height:132px;overflow:auto;display:flex;flex-direction:column;gap:4px;}'
    + '  .artm-item{font:inherit;font-size:12px;text-align:left;padding:6px 8px;border-radius:3px;cursor:pointer;'
    + '       border:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.04);color:#dfe2e6;}'
    + '  .artm-item:hover{background:rgba(255,102,0,0.18);}'
    + '  .artm-item small{display:block;color:#8b9198;font-size:10px;}'
    + '  </style>'
    + '  <div class="artm-head">'
    + '    <div class="artm-brand"><span class="artm-slash"></span><span class="artm-title">ALPINE ROADTRIP MAP</span></div>'
    + '    <div>'
    + '      <button class="artm-btn" ng-click="toggleZoom()">{{zoomed ? "Overview" : "Zoom"}}</button>'
    + '      <button class="artm-btn" ng-click="refresh()">Refresh</button>'
    + '    </div>'
    + '  </div>'
    + '  <div class="artm-sub">'
    + '    <span>Level <b>{{state.level || "-"}}</b></span>'
    + '    <span ng-if="state.lua_rev">Lua <b>{{state.lua_rev}}</b></span>'
    + '    <span ng-if="state.roads">Roads <b>{{state.roads.length}}</b></span>'
    + '  </div>'
    + '  <div class="artm-body">'
    + '    <canvas class="artm-can"></canvas>'
    + '    <div class="artm-tools">'
    + '      <button class="artm-btn" ng-click="openDefine()">Define map</button>'
    + '      <button class="artm-btn" ng-click="openPortal()">New portal</button>'
    + '      <button class="artm-btn" ng-click="openReturn()" ng-if="state.setup && state.setup.open_returns && state.setup.open_returns.length">Return ({{state.setup.open_returns.length}})</button>'
    + '    </div>'
    + '    <div class="artm-form" ng-if="panel===\'define\'">'
    + '      <div class="artm-q" ng-if="state.setup && state.setup.authority">CRS {{state.setup.authority}}</div>'
    + '      <div class="artm-note" ng-if="state.lua_rev && !(state.setup && state.setup.authority)">No map CRS authority is configured. This map cannot be added.</div>'
    + '      <input ng-model="form.name" placeholder="Location name">'
    + '      <input ng-model="form.lat" placeholder="Latitude (WGS84)">'
    + '      <input ng-model="form.lon" placeholder="Longitude (WGS84)">'
    + '      <div class="artm-q">In which direction is your vehicle currently pointing?</div>'
    + '      <div class="artm-tools">'
    + '        <button class="artm-btn" ng-click="saveLocation(\'north\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly north</button>'
    + '        <button class="artm-btn" ng-click="saveLocation(\'east\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly east</button>'
    + '        <button class="artm-btn" ng-click="saveLocation(\'south\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly south</button>'
    + '        <button class="artm-btn" ng-click="saveLocation(\'west\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly west</button>'
    + '      </div>'
    + '    </div>'
    + '    <div class="artm-form" ng-if="panel===\'portal\'">'
    + '      <input ng-model="levelQuery" placeholder="Filter maps">'
    + '      <div class="artm-list">'
    + '        <button class="artm-item" ng-repeat="lv in filteredLevels()" ng-click="choosePortal(lv)">{{lv.title}}<small>{{lv.id}}</small></button>'
    + '      </div>'
    + '    </div>'
    + '    <div class="artm-form" ng-if="panel===\'return\'">'
    + '      <div class="artm-q">Place the return portal at the vehicle, for a link that has no way back yet.</div>'
    + '      <div class="artm-list">'
    + '        <button class="artm-item" ng-repeat="link in state.setup.open_returns" ng-click="chooseReturn(link)">From {{link.label}}<small>{{link.from_level}}</small></button>'
    + '      </div>'
    + '    </div>'
    + '    <div class="artm-note" ng-if="note">{{note}}</div>'
    + '    <div class="artm-row">'
    + '      <div class="artm-leg">weather + traffic</div>'
    + '      <div style="font-size:11px;color:#7a8088">'
    + '        <span ng-if="state.map.attribution">{{state.map.attribution}}</span>'
    + '        <span ng-if="state.now_s"> t={{state.t_s}}s</span>'
    + '      </div>'
    + '    </div>'
    + '  </div>'
    + '</div>';

  function colFor(d) {
    if (d == null) return '#9aa3ae';
    if (d < 0.40) return '#3ddc84';
    if (d < 0.70) return '#ffd166';
    return '#ff4d4f';
  }

  var imgCache = {};

  function loadImg(url, onReady) {
    if (!url) return null;
    var rec = imgCache[url];
    if (rec) return rec.ok ? rec.img : null;
    var img = new Image();
    rec = { img: img, ok: false };
    imgCache[url] = rec;
    img.onload = function () {
      rec.ok = true;
      if (onReady) onReady();
    };
    img.onerror = function () {
      rec.ok = false;
      rec.fail = true;
    };
    img.src = url;
    return null;
  }

  function asBBox(raw) {
    if (!raw || raw.length < 4) return null;
    var b = [Number(raw[0]), Number(raw[1]), Number(raw[2]), Number(raw[3])];
    if (!isFinite(b[0]) || (b[2] - b[0]) < 1 || (b[3] - b[1]) < 1) return null;
    return b;
  }

  function levelRec(state) {
    var levels = state && state.map && state.map.levels;
    if (!levels || !state.level) return null;
    return levels[state.level] || null;
  }

  function imageBBox(state, zoomed) {
    if (zoomed) {
      var rec = levelRec(state);
      var zb = asBBox(rec && rec.bbox);
      if (zb) return zb;
    }
    return asBBox(state && state.map && state.map.bbox);
  }

  function contentBBox(state, zoomed) {
    if (zoomed) {
      var rec = levelRec(state);
      var zb = asBBox(rec && rec.content_bbox) || asBBox(rec && rec.bbox);
      if (zb) return zb;
    }
    var cb = asBBox(state && state.map && state.map.content_bbox);
    if (cb) return cb;
    var roads = (state && state.roads) ? state.roads : [];
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (var i = 0; i < roads.length; i++) {
      var mk = roads[i].mark;
      if (mk && mk.crs && mk.crs.length >= 2) {
        var e = Number(mk.crs[0]), n = Number(mk.crs[1]);
        if (e < minX) minX = e; if (e > maxX) maxX = e;
        if (n < minY) minY = n; if (n > maxY) maxY = n;
      }
    }
    if (!isFinite(minX)) return imageBBox(state, zoomed);
    return [minX - 800, minY - 800, maxX + 800, maxY + 800];
  }

  function expandToAspect(b, aspect, pad) {
    pad = pad || 1;
    var cx = 0.5 * (b[0] + b[2]);
    var cy = 0.5 * (b[1] + b[3]);
    var w = (b[2] - b[0]) * pad;
    var h = (b[3] - b[1]) * pad;
    if (w / h < aspect) w = h * aspect;
    else h = w / aspect;
    return [cx - w * 0.5, cy - h * 0.5, cx + w * 0.5, cy + h * 0.5];
  }

  function clampView(view, imgB) {
    if (!imgB) return view;
    var w = view[2] - view[0];
    var h = view[3] - view[1];
    var iw = imgB[2] - imgB[0];
    var ih = imgB[3] - imgB[1];
    var out = view.slice();
    if (w >= iw) {
      out[0] = imgB[0];
      out[2] = imgB[2];
    } else {
      if (out[0] < imgB[0]) { out[0] = imgB[0]; out[2] = imgB[0] + w; }
      if (out[2] > imgB[2]) { out[2] = imgB[2]; out[0] = imgB[2] - w; }
    }
    if (h >= ih) {
      out[1] = imgB[1];
      out[3] = imgB[3];
    } else {
      if (out[1] < imgB[1]) { out[1] = imgB[1]; out[3] = imgB[1] + h; }
      if (out[3] > imgB[3]) { out[3] = imgB[3]; out[1] = imgB[3] - h; }
    }
    return out;
  }

  function viewBBox(state, canvasW, canvasH, zoomed) {
    var content = contentBBox(state, zoomed);
    var imgB = imageBBox(state, zoomed);
    if (!content) return imgB;
    var aspect = Math.max(0.2, canvasW / Math.max(1, canvasH));
    return clampView(expandToAspect(content, aspect, 1.08), imgB || content);
  }

  function inBBox(crs, b) {
    if (!crs || !b) return false;
    return crs[0] >= b[0] && crs[0] <= b[2] && crs[1] >= b[1] && crs[1] <= b[3];
  }

  function iconDir(state) {
    var d = state && state.map && state.map.icons && state.map.icons.dir;
    return d ? String(d).replace(/\/$/, '') : '/ui/modules/apps/alpineRtTrafficMap/icons';
  }

  function pickMark(road, state, zoomed) {
    if (zoomed && state.level && road.marks_by_level && road.marks_by_level[state.level]) {
      return road.marks_by_level[state.level];
    }
    return road.mark;
  }

  function hideOnCurrentMap(mark, state, zoomed) {
    if (zoomed || !mark || !mark.crs) return false;
    var rec = levelRec(state);
    var home = asBBox(rec && rec.content_bbox) || asBBox(rec && rec.bbox);
    return inBBox(mark.crs, home);
  }

  function unit2(x, y) {
    var len = Math.sqrt(x * x + y * y);
    if (len < 1e-9) return [1, 0];
    return [x / len, y / len];
  }

  function drawLane(ctx, cx, cy, hx, hy, lengthPx, color) {
    var u = unit2(hx, hy);
    hx = u[0]; hy = u[1];
    var hl = (lengthPx || 28) * 0.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(cx - hx * hl, cy - hy * hl);
    ctx.lineTo(cx + hx * hl, cy + hy * hl);
    ctx.strokeStyle = 'rgba(0,0,0,0.55)';
    ctx.lineWidth = 5.5;
    ctx.globalAlpha = 0.55;
    ctx.stroke();
    ctx.strokeStyle = color;
    ctx.lineWidth = 3.2;
    ctx.globalAlpha = 0.95;
    ctx.stroke();
    ctx.globalAlpha = 1.0;
  }

  function drawCarriageway(ctx, toXY, road, state) {
    var mark = pickMark(road, state, state._zoomed);
    if (!mark || !mark.crs || mark.crs.length < 2) return;
    if (hideOnCurrentMap(mark, state, state._zoomed)) return;
    var origin = toXY(Number(mark.crs[0]), Number(mark.crs[1]));
    var hd = mark.heading || [1, 0];
    var tip = toXY(Number(mark.crs[0]) + Number(hd[0] || 0), Number(mark.crs[1]) + Number(hd[1] || 0));
    var u = unit2(tip[0] - origin[0], tip[1] - origin[1]);
    var hx = u[0], hy = u[1];
    var rx = -hy, ry = hx;
    var side = (state.map && state.map.driving_side) ? String(state.map.driving_side).toLowerCase() : 'right';
    if (side === 'left') { rx = -rx; ry = -ry; }
    var half = Number(mark.gap_px || 7) * 0.5;
    var lengthPx = Number(mark.length_px || 28);
    if (road.a) {
      drawLane(ctx, origin[0] + rx * half, origin[1] + ry * half, hx, hy, lengthPx, colFor(road.a.density));
    }
    if (road.b) {
      drawLane(ctx, origin[0] - rx * half, origin[1] - ry * half, -hx, -hy, lengthPx, colFor(road.b.density));
    }
  }

  function drawIcon(ctx, img, x, y, size) {
    if (!img) return;
    ctx.drawImage(img, x, y, size, size);
  }

  function drawStackAt(ctx, toXY, crs, node, state, onReady) {
    if (!crs || crs.length < 2) return;
    var origin = toXY(Number(crs[0]), Number(crs[1]));
    var cfg = (state.map && state.map.icons) || {};
    var local = node.icons || {};
    var size = Number(local.size_px != null ? local.size_px : (cfg.size_px || 36));
    var gap = Number(local.stack_gap_px != null ? local.stack_gap_px : (cfg.stack_gap_px || 4));
    var off = local.offset_px || cfg.offset_px || [0, -8];
    var cx = origin[0] + Number(off[0] || 0);
    var cy = origin[1] + Number(off[1] || 0);
    var dir = iconDir(state);
    var weather = node.weather || 'sun';
    var traffic = node.traffic || 'clear';
    var weatherImg = loadImg(dir + '/weather_' + weather + '.png', onReady);
    var trafficImg = loadImg(dir + '/traffic_' + traffic + '.png', onReady);
    var topY = cy - gap * 0.5 - size;
    var botY = cy + gap * 0.5;
    var x = cx - size * 0.5;
    ctx.fillStyle = 'rgba(18,20,24,0.45)';
    ctx.beginPath();
    if (ctx.roundRect) ctx.roundRect(x - 2, topY - 2, size + 4, size * 2 + gap + 4, 4);
    else ctx.rect(x - 2, topY - 2, size + 4, size * 2 + gap + 4);
    ctx.fill();
    drawIcon(ctx, weatherImg, x, topY, size);
    if (node.alert) {
      var badge = loadImg(dir + '/weather_alert.png', onReady);
      var bs = Math.max(14, Math.round(size * 0.45));
      drawIcon(ctx, badge, x + size - bs + 2, topY - 2, bs);
    }
    drawIcon(ctx, trafficImg, x, botY, size);
  }

  function draw(canvas, state, onImgReady) {
    if (!canvas) return;
    var ctx = canvas.getContext('2d');
    if (!ctx) return;

    var w = canvas.clientWidth || 10;
    var h = canvas.clientHeight || 10;
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = 'rgba(0,0,0,0.18)';
    ctx.fillRect(0, 0, w, h);

    var roads = (state && state.roads) ? state.roads : [];
    if (state && state.error && !roads.length) {
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.font = '12px system-ui, sans-serif';
      ctx.fillText(String(state.error), 12, 22);
      return;
    }

    var zoomed = !!(state && state._zoomed);
    var rec = zoomed ? levelRec(state) : null;
    var imgB = imageBBox(state, zoomed);
    var view = viewBBox(state, w, h, zoomed);
    if (!view) {
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.font = '12px system-ui, sans-serif';
      ctx.fillText('Map bounds invalid.', 12, 22);
      return;
    }

    var spanX = view[2] - view[0];
    var spanY = view[3] - view[1];
    var imgUrl = (rec && rec.image) ? String(rec.image) : (state.map && state.map.image ? String(state.map.image) : '');
    var img = loadImg(imgUrl, onImgReady);
    if (img && img.naturalWidth > 0 && img.naturalHeight > 0 && imgB) {
      var iw = img.naturalWidth;
      var ih = img.naturalHeight;
      var sx = (view[0] - imgB[0]) / (imgB[2] - imgB[0]) * iw;
      var sy = (imgB[3] - view[3]) / (imgB[3] - imgB[1]) * ih;
      var sw = (view[2] - view[0]) / (imgB[2] - imgB[0]) * iw;
      var sh = (view[3] - view[1]) / (imgB[3] - imgB[1]) * ih;
      ctx.drawImage(img, sx, sy, sw, sh, 0, 0, w, h);
    } else {
      ctx.fillStyle = 'rgba(255,255,255,0.04)';
      ctx.fillRect(0, 0, w, h);
    }

    function toXY(e, n) {
      var u = (e - view[0]) / spanX;
      var v = (n - view[1]) / spanY;
      return [u * w, (1.0 - v) * h];
    }

    ctx.strokeStyle = 'rgba(255,255,255,0.06)';
    ctx.lineWidth = 1;
    ctx.strokeRect(0.5, 0.5, w - 1, h - 1);

    for (var k = 0; k < roads.length; k++) {
      drawCarriageway(ctx, toXY, roads[k], state);
    }
    var nodes = (state && state.maps) ? state.maps : [];
    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n];
      if (!node || node.id === state.level) continue;
      if (!node.crs || node.crs.length < 2) continue;
      drawStackAt(ctx, toXY, node.crs, node, state, onImgReady);
    }
  }

  return {
    template: tpl,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      scope.state = { level: null, roads: [], setup: { open_returns: [] } };
      scope.zoomed = false;
      scope.panel = null;
      scope.note = '';
      scope.form = { name: '', lat: '', lon: '' };
      scope.levelQuery = '';
      scope.levels = [];

      function luaQuote(s) {
        return "'" + String(s == null ? '' : s).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
      }

      function callLua(expr, done) {
        if (!window.bngApi || !bngApi.engineLua) {
          scope.note = 'Game link missing';
          return;
        }
        bngApi.engineLua("pcall(extensions.load, 'alpinert')", function () {
          bngApi.engineLua(expr, function (res) {
            scope.$evalAsync(function () {
              if (done) done(res);
            });
          });
        });
      }

      scope.filteredLevels = function () {
        var q = String(scope.levelQuery || '').toLowerCase();
        var rows = scope.levels || [];
        if (!q) return rows;
        var out = [];
        for (var i = 0; i < rows.length; i++) {
          var r = rows[i];
          var hay = ((r.title || '') + ' ' + (r.id || '')).toLowerCase();
          if (hay.indexOf(q) >= 0) out.push(r);
        }
        return out;
      };

      scope.openDefine = function () {
        scope.panel = scope.panel === 'define' ? null : 'define';
        scope.note = '';
        var s = scope.state && scope.state.setup;
        if (s) {
          if (s.name) scope.form.name = s.name;
          if (s.lat != null) scope.form.lat = String(s.lat);
          if (s.lon != null) scope.form.lon = String(s.lon);
        }
      };

      scope.saveLocation = function (cardinal) {
        var lat = Number(scope.form.lat);
        var lon = Number(scope.form.lon);
        if (String(scope.form.lat).trim() === '' || String(scope.form.lon).trim() === '' || !isFinite(lat) || !isFinite(lon)) {
          scope.note = 'Latitude and longitude are required.';
          return;
        }
        var expr = 'extensions.alpinert.defineLocation('
          + luaQuote(scope.form.name) + ',' + lat + ',' + lon + ',' + luaQuote(cardinal) + ')';
        callLua(expr, function (res) {
          scope.note = (res && res.ok) ? ('Saved in ' + (res.authority || 'map CRS')) : ((res && res.error) || 'Could not save the map');
          if (res && res.ok) scope.panel = null;
          poll();
        });
      };

      scope.openPortal = function () {
        scope.panel = scope.panel === 'portal' ? null : 'portal';
        scope.note = '';
        if (scope.panel !== 'portal') return;
        callLua('(extensions.alpinert and extensions.alpinert.listLevels()) or {}', function (rows) {
          scope.levels = rows || [];
          if (!scope.levels.length) scope.note = 'No other maps found';
        });
      };

      scope.choosePortal = function (lv) {
        if (!lv || !lv.id) return;
        callLua('extensions.alpinert.placePortal(' + luaQuote(lv.id) + ')', function (res) {
          scope.note = (res && res.ok) ? ('Portal to ' + (lv.title || lv.id)) : ((res && res.error) || 'Could not place the portal');
          if (res && res.ok) scope.panel = null;
          poll();
        });
      };

      scope.openReturn = function () {
        scope.panel = scope.panel === 'return' ? null : 'return';
        scope.note = '';
      };

      scope.chooseReturn = function (link) {
        if (!link || !link.id) return;
        callLua('extensions.alpinert.placeReturn(' + luaQuote(link.id) + ')', function (res) {
          scope.note = (res && res.ok) ? 'Return portal placed' : ((res && res.error) || 'Could not place the return portal');
          if (res && res.ok) scope.panel = null;
          poll();
        });
      };

      function canvasEl() {
        return element[0] && element[0].querySelector ? element[0].querySelector('canvas') : null;
      }

      function redraw() {
        var st = scope.state || {};
        st._zoomed = !!scope.zoomed;
        draw(canvasEl(), st, redraw);
      }

      function apply(d) {
        if (!d) return;
        scope.$evalAsync(function () {
          scope.state = d;
          scope.state._zoomed = !!scope.zoomed;
          redraw();
        });
      }

      scope.toggleZoom = function () {
        scope.zoomed = !scope.zoomed;
        scope.$evalAsync(redraw);
      };

      function poll() {
        if (!window.bngApi || !bngApi.engineLua) return;
        // engineLua expects a single Lua expression (no ';' or 'return'). Do load + poll in two calls.
        bngApi.engineLua("pcall(extensions.load, 'alpinert')", function () {
          bngApi.engineLua(
            "(extensions.alpinert and extensions.alpinert.getTrafficMap and extensions.alpinert.getTrafficMap()) "
            + "or { level = (getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil), segments = {}, error = 'alpinert extension not loaded' }",
            apply
          );
        });
      }

      scope.refresh = function () {
        poll();
      };

      try {
        if (window.bngApi && bngApi.engineLua) {
          bngApi.engineLua("extensions.load('alpinert')");
        }
      } catch (e) {}

      var timer = setInterval(poll, 1000);
      poll();

      // Redraw on size changes (simple periodic check).
      var lastW = 0, lastH = 0;
      var sizeTimer = setInterval(function () {
        var c = canvasEl(); if (!c) return;
        var w = c.clientWidth || 0, h = c.clientHeight || 0;
        if (w !== lastW || h !== lastH) {
          lastW = w; lastH = h;
          redraw();
        }
      }, 700);

      scope.$on('$destroy', function () {
        clearInterval(timer);
        clearInterval(sizeTimer);
      });
    }
  };
}]);

