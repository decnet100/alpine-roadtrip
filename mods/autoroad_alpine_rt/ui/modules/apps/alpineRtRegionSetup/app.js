// Region setup. The driving overview is alpineRtTrafficMap.
// A region file is the user overlay (locations, gates, WMTS provider), not portals.json.
angular.module('beamng.apps').directive('alpinertregionsetup', [function () {
  var PROVIDERS = [
    { id: 'geoland', title: 'Geoland' },
    { id: 'geoland-aerial', title: 'Orthophoto' },
    { id: 'geoland-terrain', title: 'Geoland terrain' },
    { id: 'osm', title: 'OSM' }
  ];

  var tpl = ''
    + '<div class="arts" ng-class="{collapsed: collapsed}">'
    + '  <style>'
    + '  .arts{font-family:"Cairo","Overpass",system-ui,sans-serif;color:#dfe2e6;background:rgba(18,20,24,0.92);'
    + '       border:1px solid rgba(255,255,255,0.07);border-top:2px solid #ff6600;border-radius:5px;'
    + '       height:100%;width:100%;box-sizing:border-box;display:flex;flex-direction:column;overflow:hidden;}'
    + '  .arts *{box-sizing:border-box;}'
    + '  .arts.collapsed{height:auto;background:transparent;border-color:transparent;}'
    + '  .arts.collapsed .arts-head{background:rgba(18,20,24,0.92);border:1px solid rgba(255,255,255,0.07);'
    + '       border-top:2px solid #ff6600;border-radius:5px;pointer-events:auto;}'
    + '  .arts.collapsed .arts-body{display:none;}'
    + '  .arts-head{display:flex;align-items:center;padding:10px 11px;border-bottom:1px solid rgba(255,255,255,0.06);flex:none;pointer-events:auto;}'
    + '  .arts-slash{width:6px;height:16px;background:#ff6600;transform:skewX(-16deg);margin-right:9px;flex:none;}'
    + '  .arts-title{font-style:italic;font-weight:800;font-size:13px;color:#f4f6f8;}'
    + '  .arts-body{padding:10px 11px 12px;display:flex;flex-direction:column;gap:8px;overflow:auto;min-height:0;}'
    + '  .arts-sub{color:#8b9198;font-size:11px;}'
    + '  .arts-sub b{color:#dfe2e6;}'
    + '  .arts-btn{font:inherit;font-size:11px;font-weight:700;letter-spacing:.4px;border-radius:3px;padding:7px 10px;'
    + '       cursor:pointer;border:1px solid rgba(255,255,255,0.11);background:rgba(255,255,255,0.06);color:#dfe2e6;}'
    + '  .arts-btn.on{background:rgba(255,102,0,0.28);border-color:rgba(255,102,0,0.55);color:#fff;}'
    + '  .arts-btn:disabled{opacity:0.4;cursor:default;}'
    + '  .arts-tools{display:flex;flex-wrap:wrap;gap:6px;}'
    + '  .arts-q{font-size:11px;color:#c5cad1;line-height:1.35;}'
    + '  .arts-note{font-size:11px;color:#ffb020;line-height:1.35;}'
    + '  .arts input,.arts select{font:inherit;font-size:12px;padding:6px 8px;border-radius:3px;width:100%;'
    + '       border:1px solid rgba(255,255,255,0.12);background:rgba(0,0,0,0.28);color:#dfe2e6;}'
    + '  .arts-list{max-height:120px;overflow:auto;display:flex;flex-direction:column;gap:4px;}'
    + '  .arts-item{font:inherit;font-size:12px;text-align:left;padding:6px 8px;border-radius:3px;cursor:pointer;'
    + '       border:1px solid rgba(255,255,255,0.08);background:rgba(255,255,255,0.04);color:#dfe2e6;}'
    + '  .arts-item small{display:block;color:#8b9198;font-size:10px;}'
    + '  .arts-item.on{background:rgba(255,102,0,0.22);border-color:rgba(255,102,0,0.55);color:#fff;}'
    + '  .arts-row{display:flex;gap:6px;align-items:center;}'
    + '  .arts-row .arts-btn{flex:none;}'
    + '  .arts h3{margin:4px 0 0;font-size:11px;letter-spacing:.4px;color:#9aa3ae;font-weight:700;}'
    + '  </style>'
    + '  <div class="arts-head"><span class="arts-slash"></span><span class="arts-title" style="flex:1">REGION SETUP</span>'
    + '    <button type="button" class="arts-btn" ng-click="toggleCollapse()">{{collapsed ? "Show" : "Hide"}}</button></div>'
    + '  <div class="arts-body">'
    + '    <div class="arts-sub">Level <b>{{state.level || "-"}}</b>'
    + '      <span ng-if="state.setup && state.setup.authority"> · {{state.setup.authority}}</span>'
    + '      <span ng-if="state.lua_rev"> · Lua {{state.lua_rev}}</span></div>'
    + '    <div class="arts-q" ng-if="state.setup && state.setup.defined">This level already has a center. Saving replaces that center.</div>'
    + '    <div class="arts-tools">'
    + '      <button type="button" class="arts-btn" ng-class="{on: panel===\'place\'}" ng-click="toggle(\'place\')">Place this map</button>'
    + '      <button type="button" class="arts-btn" ng-class="{on: panel===\'portal\'}" ng-click="openPortal()">New portal</button>'
    + '      <button type="button" class="arts-btn" ng-class="{on: panel===\'return\'}" ng-click="toggle(\'return\')" ng-if="state.setup && state.setup.open_returns && state.setup.open_returns.length">Return ({{state.setup.open_returns.length}})</button>'
    + '      <button type="button" class="arts-btn" ng-class="{on: routesOn}" ng-click="editRoutes()">Edit routes</button>'
    + '    </div>'
    + '    <div ng-if="routesOn">'
    + '      <div class="arts-q">Choose a connection. The map then edits that line.</div>'
    + '      <div class="arts-list" ng-if="routeRows().length">'
    + '        <button type="button" class="arts-item" ng-repeat="r in routeRows()" ng-class="{on: routeKey===r.key}" ng-click="chooseRoute(r)">{{r.label}}</button>'
    + '      </div>'
    + '      <div class="arts-q" ng-if="!routeRows().length">No user route yet. A route appears when a portal links two placed maps.</div>'
    + '    </div>'
    + '    <h3 ng-if="gateRows().length">Portals</h3>'
    + '    <div class="arts-list" ng-if="gateRows().length">'
    + '      <div class="arts-row" ng-repeat="g in gateRows()">'
    + '        <button type="button" class="arts-item" style="flex:1" disabled>{{g.label || g.id}}<small>{{g.from_level}} → {{g.to_level}}{{g.linked ? "" : " · one way"}}</small></button>'
    + '        <button type="button" class="arts-btn" ng-if="g.here" ng-click="moveGate(g)">Move here</button>'
    + '        <button type="button" class="arts-btn" ng-if="!g.builtin" ng-click="removeGate(g)">Remove</button>'
    + '      </div>'
    + '    </div>'
    + '    <div ng-if="panel===\'place\'">'
    + '      <div class="arts-note" ng-if="state.lua_rev && !(state.setup && state.setup.authority)">No map CRS is configured.</div>'
    + '      <input ng-model="form.name" placeholder="Location name">'
    + '      <input ng-model="form.lat" placeholder="Latitude (WGS84)" style="margin-top:6px">'
    + '      <input ng-model="form.lon" placeholder="Longitude (WGS84)" style="margin-top:6px">'
    + '      <div class="arts-q" style="margin-top:6px">In which direction is your vehicle currently pointing?</div>'
    + '      <div class="arts-tools">'
    + '        <button type="button" class="arts-btn" ng-click="saveLocation(\'north\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly north</button>'
    + '        <button type="button" class="arts-btn" ng-click="saveLocation(\'east\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly east</button>'
    + '        <button type="button" class="arts-btn" ng-click="saveLocation(\'south\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly south</button>'
    + '        <button type="button" class="arts-btn" ng-click="saveLocation(\'west\')" ng-disabled="!(state.setup && state.setup.authority)">Roughly west</button>'
    + '      </div>'
    + '    </div>'
    + '    <div ng-if="panel===\'portal\'">'
    + '      <input ng-model="levelQuery" placeholder="Filter maps">'
    + '      <div class="arts-list" style="margin-top:6px">'
    + '        <button type="button" class="arts-item" ng-repeat="lv in filteredLevels()" ng-click="choosePortal(lv)">{{lv.title}}<small>{{lv.id}}</small></button>'
    + '      </div>'
    + '    </div>'
    + '    <div ng-if="panel===\'return\'">'
    + '      <div class="arts-q">Place the return portal at the vehicle.</div>'
    + '      <div class="arts-list">'
    + '        <button type="button" class="arts-item" ng-repeat="link in state.setup.open_returns" ng-click="chooseReturn(link)">From {{link.label}}<small>{{link.from_level}}</small></button>'
    + '      </div>'
    + '    </div>'
    + '    <h3 ng-if="locationRows().length">Placed maps</h3>'
    + '    <div class="arts-list" ng-if="locationRows().length">'
    + '      <div class="arts-row" ng-repeat="loc in locationRows()">'
    + '        <button type="button" class="arts-item" style="flex:1" disabled>{{loc.name}}<small>{{loc.id}}</small></button>'
    + '        <button type="button" class="arts-btn" ng-click="removeLoc(loc)">Remove</button>'
    + '      </div>'
    + '    </div>'
    + '    <h3>Region picture</h3>'
    + '    <div class="arts-q">Geoland is the road map. Orthophoto is the aerial photo.</div>'
    + '    <div class="arts-tools">'
    + '      <button type="button" class="arts-btn" ng-repeat="p in providers" ng-class="{on: (state.view && state.view.provider) === p.id}" ng-click="pickProvider(p)">{{p.title}}</button>'
    + '    </div>'
    + '    <button type="button" class="arts-btn" ng-click="redraw()">Redraw region map</button>'
    + '    <h3>Region file</h3>'
    + '    <div class="arts-q">Saves the placed maps and portals. Built-in passes stay in the mod.</div>'
    + '    <div class="arts-row">'
    + '      <input ng-model="fileName" placeholder="Region name">'
    + '      <button type="button" class="arts-btn" ng-click="saveFile()">Save</button>'
    + '      <button type="button" class="arts-btn" ng-click="refreshFiles()">Files</button>'
    + '    </div>'
    + '    <div class="arts-list" ng-if="files.length">'
    + '      <button type="button" class="arts-item" ng-repeat="f in files" ng-click="loadFile(f)">Load {{f.name}}</button>'
    + '    </div>'
    + '    <div class="arts-note" ng-if="note">{{note}}</div>'
    + '  </div>'
    + '</div>';

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

  return {
    template: tpl,
    replace: true,
    restrict: 'EA',
    scope: true,
    link: function (scope, element) {
      scope.state = { level: null, setup: { open_returns: [] }, region: { locations: [], gates: [] } };
      scope.collapsed = false;
      try { scope.collapsed = localStorage.getItem('alpineRtSetupCollapsed') === '1'; } catch (e) {}

      function syncFrame() {
        var node = element[0];
        while (node) {
          if (node.classList && node.classList.contains('ui-app-host')) {
            node.style.pointerEvents = scope.collapsed ? 'none' : '';
            return;
          }
          node = node.parentElement;
        }
      }

      scope.toggleCollapse = function () {
        scope.collapsed = !scope.collapsed;
        try { localStorage.setItem('alpineRtSetupCollapsed', scope.collapsed ? '1' : '0'); } catch (e) {}
        syncFrame();
      };
      requestAnimationFrame(syncFrame);
      scope.panel = null;
      scope.routesOn = false;
      scope.routeKey = '';
      scope.note = '';
      scope.form = { name: '', lat: '', lon: '' };
      scope.levelQuery = '';
      scope.levels = [];
      scope.files = [];
      scope.fileName = '';
      scope.providers = PROVIDERS;
      scope.formReady = false;

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

      function poll() {
        if (!window.bngApi || !bngApi.engineLua) return;
        bngApi.engineLua("pcall(extensions.load, 'alpinert')", function () {
          bngApi.engineLua(
            "(extensions.alpinert and extensions.alpinert.getTrafficMap and extensions.alpinert.getTrafficMap()) or {}",
            function (d) {
              scope.$evalAsync(function () {
                if (!d) return;
                scope.state = d;
                if (!scope.formReady && d.setup) {
                  if (d.setup.name) scope.form.name = d.setup.name;
                  if (d.setup.lat != null) scope.form.lat = String(d.setup.lat);
                  if (d.setup.lon != null) scope.form.lon = String(d.setup.lon);
                  scope.formReady = true;
                }
                var mapApi = window.__alpineRtMap;
                if (mapApi && mapApi.isEditing) scope.routesOn = !!mapApi.isEditing();
              });
            }
          );
        });
      }

      scope.gateRows = function () {
        return asList(scope.state && scope.state.region && scope.state.region.gates);
      };

      scope.locationRows = function () {
        return asList(scope.state && scope.state.region && scope.state.region.locations);
      };

      scope.toggle = function (name) {
        scope.panel = scope.panel === name ? null : name;
        scope.note = '';
      };

      function mapInLayout() {
        var cur = window.UIAppStorage && window.UIAppStorage.current;
        var apps = cur && cur.apps;
        if (!apps || !apps.length) return false;
        for (var i = 0; i < apps.length; i++) {
          var name = apps[i] && apps[i].appName;
          if (name === 'alpinerttrafficmap' || name === 'alpineRtTrafficMap') return true;
        }
        return false;
      }

      function onRoutes(ev) {
        scope.$evalAsync(function () {
          scope.routesOn = !!(ev.detail && ev.detail.on);
          scope.routeKey = (ev.detail && ev.detail.key) || '';
        });
      }
      window.addEventListener('alpineRtRoutes', onRoutes);

      function levelTitle(id) {
        var rows = scope.locationRows();
        for (var i = 0; i < rows.length; i++) {
          if (rows[i] && rows[i].id === id && rows[i].name) return rows[i].name;
        }
        var maps = asList(scope.state && scope.state.maps);
        for (var m = 0; m < maps.length; m++) {
          var title = maps[m] && maps[m].id === id && maps[m].title;
          if (title && String(title).indexOf('levels.') !== 0) return String(title);
        }
        var s = String(id || '').replace(/^autoroad_/, '').replace(/_\d+$/, '').replace(/_/g, ' ');
        if (!s) return String(id || '');
        return s.replace(/\b[a-z]/g, function (ch) { return ch.toUpperCase(); });
      }

      scope.routeRows = function () {
        var roads = asList(scope.state && scope.state.roads);
        var out = [];
        var seen = {};
        for (var i = 0; i < roads.length; i++) {
          var road = roads[i];
          if (!road || !(road.editable || road.user || String(road.id || '').indexOf('user:') === 0)) continue;
          var ends = asList(road.ends);
          if (ends.length < 2 || !ends[0] || !ends[1]) continue;
          var a = String(ends[0]);
          var b = String(ends[1]);
          var key = a + '|' + b;
          if (seen[key]) continue;
          seen[key] = true;
          out.push({ key: key, label: levelTitle(a) + ' – ' + levelTitle(b) });
        }
        out.sort(function (x, y) {
          return x.label < y.label ? -1 : (x.label > y.label ? 1 : 0);
        });
        return out;
      };

      function ensureMap(key) {
        var api = window.__alpineRtMap;
        if (api && api.setEditRoutes) return api;
        window.__alpineRtWantEditRoutes = true;
        window.__alpineRtWantRoute = key || '';
        if (document.querySelector && document.querySelector('.artm')) {
          scope.note = 'The map is open but this UI build is stale. Press Ctrl+L, then choose the route again.';
          return null;
        }
        if (mapInLayout()) {
          scope.note = 'Alpine Roadtrip Map is in the layout but not running. Press Ctrl+L, then choose the route again.';
          return null;
        }
        if (!window.bngApi || !bngApi.engineLua) {
          scope.note = 'Show Alpine Roadtrip Map from the app menu, then choose the route again.';
          return null;
        }
        bngApi.engineLua("guihooks.trigger('appContainer:spawn', {appName = 'alpinerttrafficmap'})");
        scope.note = 'Alpine Roadtrip Map was not in this layout. It is being added, and the chosen route opens there.';
        return null;
      }

      scope.editRoutes = function () {
        if (scope.routesOn) {
          var open = window.__alpineRtMap;
          if (open && open.setEditRoutes) open.setEditRoutes(false);
          scope.routesOn = false;
          scope.routeKey = '';
          scope.note = '';
          return;
        }
        var rows = scope.routeRows();
        var key = rows.length === 1 ? rows[0].key : '';
        scope.routesOn = true;
        scope.routeKey = key;
        scope.note = rows.length ? '' : 'No user route yet. A route appears when a portal links two placed maps.';
        var api = ensureMap(key);
        if (api) api.setEditRoutes(true, key);
      };

      scope.chooseRoute = function (row) {
        if (!row || !row.key) return;
        scope.routesOn = true;
        scope.routeKey = row.key;
        var api = ensureMap(row.key);
        if (api) {
          api.setEditRoutes(true, row.key);
          scope.note = '';
        }
      };

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

      scope.saveLocation = function (cardinal) {
        var lat = Number(scope.form.lat);
        var lon = Number(scope.form.lon);
        if (String(scope.form.lat).trim() === '' || String(scope.form.lon).trim() === '' || !isFinite(lat) || !isFinite(lon)) {
          scope.note = 'Latitude and longitude are required.';
          return;
        }
        callLua('extensions.alpinert.defineLocation('
          + luaQuote(scope.form.name) + ',' + lat + ',' + lon + ',' + luaQuote(cardinal) + ')', function (res) {
          scope.note = (res && res.ok) ? ('Placed in ' + (res.authority || 'map CRS')) : ((res && res.error) || 'Could not place the map');
          if (res && res.ok) scope.panel = null;
          poll();
        });
      };

      scope.openPortal = function () {
        scope.panel = scope.panel === 'portal' ? null : 'portal';
        scope.note = '';
        if (scope.panel !== 'portal') return;
        if (scope.state && scope.state.setup && scope.state.lua_rev && !scope.state.setup.defined) {
          scope.note = 'Place this map first.';
        }
        scope.levels = [];
        callLua('(extensions.alpinert and extensions.alpinert.listLevels()) or {}', function (rows) {
          scope.levels = asList(rows);
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

      scope.chooseReturn = function (link) {
        if (!link || !link.id) return;
        callLua('extensions.alpinert.placeReturn(' + luaQuote(link.id) + ')', function (res) {
          scope.note = (res && res.ok) ? 'Return portal placed' : ((res && res.error) || 'Could not place the return portal');
          if (res && res.ok) scope.panel = null;
          poll();
        });
      };

      scope.moveGate = function (g) {
        if (!g || !g.id) return;
        callLua('(extensions.alpinert and extensions.alpinert.moveUserGate and extensions.alpinert.moveUserGate('
          + luaQuote(g.id) + ')) or {ok=false, error="Restart BeamNG once, then try again."}', function (res) {
          scope.note = (res && res.ok) ? 'Portal moved to the vehicle' : ((res && res.error) || 'Could not move the portal');
          poll();
        });
      };

      scope.removeGate = function (g) {
        if (!g || !g.id) return;
        callLua('extensions.alpinert.removeUserGate(' + luaQuote(g.id) + ')', function (res) {
          scope.note = (res && res.ok) ? 'Portal removed' : ((res && res.error) || 'Could not remove the portal');
          poll();
        });
      };

      scope.removeLoc = function (loc) {
        if (!loc || !loc.id) return;
        callLua('extensions.alpinert.removeLocation(' + luaQuote(loc.id) + ')', function (res) {
          scope.note = (res && res.ok) ? 'Map removed from the region' : ((res && res.error) || 'Could not remove the map');
          poll();
        });
      };

      scope.pickProvider = function (p) {
        if (!p || !p.id) return;
        if (scope.state && scope.state.view && scope.state.view.provider === p.id) return;
        callLua('extensions.alpinert.setRegionProvider(' + luaQuote(p.id) + ')', function (res) {
          scope.note = (res && res.ok) ? (p.title + ' saved. The driving map redraws once.') : ((res && res.error) || 'Could not set the provider');
          poll();
        });
      };

      scope.redraw = function () {
        callLua('extensions.alpinert.redrawRegion()', function (res) {
          scope.note = (res && res.ok) ? 'Driving map will redraw the region.' : ((res && res.error) || 'Could not request a redraw');
          poll();
        });
      };

      scope.saveFile = function () {
        callLua('extensions.alpinert.saveRegion(' + luaQuote(scope.fileName) + ')', function (res) {
          scope.note = (res && res.ok) ? ('Saved ' + res.name) : ((res && res.error) || 'Could not save');
          if (res && res.ok) scope.refreshFiles();
        });
      };

      scope.refreshFiles = function () {
        callLua('(extensions.alpinert and extensions.alpinert.listRegions()) or {}', function (rows) {
          scope.files = asList(rows);
          if (!scope.files.length) scope.note = 'No saved region files yet';
        });
      };

      scope.loadFile = function (f) {
        if (!f || !f.name) return;
        callLua('extensions.alpinert.loadRegion(' + luaQuote(f.name) + ')', function (res) {
          scope.note = (res && res.ok) ? ('Loaded ' + res.name) : ((res && res.error) || 'Could not load');
          scope.formReady = false;
          poll();
        });
      };

      var timer = setInterval(poll, 1000);
      poll();
      scope.$on('$destroy', function () {
        clearInterval(timer);
        window.removeEventListener('alpineRtRoutes', onRoutes);
      });
    }
  };
}]);
