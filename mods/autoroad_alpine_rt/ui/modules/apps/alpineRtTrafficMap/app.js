// Alpine Roadtrip Map (Traffic Overlay)
// UI App: renders a simple map-like polyline view with low/medium/high traffic colouring.
angular.module('beamng.apps').directive('alpinerttrafficmap', [function () {
  var tpl = ''
    + '<div class="artm" ng-class="{collapsed: collapsed}">'
    + '  <style>'
    + '  .artm{font-family:"Cairo","Overpass",system-ui,sans-serif;color:#dfe2e6;background:rgba(18,20,24,0.90);'
    + '       border:1px solid rgba(255,255,255,0.07);border-top:2px solid #ff6600;border-radius:5px;'
    + '       height:100%;width:100%;box-sizing:border-box;display:flex;flex-direction:column;'
    + '       overflow:hidden;backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);}'
    + '  .artm *{box-sizing:border-box;}'
    + '  .artm.collapsed{height:auto;background:transparent;border-color:transparent;backdrop-filter:none;-webkit-backdrop-filter:none;}'
    + '  .artm.collapsed .artm-head{background:rgba(18,20,24,0.92);border:1px solid rgba(255,255,255,0.07);'
    + '            border-top:2px solid #ff6600;border-radius:5px;pointer-events:auto;}'
    + '  .artm.collapsed .artm-sub,.artm.collapsed .artm-body{display:none;}'
    + '  .artm-head{display:flex;align-items:center;justify-content:space-between;padding:10px 11px;'
    + '            border-bottom:1px solid rgba(255,255,255,0.06);pointer-events:auto;}'
    + '  .artm-brand{display:flex;align-items:center;min-width:0;}'
    + '  .artm-slash{width:6px;height:16px;background:#ff6600;transform:skewX(-16deg);margin-right:9px;flex:none;}'
    + '  .artm-title{font-style:italic;font-weight:800;font-size:13px;letter-spacing:.3px;color:#f4f6f8;white-space:nowrap;}'
    + '  .artm-sub{padding:7px 11px 0;color:#8b9198;font-size:11px;display:flex;flex-wrap:wrap;}'
    + '  .artm-sub span{margin:0 10px 4px 0;}'
    + '  .artm-sub b{color:#dfe2e6;font-weight:700;}'
    + '  .artm-body{padding:10px 11px 11px;display:flex;flex-direction:column;gap:8px;flex:1;min-height:0;overflow:hidden;}'
    + '  .artm-can{display:block;width:100%;flex:1 1 0;min-height:72px;border:1px solid rgba(255,255,255,0.08);border-radius:4px;background:rgba(0,0,0,0.18);cursor:grab;}'
    + '  .artm-can.edit{cursor:crosshair;}'
    + '  .artm-can.panning{cursor:grabbing;}'
    + '  .artm-panel{flex:0 1 auto;min-height:0;max-height:52%;overflow:auto;display:flex;flex-direction:column;gap:6px;}'
    + '  .artm-leg{display:flex;align-items:center;gap:10px;font-size:11px;color:#9aa3ae;}'
    + '  .artm-dot{width:9px;height:9px;border-radius:2px;display:inline-block;margin-right:6px;transform:skewX(-12deg);}'
    + '  .artm-row{display:flex;align-items:center;justify-content:space-between;gap:10px;flex:none;}'
    + '  .artm-btn{font-family:inherit;font-size:11px;font-weight:700;letter-spacing:.5px;border-radius:3px;padding:7px 10px;'
    + '           cursor:pointer;border:1px solid rgba(255,255,255,0.11);background:rgba(255,255,255,0.06);color:#dfe2e6;transition:all .12s;margin-left:6px;}'
    + '  .artm-btn:hover{background:rgba(255,255,255,0.12);}'
    + '  .artm-btn.on{background:rgba(255,102,0,0.28);border-color:rgba(255,102,0,0.55);color:#fff;}'
    + '  .artm-btn:disabled{opacity:0.4;cursor:default;}'
    + '  .artm-tools{display:flex;flex-wrap:wrap;gap:6px;flex:none;}'
    + '  .artm-tools .artm-btn{margin-left:0;}'
    + '  .artm-select{font:inherit;font-size:11px;font-weight:700;padding:6px 8px;border-radius:3px;'
    + '       border:1px solid rgba(255,255,255,0.11);background:rgba(0,0,0,0.28);color:#dfe2e6;}'
    + '  .artm-panel input{font:inherit;font-size:12px;padding:6px 8px;border-radius:3px;'
    + '       border:1px solid rgba(255,255,255,0.12);background:rgba(0,0,0,0.28);color:#dfe2e6;width:100%;}'
    + '  .artm-q{font-size:11px;color:#c5cad1;line-height:1.35;}'
    + '  .artm-note{font-size:11px;color:#ffb020;line-height:1.35;flex:none;}'
    + '  .artm-list{max-height:132px;overflow:auto;display:flex;flex-direction:column;gap:4px;}'
    + '  .artm-item{font:inherit;font-size:12px;text-align:left;padding:6px 8px;border-radius:3px;cursor:pointer;'
    + '       border:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.04);color:#dfe2e6;}'
    + '  .artm-item:hover{background:rgba(255,102,0,0.18);}'
    + '  .artm-item small{display:block;color:#8b9198;font-size:10px;}'
    + '  </style>'
    + '  <div class="artm-head">'
    + '    <div class="artm-brand"><span class="artm-slash"></span><span class="artm-title">ALPINE ROADTRIP MAP</span></div>'
    + '    <div>'
    + '      <button class="artm-btn" ng-click="toggleCollapse()">{{collapsed ? "Show" : "Hide"}}</button>'
    + '      <button class="artm-btn" ng-click="toggleZoom()" ng-if="!collapsed">{{zoomed ? "Overview" : "Zoom"}}</button>'
    + '      <button class="artm-btn" ng-click="refresh()" ng-if="!collapsed">Refresh</button>'
    + '    </div>'
    + '  </div>'
    + '  <div class="artm-sub">'
    + '    <span>Level <b>{{currentLevel()}}</b></span>'
    + '    <span ng-if="state.lua_rev">Lua <b>{{state.lua_rev}}</b></span>'
    + '    <span ng-if="state.roads">Roads <b>{{state.roads.length}}</b></span>'
    + '    <span ng-if="editLine && editLabel">{{editLabel}}. Drag an orange midpoint. Right-click removes a point.</span>'
    + '    <span ng-if="editLine && !editLabel">Pick a route in Region Setup, or click its line.</span>'
    + '    <span ng-if="!editLine && !zoomed">Drag to pan. Wheel zooms.</span>'
    + '  </div>'
    + '  <div class="artm-body">'
    + '    <div class="artm-note" ng-if="note">{{note}}</div>'
    + '    <canvas class="artm-can" ng-class="{edit: editLine}"></canvas>'
    + '    <div class="artm-row">'
    + '      <div class="artm-leg">weather + traffic</div>'
    + '      <div style="font-size:11px;color:#7a8088">'
    + '        <span ng-if="regionLabel">{{regionLabel}}</span>'
    + '        <span ng-if="!regionLabel && state.map.attribution">{{state.map.attribution}}</span>'
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
    var box = asBBox(state && state.map && state.map.content_bbox);
    function include(e, n) {
      if (!isFinite(e) || !isFinite(n)) return;
      if (!box) box = [e, n, e, n];
      if (e < box[0]) box[0] = e;
      if (n < box[1]) box[1] = n;
      if (e > box[2]) box[2] = e;
      if (n > box[3]) box[3] = n;
    }
    var roads = (state && state.roads) ? state.roads : [];
    for (var i = 0; i < roads.length; i++) {
      var mk = roads[i].mark;
      if (mk && mk.crs && mk.crs.length >= 2) include(Number(mk.crs[0]), Number(mk.crs[1]));
      var route = roads[i].route;
      if (route) {
        for (var r = 0; r < route.length; r++) {
          var p = route[r];
          if (p && p.length >= 2) include(Number(p[0]), Number(p[1]));
        }
      }
    }
    var nodes = (state && state.maps) ? state.maps : [];
    for (var n = 0; n < nodes.length; n++) {
      var node = nodes[n];
      if (node && node.crs && node.crs.length >= 2) include(Number(node.crs[0]), Number(node.crs[1]));
    }
    if (!box) return imageBBox(state, zoomed);
    return box;
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

  function authoredBBox(state) {
    return asBBox(state && state.map && state.map.content_bbox)
      || asBBox(state && state.map && state.map.bbox);
  }

  function viewBBox(state, canvasW, canvasH, zoomed, clampB) {
    var imgB = clampB || imageBBox(state, zoomed);
    if (!zoomed && glance) return clampView(glance, imgB || glance);
    var content = zoomed ? contentBBox(state, true) : (authoredBBox(state) || contentBBox(state, false));
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

  function drawLane(ctx, cx, cy, hx, hy, lengthPx, color, scale) {
    scale = scale || 1;
    var u = unit2(hx, hy);
    hx = u[0]; hy = u[1];
    var hl = (lengthPx || 28) * 0.5;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(cx - hx * hl, cy - hy * hl);
    ctx.lineTo(cx + hx * hl, cy + hy * hl);
    ctx.strokeStyle = 'rgba(0,0,0,0.55)';
    ctx.lineWidth = 5.5 * scale;
    ctx.globalAlpha = 0.55;
    ctx.stroke();
    ctx.strokeStyle = color;
    ctx.lineWidth = 3.2 * scale;
    ctx.globalAlpha = 0.95;
    ctx.stroke();
    ctx.globalAlpha = 1.0;
  }

  function offsetPoly(pts, dist) {
    var out = [];
    for (var i = 0; i < pts.length; i++) {
      var prev = pts[Math.max(0, i - 1)];
      var next = pts[Math.min(pts.length - 1, i + 1)];
      var u = unit2(next[0] - prev[0], next[1] - prev[1]);
      var rx = -u[1];
      var ry = u[0];
      out.push([pts[i][0] + rx * dist, pts[i][1] + ry * dist]);
    }
    return out;
  }

  function strokePoly(ctx, pts, color, scale) {
    if (!pts || pts.length < 2) return;
    scale = scale || 1;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.beginPath();
    ctx.moveTo(pts[0][0], pts[0][1]);
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
    ctx.strokeStyle = 'rgba(0,0,0,0.55)';
    ctx.lineWidth = 6.5 * scale;
    ctx.globalAlpha = 0.4;
    ctx.stroke();
    ctx.strokeStyle = color;
    ctx.lineWidth = 3.6 * scale;
    ctx.globalAlpha = 0.95;
    ctx.stroke();
    ctx.globalAlpha = 1.0;
  }

  function drawRouteLanes(ctx, toXY, road, state) {
    var route = road.route;
    if (!route || route.length < 2) return false;
    var pts = [];
    for (var i = 0; i < route.length; i++) {
      var p = route[i];
      if (!p || p.length < 2) continue;
      pts.push(toXY(Number(p[0]), Number(p[1])));
    }
    if (pts.length < 2) return false;
    var side = (state.map && state.map.driving_side) ? String(state.map.driving_side).toLowerCase() : 'right';
    var flip = side === 'left' ? -1 : 1;
    var scale = Number(state && state._laneScale) || 1;
    var half = 3.5 * scale;
    if (road.a) strokePoly(ctx, offsetPoly(pts, half * flip), colFor(road.a.density), scale);
    if (road.b) strokePoly(ctx, offsetPoly(pts, -half * flip), colFor(road.b.density), scale);
    return true;
  }

  function drawCarriageway(ctx, toXY, road, state) {
    if (drawRouteLanes(ctx, toXY, road, state)) return;
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
    var scale = Number(state && state._laneScale) || 1;
    var half = Number(mark.gap_px || 7) * 0.5 * scale;
    var lengthPx = Number(mark.length_px || 28) * scale;
    if (road.a) {
      drawLane(ctx, origin[0] + rx * half, origin[1] + ry * half, hx, hy, lengthPx, colFor(road.a.density), scale);
    }
    if (road.b) {
      drawLane(ctx, origin[0] - rx * half, origin[1] - ry * half, -hx, -hy, lengthPx, colFor(road.b.density), scale);
    }
  }

  function drawPortalMark(ctx, x, y, discovered) {
    var s = 7;
    ctx.beginPath();
    ctx.moveTo(x, y - s);
    ctx.lineTo(x + s * 0.72, y);
    ctx.lineTo(x, y + s);
    ctx.lineTo(x - s * 0.72, y);
    ctx.closePath();
    ctx.fillStyle = discovered ? '#e6c15a' : '#e85d4c';
    ctx.strokeStyle = 'rgba(0,0,0,0.7)';
    ctx.lineWidth = 2;
    ctx.fill();
    ctx.stroke();
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

  var MERCATOR = 20037508.342789244;
  var WMTS_PROVIDERS = [
    {
      id: 'local',
      title: 'Local',
      ext: 'png',
      attribution: 'Datenquelle: basemap.at · © swisstopo · © GeoBasis-DE / BKG · © Bayerische Vermessungsverwaltung · © IGM'
    },
    {
      id: 'geoland-aerial',
      title: 'Orthophoto',
      ext: 'jpeg',
      attribution: 'Datenquelle: basemap.at'
    },
    {
      id: 'geoland-terrain',
      title: 'Terrain',
      ext: 'jpeg',
      attribution: 'Datenquelle: basemap.at'
    },
    {
      id: 'osm',
      title: 'OSM',
      ext: 'png',
      attribution: '© OpenStreetMap contributors'
    }
  ];
  var region = { key: '', gen: 0, canvas: null, bbox: null };
  var frame = null;
  var glance = null;

  function providerById(id) {
    if (id === 'geoland') id = 'local';
    for (var i = 0; i < WMTS_PROVIDERS.length; i++) {
      if (WMTS_PROVIDERS[i].id === id) return WMTS_PROVIDERS[i];
    }
    return WMTS_PROVIDERS[0];
  }

  function mercatorToLonLat(x, y) {
    var lon = x / MERCATOR * 180;
    var lat = (2 * Math.atan(Math.exp((y / MERCATOR) * Math.PI)) - Math.PI / 2) * 180 / Math.PI;
    return [lon, lat];
  }

  function lonLatToTile(lon, lat, z) {
    var n = Math.pow(2, z);
    lat = Math.max(-85.05112878, Math.min(85.05112878, lat));
    var tx = Math.floor((lon + 180) / 360 * n);
    var latRad = lat * Math.PI / 180;
    var ty = Math.floor((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2 * n);
    var n1 = n - 1;
    return [Math.max(0, Math.min(n1, tx)), Math.max(0, Math.min(n1, ty))];
  }

  function tileWindow(bbox, z) {
    var sw = mercatorToLonLat(bbox[0], bbox[1]);
    var ne = mercatorToLonLat(bbox[2], bbox[3]);
    var nw = lonLatToTile(sw[0], ne[1], z);
    var se = lonLatToTile(ne[0], sw[1], z);
    return { z: z, x0: Math.min(nw[0], se[0]), y0: Math.min(nw[1], se[1]), x1: Math.max(nw[0], se[0]), y1: Math.max(nw[1], se[1]) };
  }

  function chooseZoom(bbox) {
    var best = 6;
    // fetch_region_tiles.py writes z=10. A finer zoom has no files and the picture stays blank.
    for (var z = 6; z <= 10; z++) {
      var win = tileWindow(bbox, z);
      var n = (win.x1 - win.x0 + 1) * (win.y1 - win.y0 + 1);
      if (n <= 96) best = z;
      else break;
    }
    return best;
  }

  function tileBounds(win) {
    var n = Math.pow(2, win.z);
    var tile = (2 * MERCATOR) / n;
    var left = -MERCATOR + win.x0 * tile;
    var top = MERCATOR - win.y0 * tile;
    var right = -MERCATOR + (win.x1 + 1) * tile;
    var bottom = MERCATOR - (win.y1 + 1) * tile;
    return [left, bottom, right, top];
  }

  function regionExtent(state, zoomed) {
    var content = contentBBox(state, zoomed);
    var img = imageBBox(state, zoomed);
    var box = content || img;
    if (content && img) {
      box = [
        Math.min(content[0], img[0]),
        Math.min(content[1], img[1]),
        Math.max(content[2], img[2]),
        Math.max(content[3], img[3])
      ];
    }
    if (!box) return null;
    var dx = Math.max(400, (box[2] - box[0]) * 0.04);
    var dy = Math.max(400, (box[3] - box[1]) * 0.04);
    return [box[0] - dx, box[1] - dy, box[2] + dx, box[3] + dy];
  }

  function extentKey(box) {
    var out = [];
    for (var i = 0; i < 4; i++) out.push(Math.round(box[i] / 100));
    return out.join(',');
  }

  function asList(rows) {
    if (!rows) return [];
    if (Object.prototype.toString.call(rows) === '[object Array]') return rows;
    if (typeof rows !== 'object') return [];
    var keys = Object.keys(rows).filter(function (k) { return /^\d+$/.test(k); });
    keys.sort(function (a, b) { return Number(a) - Number(b); });
    var out = [];
    for (var i = 0; i < keys.length; i++) out.push(rows[keys[i]]);
    return out;
  }

  function requestRegion(scope, force) {
    var st = scope.state;
    if (!st || !st.map || st.map.crs !== 'EPSG:3857') return;
    if (!window.bngApi || !bngApi.engineLua) return;
    var extent = regionExtent(st, false);
    if (!extent) return;
    var view = st.view || {};
    var provider = providerById(view.provider);
    var rev = Number(view.redraw) || 0;
    var key = provider.id + '|' + rev + '|' + extentKey(extent);
    if (!force && region.key === key) return;
    var win = tileWindow(extent, chooseZoom(extent));
    var cols = win.x1 - win.x0 + 1;
    var rows = win.y1 - win.y0 + 1;
    if (cols < 1 || rows < 1 || cols * rows > 96) return;
    region.key = key;
    var gen = ++region.gen;
    if (region.poll) {
      clearInterval(region.poll);
      region.poll = null;
    }
    var files = [];
    var ext = provider.ext || 'png';
    for (var ty = win.y0; ty <= win.y1; ty++) {
      for (var tx = win.x0; tx <= win.x1; tx++) {
        files.push({
          x: tx,
          y: ty,
          ok: true,
          path: '/ui/modules/apps/alpineRtTrafficMap/tilecache/' + provider.id + '/' + win.z + '/' + tx + '/' + ty + '.' + ext
        });
      }
    }
    paintTiles(scope, gen, {
      files: files,
      error: 'Region tiles are not in the mod. Run tools/fetch_region_tiles.py.'
    }, win, provider, key, false, st);
  }

  function paintTiles(scope, gen, job, win, provider, key, zoomed, st) {
    var files = asList(job && job.files);
    var byPos = {};
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      if (f && f.ok && f.path) byPos[f.x + ',' + f.y] = String(f.path);
    }
    var ts = 256;
    var cols = win.x1 - win.x0 + 1;
    var rows = win.y1 - win.y0 + 1;
    var off = document.createElement('canvas');
    off.width = cols * ts;
    off.height = rows * ts;
    var ctx = off.getContext('2d');
    ctx.fillStyle = '#d8d4cc';
    ctx.fillRect(0, 0, off.width, off.height);
    var pending = cols * rows;
    var got = 0;
    function finish() {
      if (gen !== region.gen) return;
      region.canvas = off;
      region.bbox = tileBounds(win);
      region.key = key;
      scope.$evalAsync(function () {
        scope.regionLabel = provider.attribution + (got ? (' · z' + win.z) : '');
        scope.note = got ? '' : ((job && job.error) || 'Region map: no tiles loaded');
        if (scope.redrawMap) scope.redrawMap();
      });
    }
    function one() {
      if (gen !== region.gen) return;
      pending--;
      if (pending <= 0) finish();
    }
    for (var ty = win.y0; ty <= win.y1; ty++) {
      for (var tx = win.x0; tx <= win.x1; tx++) {
        (function (tx, ty) {
          var path = byPos[tx + ',' + ty];
          if (!path) {
            one();
            return;
          }
          var img = new Image();
          img.onload = function () {
            if (gen !== region.gen) return;
            ctx.drawImage(img, (tx - win.x0) * ts, (ty - win.y0) * ts, ts, ts);
            got++;
            one();
          };
          img.onerror = function () { one(); };
          img.src = path;
        })(tx, ty);
      }
    }
  }

  function isEditableRoad(road) {
    return !!(road && (road.editable || road.user || String(road.id || '').indexOf('user:') === 0));
  }

  function roadKey(road) {
    var ends = road && road.ends;
    if (!ends || ends.length < 2 || !ends[0] || !ends[1]) return '';
    return String(ends[0]) + '|' + String(ends[1]);
  }

  function routePts(road) {
    var route = road && road.route;
    var pts = [];
    if (!route) return pts;
    for (var i = 0; i < route.length; i++) {
      var p = route[i];
      if (p && p.length >= 2 && isFinite(Number(p[0])) && isFinite(Number(p[1]))) {
        pts.push([Number(p[0]), Number(p[1])]);
      }
    }
    return pts;
  }

  function drawDot(ctx, x, y, r, fill, stroke) {
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = fill;
    ctx.fill();
    if (stroke) {
      ctx.lineWidth = 2;
      ctx.strokeStyle = stroke;
      ctx.stroke();
    }
  }

  function drawLineHandles(ctx, toXY, roads, selected) {
    if (!roads) return;
    ctx.save();
    for (var r = 0; r < roads.length; r++) {
      var road = roads[r];
      if (!isEditableRoad(road)) continue;
      var crs = routePts(road);
      if (crs.length < 2) continue;
      var active = !!selected && roadKey(road) === selected;
      var pts = [];
      for (var i = 0; i < crs.length; i++) pts.push(toXY(crs[i][0], crs[i][1]));
      ctx.beginPath();
      ctx.moveTo(pts[0][0], pts[0][1]);
      for (var k = 1; k < pts.length; k++) ctx.lineTo(pts[k][0], pts[k][1]);
      ctx.setLineDash([5, 4]);
      ctx.lineWidth = active ? 1.5 : 1;
      ctx.strokeStyle = active ? 'rgba(255,255,255,0.9)' : 'rgba(255,176,64,0.75)';
      ctx.stroke();
      ctx.setLineDash([]);
      if (!active) continue;
      for (var s = 0; s < pts.length - 1; s++) {
        drawDot(ctx, (pts[s][0] + pts[s + 1][0]) * 0.5, (pts[s][1] + pts[s + 1][1]) * 0.5, 5, '#ff6600', 'rgba(0,0,0,0.65)');
      }
      for (var v = 1; v < pts.length - 1; v++) {
        drawDot(ctx, pts[v][0], pts[v][1], 6.5, '#f4f6f8', '#ff6600');
      }
    }
    ctx.restore();
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
    var baked = region.canvas && region.bbox;
    var imgB = baked ? region.bbox : imageBBox(state, zoomed);
    var view = viewBBox(state, w, h, zoomed, baked ? region.bbox : null);
    if (!view) {
      frame = null;
      ctx.fillStyle = 'rgba(255,255,255,0.55)';
      ctx.font = '12px system-ui, sans-serif';
      ctx.fillText('Map bounds invalid.', 12, 22);
      return;
    }
    frame = { view: view.slice(), w: w, h: h };

    var spanX = view[2] - view[0];
    var spanY = view[3] - view[1];
    var webMerc = state && state.map && state.map.crs === 'EPSG:3857';
    var img = baked ? region.canvas : null;
    if (!img && !webMerc) {
      var imgUrl = (rec && rec.image) ? String(rec.image) : (state.map && state.map.image ? String(state.map.image) : '');
      img = loadImg(imgUrl, onImgReady);
    }
    var iw = img ? (img.naturalWidth || img.width) : 0;
    var ih = img ? (img.naturalHeight || img.height) : 0;
    if (img && iw > 0 && ih > 0 && imgB) {
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

    state._laneScale = 1;
    for (var k = 0; k < roads.length; k++) {
      drawCarriageway(ctx, toXY, roads[k], state);
    }
    if (state && state._editLine) drawLineHandles(ctx, toXY, roads, state._editKey || '');
    if (zoomed) {
      var marks = (state && state.gate_marks) ? state.gate_marks : [];
      for (var m = 0; m < marks.length; m++) {
        var mk = marks[m];
        if (!mk || !mk.crs || mk.crs.length < 2) continue;
        var xy = toXY(Number(mk.crs[0]), Number(mk.crs[1]));
        drawPortalMark(ctx, xy[0], xy[1], !!mk.discovered);
      }
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
      scope.state = { level: null, roads: [] };
      scope.zoomed = false;
      scope.note = '';
      scope.regionLabel = '';
      scope.collapsed = false;
      scope.editLine = false;
      scope.editKey = '';
      scope.editLabel = '';
      try { scope.collapsed = localStorage.getItem('alpineRtMapCollapsed') === '1'; } catch (e) {}

      function appHost() {
        var node = element[0];
        while (node) {
          if (node.classList && node.classList.contains('ui-app-host')) return node;
          node = node.parentElement;
        }
        return null;
      }

      function syncFrame() {
        var host = appHost();
        if (!host) return;
        host.style.pointerEvents = scope.collapsed ? 'none' : '';
      }

      scope.toggleCollapse = function () {
        scope.collapsed = !scope.collapsed;
        try { localStorage.setItem('alpineRtMapCollapsed', scope.collapsed ? '1' : '0'); } catch (e) {}
        syncFrame();
        if (!scope.collapsed) {
          requestAnimationFrame(function () {
            redraw();
            requestRegion(scope, false);
          });
        }
      };
      requestAnimationFrame(syncFrame);

      function canvasEl() {
        return element[0] && element[0].querySelector ? element[0].querySelector('canvas') : null;
      }

      var lineEdit = null;
      var lineHeld = null;
      var pan = null;

      function panLimits() {
        if (region.bbox) return region.bbox;
        var st = scope.state;
        return contentBBox(st, false) || imageBBox(st, false);
      }

      function zoomAbout(view, x, y, factor) {
        var spanX = view[2] - view[0];
        var spanY = view[3] - view[1];
        var nextX = spanX * factor;
        var nextY = spanY * factor;
        if (nextX < 20000 || nextY < 20000) return view.slice();
        var u = x / Math.max(1, frame.w);
        var v = 1 - y / Math.max(1, frame.h);
        var e = view[0] + u * spanX;
        var n = view[1] + v * spanY;
        return clampView([
          e - u * nextX,
          n - v * nextY,
          e + (1 - u) * nextX,
          n + (1 - v) * nextY
        ], panLimits());
      }

      function startPan(ev) {
        if (scope.zoomed || !frame || !frame.view) return;
        var xy = localXY(ev);
        pan = { pointerId: ev.pointerId, x: xy[0], y: xy[1], view: frame.view.slice() };
        var c = canvasEl();
        if (c) {
          if (c.setPointerCapture) {
            try { c.setPointerCapture(ev.pointerId); } catch (err) {}
          }
          c.classList.add('panning');
        }
      }

      function movePan(ev) {
        if (!pan || ev.pointerId !== pan.pointerId || !frame) return;
        var xy = localXY(ev);
        var spanX = pan.view[2] - pan.view[0];
        var spanY = pan.view[3] - pan.view[1];
        var east = -(xy[0] - pan.x) / Math.max(1, frame.w) * spanX;
        var north = (xy[1] - pan.y) / Math.max(1, frame.h) * spanY;
        glance = clampView([
          pan.view[0] + east,
          pan.view[1] + north,
          pan.view[2] + east,
          pan.view[3] + north
        ], panLimits());
        redraw();
      }

      function endPan(ev) {
        if (!pan || (ev && ev.pointerId !== pan.pointerId)) return;
        pan = null;
        var c = canvasEl();
        if (c) c.classList.remove('panning');
      }

      function onWheel(ev) {
        if (scope.collapsed || scope.zoomed || !frame || !frame.view) return;
        ev.preventDefault();
        var xy = localXY(ev);
        var factor = ev.deltaY > 0 ? 1.12 : (1 / 1.12);
        glance = zoomAbout(frame.view, xy[0], xy[1], factor);
        redraw();
      }

      function luaQuote(s) {
        return "'" + String(s == null ? '' : s).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
      }

      function localXY(ev) {
        var c = canvasEl();
        if (!c) return [0, 0];
        var rect = c.getBoundingClientRect();
        return [ev.clientX - rect.left, ev.clientY - rect.top];
      }

      function frameToXY(e, n) {
        var view = frame.view;
        var spanX = view[2] - view[0];
        var spanY = view[3] - view[1];
        return [(e - view[0]) / spanX * frame.w, (1 - (n - view[1]) / spanY) * frame.h];
      }

      function frameToCrs(x, y) {
        var view = frame.view;
        var spanX = view[2] - view[0];
        var spanY = view[3] - view[1];
        return [
          view[0] + (x / Math.max(1, frame.w)) * spanX,
          view[1] + (1 - y / Math.max(1, frame.h)) * spanY
        ];
      }

      function distPx(a, b) {
        var dx = a[0] - b[0];
        var dy = a[1] - b[1];
        return Math.sqrt(dx * dx + dy * dy);
      }

      function userRoadList() {
        var roads = (scope.state && scope.state.roads) || [];
        var out = [];
        for (var i = 0; i < roads.length; i++) {
          if (isEditableRoad(roads[i]) && roadKey(roads[i])) out.push(roads[i]);
        }
        return out;
      }

      function roadByKey(key) {
        if (!key) return null;
        var roads = userRoadList();
        for (var i = 0; i < roads.length; i++) {
          if (roadKey(roads[i]) === key) return roads[i];
        }
        return null;
      }

      function levelTitle(id) {
        var maps = asList(scope.state && scope.state.maps);
        for (var m = 0; m < maps.length; m++) {
          var title = maps[m] && maps[m].id === id && maps[m].title;
          title = String(title || '');
          if (title && title.indexOf('levels.') === -1 && title.indexOf('{{') === -1) return title;
        }
        var s = String(id || '').replace(/^autoroad_/, '').replace(/_\d+$/, '').replace(/_/g, ' ');
        if (!s) return String(id || '');
        return s.replace(/\b[a-z]/g, function (ch) { return ch.toUpperCase(); });
      }

      scope.currentLevel = function () {
        return levelTitle(scope.state && scope.state.level) || '-';
      };

      function routeLabel(key) {
        if (!key) return '';
        var cut = String(key).indexOf('|');
        if (cut < 0) return String(key);
        return levelTitle(key.slice(0, cut)) + ' – ' + levelTitle(key.slice(cut + 1));
      }

      function frameRoute(road) {
        var pts = routePts(road);
        if (pts.length < 2) return;
        var minE = pts[0][0];
        var maxE = minE;
        var minN = pts[0][1];
        var maxN = minN;
        for (var i = 1; i < pts.length; i++) {
          if (pts[i][0] < minE) minE = pts[i][0];
          if (pts[i][0] > maxE) maxE = pts[i][0];
          if (pts[i][1] < minN) minN = pts[i][1];
          if (pts[i][1] > maxN) maxN = pts[i][1];
        }
        var padE = Math.max(4000, (maxE - minE) * 0.18);
        var padN = Math.max(4000, (maxN - minN) * 0.18);
        var box = [minE - padE, minN - padN, maxE + padE, maxN + padN];
        var c = canvasEl();
        var aspect = (c && c.clientWidth && c.clientHeight) ? (c.clientWidth / c.clientHeight) : 1;
        box = expandToAspect(box, aspect, 1);
        if ((box[2] - box[0]) < 20000) {
          var cx = 0.5 * (box[0] + box[2]);
          box[0] = cx - 10000;
          box[2] = cx + 10000;
        }
        if ((box[3] - box[1]) < 20000) {
          var cy = 0.5 * (box[1] + box[3]);
          box[1] = cy - 10000;
          box[3] = cy + 10000;
        }
        var limits = panLimits();
        glance = clampView(box, limits || box);
      }

      function syncEditSelection(preferKey, frameIfNew) {
        var prev = scope.editKey || '';
        if (preferKey) scope.editKey = String(preferKey);
        var roads = userRoadList();
        if (!roadByKey(scope.editKey)) {
          if (roads.length === 1 && !preferKey) scope.editKey = roadKey(roads[0]);
          else if (roads.length > 0) scope.editKey = '';
        }
        scope.editLabel = scope.editLine ? routeLabel(scope.editKey) : '';
        if (frameIfNew && !pan && !lineEdit && scope.editKey && scope.editKey !== prev) {
          var picked = roadByKey(scope.editKey);
          if (picked) frameRoute(picked);
        }
      }

      function distToSeg(p, a, b) {
        var dx = b[0] - a[0];
        var dy = b[1] - a[1];
        var len2 = dx * dx + dy * dy;
        if (len2 < 1) return distPx(p, a);
        var t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        return distPx(p, [a[0] + t * dx, a[1] + t * dy]);
      }

      function hitRoadLine(xy) {
        var roads = userRoadList();
        var best = null;
        var bestD = 12;
        for (var r = 0; r < roads.length; r++) {
          var pts = routePts(roads[r]);
          if (pts.length < 2 || !frame) continue;
          var xyPts = [];
          for (var i = 0; i < pts.length; i++) xyPts.push(frameToXY(pts[i][0], pts[i][1]));
          for (var s = 0; s < xyPts.length - 1; s++) {
            var d = distToSeg(xy, xyPts[s], xyPts[s + 1]);
            if (d <= bestD) {
              bestD = d;
              best = roads[r];
            }
          }
        }
        return best;
      }

      function selectRoute(road) {
        var key = roadKey(road);
        if (!key) return;
        scope.editKey = key;
        scope.editLabel = routeLabel(key);
        frameRoute(road);
        publishRoutes(true);
        scope.$evalAsync(redraw);
      }

      function normalizeRoads(state) {
        if (!state) return;
        var roads = asList(state.roads);
        state.roads = roads;
        for (var i = 0; i < roads.length; i++) {
          var road = roads[i];
          if (!road) continue;
          var ends = asList(road.ends);
          if (ends.length >= 2 && ends[0] && ends[1]) road.ends = [String(ends[0]), String(ends[1])];
          var route = asList(road.route);
          var pts = [];
          for (var k = 0; k < route.length; k++) {
            var row = asList(route[k]);
            if (row.length >= 2 && isFinite(Number(row[0])) && isFinite(Number(row[1]))) {
              pts.push([Number(row[0]), Number(row[1])]);
            }
          }
          if (pts.length >= 2) road.route = pts;
        }
      }

      function copyVia(via) {
        var out = [];
        for (var i = 0; i < via.length; i++) out.push([Number(via[i][0]), Number(via[i][1])]);
        return out;
      }

      function viaOf(road) {
        var pts = routePts(road);
        var via = [];
        for (var i = 1; i < pts.length - 1; i++) via.push(pts[i]);
        return via;
      }

      function stampVia(road, via) {
        var pts = routePts(road);
        if (pts.length < 2) return;
        var next = [pts[0]];
        for (var i = 0; i < via.length; i++) next.push([Number(via[i][0]), Number(via[i][1])]);
        next.push(pts[pts.length - 1]);
        road.route = next;
      }

      function findRoad(key) {
        var roads = (scope.state && scope.state.roads) || [];
        for (var i = 0; i < roads.length; i++) {
          if (roadKey(roads[i]) === key) return roads[i];
        }
        return null;
      }

      function restoreHeld() {
        if (!lineHeld || !scope.state) return;
        if (Date.now() > lineHeld.until) {
          lineHeld = null;
          return;
        }
        var road = findRoad(lineHeld.key);
        if (!road) return;
        var pts = routePts(road);
        var same = pts.length === lineHeld.via.length + 2;
        for (var i = 0; same && i < lineHeld.via.length; i++) {
          if (Math.abs(pts[i + 1][0] - lineHeld.via[i][0]) > 1 || Math.abs(pts[i + 1][1] - lineHeld.via[i][1]) > 1) {
            same = false;
          }
        }
        if (same) {
          lineHeld = null;
          return;
        }
        stampVia(road, lineHeld.via);
      }

      function hitHandles(xy) {
        var roads = (scope.state && scope.state.roads) || [];
        var vertex = null;
        var mid = null;
        var bestV = 12;
        var bestM = 14;
        for (var r = 0; r < roads.length; r++) {
          var road = roads[r];
          if (!isEditableRoad(road) || roadKey(road) !== scope.editKey) continue;
          var pts = routePts(road);
          if (pts.length < 2) continue;
          var xyPts = [];
          for (var i = 0; i < pts.length; i++) xyPts.push(frameToXY(pts[i][0], pts[i][1]));
          for (var v = 1; v < xyPts.length - 1; v++) {
            var vd = distPx(xy, xyPts[v]);
            if (vd <= bestV) {
              bestV = vd;
              vertex = { road: road, index: v - 1 };
            }
          }
          for (var s = 0; s < xyPts.length - 1; s++) {
            var at = [(xyPts[s][0] + xyPts[s + 1][0]) * 0.5, (xyPts[s][1] + xyPts[s + 1][1]) * 0.5];
            var md = distPx(xy, at);
            if (md <= bestM) {
              bestM = md;
              mid = { road: road, index: s };
            }
          }
        }
        return { vertex: vertex, mid: mid };
      }

      function saveVia(lo, hi, via) {
        lineHeld = { key: String(lo) + '|' + String(hi), via: copyVia(via), until: Date.now() + 4000 };
        if (!window.bngApi || !bngApi.engineLua) {
          scope.note = 'Game link missing';
          return;
        }
        var parts = [];
        for (var i = 0; i < via.length; i++) {
          var e = Number(via[i][0]);
          var n = Number(via[i][1]);
          if (!isFinite(e) || !isFinite(n)) continue;
          parts.push('{' + e.toFixed(2) + ',' + n.toFixed(2) + '}');
        }
        var expr = '(extensions.alpinert and extensions.alpinert.setUserLink and extensions.alpinert.setUserLink('
          + luaQuote(lo) + ',' + luaQuote(hi) + ',{' + parts.join(',') + '})) or {ok=false}';
        bngApi.engineLua("pcall(extensions.load, 'alpinert')", function () {
          bngApi.engineLua(expr, function (res) {
            scope.$evalAsync(function () {
              if (!res || res.ok !== true) {
                scope.note = 'Line was not saved. Restart BeamNG once, then try again.';
                lineHeld = null;
              }
            });
          });
        });
      }

      function beginDrag(road, index, via, ev) {
        lineEdit = {
          key: roadKey(road),
          lo: String(road.ends[0]),
          hi: String(road.ends[1]),
          via: via,
          index: index,
          pointerId: ev.pointerId
        };
        var c = canvasEl();
        if (c && c.setPointerCapture) {
          try { c.setPointerCapture(ev.pointerId); } catch (err) {}
        }
        stampVia(road, via);
        redraw();
      }

      function onPointerDown(ev) {
        if (scope.collapsed || !frame) return;
        if (scope.editLine) {
          var xy = localXY(ev);
          var hit = hitHandles(xy);
          if (ev.button === 2) {
            if (!hit.vertex) return;
            ev.preventDefault();
            var road = hit.vertex.road;
            var via = viaOf(road);
            via.splice(hit.vertex.index, 1);
            stampVia(road, via);
            saveVia(road.ends[0], road.ends[1], via);
            redraw();
            return;
          }
          if (ev.button !== 0) return;
          if (hit.vertex) {
            ev.preventDefault();
            beginDrag(hit.vertex.road, hit.vertex.index, copyVia(viaOf(hit.vertex.road)), ev);
            return;
          }
          if (hit.mid) {
            var roadM = hit.mid.road;
            var viaM = viaOf(roadM);
            if (viaM.length >= 24) return;
            var pts = routePts(roadM);
            var seg = hit.mid.index;
            viaM.splice(seg, 0, [
              (pts[seg][0] + pts[seg + 1][0]) * 0.5,
              (pts[seg][1] + pts[seg + 1][1]) * 0.5
            ]);
            ev.preventDefault();
            beginDrag(roadM, seg, viaM, ev);
            return;
          }
          var picked = hitRoadLine(xy);
          if (picked && roadKey(picked) !== scope.editKey) {
            ev.preventDefault();
            selectRoute(picked);
            return;
          }
        }
        if (ev.button !== 0) return;
        ev.preventDefault();
        startPan(ev);
      }

      function onPointerMove(ev) {
        if (lineEdit && ev.pointerId === lineEdit.pointerId && frame) {
          var xy = localXY(ev);
          lineEdit.via[lineEdit.index] = frameToCrs(xy[0], xy[1]);
          var road = findRoad(lineEdit.key);
          if (road) stampVia(road, lineEdit.via);
          redraw();
          return;
        }
        movePan(ev);
      }

      function onPointerUp(ev) {
        if (lineEdit && ev.pointerId === lineEdit.pointerId) {
          var done = lineEdit;
          lineEdit = null;
          saveVia(done.lo, done.hi, done.via);
          return;
        }
        endPan(ev);
      }

      function onContext(ev) {
        if (!scope.editLine) return;
        ev.preventDefault();
      }

      function redraw() {
        var st = scope.state || {};
        st._zoomed = !!scope.zoomed;
        st._editLine = !!scope.editLine;
        st._editKey = scope.editKey || '';
        draw(canvasEl(), st, redraw);
      }

      function apply(d) {
        if (!d) return;
        scope.$evalAsync(function () {
          scope.state = d;
          normalizeRoads(scope.state);
          scope.state._zoomed = !!scope.zoomed;
          scope.state._editLine = !!scope.editLine;
          if (scope.editLine) syncEditSelection('', true);
          if (lineEdit) {
            var road = findRoad(lineEdit.key);
            if (road) stampVia(road, lineEdit.via);
          } else {
            restoreHeld();
          }
          redraw();
          requestRegion(scope, false);
        });
      }

      scope.redrawMap = redraw;

      function publishRoutes(on) {
        try {
          window.dispatchEvent(new CustomEvent('alpineRtRoutes', {
            detail: { on: !!on, key: on ? (scope.editKey || '') : '' }
          }));
        } catch (e) {}
      }

      function applyEditRoutes(on, key) {
        scope.editLine = !!on;
        window.__alpineRtWantEditRoutes = false;
        window.__alpineRtWantRoute = '';
        if (!scope.editLine) {
          scope.editKey = '';
          scope.editLabel = '';
        } else {
          scope.zoomed = false;
          if (scope.collapsed) {
            scope.collapsed = false;
            try { localStorage.setItem('alpineRtMapCollapsed', '0'); } catch (e) {}
            syncFrame();
          }
          syncEditSelection(key || '', true);
        }
        publishRoutes(scope.editLine);
        scope.$evalAsync(function () {
          redraw();
          if (scope.editLine) requestRegion(scope, false);
        });
      }

      var mapBridge = {
        setEditRoutes: function (on, key) {
          scope.$evalAsync(function () { applyEditRoutes(on, key); });
        },
        isEditing: function () { return !!scope.editLine; }
      };
      window.__alpineRtMap = mapBridge;
      if (window.__alpineRtWantEditRoutes) applyEditRoutes(true, window.__alpineRtWantRoute || '');

      scope.toggleZoom = function () {
        scope.zoomed = !scope.zoomed;
        if (scope.zoomed) {
          if (scope.editLine) applyEditRoutes(false);
          else scope.$evalAsync(redraw);
        } else {
          glance = null;
          scope.$evalAsync(redraw);
        }
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

      var lineCanvas = canvasEl();
      if (lineCanvas) {
        lineCanvas.addEventListener('pointerdown', onPointerDown);
        lineCanvas.addEventListener('pointermove', onPointerMove);
        lineCanvas.addEventListener('pointerup', onPointerUp);
        lineCanvas.addEventListener('pointercancel', onPointerUp);
        lineCanvas.addEventListener('contextmenu', onContext);
        lineCanvas.addEventListener('wheel', onWheel, { passive: false });
      }

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
        if (window.__alpineRtMap === mapBridge) {
          window.__alpineRtMap = null;
          publishRoutes(false);
        }
        if (region.poll) clearInterval(region.poll);
        if (lineCanvas) {
          lineCanvas.removeEventListener('pointerdown', onPointerDown);
          lineCanvas.removeEventListener('pointermove', onPointerMove);
          lineCanvas.removeEventListener('pointerup', onPointerUp);
          lineCanvas.removeEventListener('pointercancel', onPointerUp);
          lineCanvas.removeEventListener('contextmenu', onContext);
          lineCanvas.removeEventListener('wheel', onWheel);
        }
      });
    }
  };
}]);

