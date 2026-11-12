const { API, GEOSERVER_WMS: WMS, WS, CENTRO, ZOOM } = CONFIG;
const $ = (id) => document.getElementById(id);
const CAPAS = ['predios_escenario', 'vias_escenario', 'auxilio_escenario'];
let sesion = null,
  modo = 'ver',
  puestos = [],
  panes = [];

const ESC = {
  antes: { t: 'Previo al sismo', vp: () => 'escenario:antes;sesion:base' },
  despues: { t: 'Post-sísmico observado', vp: () => 'escenario:despues;sesion:base' },
  modelo: { t: 'Modelo (validación)', vp: () => 'escenario:simulacion;sesion:validacion' },
  simulacion: { t: 'Simulación', vp: () => `escenario:simulacion;sesion:${sesion}` },
};

const MODOS = [
  ['ver', 'Solo ver'],
  ['colapso_total', 'Colapso total'],
  ['colapso_parcial', 'Colapso parcial'],
  ['afectada_leve', 'Afectada leve'],
  ['sin_dano', 'Sin daño'],
  ['puesto', 'Colocar puesto de auxilio'],
];

const msg = (t) => {
  $('msg').textContent = t;
};

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

function crearPane(i, inicial) {
  const map = L.map('map' + i, { center: CENTRO, zoom: ZOOM, maxZoom: 20 });
  L.tileLayer('https://mt1.google.com/vt/lyrs=y&x={x}&y={y}&z={z}', {
    maxZoom: 20,
    attribution: 'Google Maps',
  }).addTo(map);
  const vp = ESC[inicial].vp();
  const capas = CAPAS.map((n) =>
    L.tileLayer
      .wms(WMS, {
        layers: `${WS}:${n}`,
        format: 'image/png',
        transparent: true,
        version: '1.1.1',
        viewparams: vp,
        maxZoom: 20,
      })
      .addTo(map)
  );
  const p = { map, capas, esc: inicial };
  const sel = $('sel' + i);
  sel.innerHTML = Object.entries(ESC)
    .map(([k, v]) => `<option value="${k}">${v.t}</option>`)
    .join('');
  sel.value = inicial;
  sel.onchange = () => {
    p.esc = sel.value;
    refrescar(p);
  };
  map.on('click', onClick);
  return p;
}

function sincronizar(a, b) {
  let bloq = false;
  [
    [a, b],
    [b, a],
  ].forEach(([x, y]) =>
    x.map.on('move', () => {
      if (bloq) return;
      bloq = true;
      y.map.setView(x.map.getCenter(), x.map.getZoom(), { animate: false });
      bloq = false;
    })
  );
}

function refrescar(p) {
  const vp = ESC[p.esc].vp();
  p.capas.forEach((c) => c.setParams({ viewparams: vp, t: Date.now() }));
}
const refrescarSim = () => panes.filter((p) => p.esc === 'simulacion').forEach(refrescar);

function fila(id, nombre) {
  $('tabla').tBodies[0].insertAdjacentHTML(
    'beforeend',
    `<tr><td>${nombre}</td><td id="${id}t">–</td><td id="${id}v">–</td></tr>`
  );
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
      if (!p) {
        msg('No hay un predio en ese punto');
        return;
      }
      const r = await api('POST', `/api/sesion/${sesion}/predio`, {
        predio_id: p.id,
        estado: modo,
      });
      msg(`Predio ${p.id} (${p.uso}): ${p.estado_post} → ${modo}`);
      tras(r);
    }
  } catch (err) {
    msg('Error: ' + err.message);
  }
}

async function colocar(lon, lat) {
  const r = await api('POST', `/api/sesion/${sesion}/auxilio`, { lon, lat });
  puestos.push(r.id);
  msg(`Puesto ${r.id} colocado`);
  tras(r);
}

async function init() {
  $('modos').innerHTML = MODOS.map(
    ([v, t]) =>
      `<label class="modo"><input type="radio" name="modo" value="${v}" ${v === 'ver' ? 'checked' : ''}> ${t}</label>`
  ).join('');
  document.querySelectorAll('input[name=modo]').forEach(
    (r) =>
      (r.onchange = () => {
        modo = r.value;
      })
  );

  const s = await api('POST', '/api/sesion');
  sesion = s.sesion;
  $('ses').textContent = sesion;

  panes = [crearPane(0, 'despues'), crearPane(1, 'simulacion')];
  sincronizar(panes[0], panes[1]);

  fila('ant', 'Previo');
  fila('des', 'Observado');
  fila('mod', 'Modelo');
  fila('sim', 'Simulación');
  setFila('sim', s.resumen);
  setFila('ant', await api('GET', '/api/resumen/antes'));
  setFila('des', await api('GET', '/api/resumen/despues'));
  setFila('mod', await api('GET', '/api/resumen/modelo'));

  $('bDes').onclick = async () => {
    try {
      const r = await api('POST', `/api/sesion/${sesion}/deshacer`);
      msg(r.deshecho ? 'Último cambio deshecho' : 'No hay cambios por deshacer');
      tras(r);
    } catch (e) {
      msg(e.message);
    }
  };
  $('bRes').onclick = async () => {
    try {
      puestos = [];
      const r = await api('POST', `/api/sesion/${sesion}/reiniciar`);
      $('opt').innerHTML = '';
      msg('Simulación reiniciada al escenario previo');
      tras(r);
    } catch (e) {
      msg(e.message);
    }
  };
  $('bQuitar').onclick = async () => {
    if (!puestos.length) {
      msg('No hay puestos agregados');
      return;
    }
    const id = puestos.pop();
    const r = await api('DELETE', `/api/sesion/${sesion}/auxilio/${id}`);
    msg(`Puesto ${id} quitado`);
    tras(r);
  };
  $('bOpt').onclick = async () => {
    try {
      msg('Calculando…');
      const r = await api('GET', `/api/sesion/${sesion}/optimo`);
      $('opt').innerHTML =
        '<h2>Mejores nodos para un puesto</h2>' +
        r
          .map(
            (o) =>
              `<div>Nodo ${o.nodo_id}: ${o.viv_sin_acceso} viv. sin acceso, media ${o.dist_media_m} m
         <button data-lon="${o.lon}" data-lat="${o.lat}">Colocar</button></div>`
          )
          .join('');
      document
        .querySelectorAll('#opt button')
        .forEach((b) => (b.onclick = () => colocar(+b.dataset.lon, +b.dataset.lat)));
      msg('');
    } catch (e) {
      msg(e.message);
    }
  };
}
init().catch((e) => msg('No se pudo iniciar: ' + e.message));