const { API, CENTRO, ZOOM } = CONFIG;
const $ = (id) => document.getElementById(id);
let sesion = null, modo = 'ver', puestos = [], panes = [];

const ESC = {
  antes:      { t: 'Previo al sismo',        esc: 'antes',      ses: () => 'base' },
  despues:    { t: 'Post-sísmico observado', esc: 'despues',    ses: () => 'base' },
  modelo:     { t: 'Modelo (validación)',    esc: 'simulacion', ses: () => 'validacion' },
  simulacion: { t: 'Simulación',             esc: 'simulacion', ses: () => sesion }
};

const MODOS = [
  ['ver', 'Solo ver'],
  ['colapso_total', 'Colapso total'],
  ['colapso_parcial', 'Colapso parcial'],
  ['afectada_leve', 'Afectada leve'],
  ['sin_dano', 'Sin daño'],
  ['puesto', 'Colocar puesto de auxilio'],
];

const msg = (t) => { $('msg').textContent = t; };

async function api(metodo, url, cuerpo) {
  const r = await fetch(API + url, {
    method: metodo,
    headers: { 'Content-Type': 'application/json' },
    body: cuerpo ? JSON.stringify(cuerpo) : undefined,
  });
  if (!r.ok) {
    const e = await r.json().catch(() => ({}));
    throw new Error(e.detail || r.status);
  }
  return r.json();
}

function estiloVia(f) {
  const t = f.properties.tipo_via, e = f.properties.estado_post;
  if (t === 'sendero') return { color: '#ffffff', weight: 1.5, dashArray: '4, 3' };
  if (e === 'bloqueada_total') return { color: '#c62828', weight: 4.5, opacity: 0.95 };
  if (e === 'bloqueada_parcial') return { color: '#ef6c00', weight: 4, opacity: 0.95 };
  return { color: '#2e7d32', weight: 3, opacity: 0.9 };
}

function estiloPredio(f) {
  const e = f.properties.estado_post;
  if (e === 'colapso_total') return { fillColor: '#f44336', fillOpacity: 0.45, color: '#d50000', weight: 2.5 };
  if (e === 'colapso_parcial') return { fillColor: '#ff9800', fillOpacity: 0.35, color: '#ff6d00', weight: 2.2 };
  if (e === 'afectada_leve') return { fillColor: '#ffeb3b', fillOpacity: 0.28, color: '#ffd600', weight: 2.0 };
  return { fillColor: '#ffffff', fillOpacity: 0.12, color: '#ffffff', weight: 1.8 };
}

function crearPane(i, inicial) {
  const map = L.map('map' + i, { center: CENTRO, zoom: ZOOM, maxZoom: 20 });
  L.tileLayer('https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}', {
    maxZoom: 20,
    attribution: 'Google Maps',
  }).addTo(map);

  const group = L.featureGroup().addTo(map);
  const p = { map, group, esc: inicial };

  const sel = $('sel' + i);
  sel.innerHTML = Object.entries(ESC).map(([k, v]) => `<option value="${k}">${v.t}</option>`).join('');
  sel.value = inicial;
  sel.onchange = () => { p.esc = sel.value; cargarCapas(p); };
  map.on('click', onClick);

  cargarCapas(p);
  return p;
}

async function cargarCapas(p) {
  p.group.clearLayers();
  const conf = ESC[p.esc];
  const esc = conf.esc, ses = conf.ses();

  try {
    const [predios, vias, auxilio] = await Promise.all([
      api('GET', `/api/capas/predios?escenario=${esc}&sesion=${ses}`),
      api('GET', `/api/capas/vias?escenario=${esc}&sesion=${ses}`),
      api('GET', `/api/capas/auxilio?escenario=${esc}&sesion=${ses}`)
    ]);

    L.geoJSON(predios, {
      style: estiloPredio,
      onEachFeature: (f, layer) => {
        layer.bindTooltip(String(f.properties.id), {
          permanent: true, direction: 'center', className: 'id-tooltip'
        });
      }
    }).addTo(p.group);

    L.geoJSON(vias, { style: estiloVia }).addTo(p.group);

    L.geoJSON(auxilio, {
      pointToLayer: (f, latlng) => L.marker(latlng, {
        icon: L.divIcon({
          className: 'star-icon',
          html: `<svg width="22" height="22" viewBox="0 0 24 24"><polygon points="12,2 15,9 22,9 17,14 19,21 12,17 5,21 7,14 2,9 9,9" fill="#1565c0" stroke="#ffffff" stroke-width="2"/></svg>`,
          iconSize: [22, 22], iconAnchor: [11, 11]
        })
      })
    }).addTo(p.group);

  } catch (err) {
    console.error("Error cargando capas:", err);
  }
}

function sincronizar(a, b) {
  let bloq = false;
  [[a, b], [b, a]].forEach(([x, y]) =>
    x.map.on('move', () => {
      if (bloq) return;
      bloq = true;
      y.map.setView(x.map.getCenter(), x.map.getZoom(), { animate: false });
      bloq = false;
    })
  );
}

const refrescarSim = () => panes.filter((p) => p.esc === 'simulacion').forEach(cargarCapas);

function fila(id, nombre) {
  $('tabla').tBodies[0].insertAdjacentHTML('beforeend',
    `<tr><td>${nombre}</td><td id="${id}t">–</td><td id="${id}v">–</td></tr>`);
}
function setFila(id, r) {
  $(id + 't').textContent = r.tramos_bloqueados;
  $(id + 'v').textContent = `${r.viv_sin_acceso} / ${r.viviendas}`;
}
function tras(r) {
  setFila('sim', r.resumen);
  refrescarSim();
}

async function onClick(e) {
  if (modo === 'ver' || !sesion) return;
  const { lng, lat } = e.latlng;
  try {
    if (modo === 'puesto') {
      const r = await api('POST', `/api/sesion/${sesion}/auxilio`, { lon: lng, lat });
      puestos.push(r.id);
      msg(`Puesto ${r.id} colocado`);
      tras(r);
    } else {
      const p = await api('GET', `/api/sesion/${sesion}/predio_en?lon=${lng}&lat=${lat}`);
      if (!p) { msg('No hay un predio en ese punto'); return; }
      const r = await api('POST', `/api/sesion/${sesion}/predio`, { predio_id: p.id, estado: modo });
      msg(`Predio ${p.id} (${p.uso}): ${p.estado_post} → ${modo}`);
      tras(r);
    }
  } catch (err) { msg('Error: ' + err.message); }
}

async function colocar(lon, lat) {
  const r = await api('POST', `/api/sesion/${sesion}/auxilio`, { lon, lat });
  puestos.push(r.id);
  msg(`Puesto ${r.id} colocado`);
  tras(r);
}

async function init() {
  $('modos').innerHTML = MODOS.map(([v, t]) =>
    `<label class="modo"><input type="radio" name="modo" value="${v}" ${v === 'ver' ? 'checked' : ''}> ${t}</label>`).join('');
  document.querySelectorAll('input[name=modo]').forEach(r => r.onchange = () => { modo = r.value; });

  const s = await api('POST', '/api/sesion');
  sesion = s.sesion;
  $('ses').textContent = sesion;

  panes = [crearPane(0, 'despues'), crearPane(1, 'simulacion')];
  sincronizar(panes[0], panes[1]);

  fila('ant', 'Previo'); fila('des', 'Observado'); fila('mod', 'Modelo'); fila('sim', 'Simulación');
  setFila('sim', s.resumen);
  setFila('ant', await api('GET', '/api/resumen/antes'));
  setFila('des', await api('GET', '/api/resumen/despues'));
  setFila('mod', await api('GET', '/api/resumen/modelo'));

  $('bDes').onclick = async () => {
    try { const r = await api('POST', `/api/sesion/${sesion}/deshacer`);
      msg(r.deshecho ? 'Último cambio deshecho' : 'No hay cambios por deshacer'); tras(r); } catch (e) { msg(e.message); }
  };
  $('bRes').onclick = async () => {
    try { puestos = []; const r = await api('POST', `/api/sesion/${sesion}/reiniciar`);
      $('opt').innerHTML = ''; msg('Simulación reiniciada al escenario previo'); tras(r); } catch (e) { msg(e.message); }
  };
  $('bQuitar').onclick = async () => {
    if (!puestos.length) { msg('No hay puestos agregados'); return; }
    const id = puestos.pop();
    const r = await api('DELETE', `/api/sesion/${sesion}/auxilio/${id}`);
    msg(`Puesto ${id} quitado`); tras(r);
  };
  $('bOpt').onclick = async () => {
    try {
      msg('Calculando…');
      const r = await api('GET', `/api/sesion/${sesion}/optimo`);
      $('opt').innerHTML = '<h2>Mejores nodos para un puesto</h2>' + r.map(o =>
        `<div>Nodo ${o.nodo_id}: ${o.viv_sin_acceso} viv. sin acceso, media ${o.dist_media_m} m
         <button data-lon="${o.lon}" data-lat="${o.lat}">Colocar</button></div>`).join('');
      document.querySelectorAll('#opt button').forEach(b => b.onclick = () => colocar(+b.dataset.lon, +b.dataset.lat));
      msg('');
    } catch (e) { msg(e.message); }
  };
}
init().catch((e) => msg('No se pudo iniciar: ' + e.message));
