"""Servicio del simulador del SIG de Pumpunya (FastAPI + psycopg2) - Versión Cloud."""
import os
import re
import uuid
from contextlib import asynccontextmanager, contextmanager
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

DATABASE_URL = os.getenv("DATABASE_URL")
if DATABASE_URL:
    if DATABASE_URL.startswith("postgres://"):
        DATABASE_URL = DATABASE_URL.replace("postgres://", "postgresql://", 1)
    pool = ThreadedConnectionPool(1, 10, dsn=DATABASE_URL, options="-c client_encoding=UTF8")
else:
    host = os.getenv("PGHOST", "localhost")
    port = os.getenv("PGPORT", "5432")
    dbname = os.getenv("PGDATABASE", "sig_pumpunya_db")
    user = os.getenv("PGUSER", "postgres")
    password = os.getenv("PGPASSWORD", "")
    pool = ThreadedConnectionPool(1, 5, host=host, port=port, dbname=dbname, user=user, password=password, options="-c client_encoding=UTF8")

SESION_OK = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
RESERVADAS = {"base", "validacion", "prueba"}
ESTADOS = {"sin_dano", "afectada_leve", "colapso_parcial", "colapso_total"}
FIJOS = {"antes": ("antes", "base"), "despues": ("despues", "base"), "modelo": ("simulacion", "validacion")}

@contextmanager
def cursor():
    conn = pool.getconn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as c:
            yield c
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        pool.putconn(conn)

@asynccontextmanager
async def lifespan(app):
    with cursor() as c:
        c.execute("SELECT * FROM sig.validar()")
    yield
    pool.closeall()

app = FastAPI(title="SIG Pumpunya API Cloud", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

def sesion_valida(s: str) -> str:
    if not SESION_OK.match(s) or s in RESERVADAS:
        raise HTTPException(400, "Sesión no válida")
    return s

def resumen(c, escenario, sesion):
    c.execute("SELECT * FROM sig.resumen(%s, %s)", (escenario, sesion))
    return dict(c.fetchone())

class CambioPredio(BaseModel):
    predio_id: int
    estado: str

class Punto(BaseModel):
    lon: float
    lat: float

@app.get("/")
def raiz():
    return {"servicio": "SIG Pumpunya API Cloud", "docs": "/docs", "estado": "online"}

@app.get("/api/salud")
def salud():
    return {"estado": "ok", "cloud": True}

@app.get("/api/resumen/{nombre}")
def resumen_fijo(nombre: str):
    if nombre not in FIJOS:
        raise HTTPException(404, "Escenario desconocido")
    with cursor() as c:
        return resumen(c, *FIJOS[nombre])

@app.post("/api/sesion")
def nueva_sesion():
    s = "s" + uuid.uuid4().hex[:10]
    with cursor() as c:
        c.execute("SELECT sig.sim_iniciar(%s)", (s,))
        return {"sesion": s, "resumen": resumen(c, "simulacion", s)}

@app.get("/api/sesion/{s}/resumen")
def resumen_sesion(s: str):
    s = sesion_valida(s)
    with cursor() as c:
        return resumen(c, "simulacion", s)

@app.get("/api/sesion/{s}/predio_en")
def predio_en(s: str, lon: float, lat: float):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("""
            SELECT p.id, p.uso, p.barrio, e.estado_post
            FROM sig.predios p
            JOIN sig.predio_estado e ON e.predio_id = p.id
             AND e.escenario = 'simulacion' AND e.sesion_id = %s
            WHERE ST_DWithin(p.geom, ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 32718), 3)
            ORDER BY ST_Distance(p.geom, ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 32718))
            LIMIT 1
        """, (s, lon, lat, lon, lat))
        fila = c.fetchone()
        return dict(fila) if fila else None

@app.post("/api/sesion/{s}/predio")
def cambiar_predio(s: str, body: CambioPredio):
    s = sesion_valida(s)
    if body.estado not in ESTADOS:
        raise HTTPException(400, "Estado no válido")
    with cursor() as c:
        c.execute("SELECT sig.sim_set_predio(%s, %s, %s)", (s, body.predio_id, body.estado))
        return {"resumen": resumen(c, "simulacion", s)}

@app.post("/api/sesion/{s}/deshacer")
def deshacer(s: str):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT sig.sim_deshacer(%s) AS ok", (s,))
        return {"deshecho": c.fetchone()["ok"], "resumen": resumen(c, "simulacion", s)}

@app.post("/api/sesion/{s}/reiniciar")
def reiniciar(s: str):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT sig.sim_reset(%s)", (s,))
        return {"resumen": resumen(c, "simulacion", s)}

@app.get("/api/sesion/{s}/optimo")
def optimo(s: str):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT * FROM sig.ubicacion_optima(%s)", (s,))
        return [dict(f) for f in c.fetchall()]

@app.post("/api/sesion/{s}/auxilio")
def agregar_auxilio(s: str, p: Punto):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT sig.sim_agregar_auxilio(%s, %s, %s) AS id", (s, p.lon, p.lat))
        return {"id": c.fetchone()["id"], "resumen": resumen(c, "simulacion", s)}

@app.delete("/api/sesion/{s}/auxilio/{aid}")
def quitar_auxilio(s: str, aid: int):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT sig.sim_quitar_auxilio(%s, %s)", (s, aid))
        return {"resumen": resumen(c, "simulacion", s)}

@app.get("/api/capas/vias")
def capa_vias(escenario: str = "despues", sesion: str = "base"):
    with cursor() as c:
        c.execute("""
            SELECT jsonb_build_object(
                'type', 'FeatureCollection',
                'features', COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'type', 'Feature',
                        'id', v.seg_id,
                        'geometry', ST_AsGeoJSON(ST_Transform(v.geom, 4326))::jsonb,
                        'properties', jsonb_build_object(
                            'seg_id', v.seg_id,
                            'tipo_via', v.tipo_via,
                            'estado_post', e.estado_post,
                            'w_efectivo_m', round(e.w_efectivo_m::numeric, 2)
                        )
                    )
                ), '[]'::jsonb)
            ) AS geojson
            FROM sig.vias v
            JOIN sig.via_estado e ON e.seg_id = v.seg_id
             AND e.escenario = %s AND e.sesion_id = %s
        """, (escenario, sesion))
        return c.fetchone()["geojson"]

@app.get("/api/capas/predios")
def capa_predios(escenario: str = "despues", sesion: str = "base"):
    with cursor() as c:
        c.execute("""
            SELECT jsonb_build_object(
                'type', 'FeatureCollection',
                'features', COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'type', 'Feature',
                        'id', p.id,
                        'geometry', ST_AsGeoJSON(ST_Transform(p.geom, 4326))::jsonb,
                        'properties', jsonb_build_object(
                            'id', p.id,
                            'uso', p.uso,
                            'estado_post', e.estado_post,
                            'barrio', p.barrio
                        )
                    )
                ), '[]'::jsonb)
            ) AS geojson
            FROM sig.predios p
            JOIN sig.predio_estado e ON e.predio_id = p.id
             AND e.escenario = %s AND e.sesion_id = %s
        """, (escenario, sesion))
        return c.fetchone()["geojson"]

@app.get("/api/capas/auxilio")
def capa_auxilio(escenario: str = "despues", sesion: str = "base"):
    with cursor() as c:
        c.execute("""
            SELECT jsonb_build_object(
                'type', 'FeatureCollection',
                'features', COALESCE(jsonb_agg(
                    jsonb_build_object(
                        'type', 'Feature',
                        'id', a.id,
                        'geometry', ST_AsGeoJSON(ST_Transform(a.geom, 4326))::jsonb,
                        'properties', jsonb_build_object('id', a.id)
                    )
                ), '[]'::jsonb)
            ) AS geojson
            FROM sig.auxilio a
            WHERE a.escenario = %s AND a.sesion_id = %s
        """, (escenario, sesion))
        return c.fetchone()["geojson"]
