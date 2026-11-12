"""Servicio del simulador del SIG de Pumpunya (FastAPI + psycopg2)."""
import os
import re
import uuid
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path

import psycopg2
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from psycopg2.extras import RealDictCursor
from psycopg2.pool import ThreadedConnectionPool
from pydantic import BaseModel

if "PGPASSWORD" not in os.environ:
    raise SystemExit("Define la variable de entorno PGPASSWORD antes de iniciar el servicio.")

pool = ThreadedConnectionPool(
    1, 5,
    host=os.getenv("PGHOST", "localhost"), port=os.getenv("PGPORT", "5432"),
    dbname=os.getenv("PGDATABASE", "sig_pumpunya_db"), user=os.getenv("PGUSER", "postgres"),
    password=os.environ["PGPASSWORD"], options="-c client_encoding=UTF8",
)

SESION_OK = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
RESERVADAS = {"base", "validacion", "prueba"}
ESTADOS = {"sin_dano", "afectada_leve", "colapso_parcial", "colapso_total"}
FIJOS = {"antes": ("antes", "base"), "despues": ("despues", "base"),
         "modelo": ("simulacion", "validacion")}
VISOR = Path(__file__).parent / "visor"


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
    with cursor() as c:                      # deja cargada la sesión 'validacion'
        c.execute("SELECT * FROM sig.validar()")
    yield
    pool.closeall()


app = FastAPI(title="SIG Pumpunya - Simulador", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@app.exception_handler(psycopg2.Error)
async def error_bd(request, exc):
    texto = (str(exc).strip().splitlines() or ["Error de base de datos"])[0]
    return JSONResponse(status_code=400, content={"detail": texto})


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


@app.get("/api/salud")
def salud():
    return {"estado": "ok"}


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
        c.execute(
            """SELECT p.id, p.uso, p.barrio, e.estado_post
               FROM sig.predios p
               JOIN sig.predio_estado e ON e.predio_id = p.id
                AND e.escenario = 'simulacion' AND e.sesion_id = %s
               WHERE ST_DWithin(p.geom,
                     ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 32718), 3)
               ORDER BY ST_Distance(p.geom,
                     ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 32718))
               LIMIT 1""", (s, lon, lat, lon, lat))
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
        ok = c.fetchone()["ok"]
        return {"deshecho": ok, "resumen": resumen(c, "simulacion", s)}


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
        nuevo = c.fetchone()["id"]
        return {"id": nuevo, "resumen": resumen(c, "simulacion", s)}


@app.delete("/api/sesion/{s}/auxilio/{aid}")
def quitar_auxilio(s: str, aid: int):
    s = sesion_valida(s)
    with cursor() as c:
        c.execute("SELECT sig.sim_quitar_auxilio(%s, %s)", (s, aid))
        return {"resumen": resumen(c, "simulacion", s)}


app.mount("/", StaticFiles(directory=VISOR, html=True), name="visor")