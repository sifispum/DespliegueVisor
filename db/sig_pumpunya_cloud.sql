--
-- PostgreSQL database dump
--

\restrict tKgfChdq72bPWGmIQglom8FRtuXvd8prCCelfu0YavXBxEB2AWuWDt6eAKVUmi4

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: sig; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sig;


--
-- Name: calcular_vias(text, text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.calcular_vias(p_escenario text, p_sesion text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_alpha   double precision := sig.param('alpha_grados');
    v_parcial double precision := sig.param('factor_parcial');
    v_umbral  double precision := sig.param('umbral_vehiculo_m');
    v_total   double precision := sig.param('umbral_total_m');
    v_busca   double precision := sig.param('max_busca_m');
BEGIN
    DELETE FROM sig.bloqueos WHERE escenario = p_escenario AND sesion_id = p_sesion;

    INSERT INTO sig.bloqueos (escenario, sesion_id, seg_id, predio_id, lado, wd_m, invasion_m)
    SELECT p_escenario, p_sesion, c.seg_id, c.predio_id, c.lado, c.wd,
           c.wd - GREATEST(0, c.d - c.ancho_m / 2)
    FROM (
        SELECT v.seg_id, v.ancho_m, p.id AS predio_id,
               ST_Distance(p.geom, v.geom) AS d,
               sig.lado_de(v.geom, ST_ClosestPoint(p.geom, v.geom)) AS lado,
               p.altura_muro_m
                 * CASE e.estado_post WHEN 'colapso_total' THEN 1 ELSE v_parcial END
                 / tan(radians(v_alpha)) AS wd
        FROM sig.vias v
        JOIN sig.predios p ON ST_DWithin(p.geom, v.geom, v_busca)
        JOIN sig.predio_estado e ON e.predio_id = p.id
                                AND e.escenario = p_escenario
                                AND e.sesion_id = p_sesion
        WHERE v.tipo_via <> 'sendero'
          AND e.estado_post IN ('colapso_total', 'colapso_parcial')
    ) c
    WHERE c.wd - GREATEST(0, c.d - c.ancho_m / 2) > 0;

    INSERT INTO sig.via_estado
        (escenario, sesion_id, seg_id, estado_post, w_efectivo_m,
         acceso_vehiculo, acceso_peatonal, id_viv_bloqueo)
    SELECT p_escenario, p_sesion, v.seg_id, cls.estado, calc.w_ef,
           (cls.estado = 'libre' AND v.tipo_via <> 'sendero'),
           TRUE,
           CASE WHEN cls.estado <> 'libre' THEN b.causa END
    FROM sig.vias v
    LEFT JOIN (
        SELECT seg_id,
               COALESCE(MAX(invasion_m) FILTER (WHERE lado = 1), 0)  AS inv_i,
               COALESCE(MAX(invasion_m) FILTER (WHERE lado = -1), 0) AS inv_d,
               (ARRAY_AGG(predio_id ORDER BY invasion_m DESC))[1]    AS causa
        FROM sig.bloqueos
        WHERE escenario = p_escenario AND sesion_id = p_sesion
        GROUP BY seg_id
    ) b ON b.seg_id = v.seg_id
    CROSS JOIN LATERAL (
        SELECT GREATEST(0, v.ancho_m - COALESCE(b.inv_i, 0) - COALESCE(b.inv_d, 0)) AS w_ef
    ) calc
    CROSS JOIN LATERAL (
        SELECT CASE
                 WHEN v.tipo_via = 'sendero' OR b.seg_id IS NULL THEN 'libre'
                 WHEN calc.w_ef < v_total  THEN 'bloqueada_total'
                 WHEN calc.w_ef < v_umbral THEN 'bloqueada_parcial'
                 ELSE 'libre'
               END AS estado
    ) cls
    ON CONFLICT (escenario, sesion_id, seg_id) DO UPDATE
    SET estado_post     = EXCLUDED.estado_post,
        w_efectivo_m    = EXCLUDED.w_efectivo_m,
        acceso_vehiculo = EXCLUDED.acceso_vehiculo,
        acceso_peatonal = EXCLUDED.acceso_peatonal,
        id_viv_bloqueo  = EXCLUDED.id_viv_bloqueo;
END $$;


--
-- Name: dist_red(text, text, text, bigint[]); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.dist_red(p_escenario text, p_sesion text, p_modo text, p_aux_nodos bigint[] DEFAULT NULL::bigint[]) RETURNS TABLE(predio_id integer, ruta_m double precision)
    LANGUAGE plpgsql STABLE
    AS $$
#variable_conflict use_column
DECLARE
    v_aristas text;
BEGIN
    v_aristas := format(
        'SELECT v.seg_id AS id, v.source, v.target,
                ST_Length(v.geom) AS cost, ST_Length(v.geom) AS reverse_cost
         FROM sig.vias v
         LEFT JOIN sig.via_estado e
                ON e.seg_id = v.seg_id AND e.escenario = %L AND e.sesion_id = %L
         WHERE %s',
        p_escenario, p_sesion,
        CASE WHEN p_modo = 'vehiculo'
             THEN 'v.tipo_via <> ''sendero'' AND COALESCE(e.estado_post, ''libre'') = ''libre'''
             ELSE 'TRUE' END);

    RETURN QUERY
    WITH aux AS (
        SELECT a.nodo_id::bigint AS nodo, MIN(a.nodo_dist) AS enlace
        FROM sig.auxilio a
        WHERE p_aux_nodos IS NULL AND a.escenario = p_escenario AND a.sesion_id = p_sesion
        GROUP BY a.nodo_id
        UNION ALL
        SELECT n, 0 FROM unnest(p_aux_nodos) AS n
    ),
    inicio AS (
        SELECT p.id AS pid, t.enlace, t.source, t.target, t.a_source, t.a_target, t.bloqueado
        FROM sig.predios p
        CROSS JOIN LATERAL (
            SELECT v.source, v.target,
                   ST_Distance(v.geom, p.geom) AS enlace,
                   ST_Length(v.geom) * ST_LineLocatePoint(v.geom, ST_Centroid(p.geom)) AS a_source,
                   ST_Length(v.geom) * (1 - ST_LineLocatePoint(v.geom, ST_Centroid(p.geom))) AS a_target,
                   (p_modo = 'vehiculo' AND COALESCE(e.estado_post, 'libre') <> 'libre') AS bloqueado
            FROM sig.vias v
            LEFT JOIN sig.via_estado e
                   ON e.seg_id = v.seg_id AND e.escenario = p_escenario AND e.sesion_id = p_sesion
            WHERE p_modo = 'peatonal' OR v.tipo_via <> 'sendero'
            ORDER BY ST_Distance(v.geom, p.geom)
            LIMIT 1
        ) t
        WHERE p.uso = 'vivienda'
    ),
    nodos_ini AS (
        SELECT source::bigint AS n FROM inicio WHERE NOT bloqueado
        UNION
        SELECT target::bigint FROM inicio WHERE NOT bloqueado
    ),
    costos AS (
        SELECT start_vid, end_vid, agg_cost
        FROM pgr_dijkstraCost(
            v_aristas,
            COALESCE((SELECT array_agg(n) FROM nodos_ini), '{}'::bigint[]),
            COALESCE((SELECT array_agg(nodo) FROM aux), '{}'::bigint[]),
            false)
        UNION ALL
        SELECT a.nodo, a.nodo, 0::double precision
        FROM aux a JOIN nodos_ini ni ON ni.n = a.nodo
    )
    SELECT i.pid, i.enlace + r.mejor
    FROM inicio i
    LEFT JOIN LATERAL (
        SELECT MIN(x.a + c.agg_cost + ax.enlace) AS mejor
        FROM (VALUES (i.source::bigint, i.a_source), (i.target::bigint, i.a_target)) AS x (nodo, a)
        JOIN costos c ON c.start_vid = x.nodo
        JOIN aux ax ON ax.nodo = c.end_vid
        WHERE NOT i.bloqueado
    ) r ON TRUE;
END $$;


--
-- Name: distancias(text, text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.distancias(p_escenario text, p_sesion text) RETURNS TABLE(predio_id integer, barrio text, ruta_vehiculo_m numeric, ruta_peatonal_m numeric, recta_m numeric, sin_acceso_vehiculo boolean, fuera_radio boolean)
    LANGUAGE sql STABLE
    AS $$
    SELECT p.id, p.barrio,
           ROUND(rv.ruta_m::numeric, 1),
           ROUND(rp.ruta_m::numeric, 1),
           ROUND((SELECT MIN(ST_Distance(p.geom, a.geom))
                  FROM sig.auxilio a
                  WHERE a.escenario = p_escenario AND a.sesion_id = p_sesion)::numeric, 1),
           rv.ruta_m IS NULL,
           rv.ruta_m IS NULL OR rv.ruta_m > sig.param('radio_auxilio_m')
    FROM sig.predios p
    JOIN sig.dist_red(p_escenario, p_sesion, 'vehiculo') rv ON rv.predio_id = p.id
    JOIN sig.dist_red(p_escenario, p_sesion, 'peatonal') rp ON rp.predio_id = p.id
    ORDER BY p.id
$$;


--
-- Name: lado_de(public.geometry, public.geometry); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.lado_de(p_linea public.geometry, p_punto public.geometry) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
             WHEN (ST_X(s.b) - ST_X(s.a)) * (ST_Y(p_punto) - ST_Y(s.a))
                - (ST_Y(s.b) - ST_Y(s.a)) * (ST_X(p_punto) - ST_X(s.a)) >= 0
             THEN 1 ELSE -1
           END
    FROM (SELECT ST_LineInterpolatePoint(p_linea, GREATEST(f.pos - 0.01, 0)) AS a,
                 ST_LineInterpolatePoint(p_linea, LEAST(f.pos + 0.01, 1))    AS b
          FROM (SELECT ST_LineLocatePoint(p_linea, p_punto) AS pos) f) s
$$;


--
-- Name: param(text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.param(p_clave text) RETURNS double precision
    LANGUAGE sql STABLE
    AS $$
    SELECT valor FROM sig.parametros WHERE clave = p_clave
$$;


--
-- Name: resumen(text, text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.resumen(p_escenario text, p_sesion text) RETURNS TABLE(viviendas integer, viv_sin_acceso integer, viv_fuera_radio integer, ruta_vehiculo_media_m numeric, ruta_peatonal_media_m numeric, recta_media_m numeric, tramos_bloqueados integer)
    LANGUAGE sql STABLE
    AS $$
    SELECT COUNT(*)::integer,
           (COUNT(*) FILTER (WHERE d.sin_acceso_vehiculo))::integer,
           (COUNT(*) FILTER (WHERE d.fuera_radio))::integer,
           ROUND(AVG(d.ruta_vehiculo_m), 1),
           ROUND(AVG(d.ruta_peatonal_m), 1),
           ROUND(AVG(d.recta_m), 1),
           (SELECT COUNT(*) FROM sig.via_estado e
            WHERE e.escenario = p_escenario AND e.sesion_id = p_sesion
              AND e.estado_post <> 'libre')::integer
    FROM sig.distancias(p_escenario, p_sesion) d
$$;


--
-- Name: sim_agregar_auxilio(text, double precision, double precision); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_agregar_auxilio(p_sesion text, p_lon double precision, p_lat double precision) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_punto geometry := ST_Transform(ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), 32718);
    v_id    integer;
BEGIN
    INSERT INTO sig.auxilio (escenario, sesion_id, geom, nodo_id, nodo_dist)
    SELECT 'simulacion', p_sesion, v_punto, n.id, ST_Distance(n.geom, v_punto)
    FROM sig.nodos n
    ORDER BY ST_Distance(n.geom, v_punto)
    LIMIT 1
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;


--
-- Name: sim_deshacer(text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_deshacer(p_sesion text) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
DECLARE
    h sig.sim_historial%ROWTYPE;
BEGIN
    SELECT * INTO h FROM sig.sim_historial
    WHERE sesion_id = p_sesion ORDER BY id DESC LIMIT 1;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    UPDATE sig.predio_estado SET estado_post = h.estado_anterior
    WHERE escenario = 'simulacion' AND sesion_id = p_sesion AND predio_id = h.predio_id;

    DELETE FROM sig.sim_historial WHERE id = h.id;
    PERFORM sig.calcular_vias('simulacion', p_sesion);
    RETURN TRUE;
END $$;


--
-- Name: sim_iniciar(text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_iniciar(p_sesion text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sig.predio_estado
                   WHERE escenario = 'simulacion' AND sesion_id = p_sesion) THEN
        PERFORM sig.sim_reset(p_sesion);
    END IF;
END $$;


--
-- Name: sim_quitar_auxilio(text, integer); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_quitar_auxilio(p_sesion text, p_id integer) RETURNS void
    LANGUAGE sql
    AS $$
    DELETE FROM sig.auxilio
    WHERE escenario = 'simulacion' AND sesion_id = p_sesion AND id = p_id
$$;


--
-- Name: sim_reset(text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_reset(p_sesion text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM sig.sim_historial WHERE sesion_id = p_sesion;
    DELETE FROM sig.bloqueos      WHERE escenario = 'simulacion' AND sesion_id = p_sesion;
    DELETE FROM sig.via_estado    WHERE escenario = 'simulacion' AND sesion_id = p_sesion;
    DELETE FROM sig.predio_estado WHERE escenario = 'simulacion' AND sesion_id = p_sesion;
    DELETE FROM sig.auxilio       WHERE escenario = 'simulacion' AND sesion_id = p_sesion;

    INSERT INTO sig.predio_estado (escenario, sesion_id, predio_id, estado_post)
    SELECT 'simulacion', p_sesion, predio_id, estado_post
    FROM sig.predio_estado WHERE escenario = 'antes' AND sesion_id = 'base';

    INSERT INTO sig.via_estado
        (escenario, sesion_id, seg_id, estado_post, w_efectivo_m,
         acceso_vehiculo, acceso_peatonal, id_viv_bloqueo)
    SELECT 'simulacion', p_sesion, seg_id, estado_post, w_efectivo_m,
           acceso_vehiculo, acceso_peatonal, id_viv_bloqueo
    FROM sig.via_estado WHERE escenario = 'antes' AND sesion_id = 'base';

    INSERT INTO sig.auxilio (escenario, sesion_id, geom, nodo_id, nodo_dist)
    SELECT 'simulacion', p_sesion, geom, nodo_id, nodo_dist
    FROM sig.auxilio WHERE escenario = 'antes' AND sesion_id = 'base';
END $$;


--
-- Name: sim_set_predio(text, integer, text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.sim_set_predio(p_sesion text, p_predio integer, p_estado text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_antes text;
BEGIN
    SELECT estado_post INTO v_antes
    FROM sig.predio_estado
    WHERE escenario = 'simulacion' AND sesion_id = p_sesion AND predio_id = p_predio;

    IF v_antes IS NULL THEN
        RAISE EXCEPTION 'Sesion % sin iniciar o predio % no existe (usa sig.sim_iniciar)', p_sesion, p_predio;
    END IF;
    IF v_antes = p_estado THEN
        RETURN;
    END IF;

    UPDATE sig.predio_estado SET estado_post = p_estado
    WHERE escenario = 'simulacion' AND sesion_id = p_sesion AND predio_id = p_predio;

    INSERT INTO sig.sim_historial (sesion_id, predio_id, estado_anterior, estado_nuevo)
    VALUES (p_sesion, p_predio, v_antes, p_estado);

    PERFORM sig.calcular_vias('simulacion', p_sesion);
END $$;


--
-- Name: ubicacion_optima(text); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.ubicacion_optima(p_sesion text) RETURNS TABLE(nodo_id integer, lon double precision, lat double precision, viv_sin_acceso integer, viv_fuera_radio integer, dist_media_m numeric)
    LANGUAGE sql STABLE
    AS $$
    SELECT n.id,
           ST_X(ST_Transform(n.geom, 4326)),
           ST_Y(ST_Transform(n.geom, 4326)),
           (COUNT(*) FILTER (WHERE r.ruta_m IS NULL))::integer,
           (COUNT(*) FILTER (WHERE r.ruta_m IS NULL OR r.ruta_m > sig.param('radio_auxilio_m')))::integer,
           ROUND(AVG(r.ruta_m)::numeric, 1)
    FROM sig.nodos n
    CROSS JOIN LATERAL sig.dist_red('simulacion', p_sesion, 'vehiculo', ARRAY[n.id]::bigint[]) r
    GROUP BY n.id, n.geom
    ORDER BY 5, 6
    LIMIT 5
$$;


--
-- Name: validar(); Type: FUNCTION; Schema: sig; Owner: -
--

CREATE FUNCTION sig.validar() RETURNS TABLE(tp integer, fp integer, fn integer, tn integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM sig.sim_reset('validacion');

    UPDATE sig.predio_estado s SET estado_post = d.estado_post
    FROM sig.predio_estado d
    WHERE s.escenario = 'simulacion' AND s.sesion_id = 'validacion'
      AND d.escenario = 'despues' AND d.sesion_id = 'base'
      AND d.predio_id = s.predio_id;

    PERFORM sig.calcular_vias('simulacion', 'validacion');

    RETURN QUERY
    SELECT (COUNT(*) FILTER (WHERE m.estado_post <> 'libre' AND o.estado_post <> 'libre'))::integer,
           (COUNT(*) FILTER (WHERE m.estado_post <> 'libre' AND o.estado_post = 'libre'))::integer,
           (COUNT(*) FILTER (WHERE m.estado_post = 'libre'  AND o.estado_post <> 'libre'))::integer,
           (COUNT(*) FILTER (WHERE m.estado_post = 'libre'  AND o.estado_post = 'libre'))::integer
    FROM sig.via_estado m
    JOIN sig.via_estado o ON o.seg_id = m.seg_id AND o.escenario = 'despues' AND o.sesion_id = 'base'
    JOIN sig.vias v ON v.seg_id = m.seg_id
    WHERE m.escenario = 'simulacion' AND m.sesion_id = 'validacion'
      AND v.tipo_via <> 'sendero';
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: auxilio; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.auxilio (
    id integer NOT NULL,
    escenario text NOT NULL,
    sesion_id text DEFAULT 'base'::text NOT NULL,
    geom public.geometry(Point,32718) NOT NULL,
    nodo_id integer NOT NULL,
    nodo_dist double precision NOT NULL,
    CONSTRAINT auxilio_escenario_check CHECK ((escenario = ANY (ARRAY['antes'::text, 'despues'::text, 'simulacion'::text])))
);


--
-- Name: auxilio_id_seq; Type: SEQUENCE; Schema: sig; Owner: -
--

CREATE SEQUENCE sig.auxilio_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auxilio_id_seq; Type: SEQUENCE OWNED BY; Schema: sig; Owner: -
--

ALTER SEQUENCE sig.auxilio_id_seq OWNED BY sig.auxilio.id;


--
-- Name: bloqueos; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.bloqueos (
    escenario text NOT NULL,
    sesion_id text NOT NULL,
    seg_id integer NOT NULL,
    predio_id integer NOT NULL,
    lado integer NOT NULL,
    wd_m double precision NOT NULL,
    invasion_m double precision NOT NULL
);


--
-- Name: nodos; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.nodos (
    id integer NOT NULL,
    geom public.geometry(Point,32718) NOT NULL
);


--
-- Name: nodos_id_seq; Type: SEQUENCE; Schema: sig; Owner: -
--

CREATE SEQUENCE sig.nodos_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nodos_id_seq; Type: SEQUENCE OWNED BY; Schema: sig; Owner: -
--

ALTER SEQUENCE sig.nodos_id_seq OWNED BY sig.nodos.id;


--
-- Name: parametros; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.parametros (
    clave text NOT NULL,
    valor double precision NOT NULL,
    descripcion text
);


--
-- Name: predio_estado; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.predio_estado (
    escenario text NOT NULL,
    sesion_id text DEFAULT 'base'::text NOT NULL,
    predio_id integer NOT NULL,
    estado_post text NOT NULL,
    CONSTRAINT predio_estado_escenario_check CHECK ((escenario = ANY (ARRAY['antes'::text, 'despues'::text, 'simulacion'::text]))),
    CONSTRAINT predio_estado_estado_post_check CHECK ((estado_post = ANY (ARRAY['sin_dano'::text, 'afectada_leve'::text, 'colapso_parcial'::text, 'colapso_total'::text])))
);


--
-- Name: predios; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.predios (
    id integer NOT NULL,
    uso text NOT NULL,
    material text,
    barrio text,
    estado_post text NOT NULL,
    dano_orig text,
    altura_muro_m double precision NOT NULL,
    altura_fuente text,
    via_frente integer,
    geom public.geometry(MultiPolygon,32718) NOT NULL,
    CONSTRAINT predios_altura_muro_m_check CHECK ((altura_muro_m > (0)::double precision)),
    CONSTRAINT predios_estado_post_check CHECK ((estado_post = ANY (ARRAY['sin_dano'::text, 'afectada_leve'::text, 'colapso_parcial'::text, 'colapso_total'::text]))),
    CONSTRAINT predios_uso_check CHECK ((uso = ANY (ARRAY['vivienda'::text, 'iglesia'::text, 'escuela'::text, 'otro'::text])))
);


--
-- Name: puntos; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.puntos (
    id integer NOT NULL,
    nombre text,
    tipo text,
    existe_antes boolean,
    existe_despues boolean,
    es_auxilio boolean,
    geom public.geometry(Point,32718) NOT NULL
);


--
-- Name: sim_historial; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.sim_historial (
    id bigint NOT NULL,
    sesion_id text NOT NULL,
    predio_id integer NOT NULL,
    estado_anterior text NOT NULL,
    estado_nuevo text NOT NULL,
    creado timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: sim_historial_id_seq; Type: SEQUENCE; Schema: sig; Owner: -
--

CREATE SEQUENCE sig.sim_historial_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sim_historial_id_seq; Type: SEQUENCE OWNED BY; Schema: sig; Owner: -
--

ALTER SEQUENCE sig.sim_historial_id_seq OWNED BY sig.sim_historial.id;


--
-- Name: via_estado; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.via_estado (
    escenario text NOT NULL,
    sesion_id text DEFAULT 'base'::text NOT NULL,
    seg_id integer NOT NULL,
    estado_post text NOT NULL,
    w_efectivo_m double precision,
    acceso_vehiculo boolean NOT NULL,
    acceso_peatonal boolean NOT NULL,
    id_viv_bloqueo integer,
    CONSTRAINT via_estado_escenario_check CHECK ((escenario = ANY (ARRAY['antes'::text, 'despues'::text, 'simulacion'::text]))),
    CONSTRAINT via_estado_estado_post_check CHECK ((estado_post = ANY (ARRAY['libre'::text, 'bloqueada_parcial'::text, 'bloqueada_total'::text])))
);


--
-- Name: vias; Type: TABLE; Schema: sig; Owner: -
--

CREATE TABLE sig.vias (
    seg_id integer NOT NULL,
    via_id integer NOT NULL,
    nombre text,
    tipo_via text NOT NULL,
    ancho_m double precision NOT NULL,
    estado_obs text NOT NULL,
    source integer,
    target integer,
    geom public.geometry(LineString,32718) NOT NULL,
    CONSTRAINT vias_ancho_m_check CHECK ((ancho_m > (0)::double precision)),
    CONSTRAINT vias_estado_obs_check CHECK ((estado_obs = ANY (ARRAY['libre'::text, 'bloqueada_parcial'::text, 'bloqueada_total'::text]))),
    CONSTRAINT vias_tipo_via_check CHECK ((tipo_via = ANY (ARRAY['carretera'::text, 'callejon'::text, 'sendero'::text])))
);


--
-- Name: auxilio id; Type: DEFAULT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.auxilio ALTER COLUMN id SET DEFAULT nextval('sig.auxilio_id_seq'::regclass);


--
-- Name: nodos id; Type: DEFAULT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.nodos ALTER COLUMN id SET DEFAULT nextval('sig.nodos_id_seq'::regclass);


--
-- Name: sim_historial id; Type: DEFAULT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.sim_historial ALTER COLUMN id SET DEFAULT nextval('sig.sim_historial_id_seq'::regclass);


--
-- Data for Name: auxilio; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.auxilio (id, escenario, sesion_id, geom, nodo_id, nodo_dist) FROM stdin;
1	antes	base	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
2	despues	base	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
3	antes	base	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
4	despues	base	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
5	antes	base	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
6	despues	base	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1732	simulacion	prueba	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1733	simulacion	prueba	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1734	simulacion	prueba	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1738	simulacion	se8c845ecd9	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1739	simulacion	se8c845ecd9	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1740	simulacion	se8c845ecd9	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1741	simulacion	s6f8ce6f031	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1742	simulacion	s6f8ce6f031	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1743	simulacion	s6f8ce6f031	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1744	simulacion	s6f8ce6f031	0101000020CE7F0000AC693D2E63C11C4182A2CC5390826041	25	39.920962054558686
1745	simulacion	s0413428c13	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1746	simulacion	s0413428c13	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1747	simulacion	s0413428c13	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1751	simulacion	sbcdc0502da	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1752	simulacion	sbcdc0502da	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1753	simulacion	sbcdc0502da	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1754	simulacion	s0f4dd06250	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1755	simulacion	s0f4dd06250	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1756	simulacion	s0f4dd06250	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1757	simulacion	s57a27c547d	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1758	simulacion	s57a27c547d	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1759	simulacion	s57a27c547d	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1760	simulacion	s57a27c547d	0101000020CE7F00007297508E37C11C41D662BA8284826041	50	13.462317661261848
1761	simulacion	s57a27c547d	0101000020CE7F00003E3333332DC21C41333333C389826041	40	6.402842700481415e-10
1762	simulacion	s57a27c547d	0101000020CE7F00003E3333332DC21C41333333C389826041	40	6.402842700481415e-10
1763	simulacion	validacion	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1764	simulacion	validacion	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1765	simulacion	validacion	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1766	simulacion	se75f401cdf	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1767	simulacion	se75f401cdf	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1768	simulacion	se75f401cdf	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1769	simulacion	s50bd328e7f	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1770	simulacion	s50bd328e7f	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1771	simulacion	s50bd328e7f	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1772	simulacion	s1662d29df5	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1773	simulacion	s1662d29df5	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1774	simulacion	s1662d29df5	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1775	simulacion	s61cd91a577	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1776	simulacion	s61cd91a577	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1777	simulacion	s61cd91a577	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1778	simulacion	saa7ac3c714	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1779	simulacion	saa7ac3c714	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1780	simulacion	saa7ac3c714	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1781	simulacion	s8419d72a77	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1782	simulacion	s8419d72a77	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1783	simulacion	s8419d72a77	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1784	simulacion	s2a33e30ee1	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1785	simulacion	s2a33e30ee1	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1786	simulacion	s2a33e30ee1	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1787	simulacion	sadb934d385	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1788	simulacion	sadb934d385	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1789	simulacion	sadb934d385	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1794	simulacion	s0ecf2d55f7	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1795	simulacion	s0ecf2d55f7	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1796	simulacion	s0ecf2d55f7	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
1797	simulacion	sc1195efed5	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041	37	6.63096249752342
1798	simulacion	sc1195efed5	0101000020CE7F00008ABCCFB45CC11C415C46711683826041	37	9.436209960330622
1799	simulacion	sc1195efed5	0101000020CE7F00000641964977C11C41D2A7133E84826041	34	19.645718681680496
\.


--
-- Data for Name: bloqueos; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.bloqueos (escenario, sesion_id, seg_id, predio_id, lado, wd_m, invasion_m) FROM stdin;
simulacion	sc1195efed5	41	20	1	4.113838947023271	1.1357392148522378
simulacion	sc1195efed5	42	20	1	4.113838947023271	2.702068298219547
simulacion	s57a27c547d	41	21	1	4.113838947023271	2.553370199343282
simulacion	s57a27c547d	42	19	1	4.113838947023271	4.024140059679565
simulacion	s57a27c547d	42	20	1	2.0569194735116354	0.6451488247079116
simulacion	s57a27c547d	42	21	1	4.113838947023271	2.702068298219547
simulacion	s57a27c547d	43	19	1	4.113838947023271	4.113838947023271
simulacion	s57a27c547d	52	19	1	4.113838947023271	4.113838947023271
simulacion	validacion	14	13	1	1.8578627502685738	1.8578627502685738
simulacion	validacion	14	15	-1	2.0569194735116354	2.0569194735116354
simulacion	validacion	14	43	1	4.113838947023271	3.0926885602617373
simulacion	validacion	15	43	1	4.113838947023271	4.113838947023271
simulacion	validacion	48	41	1	3.7157255005371477	2.922127475547178
simulacion	validacion	48	43	1	4.113838947023271	4.113838947023271
simulacion	validacion	48	34	-1	2.0569194735116354	2.0569194735116354
simulacion	validacion	16	41	1	3.7157255005371477	3.7157255005371477
simulacion	validacion	16	43	1	4.113838947023271	1.9334670284053708
simulacion	validacion	16	30	-1	2.0569194735116354	2.0569194735116354
simulacion	validacion	16	34	-1	2.0569194735116354	2.0569194735116354
simulacion	validacion	32	41	-1	3.7157255005371477	3.0341710126570276
simulacion	validacion	33	41	-1	3.7157255005371477	3.7157255005371477
simulacion	validacion	33	30	-1	2.0569194735116354	0.7845694384169071
simulacion	validacion	34	30	-1	2.0569194735116354	1.7380893549982432
simulacion	validacion	35	33	-1	2.0569194735116354	0.700160252026806
simulacion	validacion	36	32	-1	2.0569194735116354	0.3958749977720979
simulacion	validacion	36	33	-1	2.0569194735116354	0.7049788763885054
simulacion	validacion	49	32	-1	2.0569194735116354	0.2932827986137836
simulacion	validacion	40	2	1	3.848429982699189	2.0314546999818597
simulacion	validacion	40	3	1	2.0569194735116354	0.09582264892100767
simulacion	validacion	41	20	1	4.113838947023271	1.1357392148522378
simulacion	validacion	41	21	1	4.113838947023271	2.553370199343282
simulacion	validacion	41	22	1	3.7157255005371477	1.743847487799688
simulacion	validacion	41	2	-1	3.848429982699189	0.9482354531804131
simulacion	validacion	42	20	1	4.113838947023271	2.702068298219547
simulacion	validacion	42	21	1	4.113838947023271	2.702068298219547
simulacion	validacion	42	22	1	3.7157255005371477	0.837113147969061
simulacion	validacion	43	20	1	4.113838947023271	0.1256423196187808
simulacion	validacion	52	1	-1	4.246543429185312	4.246543429185312
simulacion	validacion	44	26	-1	4.246543429185312	4.246543429185312
simulacion	validacion	44	2	1	3.848429982699189	3.848429982699189
simulacion	validacion	44	12	1	2.0569194735116354	0.8710287518989293
simulacion	validacion	45	26	-1	4.246543429185312	4.246543429185312
simulacion	validacion	45	12	1	2.0569194735116354	2.0569194735116354
simulacion	sc1195efed5	43	20	1	4.113838947023271	0.1256423196187808
simulacion	validacion	61	13	1	1.8578627502685738	1.8578627502685738
simulacion	validacion	61	15	-1	2.0569194735116354	2.0569194735116354
\.


--
-- Data for Name: nodos; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.nodos (id, geom) FROM stdin;
1	0101000020CE7F0000CDCCCCCC04C21C410000007086826041
2	0101000020CE7F00009A999999C9C11C419A9999B976826041
3	0101000020CE7F0000000000003CC21C419A9999B98C826041
4	0101000020CE7F00009A9999991FC41C416666665690826041
5	0101000020CE7F00000000000038C21C419A9999C9A0826041
6	0101000020CE7F000066666666A6C41C41666666E6A9826041
7	0101000020CE7F0000CDCCCCCCC6C01C41CDCCCC5C8D826041
8	0101000020CE7F000000000000EAC11C41666666D684826041
9	0101000020CE7F00009A999999FDC41C41000000309D826041
10	0101000020CE7F0000000000006EC41C416666668695826041
11	0101000020CE7F000000000000C6C11C41666666967A826041
12	0101000020CE7F00000000000020C21C41000000B095826041
13	0101000020CE7F00009A99999927C31C41333333C38C826041
14	0101000020CE7F0000CDCCCCCCD4C11C416666669689826041
15	0101000020CE7F000033333333C3C41C419A999929A7826041
16	0101000020CE7F000000000000CEC11C419A9999897E826041
17	0101000020CE7F00006666666670C41C41666666D6AB826041
18	0101000020CE7F00003333333301C51C419A9999E9A4826041
19	0101000020CE7F00000000000024C21C41CDCCCC2C94826041
20	0101000020CE7F0000CDCCCCCCCEC41C41CDCCCC7CAC826041
21	0101000020CE7F000000000000F4C11C41CDCCCC6C85826041
22	0101000020CE7F000066666666C8C41C41CDCCCCBC9A826041
23	0101000020CE7F000033333333BBC11C416666661681826041
24	0101000020CE7F00006666666640C21C41CDCCCCDC8E826041
25	0101000020CE7F00009A999999D9C11C41CDCCCCAC93826041
26	0101000020CE7F00009A9999992FC51C41666666B69F826041
27	0101000020CE7F0000000000007EC11C41333333C388826041
28	0101000020CE7F0000666666662CC21C41000000B092826041
29	0101000020CE7F0000333333330BC21C419A9999A99B826041
30	0101000020CE7F00000000000014C21C41CDCCCC8C87826041
31	0101000020CE7F00003333333399C41C419A99992998826041
32	0101000020CE7F0000CDCCCCCC80C31C419A9999C9A6826041
33	0101000020CE7F00000000000030C31C41CDCCCC1CA5826041
34	0101000020CE7F00003333333379C11C419A9999C981826041
35	0101000020CE7F00000000000096C21C4133333383A1826041
36	0101000020CE7F00009A999999FFC01C41CDCCCCDC83826041
37	0101000020CE7F00003333333339C11C41000000B082826041
38	0101000020CE7F0000CDCCCCCCC6C11C41666666E67B826041
39	0101000020CE7F00003333333329C11C41000000C087826041
40	0101000020CE7F0000333333332DC21C41333333C389826041
41	0101000020CE7F000000000000E4C21C4133333343A3826041
42	0101000020CE7F00003333333339C51C419A999989A2826041
43	0101000020CE7F000000000000FCC11C41333333A39E826041
44	0101000020CE7F0000CDCCCCCCD2C11C410000005083826041
45	0101000020CE7F000066666666C6C11C410000004079826041
46	0101000020CE7F0000CDCCCCCCD8C31C41CDCCCC5C8E826041
47	0101000020CE7F0000CDCCCCCC46C11C41CDCCCC1C87826041
48	0101000020CE7F0000333333331BC41C4100000070AA826041
49	0101000020CE7F00009A99999983C31C41333333138D826041
50	0101000020CE7F0000CDCCCCCC16C11C41CDCCCC2C83826041
51	0101000020CE7F00009A999999CDC31C41000000A0A8826041
52	0101000020CE7F00009A9999997DC21C419A9999098B826041
53	0101000020CE7F0000000000005EC11C410000007088826041
54	0101000020CE7F000000000000DAC21C41CDCCCC1C8B826041
55	0101000020CE7F00009A9999993FC21C41000000C08F826041
56	0101000020CE7F00003333333357C41C41CDCCCCBC92826041
57	0101000020CE7F0000666666661EC21C41666666B698826041
\.


--
-- Data for Name: parametros; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.parametros (clave, valor, descripcion) FROM stdin;
alpha_grados	37	Angulo de reposo del adobe
factor_parcial	0.5	Fraccion de la altura que cae a la calle en colapso parcial
umbral_vehiculo_m	3	Si el ancho libre es menor no puede pasar un vehiculo
umbral_total_m	0.9	Si el ancho libre es menor no puede pasar una persona
max_busca_m	10	Casas colapsadas a mas de la distancia del tramo se ignoran
radio_auxilio_m	1000	Distancia maxima a punto de auxilio
mmi_pumpunya	5.59	Intensidad Mercalli en Pumpunya de ShakeMap USGS
\.


--
-- Data for Name: predio_estado; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.predio_estado (escenario, sesion_id, predio_id, estado_post) FROM stdin;
antes	base	19	sin_dano
antes	base	20	sin_dano
antes	base	21	sin_dano
antes	base	22	sin_dano
antes	base	23	sin_dano
antes	base	24	sin_dano
antes	base	25	sin_dano
antes	base	26	sin_dano
antes	base	2	sin_dano
antes	base	3	sin_dano
antes	base	4	sin_dano
antes	base	5	sin_dano
antes	base	6	sin_dano
antes	base	7	sin_dano
antes	base	1	sin_dano
antes	base	8	sin_dano
antes	base	41	sin_dano
antes	base	42	sin_dano
antes	base	43	sin_dano
antes	base	44	sin_dano
antes	base	9	sin_dano
antes	base	10	sin_dano
antes	base	11	sin_dano
antes	base	12	sin_dano
antes	base	27	sin_dano
antes	base	28	sin_dano
antes	base	29	sin_dano
antes	base	30	sin_dano
antes	base	31	sin_dano
antes	base	32	sin_dano
antes	base	33	sin_dano
antes	base	34	sin_dano
antes	base	35	sin_dano
antes	base	36	sin_dano
antes	base	37	sin_dano
antes	base	13	sin_dano
antes	base	14	sin_dano
antes	base	15	sin_dano
antes	base	16	sin_dano
antes	base	38	sin_dano
antes	base	39	sin_dano
antes	base	40	sin_dano
antes	base	45	sin_dano
antes	base	46	sin_dano
despues	base	19	afectada_leve
despues	base	20	colapso_total
despues	base	21	colapso_total
despues	base	22	colapso_total
despues	base	23	afectada_leve
despues	base	24	afectada_leve
despues	base	25	afectada_leve
despues	base	26	colapso_total
despues	base	2	colapso_total
despues	base	3	colapso_parcial
despues	base	4	afectada_leve
despues	base	5	afectada_leve
despues	base	6	afectada_leve
despues	base	7	afectada_leve
despues	base	1	colapso_total
despues	base	8	afectada_leve
despues	base	41	colapso_total
despues	base	42	afectada_leve
despues	base	44	afectada_leve
despues	base	9	afectada_leve
despues	base	10	colapso_parcial
despues	base	11	afectada_leve
despues	base	12	colapso_parcial
despues	base	27	afectada_leve
despues	base	28	colapso_total
despues	base	29	afectada_leve
despues	base	30	colapso_parcial
despues	base	31	afectada_leve
despues	base	32	colapso_parcial
despues	base	33	colapso_parcial
despues	base	34	colapso_parcial
despues	base	35	colapso_parcial
despues	base	36	colapso_parcial
despues	base	37	colapso_parcial
despues	base	13	colapso_parcial
despues	base	14	afectada_leve
despues	base	15	colapso_parcial
despues	base	16	afectada_leve
despues	base	38	afectada_leve
despues	base	39	afectada_leve
despues	base	40	colapso_parcial
despues	base	45	afectada_leve
despues	base	46	afectada_leve
antes	base	17	sin_dano
antes	base	18	sin_dano
despues	base	17	afectada_leve
despues	base	18	afectada_leve
simulacion	prueba	44	sin_dano
despues	base	43	colapso_total
simulacion	prueba	9	sin_dano
simulacion	prueba	10	sin_dano
simulacion	prueba	11	sin_dano
simulacion	prueba	12	sin_dano
simulacion	prueba	27	sin_dano
simulacion	prueba	28	sin_dano
simulacion	prueba	29	sin_dano
simulacion	prueba	30	sin_dano
simulacion	prueba	31	sin_dano
simulacion	prueba	32	sin_dano
simulacion	prueba	33	sin_dano
simulacion	prueba	34	sin_dano
simulacion	prueba	35	sin_dano
simulacion	prueba	36	sin_dano
simulacion	prueba	37	sin_dano
simulacion	prueba	13	sin_dano
simulacion	prueba	14	sin_dano
simulacion	prueba	15	sin_dano
simulacion	prueba	16	sin_dano
simulacion	prueba	38	sin_dano
simulacion	prueba	39	sin_dano
simulacion	prueba	40	sin_dano
simulacion	prueba	45	sin_dano
simulacion	prueba	46	sin_dano
simulacion	prueba	17	sin_dano
simulacion	prueba	18	sin_dano
simulacion	se8c845ecd9	19	sin_dano
simulacion	se8c845ecd9	20	sin_dano
simulacion	se8c845ecd9	21	sin_dano
simulacion	se8c845ecd9	22	sin_dano
simulacion	se8c845ecd9	23	sin_dano
simulacion	se8c845ecd9	24	sin_dano
simulacion	s50bd328e7f	19	sin_dano
simulacion	s50bd328e7f	20	sin_dano
simulacion	s50bd328e7f	21	sin_dano
simulacion	s50bd328e7f	22	sin_dano
simulacion	s50bd328e7f	23	sin_dano
simulacion	s50bd328e7f	24	sin_dano
simulacion	s50bd328e7f	25	sin_dano
simulacion	s50bd328e7f	26	sin_dano
simulacion	s50bd328e7f	2	sin_dano
simulacion	s50bd328e7f	3	sin_dano
simulacion	s50bd328e7f	4	sin_dano
simulacion	s50bd328e7f	5	sin_dano
simulacion	s50bd328e7f	6	sin_dano
simulacion	s50bd328e7f	7	sin_dano
simulacion	s50bd328e7f	1	sin_dano
simulacion	s50bd328e7f	8	sin_dano
simulacion	s50bd328e7f	41	sin_dano
simulacion	s50bd328e7f	42	sin_dano
simulacion	s50bd328e7f	43	sin_dano
simulacion	s50bd328e7f	44	sin_dano
simulacion	s50bd328e7f	9	sin_dano
simulacion	s50bd328e7f	10	sin_dano
simulacion	s50bd328e7f	11	sin_dano
simulacion	s50bd328e7f	12	sin_dano
simulacion	s50bd328e7f	27	sin_dano
simulacion	s50bd328e7f	28	sin_dano
simulacion	s50bd328e7f	29	sin_dano
simulacion	s50bd328e7f	30	sin_dano
simulacion	s50bd328e7f	31	sin_dano
simulacion	s50bd328e7f	32	sin_dano
simulacion	s50bd328e7f	33	sin_dano
simulacion	s50bd328e7f	34	sin_dano
simulacion	s50bd328e7f	35	sin_dano
simulacion	s50bd328e7f	36	sin_dano
simulacion	s50bd328e7f	37	sin_dano
simulacion	s50bd328e7f	13	sin_dano
simulacion	s50bd328e7f	14	sin_dano
simulacion	s50bd328e7f	15	sin_dano
simulacion	s50bd328e7f	16	sin_dano
simulacion	s50bd328e7f	38	sin_dano
simulacion	s50bd328e7f	39	sin_dano
simulacion	s50bd328e7f	40	sin_dano
simulacion	s50bd328e7f	45	sin_dano
simulacion	s50bd328e7f	46	sin_dano
simulacion	s50bd328e7f	17	sin_dano
simulacion	s50bd328e7f	18	sin_dano
simulacion	s1662d29df5	19	sin_dano
simulacion	s1662d29df5	20	sin_dano
simulacion	s1662d29df5	21	sin_dano
simulacion	s1662d29df5	22	sin_dano
simulacion	s1662d29df5	23	sin_dano
simulacion	s1662d29df5	24	sin_dano
simulacion	prueba	19	sin_dano
simulacion	prueba	20	sin_dano
simulacion	prueba	21	sin_dano
simulacion	prueba	22	sin_dano
simulacion	prueba	23	sin_dano
simulacion	prueba	24	sin_dano
simulacion	prueba	25	sin_dano
simulacion	prueba	26	sin_dano
simulacion	prueba	2	sin_dano
simulacion	prueba	3	sin_dano
simulacion	prueba	4	sin_dano
simulacion	prueba	5	sin_dano
simulacion	prueba	6	sin_dano
simulacion	prueba	7	sin_dano
simulacion	prueba	1	sin_dano
simulacion	prueba	8	sin_dano
simulacion	prueba	41	sin_dano
simulacion	prueba	42	sin_dano
simulacion	prueba	43	sin_dano
simulacion	se8c845ecd9	25	sin_dano
simulacion	se8c845ecd9	26	sin_dano
simulacion	se8c845ecd9	2	sin_dano
simulacion	se8c845ecd9	3	sin_dano
simulacion	se8c845ecd9	4	sin_dano
simulacion	se8c845ecd9	5	sin_dano
simulacion	se8c845ecd9	6	sin_dano
simulacion	se8c845ecd9	7	sin_dano
simulacion	se8c845ecd9	1	sin_dano
simulacion	se8c845ecd9	8	sin_dano
simulacion	se8c845ecd9	41	sin_dano
simulacion	se8c845ecd9	42	sin_dano
simulacion	se8c845ecd9	43	sin_dano
simulacion	se8c845ecd9	44	sin_dano
simulacion	se8c845ecd9	9	sin_dano
simulacion	se8c845ecd9	10	sin_dano
simulacion	se8c845ecd9	11	sin_dano
simulacion	se8c845ecd9	12	sin_dano
simulacion	se8c845ecd9	27	sin_dano
simulacion	se8c845ecd9	28	sin_dano
simulacion	se8c845ecd9	29	sin_dano
simulacion	se8c845ecd9	30	sin_dano
simulacion	se8c845ecd9	31	sin_dano
simulacion	se8c845ecd9	32	sin_dano
simulacion	se8c845ecd9	33	sin_dano
simulacion	se8c845ecd9	34	sin_dano
simulacion	se8c845ecd9	35	sin_dano
simulacion	se8c845ecd9	36	sin_dano
simulacion	se8c845ecd9	37	sin_dano
simulacion	se8c845ecd9	13	sin_dano
simulacion	se8c845ecd9	14	sin_dano
simulacion	se8c845ecd9	15	sin_dano
simulacion	se8c845ecd9	16	sin_dano
simulacion	se8c845ecd9	38	sin_dano
simulacion	se8c845ecd9	39	sin_dano
simulacion	se8c845ecd9	40	sin_dano
simulacion	se8c845ecd9	45	sin_dano
simulacion	se8c845ecd9	46	sin_dano
simulacion	se8c845ecd9	17	sin_dano
simulacion	se8c845ecd9	18	sin_dano
simulacion	s6f8ce6f031	19	sin_dano
simulacion	s6f8ce6f031	20	sin_dano
simulacion	s6f8ce6f031	21	sin_dano
simulacion	s6f8ce6f031	22	sin_dano
simulacion	s6f8ce6f031	23	sin_dano
simulacion	s6f8ce6f031	24	sin_dano
simulacion	s6f8ce6f031	25	sin_dano
simulacion	s6f8ce6f031	26	sin_dano
simulacion	s6f8ce6f031	2	sin_dano
simulacion	s6f8ce6f031	3	sin_dano
simulacion	s6f8ce6f031	4	sin_dano
simulacion	s6f8ce6f031	5	sin_dano
simulacion	s6f8ce6f031	6	sin_dano
simulacion	s6f8ce6f031	7	sin_dano
simulacion	s6f8ce6f031	1	sin_dano
simulacion	s6f8ce6f031	8	sin_dano
simulacion	s6f8ce6f031	41	sin_dano
simulacion	s6f8ce6f031	42	sin_dano
simulacion	s6f8ce6f031	43	sin_dano
simulacion	s6f8ce6f031	44	sin_dano
simulacion	s6f8ce6f031	9	sin_dano
simulacion	s6f8ce6f031	10	sin_dano
simulacion	s6f8ce6f031	11	sin_dano
simulacion	s6f8ce6f031	12	sin_dano
simulacion	s6f8ce6f031	27	sin_dano
simulacion	s6f8ce6f031	28	sin_dano
simulacion	s6f8ce6f031	29	sin_dano
simulacion	s6f8ce6f031	30	sin_dano
simulacion	s6f8ce6f031	31	sin_dano
simulacion	s6f8ce6f031	32	sin_dano
simulacion	s6f8ce6f031	33	sin_dano
simulacion	s6f8ce6f031	34	sin_dano
simulacion	s6f8ce6f031	35	sin_dano
simulacion	s6f8ce6f031	36	sin_dano
simulacion	s6f8ce6f031	37	sin_dano
simulacion	s6f8ce6f031	13	sin_dano
simulacion	s6f8ce6f031	14	sin_dano
simulacion	s6f8ce6f031	15	sin_dano
simulacion	s6f8ce6f031	16	sin_dano
simulacion	s6f8ce6f031	38	sin_dano
simulacion	s6f8ce6f031	39	sin_dano
simulacion	s6f8ce6f031	40	sin_dano
simulacion	s6f8ce6f031	45	sin_dano
simulacion	s6f8ce6f031	46	sin_dano
simulacion	s6f8ce6f031	17	sin_dano
simulacion	s6f8ce6f031	18	sin_dano
simulacion	s0413428c13	19	sin_dano
simulacion	s0413428c13	20	sin_dano
simulacion	s0413428c13	21	sin_dano
simulacion	s0413428c13	22	sin_dano
simulacion	s0413428c13	23	sin_dano
simulacion	s0413428c13	24	sin_dano
simulacion	s0413428c13	25	sin_dano
simulacion	s0413428c13	26	sin_dano
simulacion	s0413428c13	2	sin_dano
simulacion	s0413428c13	3	sin_dano
simulacion	s0413428c13	4	sin_dano
simulacion	s0413428c13	5	sin_dano
simulacion	s0413428c13	6	sin_dano
simulacion	s0413428c13	7	sin_dano
simulacion	s0413428c13	1	sin_dano
simulacion	s0413428c13	8	sin_dano
simulacion	s0413428c13	41	sin_dano
simulacion	s0413428c13	42	sin_dano
simulacion	s0413428c13	43	sin_dano
simulacion	s0413428c13	44	sin_dano
simulacion	s0413428c13	9	sin_dano
simulacion	s0413428c13	10	sin_dano
simulacion	s0413428c13	11	sin_dano
simulacion	s0413428c13	12	sin_dano
simulacion	s0413428c13	27	sin_dano
simulacion	s0413428c13	28	sin_dano
simulacion	s0413428c13	29	sin_dano
simulacion	s0413428c13	30	sin_dano
simulacion	s0413428c13	31	sin_dano
simulacion	s0413428c13	32	sin_dano
simulacion	s0413428c13	33	sin_dano
simulacion	s0413428c13	34	sin_dano
simulacion	s0413428c13	35	sin_dano
simulacion	s0413428c13	36	sin_dano
simulacion	s0413428c13	37	sin_dano
simulacion	s0413428c13	13	sin_dano
simulacion	s0413428c13	14	sin_dano
simulacion	s0413428c13	15	sin_dano
simulacion	s0413428c13	16	sin_dano
simulacion	s0413428c13	38	sin_dano
simulacion	s0413428c13	39	sin_dano
simulacion	s0413428c13	40	sin_dano
simulacion	s0413428c13	45	sin_dano
simulacion	s0413428c13	46	sin_dano
simulacion	s0413428c13	17	sin_dano
simulacion	s0413428c13	18	sin_dano
simulacion	s1662d29df5	25	sin_dano
simulacion	s1662d29df5	26	sin_dano
simulacion	s1662d29df5	2	sin_dano
simulacion	s1662d29df5	3	sin_dano
simulacion	s1662d29df5	4	sin_dano
simulacion	s1662d29df5	5	sin_dano
simulacion	s1662d29df5	6	sin_dano
simulacion	s1662d29df5	7	sin_dano
simulacion	s1662d29df5	1	sin_dano
simulacion	s1662d29df5	8	sin_dano
simulacion	s1662d29df5	41	sin_dano
simulacion	s1662d29df5	42	sin_dano
simulacion	s1662d29df5	43	sin_dano
simulacion	s1662d29df5	44	sin_dano
simulacion	s1662d29df5	9	sin_dano
simulacion	s1662d29df5	10	sin_dano
simulacion	s1662d29df5	11	sin_dano
simulacion	s1662d29df5	12	sin_dano
simulacion	s1662d29df5	27	sin_dano
simulacion	s1662d29df5	28	sin_dano
simulacion	s1662d29df5	29	sin_dano
simulacion	s1662d29df5	30	sin_dano
simulacion	s1662d29df5	31	sin_dano
simulacion	s1662d29df5	32	sin_dano
simulacion	s1662d29df5	33	sin_dano
simulacion	s1662d29df5	34	sin_dano
simulacion	s1662d29df5	35	sin_dano
simulacion	s1662d29df5	36	sin_dano
simulacion	s1662d29df5	37	sin_dano
simulacion	s1662d29df5	13	sin_dano
simulacion	s1662d29df5	14	sin_dano
simulacion	s1662d29df5	15	sin_dano
simulacion	s1662d29df5	16	sin_dano
simulacion	s1662d29df5	38	sin_dano
simulacion	s1662d29df5	39	sin_dano
simulacion	s1662d29df5	40	sin_dano
simulacion	s1662d29df5	45	sin_dano
simulacion	s1662d29df5	46	sin_dano
simulacion	s1662d29df5	17	sin_dano
simulacion	s1662d29df5	18	sin_dano
simulacion	s61cd91a577	19	sin_dano
simulacion	s61cd91a577	20	sin_dano
simulacion	s61cd91a577	21	sin_dano
simulacion	s61cd91a577	22	sin_dano
simulacion	s61cd91a577	23	sin_dano
simulacion	s61cd91a577	24	sin_dano
simulacion	s61cd91a577	25	sin_dano
simulacion	s61cd91a577	26	sin_dano
simulacion	s61cd91a577	2	sin_dano
simulacion	s61cd91a577	3	sin_dano
simulacion	s61cd91a577	4	sin_dano
simulacion	s61cd91a577	5	sin_dano
simulacion	s61cd91a577	6	sin_dano
simulacion	s61cd91a577	7	sin_dano
simulacion	s61cd91a577	1	sin_dano
simulacion	s61cd91a577	8	sin_dano
simulacion	s61cd91a577	41	sin_dano
simulacion	s61cd91a577	42	sin_dano
simulacion	s61cd91a577	43	sin_dano
simulacion	s61cd91a577	44	sin_dano
simulacion	s61cd91a577	9	sin_dano
simulacion	s61cd91a577	10	sin_dano
simulacion	s61cd91a577	11	sin_dano
simulacion	s61cd91a577	12	sin_dano
simulacion	s61cd91a577	27	sin_dano
simulacion	s61cd91a577	28	sin_dano
simulacion	s61cd91a577	29	sin_dano
simulacion	s61cd91a577	30	sin_dano
simulacion	s61cd91a577	31	sin_dano
simulacion	s61cd91a577	32	sin_dano
simulacion	s61cd91a577	33	sin_dano
simulacion	s61cd91a577	34	sin_dano
simulacion	s61cd91a577	35	sin_dano
simulacion	s61cd91a577	36	sin_dano
simulacion	s61cd91a577	37	sin_dano
simulacion	s61cd91a577	13	sin_dano
simulacion	s61cd91a577	14	sin_dano
simulacion	s61cd91a577	15	sin_dano
simulacion	s61cd91a577	16	sin_dano
simulacion	s61cd91a577	38	sin_dano
simulacion	s61cd91a577	39	sin_dano
simulacion	s61cd91a577	40	sin_dano
simulacion	s61cd91a577	45	sin_dano
simulacion	s61cd91a577	46	sin_dano
simulacion	s61cd91a577	17	sin_dano
simulacion	s61cd91a577	18	sin_dano
simulacion	s8419d72a77	7	sin_dano
simulacion	s8419d72a77	1	sin_dano
simulacion	s8419d72a77	8	sin_dano
simulacion	s8419d72a77	41	sin_dano
simulacion	s8419d72a77	42	sin_dano
simulacion	s8419d72a77	43	sin_dano
simulacion	sbcdc0502da	19	sin_dano
simulacion	sbcdc0502da	20	sin_dano
simulacion	sbcdc0502da	21	sin_dano
simulacion	sbcdc0502da	22	sin_dano
simulacion	sbcdc0502da	23	sin_dano
simulacion	sbcdc0502da	24	sin_dano
simulacion	sbcdc0502da	25	sin_dano
simulacion	sbcdc0502da	26	sin_dano
simulacion	sbcdc0502da	2	sin_dano
simulacion	sbcdc0502da	3	sin_dano
simulacion	sbcdc0502da	4	sin_dano
simulacion	sbcdc0502da	5	sin_dano
simulacion	sbcdc0502da	6	sin_dano
simulacion	sbcdc0502da	7	sin_dano
simulacion	sbcdc0502da	1	sin_dano
simulacion	sbcdc0502da	8	sin_dano
simulacion	sbcdc0502da	41	sin_dano
simulacion	sbcdc0502da	42	sin_dano
simulacion	sbcdc0502da	43	sin_dano
simulacion	sbcdc0502da	44	sin_dano
simulacion	sbcdc0502da	9	sin_dano
simulacion	sbcdc0502da	10	sin_dano
simulacion	sbcdc0502da	11	sin_dano
simulacion	sbcdc0502da	12	sin_dano
simulacion	sbcdc0502da	27	sin_dano
simulacion	sbcdc0502da	28	sin_dano
simulacion	sbcdc0502da	29	sin_dano
simulacion	sbcdc0502da	30	sin_dano
simulacion	sbcdc0502da	31	sin_dano
simulacion	sbcdc0502da	32	sin_dano
simulacion	sbcdc0502da	33	sin_dano
simulacion	sbcdc0502da	34	sin_dano
simulacion	sbcdc0502da	35	sin_dano
simulacion	sbcdc0502da	36	sin_dano
simulacion	sbcdc0502da	37	sin_dano
simulacion	sbcdc0502da	13	sin_dano
simulacion	sbcdc0502da	14	sin_dano
simulacion	sbcdc0502da	15	sin_dano
simulacion	sbcdc0502da	16	sin_dano
simulacion	sbcdc0502da	38	sin_dano
simulacion	sbcdc0502da	39	sin_dano
simulacion	sbcdc0502da	40	sin_dano
simulacion	sbcdc0502da	45	sin_dano
simulacion	sbcdc0502da	46	sin_dano
simulacion	sbcdc0502da	17	sin_dano
simulacion	sbcdc0502da	18	sin_dano
simulacion	s0f4dd06250	19	sin_dano
simulacion	s0f4dd06250	20	sin_dano
simulacion	s0f4dd06250	21	sin_dano
simulacion	s0f4dd06250	22	sin_dano
simulacion	s0f4dd06250	23	sin_dano
simulacion	s0f4dd06250	24	sin_dano
simulacion	s0f4dd06250	25	sin_dano
simulacion	s0f4dd06250	26	sin_dano
simulacion	s0f4dd06250	2	sin_dano
simulacion	s0f4dd06250	3	sin_dano
simulacion	s0f4dd06250	4	sin_dano
simulacion	s8419d72a77	44	sin_dano
simulacion	s8419d72a77	9	sin_dano
simulacion	s8419d72a77	10	sin_dano
simulacion	s8419d72a77	11	sin_dano
simulacion	s8419d72a77	12	sin_dano
simulacion	s8419d72a77	27	sin_dano
simulacion	s0f4dd06250	5	sin_dano
simulacion	s0f4dd06250	6	sin_dano
simulacion	s0f4dd06250	7	sin_dano
simulacion	s0f4dd06250	1	sin_dano
simulacion	s0f4dd06250	8	sin_dano
simulacion	s0f4dd06250	41	sin_dano
simulacion	s0f4dd06250	42	sin_dano
simulacion	s0f4dd06250	43	sin_dano
simulacion	s0f4dd06250	44	sin_dano
simulacion	s0f4dd06250	9	sin_dano
simulacion	s0f4dd06250	10	sin_dano
simulacion	s0f4dd06250	11	sin_dano
simulacion	s0f4dd06250	12	sin_dano
simulacion	s0f4dd06250	27	sin_dano
simulacion	s0f4dd06250	28	sin_dano
simulacion	s0f4dd06250	29	sin_dano
simulacion	s0f4dd06250	30	sin_dano
simulacion	s0f4dd06250	31	sin_dano
simulacion	s0f4dd06250	32	sin_dano
simulacion	s0f4dd06250	33	sin_dano
simulacion	s0f4dd06250	34	sin_dano
simulacion	s0f4dd06250	35	sin_dano
simulacion	s0f4dd06250	36	sin_dano
simulacion	s0f4dd06250	37	sin_dano
simulacion	s0f4dd06250	13	sin_dano
simulacion	s0f4dd06250	14	sin_dano
simulacion	s0f4dd06250	15	sin_dano
simulacion	s0f4dd06250	16	sin_dano
simulacion	s0f4dd06250	38	sin_dano
simulacion	s0f4dd06250	39	sin_dano
simulacion	s0f4dd06250	40	sin_dano
simulacion	s0f4dd06250	45	sin_dano
simulacion	s0f4dd06250	46	sin_dano
simulacion	s0f4dd06250	17	sin_dano
simulacion	s0f4dd06250	18	sin_dano
simulacion	s57a27c547d	22	sin_dano
simulacion	s57a27c547d	23	sin_dano
simulacion	s57a27c547d	24	sin_dano
simulacion	s57a27c547d	25	sin_dano
simulacion	s57a27c547d	26	sin_dano
simulacion	s57a27c547d	2	sin_dano
simulacion	s57a27c547d	4	sin_dano
simulacion	s57a27c547d	5	sin_dano
simulacion	s57a27c547d	6	sin_dano
simulacion	s57a27c547d	7	sin_dano
simulacion	s57a27c547d	1	sin_dano
simulacion	s57a27c547d	8	sin_dano
simulacion	s57a27c547d	41	sin_dano
simulacion	s57a27c547d	42	sin_dano
simulacion	s57a27c547d	43	sin_dano
simulacion	s57a27c547d	44	sin_dano
simulacion	s57a27c547d	9	sin_dano
simulacion	s57a27c547d	10	sin_dano
simulacion	s57a27c547d	11	sin_dano
simulacion	s57a27c547d	12	sin_dano
simulacion	s57a27c547d	27	sin_dano
simulacion	s57a27c547d	28	sin_dano
simulacion	s57a27c547d	29	sin_dano
simulacion	s57a27c547d	30	sin_dano
simulacion	s57a27c547d	31	sin_dano
simulacion	s57a27c547d	32	sin_dano
simulacion	s57a27c547d	33	sin_dano
simulacion	s57a27c547d	34	sin_dano
simulacion	s57a27c547d	35	sin_dano
simulacion	s57a27c547d	36	sin_dano
simulacion	s57a27c547d	37	sin_dano
simulacion	s57a27c547d	13	sin_dano
simulacion	s57a27c547d	14	sin_dano
simulacion	s57a27c547d	15	sin_dano
simulacion	s57a27c547d	16	sin_dano
simulacion	s57a27c547d	38	sin_dano
simulacion	s57a27c547d	39	sin_dano
simulacion	s57a27c547d	40	sin_dano
simulacion	s57a27c547d	45	sin_dano
simulacion	s57a27c547d	46	sin_dano
simulacion	s57a27c547d	17	sin_dano
simulacion	s57a27c547d	18	sin_dano
simulacion	validacion	19	afectada_leve
simulacion	s57a27c547d	21	colapso_total
simulacion	s57a27c547d	19	colapso_total
simulacion	s57a27c547d	20	colapso_parcial
simulacion	s57a27c547d	3	afectada_leve
simulacion	saa7ac3c714	19	sin_dano
simulacion	saa7ac3c714	20	sin_dano
simulacion	saa7ac3c714	21	sin_dano
simulacion	saa7ac3c714	22	sin_dano
simulacion	saa7ac3c714	23	sin_dano
simulacion	saa7ac3c714	24	sin_dano
simulacion	saa7ac3c714	25	sin_dano
simulacion	saa7ac3c714	26	sin_dano
simulacion	saa7ac3c714	2	sin_dano
simulacion	saa7ac3c714	3	sin_dano
simulacion	saa7ac3c714	4	sin_dano
simulacion	saa7ac3c714	5	sin_dano
simulacion	saa7ac3c714	6	sin_dano
simulacion	saa7ac3c714	7	sin_dano
simulacion	saa7ac3c714	1	sin_dano
simulacion	saa7ac3c714	8	sin_dano
simulacion	saa7ac3c714	41	sin_dano
simulacion	saa7ac3c714	42	sin_dano
simulacion	saa7ac3c714	43	sin_dano
simulacion	saa7ac3c714	44	sin_dano
simulacion	saa7ac3c714	9	sin_dano
simulacion	saa7ac3c714	10	sin_dano
simulacion	saa7ac3c714	11	sin_dano
simulacion	saa7ac3c714	12	sin_dano
simulacion	saa7ac3c714	27	sin_dano
simulacion	saa7ac3c714	28	sin_dano
simulacion	saa7ac3c714	29	sin_dano
simulacion	saa7ac3c714	30	sin_dano
simulacion	saa7ac3c714	31	sin_dano
simulacion	validacion	20	colapso_total
simulacion	validacion	21	colapso_total
simulacion	validacion	22	colapso_total
simulacion	saa7ac3c714	32	sin_dano
simulacion	saa7ac3c714	33	sin_dano
simulacion	saa7ac3c714	34	sin_dano
simulacion	saa7ac3c714	35	sin_dano
simulacion	validacion	23	afectada_leve
simulacion	validacion	24	afectada_leve
simulacion	validacion	25	afectada_leve
simulacion	validacion	26	colapso_total
simulacion	validacion	2	colapso_total
simulacion	validacion	3	colapso_parcial
simulacion	validacion	4	afectada_leve
simulacion	validacion	5	afectada_leve
simulacion	validacion	6	afectada_leve
simulacion	validacion	7	afectada_leve
simulacion	validacion	1	colapso_total
simulacion	validacion	8	afectada_leve
simulacion	validacion	41	colapso_total
simulacion	validacion	42	afectada_leve
simulacion	validacion	43	colapso_total
simulacion	validacion	44	afectada_leve
simulacion	validacion	9	afectada_leve
simulacion	validacion	10	colapso_parcial
simulacion	validacion	11	afectada_leve
simulacion	validacion	12	colapso_parcial
simulacion	validacion	27	afectada_leve
simulacion	validacion	28	colapso_total
simulacion	validacion	29	afectada_leve
simulacion	validacion	30	colapso_parcial
simulacion	validacion	31	afectada_leve
simulacion	validacion	32	colapso_parcial
simulacion	validacion	33	colapso_parcial
simulacion	validacion	34	colapso_parcial
simulacion	validacion	35	colapso_parcial
simulacion	validacion	36	colapso_parcial
simulacion	validacion	37	colapso_parcial
simulacion	validacion	13	colapso_parcial
simulacion	validacion	14	afectada_leve
simulacion	validacion	15	colapso_parcial
simulacion	validacion	16	afectada_leve
simulacion	validacion	38	afectada_leve
simulacion	validacion	39	afectada_leve
simulacion	validacion	40	colapso_parcial
simulacion	validacion	45	afectada_leve
simulacion	validacion	46	afectada_leve
simulacion	validacion	17	afectada_leve
simulacion	validacion	18	afectada_leve
simulacion	se75f401cdf	19	sin_dano
simulacion	se75f401cdf	20	sin_dano
simulacion	se75f401cdf	21	sin_dano
simulacion	se75f401cdf	22	sin_dano
simulacion	se75f401cdf	23	sin_dano
simulacion	se75f401cdf	24	sin_dano
simulacion	se75f401cdf	25	sin_dano
simulacion	se75f401cdf	26	sin_dano
simulacion	se75f401cdf	2	sin_dano
simulacion	se75f401cdf	3	sin_dano
simulacion	se75f401cdf	4	sin_dano
simulacion	se75f401cdf	5	sin_dano
simulacion	se75f401cdf	6	sin_dano
simulacion	se75f401cdf	7	sin_dano
simulacion	se75f401cdf	1	sin_dano
simulacion	se75f401cdf	8	sin_dano
simulacion	se75f401cdf	41	sin_dano
simulacion	se75f401cdf	42	sin_dano
simulacion	se75f401cdf	43	sin_dano
simulacion	se75f401cdf	44	sin_dano
simulacion	se75f401cdf	9	sin_dano
simulacion	se75f401cdf	10	sin_dano
simulacion	se75f401cdf	11	sin_dano
simulacion	se75f401cdf	12	sin_dano
simulacion	se75f401cdf	27	sin_dano
simulacion	se75f401cdf	28	sin_dano
simulacion	se75f401cdf	29	sin_dano
simulacion	se75f401cdf	30	sin_dano
simulacion	se75f401cdf	31	sin_dano
simulacion	se75f401cdf	32	sin_dano
simulacion	se75f401cdf	33	sin_dano
simulacion	se75f401cdf	34	sin_dano
simulacion	se75f401cdf	35	sin_dano
simulacion	se75f401cdf	36	sin_dano
simulacion	se75f401cdf	37	sin_dano
simulacion	se75f401cdf	13	sin_dano
simulacion	se75f401cdf	14	sin_dano
simulacion	se75f401cdf	15	sin_dano
simulacion	se75f401cdf	16	sin_dano
simulacion	se75f401cdf	38	sin_dano
simulacion	se75f401cdf	39	sin_dano
simulacion	se75f401cdf	40	sin_dano
simulacion	se75f401cdf	45	sin_dano
simulacion	se75f401cdf	46	sin_dano
simulacion	se75f401cdf	17	sin_dano
simulacion	se75f401cdf	18	sin_dano
simulacion	saa7ac3c714	36	sin_dano
simulacion	saa7ac3c714	37	sin_dano
simulacion	saa7ac3c714	13	sin_dano
simulacion	saa7ac3c714	14	sin_dano
simulacion	saa7ac3c714	15	sin_dano
simulacion	saa7ac3c714	16	sin_dano
simulacion	saa7ac3c714	38	sin_dano
simulacion	saa7ac3c714	39	sin_dano
simulacion	saa7ac3c714	40	sin_dano
simulacion	saa7ac3c714	45	sin_dano
simulacion	saa7ac3c714	46	sin_dano
simulacion	saa7ac3c714	17	sin_dano
simulacion	saa7ac3c714	18	sin_dano
simulacion	s8419d72a77	19	sin_dano
simulacion	s8419d72a77	20	sin_dano
simulacion	s8419d72a77	21	sin_dano
simulacion	s8419d72a77	22	sin_dano
simulacion	s8419d72a77	23	sin_dano
simulacion	s8419d72a77	24	sin_dano
simulacion	s8419d72a77	25	sin_dano
simulacion	s8419d72a77	26	sin_dano
simulacion	s8419d72a77	2	sin_dano
simulacion	s8419d72a77	3	sin_dano
simulacion	s8419d72a77	4	sin_dano
simulacion	s8419d72a77	5	sin_dano
simulacion	s8419d72a77	6	sin_dano
simulacion	s8419d72a77	28	sin_dano
simulacion	s8419d72a77	29	sin_dano
simulacion	s8419d72a77	30	sin_dano
simulacion	s8419d72a77	31	sin_dano
simulacion	s8419d72a77	32	sin_dano
simulacion	s8419d72a77	33	sin_dano
simulacion	s8419d72a77	34	sin_dano
simulacion	s8419d72a77	35	sin_dano
simulacion	s8419d72a77	36	sin_dano
simulacion	s8419d72a77	37	sin_dano
simulacion	s8419d72a77	13	sin_dano
simulacion	s8419d72a77	14	sin_dano
simulacion	s8419d72a77	15	sin_dano
simulacion	s8419d72a77	16	sin_dano
simulacion	s8419d72a77	38	sin_dano
simulacion	s8419d72a77	39	sin_dano
simulacion	s8419d72a77	40	sin_dano
simulacion	s8419d72a77	45	sin_dano
simulacion	s8419d72a77	46	sin_dano
simulacion	s8419d72a77	17	sin_dano
simulacion	s8419d72a77	18	sin_dano
simulacion	s2a33e30ee1	19	sin_dano
simulacion	s2a33e30ee1	20	sin_dano
simulacion	s2a33e30ee1	21	sin_dano
simulacion	s2a33e30ee1	22	sin_dano
simulacion	s2a33e30ee1	23	sin_dano
simulacion	s2a33e30ee1	24	sin_dano
simulacion	s2a33e30ee1	25	sin_dano
simulacion	s2a33e30ee1	26	sin_dano
simulacion	s2a33e30ee1	2	sin_dano
simulacion	s2a33e30ee1	3	sin_dano
simulacion	s2a33e30ee1	4	sin_dano
simulacion	s2a33e30ee1	5	sin_dano
simulacion	s2a33e30ee1	6	sin_dano
simulacion	s2a33e30ee1	7	sin_dano
simulacion	s2a33e30ee1	1	sin_dano
simulacion	s2a33e30ee1	8	sin_dano
simulacion	s2a33e30ee1	41	sin_dano
simulacion	s2a33e30ee1	42	sin_dano
simulacion	s2a33e30ee1	43	sin_dano
simulacion	s2a33e30ee1	44	sin_dano
simulacion	s2a33e30ee1	9	sin_dano
simulacion	s2a33e30ee1	10	sin_dano
simulacion	s2a33e30ee1	11	sin_dano
simulacion	s2a33e30ee1	12	sin_dano
simulacion	s2a33e30ee1	27	sin_dano
simulacion	s2a33e30ee1	28	sin_dano
simulacion	s2a33e30ee1	29	sin_dano
simulacion	s2a33e30ee1	30	sin_dano
simulacion	s2a33e30ee1	31	sin_dano
simulacion	s2a33e30ee1	32	sin_dano
simulacion	s2a33e30ee1	33	sin_dano
simulacion	s2a33e30ee1	34	sin_dano
simulacion	s2a33e30ee1	35	sin_dano
simulacion	s2a33e30ee1	36	sin_dano
simulacion	s2a33e30ee1	37	sin_dano
simulacion	s2a33e30ee1	13	sin_dano
simulacion	s2a33e30ee1	14	sin_dano
simulacion	s2a33e30ee1	15	sin_dano
simulacion	s2a33e30ee1	16	sin_dano
simulacion	s2a33e30ee1	38	sin_dano
simulacion	s2a33e30ee1	39	sin_dano
simulacion	s2a33e30ee1	40	sin_dano
simulacion	s2a33e30ee1	45	sin_dano
simulacion	s2a33e30ee1	46	sin_dano
simulacion	s2a33e30ee1	17	sin_dano
simulacion	s2a33e30ee1	18	sin_dano
simulacion	sadb934d385	19	sin_dano
simulacion	sadb934d385	20	sin_dano
simulacion	sadb934d385	21	sin_dano
simulacion	sadb934d385	22	sin_dano
simulacion	sadb934d385	23	sin_dano
simulacion	sadb934d385	24	sin_dano
simulacion	sadb934d385	25	sin_dano
simulacion	sadb934d385	26	sin_dano
simulacion	sadb934d385	2	sin_dano
simulacion	sadb934d385	3	sin_dano
simulacion	sadb934d385	4	sin_dano
simulacion	sadb934d385	5	sin_dano
simulacion	sadb934d385	6	sin_dano
simulacion	sadb934d385	7	sin_dano
simulacion	sadb934d385	1	sin_dano
simulacion	sadb934d385	8	sin_dano
simulacion	sadb934d385	41	sin_dano
simulacion	sadb934d385	42	sin_dano
simulacion	sadb934d385	43	sin_dano
simulacion	sadb934d385	44	sin_dano
simulacion	sadb934d385	9	sin_dano
simulacion	sadb934d385	10	sin_dano
simulacion	sadb934d385	11	sin_dano
simulacion	sadb934d385	12	sin_dano
simulacion	sadb934d385	27	sin_dano
simulacion	sadb934d385	28	sin_dano
simulacion	sadb934d385	29	sin_dano
simulacion	sadb934d385	30	sin_dano
simulacion	sadb934d385	31	sin_dano
simulacion	sadb934d385	32	sin_dano
simulacion	sadb934d385	33	sin_dano
simulacion	sadb934d385	34	sin_dano
simulacion	sadb934d385	35	sin_dano
simulacion	sadb934d385	36	sin_dano
simulacion	sadb934d385	37	sin_dano
simulacion	sadb934d385	13	sin_dano
simulacion	sadb934d385	14	sin_dano
simulacion	sadb934d385	15	sin_dano
simulacion	sadb934d385	16	sin_dano
simulacion	sadb934d385	38	sin_dano
simulacion	sadb934d385	39	sin_dano
simulacion	sadb934d385	40	sin_dano
simulacion	sadb934d385	45	sin_dano
simulacion	sadb934d385	46	sin_dano
simulacion	sadb934d385	17	sin_dano
simulacion	sadb934d385	18	sin_dano
simulacion	s0ecf2d55f7	19	sin_dano
simulacion	s0ecf2d55f7	20	sin_dano
simulacion	s0ecf2d55f7	21	sin_dano
simulacion	s0ecf2d55f7	22	sin_dano
simulacion	s0ecf2d55f7	23	sin_dano
simulacion	s0ecf2d55f7	24	sin_dano
simulacion	s0ecf2d55f7	25	sin_dano
simulacion	s0ecf2d55f7	26	sin_dano
simulacion	s0ecf2d55f7	2	sin_dano
simulacion	s0ecf2d55f7	3	sin_dano
simulacion	s0ecf2d55f7	4	sin_dano
simulacion	s0ecf2d55f7	5	sin_dano
simulacion	s0ecf2d55f7	6	sin_dano
simulacion	s0ecf2d55f7	7	sin_dano
simulacion	s0ecf2d55f7	1	sin_dano
simulacion	s0ecf2d55f7	8	sin_dano
simulacion	s0ecf2d55f7	41	sin_dano
simulacion	s0ecf2d55f7	42	sin_dano
simulacion	s0ecf2d55f7	43	sin_dano
simulacion	s0ecf2d55f7	44	sin_dano
simulacion	s0ecf2d55f7	9	sin_dano
simulacion	s0ecf2d55f7	10	sin_dano
simulacion	s0ecf2d55f7	11	sin_dano
simulacion	s0ecf2d55f7	12	sin_dano
simulacion	s0ecf2d55f7	27	sin_dano
simulacion	s0ecf2d55f7	28	sin_dano
simulacion	s0ecf2d55f7	29	sin_dano
simulacion	s0ecf2d55f7	30	sin_dano
simulacion	s0ecf2d55f7	31	sin_dano
simulacion	s0ecf2d55f7	32	sin_dano
simulacion	s0ecf2d55f7	33	sin_dano
simulacion	s0ecf2d55f7	34	sin_dano
simulacion	s0ecf2d55f7	35	sin_dano
simulacion	s0ecf2d55f7	36	sin_dano
simulacion	s0ecf2d55f7	37	sin_dano
simulacion	s0ecf2d55f7	13	sin_dano
simulacion	s0ecf2d55f7	14	sin_dano
simulacion	s0ecf2d55f7	15	sin_dano
simulacion	s0ecf2d55f7	16	sin_dano
simulacion	s0ecf2d55f7	38	sin_dano
simulacion	s0ecf2d55f7	39	sin_dano
simulacion	s0ecf2d55f7	40	sin_dano
simulacion	s0ecf2d55f7	45	sin_dano
simulacion	s0ecf2d55f7	46	sin_dano
simulacion	s0ecf2d55f7	17	sin_dano
simulacion	s0ecf2d55f7	18	sin_dano
simulacion	sc1195efed5	19	sin_dano
simulacion	sc1195efed5	21	sin_dano
simulacion	sc1195efed5	22	sin_dano
simulacion	sc1195efed5	23	sin_dano
simulacion	sc1195efed5	24	sin_dano
simulacion	sc1195efed5	25	sin_dano
simulacion	sc1195efed5	26	sin_dano
simulacion	sc1195efed5	2	sin_dano
simulacion	sc1195efed5	3	sin_dano
simulacion	sc1195efed5	4	sin_dano
simulacion	sc1195efed5	5	sin_dano
simulacion	sc1195efed5	6	sin_dano
simulacion	sc1195efed5	7	sin_dano
simulacion	sc1195efed5	1	sin_dano
simulacion	sc1195efed5	8	sin_dano
simulacion	sc1195efed5	41	sin_dano
simulacion	sc1195efed5	42	sin_dano
simulacion	sc1195efed5	43	sin_dano
simulacion	sc1195efed5	44	sin_dano
simulacion	sc1195efed5	9	sin_dano
simulacion	sc1195efed5	10	sin_dano
simulacion	sc1195efed5	11	sin_dano
simulacion	sc1195efed5	12	sin_dano
simulacion	sc1195efed5	27	sin_dano
simulacion	sc1195efed5	28	sin_dano
simulacion	sc1195efed5	29	sin_dano
simulacion	sc1195efed5	30	sin_dano
simulacion	sc1195efed5	31	sin_dano
simulacion	sc1195efed5	32	sin_dano
simulacion	sc1195efed5	33	sin_dano
simulacion	sc1195efed5	34	sin_dano
simulacion	sc1195efed5	20	colapso_total
simulacion	sc1195efed5	35	sin_dano
simulacion	sc1195efed5	36	sin_dano
simulacion	sc1195efed5	37	sin_dano
simulacion	sc1195efed5	13	sin_dano
simulacion	sc1195efed5	14	sin_dano
simulacion	sc1195efed5	15	sin_dano
simulacion	sc1195efed5	16	sin_dano
simulacion	sc1195efed5	38	sin_dano
simulacion	sc1195efed5	39	sin_dano
simulacion	sc1195efed5	40	sin_dano
simulacion	sc1195efed5	45	sin_dano
simulacion	sc1195efed5	46	sin_dano
simulacion	sc1195efed5	17	sin_dano
simulacion	sc1195efed5	18	sin_dano
\.


--
-- Data for Name: predios; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.predios (id, uso, material, barrio, estado_post, dano_orig, altura_muro_m, altura_fuente, via_frente, geom) FROM stdin;
19	vivienda	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	8	0106000020CE7F00000100000001030000000100000005000000E9BF68C9CAC01C41A7CD0A1984826041FFD90DC243C11C4125506B2082826041C301F85E35C11C412BDCCC2F81826041E842C5A7B8C01C412382978483826041E9BF68C9CAC01C41A7CD0A1984826041
20	vivienda	Adobe	Huariracay	colapso_total	Colapsada	3.1	video	8	0106000020CE7F000001000000010300000001000000060000009456911242C11C41E4F861CC8182604183B1CFF143C11C41ED1C35EC818260411E52C33C64C11C4164B73E8581826041623C76B54EC11C410F7D941280826041FA5FF1D12FC11C41776C4F6E808260419456911242C11C41E4F861CC81826041
21	vivienda	Adobe	Huariracay	colapso_total	Colapsada	3.1	video	5	0106000020CE7F000001000000010300000001000000070000001DF85FA67EC11C4156CA211E8182604193D55DB466C11C4156DE68807F82604176178D6F4AC11C41157393C97F82604146A573AF4EC11C413556A61280826041623C76B54EC11C410F7D9412808260411E52C33C64C11C4164B73E85818260411DF85FA67EC11C4156CA211E81826041
22	vivienda	Adobe	Huariracay	colapso_total	Colapsada	2.8	video	5	0106000020CE7F000001000000010300000001000000050000001AFCABB09AC11C4176FA2F9E808260414C83A83584C11C411490D5547F8260419B29C5BE6AC11C41821039C67F8260411DF85FA67EC11C4156CA211E818260411AFCABB09AC11C4176FA2F9E80826041
23	iglesia	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	6	0106000020CE7F000001000000010300000001000000060000004C83A83584C11C411490D5547F8260411AFCABB09AC11C4176FA2F9E8082604152421503B7C11C4127625EF37F8260412FE765A991C11C417FF79A147E8260419F4A76DC75C11C4176F9D19F7E8260414C83A83584C11C411490D5547F826041
24	vivienda	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	8	0106000020CE7F00000100000001030000000100000005000000A697FB9DB4C11C41B68F817B7B8260415B7609AE7EC11C417E17C7CE7B8260413CE6BF4D85C11C4156FB99937C826041104C2F22BDC11C4158949E297C826041A697FB9DB4C11C41B68F817B7B826041
25	vivienda	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	6	0106000020CE7F00000100000001030000000100000007000000067BDBDF61C11C41972BCEC87C8260412F5F498D6DC11C412D02A90C7E82604124264DE9C5C11C4145A9ECC17D826041104C2F22BDC11C4158949E297C8260413CE6BF4D85C11C4156FB99937C8260416B66CB0785C11C4112517B8B7C826041067BDBDF61C11C41972BCEC87C826041
26	vivienda	Adobe	Huariracay	colapso_total	Colapsada	3.2	video	6	0106000020CE7F0000010000000103000000010000000500000052421503B7C11C4127625EF37F82604130D7F728CAC11C41C7CF07967F82604124264DE9C5C11C4145A9ECC17D8260412FE765A991C11C417FF79A147E82604152421503B7C11C4127625EF37F826041
2	vivienda	Adobe	Santa Fe	colapso_total	Colapsada	2.9	video	6	0106000020CE7F000001000000010300000001000000050000009155FF3CD4C11C4198858B897F826041C5C84254D1C11C41397E545E8182604110D047EDEBC11C411BE04D6881826041680C742CEDC11C41F76438867F8260419155FF3CD4C11C4198858B897F826041
3	vivienda	Adobe	Santa Fe	colapso_parcial	Afectada Grave	3.1	video	7	0106000020CE7F000001000000010300000001000000050000004FBC56E6D3C11C41A1C9988E818260410CB404CEF3C11C4139E7ECD083826041A095C1B011C21C41BFE9757683826041493CEDC9F4C11C41E34A5D61818260414FBC56E6D3C11C41A1C9988E81826041
4	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	7	0106000020CE7F000001000000010300000001000000080000004A596623F6C11C41A5079AC87F826041E67C87FCEDC11C4185139E5880826041D22926EAFDC11C414A38FBAE80826041DA28E1DBF0C11C415078D20B81826041AE76407702C21C418AD6A9A0818260413A47D6A916C21C41EE905B39818260417877936327C21C410DC29CD5808260414A596623F6C11C41A5079AC87F826041
5	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	7	0106000020CE7F0000010000000103000000010000000500000037C1DE7B2CC21C41995BCE0381826041106AB72D01C21C4160C8B6DC81826041996A886E08C21C416906785982826041143E639E45C21C415646F99B8182604137C1DE7B2CC21C41995BCE0381826041
6	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	7	0106000020CE7F000001000000010300000001000000050000004850171B48C21C41BB0B72AA81826041D7AA19B20BC21C416DA6E387828260416F2B99AC13C21C417910432D8382604196FDBF3F5CC21C4181670E25828260414850171B48C21C41BB0B72AA81826041
7	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	4	0106000020CE7F00000100000001030000000100000005000000DBD961671FC21C415DEDDE968682604159F8B1636EC21C41204DE6F8858260415F0FF95860C21C413DD74C8884826041A2B6FAD90DC21C414BE95A4285826041DBD961671FC21C415DEDDE9686826041
1	vivienda	Adobe	Taracayo	colapso_total	Colapsada	3.2	video	5	0106000020CE7F0000010000000103000000010000000500000029FE15D3FDC01C41B6417FEE83826041E011411ED8C01C417D286C798482604178883A0D0CC11C4196CFB73B8782604124FD92E030C11C41C02B338A8682604129FE15D3FDC01C41B6417FEE83826041
8	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	4	0106000020CE7F00000100000001030000000100000005000000EDB5F13F27C21C417467CCF486826041C71198D635C21C41F936B8A388826041E1CC7B577FC21C411582F7408882604158918DA16FC21C418DF1059B86826041EDB5F13F27C21C417467CCF486826041
41	vivienda	Adobe	Alfahuata	colapso_total	Colapsada	2.8	video	1	0106000020CE7F0000010000000103000000010000000500000015205B5744C21C41E302B0268B8260410DA3B83042C21C415CCB9B428C8260419556E7036EC21C4138696B5C8C8260411A9538176FC21C41CC16E5378B82604115205B5744C21C41E302B0268B826041
42	vivienda	Adobe	Alfahuata	afectada_leve	Afectada Leve	3.1	video	1	0106000020CE7F000001000000010300000001000000050000003CF762CE41C21C4176ED1D758C8260414D5B923A42C21C4118C9F63F8D8260414980E6A760C21C41384458438D82604126B887CF5FC21C41F7E69F798C8260413CF762CE41C21C4176ED1D758C826041
44	vivienda	Adobe	Alfahuata	afectada_leve	Afectada Leve	3.1	video	1	0106000020CE7F00000100000001030000000100000007000000A61111BD4CC21C410C995A9390826041C2A630156FC21C4180AC337390826041842BCA2D70C21C41FBCCACA38F826041430265E36FC21C41ADEB7B538F826041FCA03D254BC21C41886A31558F826041FCA03D254BC21C41886A31558F826041A61111BD4CC21C410C995A9390826041
9	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	7	0106000020CE7F000001000000010300000001000000050000005E27038F46C21C419F16CAEE80826041E80CC2036DC21C41F675E8E48182604158A5B18187C21C410F4D3F44818260416A6D16C75CC21C416F7C093D808260415E27038F46C21C419F16CAEE80826041
10	vivienda	Adobe	Santa Fe	colapso_parcial	Afectada Grave	3.1	video	7	0106000020CE7F000001000000010300000001000000050000008A3C37CB27C21C4110D7B54A80826041AA9DC0A854C21C4103E9AE657F826041FAD4264942C21C417B6559B77E8260419D754CDB12C21C418197A1A67F8260418A3C37CB27C21C4110D7B54A80826041
43	vivienda	Adobe	Alfahuata	colapso_total	Colapsada	3.1	video	1	0106000020CE7F000001000000010300000001000000050000009AC69D6945C21C415B7E33408F8260414F5654BF6FC21C4143BA7A3C8F8260415ACD0A5A6EC21C4175D4AD658D8260412A79AF5143C21C41464C3C5E8D8260419AC69D6945C21C415B7E33408F826041
11	vivienda	Adobe	Santa Fe	afectada_leve	Afectada Leve	3.1	video	7	0106000020CE7F000001000000010300000001000000050000009E31B6EB2DC21C41915B17E97D82604151D8E34EF4C11C4171FA09FF7E8260410476471908C21C41DF0D16987F826041991FE04A3FC21C417C9E869C7E8260419E31B6EB2DC21C41915B17E97D826041
12	vivienda	Adobe	Santa Fe	colapso_parcial	Afectada Grave	3.1	video	6	0106000020CE7F000001000000010300000001000000050000001A9C7EC3D3C11C418E94C1087E826041F5488FCFEEC11C41F47B2BE87E826041BBB611F101C21C417FC7E5837E8260417EF96631EAC11C419987B9A27D8260411A9C7EC3D3C11C418E94C1087E826041
27	vivienda	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	8	0106000020CE7F0000010000000103000000010000000500000075A3BBE479C11C41C45867DB7B826041511F100219C11C41503A964B7C82604103232BA820C11C4158915B0D7D826041BD70B94F7FC11C4115ABAD837C82604175A3BBE479C11C41C45867DB7B826041
28	vivienda	Adobe	Huariracay	colapso_total	Colapsada	2.8	video	8	0106000020CE7F000001000000010300000001000000050000009955D6355DC11C413ED4D0D77C82604186AD945620C11C4167FDF32B7D8260415F2FA22924C11C41A9E3A1B57D8260416CC210AC61C11C41D82198667D8260419955D6355DC11C413ED4D0D77C826041
29	vivienda	Adobe	Huariracay	afectada_leve	Afectada Leve	3.1	video	8	0106000020CE7F00000100000001030000000100000005000000EBD42DE23EC11C41EC19D7CD7D826041A871057924C11C41822306EC7D826041CF78261B30C11C417DFA6AC77F82604168CA258C4FC11C413FBE14907F826041EBD42DE23EC11C41EC19D7CD7D826041
30	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	1	0106000020CE7F000001000000010300000001000000050000001B504DE6ECC11C4125E297378A82604193335AC8E9C11C41A801B5E98A8260415CB349AF2BC21C417033941B8B826041C61051E729C21C415C8F86898A8260411B504DE6ECC11C4125E297378A826041
31	vivienda	Adobe	Centro	afectada_leve	Afectada Leve	3.1	video	3	0106000020CE7F00000100000001030000000100000005000000AE65CB5F0EC11C4136ED033388826041B5DBC530ECC01C4130BD09B68A826041FC47BB032BC11C41B563BA638B826041ACE6113041C11C41CD1172BF88826041AE65CB5F0EC11C4136ED033388826041
32	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	3	0106000020CE7F00000100000001030000000100000005000000F77B49E74BC11C41BBC87FDB88826041A74A716E3AC11C416CB78BA48A826041E2E6413B4FC11C418B660BC88A826041F3B91A6D60C11C41A263DF0789826041F77B49E74BC11C41BBC87FDB88826041
33	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	3	0106000020CE7F00000100000001030000000100000005000000B7D85A5D64C11C418095B30D89826041D27F6F5056C11C410454C1CF8A82604128F0277B67C11C4160E511F38A826041C322502878C11C415C0D993B89826041B7D85A5D64C11C418095B30D89826041
34	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	1	0106000020CE7F00000100000001030000000100000007000000C52358AF2DC21C419EAD4D6E8B826041CC06EBFF14C21C419EAD4D6E8B8260419AC41CCF15C21C41A1C1122A8C82604158F9726202C21C41B23399238C8260418B3B419301C21C411645A4198D8260412D5DED1C30C21C41E1EE102D8D826041C52358AF2DC21C419EAD4D6E8B826041
35	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	9	0106000020CE7F000001000000010300000001000000080000005BEBB5D3C0C11C41F4D328928A826041233FF68AB9C11C41F4D328928A826041D426C8B5B6C11C41E302D6E88D826041123D7916C6C11C41E302D6E88D826041123D7916C6C11C41CDDEE2198C8260416D298A1BD9C11C41A1C1122A8C826041EF838621DBC11C41D1EF1B9F8A8260415BEBB5D3C0C11C41F4D328928A826041
36	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	3	0106000020CE7F0000010000000103000000010000000500000017233DAC8DC11C41EBB550578A8260412D353DBC84C11C417881C4298C82604126EFB64A9BC11C417881C4298C826041AC9B2466A0C11C41F647F5758A82604117233DAC8DC11C41EBB550578A826041
37	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	3	0106000020CE7F000001000000010300000001000000050000000C7E73909FC11C418E94D8208C8260411B293FDFB2C11C417847AC258C82604129CD5396B5C11C4185DF618B8A826041233AEB16A4C11C41C5C6E67C8A8260410C7E73909FC11C418E94D8208C826041
14	vivienda	Adobe	Inay	afectada_leve	Afectada Leve	3.1	video	1	0106000020CE7F0000010000000103000000010000000500000093CABB0928C21C4131F80947918260413EC52EBBC3C11C4147A5CD349282604139FA9A82C9C11C4149A285E092826041FF311E572BC21C413DCDC7139282604193CABB0928C21C4131F8094791826041
16	vivienda	Adobe	Inay	afectada_leve	Afectada Leve	3.1	video	13	0106000020CE7F00000100000001030000000100000006000000276939B996C11C413C455C24948260415149F5C56BC11C411168A67E948260419D0B32CE75C11C41B22B919C9582604196A29120DAC11C41DC97CFB0948260416FACD8B8D0C11C4144C705BB93826041276939B996C11C413C455C2494826041
38	vivienda	Adobe	Centro	afectada_leve	Afectada Leve	3.1	video	9	0106000020CE7F000001000000010300000001000000050000006EA2A2329BC01C413D3B5CE58A826041FF56E6417CC01C41C460EC858C826041086E6D5DB6C01C41BB3439598D82604111864BD5D9C01C41329BD8D68B8260416EA2A2329BC01C413D3B5CE58A826041
39	vivienda	Adobe	Centro	afectada_leve	Afectada Leve	3.1	video	9	0106000020CE7F00000100000001030000000100000005000000FF56E6417CC01C41499EDB628E82604122B8B57DF3C01C4135D2A427908260415E6A2E6009C11C4112BB4DAB8E82604119A3DC1A8CC01C41BF90AAFE8C826041FF56E6417CC01C41499EDB628E826041
40	vivienda	Adobe	Centro	colapso_parcial	Afectada Grave	3.1	video	3	0106000020CE7F00000100000001030000000100000005000000EAF9F5F9C0C01C41345D095D888260413DAA4F9BD6C01C41E92069D98882604128940A52F2C01C41B18FFEAF87826041C51270A2D8C01C418F75362E87826041EAF9F5F9C0C01C41345D095D88826041
45	vivienda	Adobe	Alfahuata	afectada_leve	Afectada Leve	3.1	video	2	0106000020CE7F0000010000000103000000010000000500000079E5384D78C21C419297EF518B826041E78A23D277C21C412E4EB86A8C8260411F221193BCC21C412E4EB86A8C826041199CA6F0BFC21C41E9413E4A8B82604179E5384D78C21C419297EF518B826041
46	escuela	Adobe	Taracayo	afectada_leve	Afectada Leve	3.1	video	11	0106000020CE7F0000010000000103000000010000000700000083FF9EC290C11C4150B5234E85826041F744CE778EC11C41B1AC59FC8582604132358575BDC11C41F3E3D7E085826041ECD71C50BCC11C4174F66D5A83826041728EF563A5C11C41FF54D8558382604142A57086A2C11C41BD664B208582604183FF9EC290C11C4150B5234E85826041
17	vivienda	Adobe	Centro	afectada_leve	Afectada Leve	3.1	video	9	0106000020CE7F000001000000010300000001000000050000000127490B2FC21C41481D6F058E82604154925B542FC21C410C946C7C8D826041B1657C3B00C21C4137F9276A8D82604196A8783DF8C11C41386395FE8D8260410127490B2FC21C41481D6F058E826041
18	vivienda	Adobe	Inay	afectada_leve	Afectada Leve	3.1	video	1	0106000020CE7F00000100000001030000000100000005000000986C7D5631C21C417E46E3CB908260415B72ACF834C21C41CB2174EF8F826041F01BEB77FEC11C412441E0F18F8260417F5A5F8FFDC11C41D7654FCE90826041986C7D5631C21C417E46E3CB90826041
13	vivienda	Adobe	Inay	colapso_parcial	Afectada Grave	2.8	video	1	0106000020CE7F00000100000001030000000100000005000000E3E8A24F37C21C41E52E034292826041FF311E572BC21C41108CD27193826041B9B767EA3DC21C414B9F3D8C93826041C3D4930F49C21C418D903E7092826041E3E8A24F37C21C41E52E034292826041
15	vivienda	Adobe	Inay	colapso_parcial	Afectada Grave	3.1	video	13	0106000020CE7F00000100000001030000000100000005000000E2619E9B20C21C41927CC18092826041A461FDCFCCC11C418F8DF61B93826041C5FC10C4D1C11C411A64D89293826041BDFBF66E21C21C41BBDCD80493826041E2619E9B20C21C41927CC18092826041
\.


--
-- Data for Name: puntos; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.puntos (id, nombre, tipo, existe_antes, existe_despues, es_auxilio, geom) FROM stdin;
1	Losa Deportiva	losa	t	t	f	0101000020CE7F00008EB751AF51C11C4177932A0385826041
2	Iglesia Comunal de Pumpunya	iglesia	t	t	f	0101000020CE7F0000210111D39BC11C41A67C3B6280826041
3	Servicio de Atención Móvil de Urgencia 01	puesto_ayuda	f	t	t	0101000020CE7F000058EDF96B43C11C4159F9CC7383826041
4	Servicio de Atención Móvil de Urgencia 02	puesto_ayuda	f	t	t	0101000020CE7F00008ABCCFB45CC11C415C46711683826041
5	Servicio de Atención Móvil de Urgencia 03	puesto_ayuda	f	t	t	0101000020CE7F00000641964977C11C41D2A7133E84826041
6	Fundación Caja Huancayo	centro_acopio	f	t	f	0101000020CE7F00002A1C466068C11C41AD95AAA783826041
7	Escuela 30163 Pumpunya	escuela	t	t	f	0101000020CE7F000030C34473B6C11C412156BC7084826041
\.


--
-- Data for Name: sim_historial; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.sim_historial (id, sesion_id, predio_id, estado_anterior, estado_nuevo, creado) FROM stdin;
19	s57a27c547d	20	sin_dano	colapso_total	2026-11-11 07:41:49.639341-05
20	s57a27c547d	21	sin_dano	colapso_total	2026-11-11 07:41:51.78029-05
21	s57a27c547d	19	sin_dano	colapso_total	2026-11-11 07:41:54.253663-05
22	s57a27c547d	20	colapso_total	colapso_parcial	2026-11-11 07:42:01.887275-05
23	s57a27c547d	3	sin_dano	afectada_leve	2026-11-11 07:42:05.449832-05
27	sc1195efed5	20	sin_dano	colapso_total	2026-11-11 16:37:53.216668-05
\.


--
-- Data for Name: via_estado; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.via_estado (escenario, sesion_id, seg_id, estado_post, w_efectivo_m, acceso_vehiculo, acceso_peatonal, id_viv_bloqueo) FROM stdin;
antes	base	1	libre	6.48	t	t	\N
antes	base	2	libre	6.48	t	t	\N
antes	base	3	libre	6.48	t	t	\N
antes	base	4	libre	6.48	t	t	\N
antes	base	5	libre	6.48	t	t	\N
antes	base	6	libre	6.48	t	t	\N
antes	base	7	libre	6.48	t	t	\N
antes	base	8	libre	6.48	t	t	\N
antes	base	9	libre	6.48	t	t	\N
antes	base	10	libre	6.48	t	t	\N
antes	base	11	libre	6.48	t	t	\N
antes	base	12	libre	6.48	t	t	\N
antes	base	13	libre	6.48	t	t	\N
antes	base	14	libre	6.48	t	t	\N
antes	base	15	libre	6.48	t	t	\N
antes	base	48	libre	6.48	t	t	\N
antes	base	16	libre	6.48	t	t	\N
antes	base	17	libre	6.48	t	t	\N
antes	base	18	libre	6.48	t	t	\N
antes	base	19	libre	6.48	t	t	\N
antes	base	20	libre	6.48	t	t	\N
antes	base	21	libre	6.48	t	t	\N
antes	base	51	libre	5.38	t	t	\N
antes	base	22	libre	6.48	t	t	\N
antes	base	23	libre	6.48	t	t	\N
antes	base	24	libre	6.48	t	t	\N
antes	base	25	libre	6.48	t	t	\N
antes	base	26	libre	6.48	t	t	\N
antes	base	27	libre	6.48	t	t	\N
antes	base	28	libre	6.48	t	t	\N
antes	base	29	libre	6.48	t	t	\N
antes	base	30	libre	6.48	t	t	\N
antes	base	31	libre	6.48	t	t	\N
antes	base	32	libre	6.48	t	t	\N
antes	base	33	libre	6.48	t	t	\N
antes	base	34	libre	5.38	t	t	\N
antes	base	35	libre	5.38	t	t	\N
antes	base	36	libre	5.38	t	t	\N
antes	base	49	libre	5.38	t	t	\N
antes	base	37	libre	5.38	t	t	\N
antes	base	38	libre	5.38	t	t	\N
antes	base	50	libre	5.38	t	t	\N
antes	base	39	libre	5.38	t	t	\N
antes	base	40	libre	5.38	t	t	\N
antes	base	41	libre	5.38	t	t	\N
antes	base	42	libre	5.38	t	t	\N
antes	base	43	libre	5.38	t	t	\N
antes	base	52	libre	5.38	t	t	\N
antes	base	44	libre	5.38	t	t	\N
antes	base	45	libre	5.38	t	t	\N
antes	base	46	libre	5.38	t	t	\N
antes	base	53	libre	5.38	t	t	\N
antes	base	47	libre	5.38	t	t	\N
antes	base	54	libre	1.8	f	t	\N
antes	base	55	libre	1.8	f	t	\N
antes	base	56	libre	1.8	f	t	\N
antes	base	57	libre	1.8	f	t	\N
antes	base	58	libre	1.8	f	t	\N
antes	base	59	libre	1.8	f	t	\N
antes	base	60	libre	1.8	f	t	\N
antes	base	61	libre	6.48	t	t	\N
despues	base	1	libre	\N	t	t	\N
despues	base	2	libre	\N	t	t	\N
despues	base	3	libre	\N	t	t	\N
despues	base	4	libre	\N	t	t	\N
despues	base	5	libre	\N	t	t	\N
despues	base	6	libre	\N	t	t	\N
despues	base	7	libre	\N	t	t	\N
despues	base	8	libre	\N	t	t	\N
despues	base	9	libre	\N	t	t	\N
despues	base	10	libre	\N	t	t	\N
despues	base	11	libre	\N	t	t	\N
despues	base	12	libre	\N	t	t	\N
despues	base	13	bloqueada_total	\N	f	t	\N
despues	base	14	libre	\N	t	t	\N
despues	base	15	bloqueada_total	\N	f	t	\N
despues	base	48	bloqueada_total	\N	f	t	\N
despues	base	16	bloqueada_total	\N	f	t	\N
despues	base	17	libre	\N	t	t	\N
despues	base	18	libre	\N	t	t	\N
despues	base	19	libre	\N	t	t	\N
despues	base	20	libre	\N	t	t	\N
despues	base	21	libre	\N	t	t	\N
despues	base	51	libre	\N	t	t	\N
despues	base	22	libre	\N	t	t	\N
despues	base	23	libre	\N	t	t	\N
despues	base	24	libre	\N	t	t	\N
despues	base	25	libre	\N	t	t	\N
despues	base	26	libre	\N	t	t	\N
despues	base	27	libre	\N	t	t	\N
despues	base	28	libre	\N	t	t	\N
despues	base	29	libre	\N	t	t	\N
despues	base	30	libre	\N	t	t	\N
despues	base	31	libre	\N	t	t	\N
despues	base	32	libre	\N	t	t	\N
despues	base	33	libre	\N	t	t	\N
despues	base	34	libre	\N	t	t	\N
despues	base	35	libre	\N	t	t	\N
despues	base	36	libre	\N	t	t	\N
despues	base	49	libre	\N	t	t	\N
despues	base	37	libre	\N	t	t	\N
despues	base	38	libre	\N	t	t	\N
despues	base	50	libre	\N	t	t	\N
despues	base	39	libre	\N	t	t	\N
despues	base	40	libre	\N	t	t	\N
despues	base	41	bloqueada_total	\N	f	t	\N
despues	base	42	libre	\N	t	t	\N
despues	base	43	libre	\N	t	t	\N
despues	base	52	libre	\N	t	t	\N
despues	base	44	bloqueada_total	\N	f	t	\N
despues	base	45	libre	\N	t	t	\N
despues	base	46	libre	\N	t	t	\N
despues	base	53	libre	\N	t	t	\N
despues	base	47	libre	\N	t	t	\N
despues	base	54	libre	\N	f	t	\N
despues	base	55	libre	\N	f	t	\N
despues	base	56	libre	\N	f	t	\N
despues	base	57	libre	\N	f	t	\N
despues	base	58	libre	\N	f	t	\N
despues	base	59	libre	\N	f	t	\N
despues	base	60	libre	\N	f	t	\N
despues	base	61	bloqueada_total	\N	f	t	\N
simulacion	s6f8ce6f031	13	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	14	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	15	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	1	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	2	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	3	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	4	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	5	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	6	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	7	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	8	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	9	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	10	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	11	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	12	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	13	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	14	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	15	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	16	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	17	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	18	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	19	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	20	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	21	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	22	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	23	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	24	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	25	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	26	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	27	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	28	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	29	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	30	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	31	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	32	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	33	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	34	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	35	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	48	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	16	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	17	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	18	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	19	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	20	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	21	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	51	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	22	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	23	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	24	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	25	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	26	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	27	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	28	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	29	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	30	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	31	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	32	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	33	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	34	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	35	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	36	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	36	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	37	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	38	libre	5.38	t	t	\N
simulacion	s57a27c547d	16	libre	6.48	t	t	\N
simulacion	s57a27c547d	17	libre	6.48	t	t	\N
simulacion	s57a27c547d	18	libre	6.48	t	t	\N
simulacion	s57a27c547d	19	libre	6.48	t	t	\N
simulacion	s57a27c547d	20	libre	6.48	t	t	\N
simulacion	s57a27c547d	21	libre	6.48	t	t	\N
simulacion	s57a27c547d	51	libre	5.38	t	t	\N
simulacion	s57a27c547d	22	libre	6.48	t	t	\N
simulacion	s57a27c547d	23	libre	6.48	t	t	\N
simulacion	s57a27c547d	24	libre	6.48	t	t	\N
simulacion	s57a27c547d	25	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	49	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	37	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	38	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	50	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	39	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	40	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	41	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	42	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	43	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	52	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	44	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	45	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	46	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	53	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	47	libre	5.38	t	t	\N
simulacion	s6f8ce6f031	54	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	55	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	56	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	57	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	58	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	59	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	60	libre	1.8	f	t	\N
simulacion	s6f8ce6f031	61	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	39	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	40	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	41	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	42	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	43	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	44	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	45	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	46	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	47	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	48	libre	6.48	t	t	\N
simulacion	s0ecf2d55f7	49	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	50	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	51	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	52	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	53	libre	5.38	t	t	\N
simulacion	s0ecf2d55f7	54	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	55	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	56	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	57	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	58	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	59	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	60	libre	1.8	f	t	\N
simulacion	s0ecf2d55f7	61	libre	6.48	t	t	\N
simulacion	se8c845ecd9	1	libre	6.48	t	t	\N
simulacion	se8c845ecd9	2	libre	6.48	t	t	\N
simulacion	se8c845ecd9	3	libre	6.48	t	t	\N
simulacion	se8c845ecd9	4	libre	6.48	t	t	\N
simulacion	se8c845ecd9	5	libre	6.48	t	t	\N
simulacion	se8c845ecd9	6	libre	6.48	t	t	\N
simulacion	se8c845ecd9	7	libre	6.48	t	t	\N
simulacion	se8c845ecd9	8	libre	6.48	t	t	\N
simulacion	se8c845ecd9	9	libre	6.48	t	t	\N
simulacion	se8c845ecd9	10	libre	6.48	t	t	\N
simulacion	se8c845ecd9	11	libre	6.48	t	t	\N
simulacion	se8c845ecd9	12	libre	6.48	t	t	\N
simulacion	se8c845ecd9	13	libre	6.48	t	t	\N
simulacion	se8c845ecd9	14	libre	6.48	t	t	\N
simulacion	se8c845ecd9	15	libre	6.48	t	t	\N
simulacion	se8c845ecd9	48	libre	6.48	t	t	\N
simulacion	se8c845ecd9	16	libre	6.48	t	t	\N
simulacion	se8c845ecd9	17	libre	6.48	t	t	\N
simulacion	se8c845ecd9	18	libre	6.48	t	t	\N
simulacion	se8c845ecd9	19	libre	6.48	t	t	\N
simulacion	se8c845ecd9	20	libre	6.48	t	t	\N
simulacion	se8c845ecd9	21	libre	6.48	t	t	\N
simulacion	se8c845ecd9	51	libre	5.38	t	t	\N
simulacion	se8c845ecd9	22	libre	6.48	t	t	\N
simulacion	se8c845ecd9	23	libre	6.48	t	t	\N
simulacion	se8c845ecd9	24	libre	6.48	t	t	\N
simulacion	se8c845ecd9	25	libre	6.48	t	t	\N
simulacion	se8c845ecd9	26	libre	6.48	t	t	\N
simulacion	se8c845ecd9	27	libre	6.48	t	t	\N
simulacion	se8c845ecd9	28	libre	6.48	t	t	\N
simulacion	se8c845ecd9	29	libre	6.48	t	t	\N
simulacion	se8c845ecd9	30	libre	6.48	t	t	\N
simulacion	se8c845ecd9	31	libre	6.48	t	t	\N
simulacion	se8c845ecd9	32	libre	6.48	t	t	\N
simulacion	se8c845ecd9	33	libre	6.48	t	t	\N
simulacion	se8c845ecd9	34	libre	5.38	t	t	\N
simulacion	se8c845ecd9	35	libre	5.38	t	t	\N
simulacion	se8c845ecd9	36	libre	5.38	t	t	\N
simulacion	se8c845ecd9	49	libre	5.38	t	t	\N
simulacion	se8c845ecd9	37	libre	5.38	t	t	\N
simulacion	se8c845ecd9	38	libre	5.38	t	t	\N
simulacion	se8c845ecd9	50	libre	5.38	t	t	\N
simulacion	se8c845ecd9	39	libre	5.38	t	t	\N
simulacion	se8c845ecd9	40	libre	5.38	t	t	\N
simulacion	se8c845ecd9	41	libre	5.38	t	t	\N
simulacion	se8c845ecd9	42	libre	5.38	t	t	\N
simulacion	se8c845ecd9	43	libre	5.38	t	t	\N
simulacion	se8c845ecd9	52	libre	5.38	t	t	\N
simulacion	se8c845ecd9	44	libre	5.38	t	t	\N
simulacion	se8c845ecd9	45	libre	5.38	t	t	\N
simulacion	se8c845ecd9	46	libre	5.38	t	t	\N
simulacion	se8c845ecd9	53	libre	5.38	t	t	\N
simulacion	se8c845ecd9	47	libre	5.38	t	t	\N
simulacion	se8c845ecd9	54	libre	1.8	f	t	\N
simulacion	se8c845ecd9	55	libre	1.8	f	t	\N
simulacion	se8c845ecd9	56	libre	1.8	f	t	\N
simulacion	se8c845ecd9	57	libre	1.8	f	t	\N
simulacion	se8c845ecd9	58	libre	1.8	f	t	\N
simulacion	se8c845ecd9	59	libre	1.8	f	t	\N
simulacion	se8c845ecd9	60	libre	1.8	f	t	\N
simulacion	se8c845ecd9	61	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	1	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	2	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	3	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	4	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	5	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	6	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	7	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	8	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	9	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	10	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	11	libre	6.48	t	t	\N
simulacion	s6f8ce6f031	12	libre	6.48	t	t	\N
simulacion	validacion	1	libre	6.48	t	t	\N
simulacion	s0413428c13	1	libre	6.48	t	t	\N
simulacion	s0413428c13	2	libre	6.48	t	t	\N
simulacion	s0413428c13	3	libre	6.48	t	t	\N
simulacion	s0413428c13	4	libre	6.48	t	t	\N
simulacion	s0413428c13	5	libre	6.48	t	t	\N
simulacion	s0413428c13	6	libre	6.48	t	t	\N
simulacion	s0413428c13	7	libre	6.48	t	t	\N
simulacion	s0413428c13	8	libre	6.48	t	t	\N
simulacion	s0413428c13	9	libre	6.48	t	t	\N
simulacion	s0413428c13	10	libre	6.48	t	t	\N
simulacion	s0413428c13	11	libre	6.48	t	t	\N
simulacion	s0413428c13	12	libre	6.48	t	t	\N
simulacion	s0413428c13	13	libre	6.48	t	t	\N
simulacion	s0413428c13	14	libre	6.48	t	t	\N
simulacion	s0413428c13	15	libre	6.48	t	t	\N
simulacion	s0413428c13	48	libre	6.48	t	t	\N
simulacion	s0413428c13	16	libre	6.48	t	t	\N
simulacion	s0413428c13	17	libre	6.48	t	t	\N
simulacion	s0413428c13	18	libre	6.48	t	t	\N
simulacion	s0413428c13	19	libre	6.48	t	t	\N
simulacion	s0413428c13	20	libre	6.48	t	t	\N
simulacion	s0413428c13	21	libre	6.48	t	t	\N
simulacion	s0413428c13	51	libre	5.38	t	t	\N
simulacion	s0413428c13	22	libre	6.48	t	t	\N
simulacion	s0413428c13	23	libre	6.48	t	t	\N
simulacion	s0413428c13	24	libre	6.48	t	t	\N
simulacion	s0413428c13	25	libre	6.48	t	t	\N
simulacion	s0413428c13	26	libre	6.48	t	t	\N
simulacion	s0413428c13	27	libre	6.48	t	t	\N
simulacion	s0413428c13	28	libre	6.48	t	t	\N
simulacion	s0413428c13	29	libre	6.48	t	t	\N
simulacion	s0413428c13	30	libre	6.48	t	t	\N
simulacion	s0413428c13	31	libre	6.48	t	t	\N
simulacion	s0413428c13	32	libre	6.48	t	t	\N
simulacion	s0413428c13	33	libre	6.48	t	t	\N
simulacion	s0413428c13	34	libre	5.38	t	t	\N
simulacion	s0413428c13	35	libre	5.38	t	t	\N
simulacion	s0413428c13	36	libre	5.38	t	t	\N
simulacion	s0413428c13	49	libre	5.38	t	t	\N
simulacion	s0413428c13	37	libre	5.38	t	t	\N
simulacion	s0413428c13	38	libre	5.38	t	t	\N
simulacion	s0413428c13	50	libre	5.38	t	t	\N
simulacion	s0413428c13	39	libre	5.38	t	t	\N
simulacion	s0413428c13	40	libre	5.38	t	t	\N
simulacion	s0413428c13	41	libre	5.38	t	t	\N
simulacion	s0413428c13	42	libre	5.38	t	t	\N
simulacion	s0413428c13	43	libre	5.38	t	t	\N
simulacion	s0413428c13	52	libre	5.38	t	t	\N
simulacion	s0413428c13	44	libre	5.38	t	t	\N
simulacion	s0413428c13	45	libre	5.38	t	t	\N
simulacion	s0413428c13	46	libre	5.38	t	t	\N
simulacion	s0413428c13	53	libre	5.38	t	t	\N
simulacion	s0413428c13	47	libre	5.38	t	t	\N
simulacion	s0413428c13	54	libre	1.8	f	t	\N
simulacion	s0413428c13	55	libre	1.8	f	t	\N
simulacion	s0413428c13	56	libre	1.8	f	t	\N
simulacion	s0413428c13	57	libre	1.8	f	t	\N
simulacion	s0413428c13	58	libre	1.8	f	t	\N
simulacion	s0413428c13	59	libre	1.8	f	t	\N
simulacion	s0413428c13	60	libre	1.8	f	t	\N
simulacion	s0413428c13	61	libre	6.48	t	t	\N
simulacion	validacion	2	libre	6.48	t	t	\N
simulacion	validacion	3	libre	6.48	t	t	\N
simulacion	validacion	4	libre	6.48	t	t	\N
simulacion	validacion	5	libre	6.48	t	t	\N
simulacion	validacion	6	libre	6.48	t	t	\N
simulacion	validacion	7	libre	6.48	t	t	\N
simulacion	validacion	8	libre	6.48	t	t	\N
simulacion	validacion	9	libre	6.48	t	t	\N
simulacion	validacion	10	libre	6.48	t	t	\N
simulacion	validacion	11	libre	6.48	t	t	\N
simulacion	validacion	12	libre	6.48	t	t	\N
simulacion	validacion	13	libre	6.48	t	t	\N
simulacion	validacion	14	bloqueada_parcial	1.3303919662266277	f	t	43
simulacion	validacion	15	bloqueada_parcial	2.3661610529767296	f	t	43
simulacion	validacion	48	bloqueada_total	0.30924157946509423	f	t	43
simulacion	validacion	16	bloqueada_total	0.7073550259512174	f	t	41
simulacion	validacion	17	libre	6.48	t	t	\N
simulacion	validacion	18	libre	6.48	t	t	\N
simulacion	validacion	19	libre	6.48	t	t	\N
simulacion	validacion	20	libre	6.48	t	t	\N
simulacion	validacion	21	libre	6.48	t	t	\N
simulacion	validacion	51	libre	5.38	t	t	\N
simulacion	validacion	22	libre	6.48	t	t	\N
simulacion	validacion	23	libre	6.48	t	t	\N
simulacion	validacion	24	libre	6.48	t	t	\N
simulacion	validacion	25	libre	6.48	t	t	\N
simulacion	validacion	26	libre	6.48	t	t	\N
simulacion	validacion	27	libre	6.48	t	t	\N
simulacion	validacion	28	libre	6.48	t	t	\N
simulacion	validacion	29	libre	6.48	t	t	\N
simulacion	validacion	30	libre	6.48	t	t	\N
simulacion	validacion	31	libre	6.48	t	t	\N
simulacion	validacion	32	libre	3.445828987342973	t	t	\N
simulacion	s57a27c547d	26	libre	6.48	t	t	\N
simulacion	s57a27c547d	27	libre	6.48	t	t	\N
simulacion	validacion	33	bloqueada_parcial	2.7642744994628528	f	t	41
simulacion	validacion	34	libre	3.6419106450017567	t	t	\N
simulacion	validacion	35	libre	4.679839747973194	t	t	\N
simulacion	validacion	36	libre	4.6750211236114945	t	t	\N
simulacion	validacion	49	libre	5.086717201386216	t	t	\N
simulacion	validacion	37	libre	5.38	t	t	\N
simulacion	validacion	38	libre	5.38	t	t	\N
simulacion	validacion	50	libre	5.38	t	t	\N
simulacion	validacion	39	libre	5.38	t	t	\N
simulacion	validacion	40	libre	3.34854530001814	t	t	\N
simulacion	validacion	41	bloqueada_parcial	1.8783943474763047	f	t	21
simulacion	validacion	42	bloqueada_parcial	2.677931701780453	f	t	21
simulacion	validacion	43	libre	5.254357680381219	t	t	\N
simulacion	validacion	52	bloqueada_parcial	1.1334565708146878	f	t	1
simulacion	validacion	44	bloqueada_total	0	f	t	26
simulacion	validacion	45	bloqueada_total	0	f	t	26
simulacion	validacion	46	libre	5.38	t	t	\N
simulacion	validacion	53	libre	5.38	t	t	\N
simulacion	validacion	47	libre	5.38	t	t	\N
simulacion	validacion	54	libre	1.8	f	t	\N
simulacion	validacion	55	libre	1.8	f	t	\N
simulacion	validacion	56	libre	1.8	f	t	\N
simulacion	validacion	57	libre	1.8	f	t	\N
simulacion	validacion	58	libre	1.8	f	t	\N
simulacion	validacion	59	libre	1.8	f	t	\N
simulacion	validacion	60	libre	1.8	f	t	\N
simulacion	validacion	61	bloqueada_parcial	2.5652177762197916	f	t	15
simulacion	se75f401cdf	1	libre	6.48	t	t	\N
simulacion	se75f401cdf	2	libre	6.48	t	t	\N
simulacion	se75f401cdf	3	libre	6.48	t	t	\N
simulacion	se75f401cdf	4	libre	6.48	t	t	\N
simulacion	se75f401cdf	5	libre	6.48	t	t	\N
simulacion	se75f401cdf	6	libre	6.48	t	t	\N
simulacion	se75f401cdf	7	libre	6.48	t	t	\N
simulacion	se75f401cdf	8	libre	6.48	t	t	\N
simulacion	se75f401cdf	9	libre	6.48	t	t	\N
simulacion	se75f401cdf	10	libre	6.48	t	t	\N
simulacion	se75f401cdf	11	libre	6.48	t	t	\N
simulacion	se75f401cdf	12	libre	6.48	t	t	\N
simulacion	se75f401cdf	13	libre	6.48	t	t	\N
simulacion	se75f401cdf	14	libre	6.48	t	t	\N
simulacion	se75f401cdf	15	libre	6.48	t	t	\N
simulacion	se75f401cdf	48	libre	6.48	t	t	\N
simulacion	se75f401cdf	16	libre	6.48	t	t	\N
simulacion	se75f401cdf	17	libre	6.48	t	t	\N
simulacion	se75f401cdf	18	libre	6.48	t	t	\N
simulacion	se75f401cdf	19	libre	6.48	t	t	\N
simulacion	se75f401cdf	20	libre	6.48	t	t	\N
simulacion	se75f401cdf	21	libre	6.48	t	t	\N
simulacion	se75f401cdf	51	libre	5.38	t	t	\N
simulacion	se75f401cdf	22	libre	6.48	t	t	\N
simulacion	se75f401cdf	23	libre	6.48	t	t	\N
simulacion	se75f401cdf	24	libre	6.48	t	t	\N
simulacion	se75f401cdf	25	libre	6.48	t	t	\N
simulacion	se75f401cdf	26	libre	6.48	t	t	\N
simulacion	se75f401cdf	27	libre	6.48	t	t	\N
simulacion	se75f401cdf	28	libre	6.48	t	t	\N
simulacion	se75f401cdf	29	libre	6.48	t	t	\N
simulacion	se75f401cdf	30	libre	6.48	t	t	\N
simulacion	sbcdc0502da	1	libre	6.48	t	t	\N
simulacion	sbcdc0502da	2	libre	6.48	t	t	\N
simulacion	sbcdc0502da	3	libre	6.48	t	t	\N
simulacion	sbcdc0502da	4	libre	6.48	t	t	\N
simulacion	sbcdc0502da	5	libre	6.48	t	t	\N
simulacion	sbcdc0502da	6	libre	6.48	t	t	\N
simulacion	sbcdc0502da	7	libre	6.48	t	t	\N
simulacion	sbcdc0502da	8	libre	6.48	t	t	\N
simulacion	sbcdc0502da	9	libre	6.48	t	t	\N
simulacion	sbcdc0502da	10	libre	6.48	t	t	\N
simulacion	sbcdc0502da	11	libre	6.48	t	t	\N
simulacion	sbcdc0502da	12	libre	6.48	t	t	\N
simulacion	sbcdc0502da	13	libre	6.48	t	t	\N
simulacion	sbcdc0502da	14	libre	6.48	t	t	\N
simulacion	sbcdc0502da	15	libre	6.48	t	t	\N
simulacion	sbcdc0502da	48	libre	6.48	t	t	\N
simulacion	sbcdc0502da	16	libre	6.48	t	t	\N
simulacion	sbcdc0502da	17	libre	6.48	t	t	\N
simulacion	sbcdc0502da	18	libre	6.48	t	t	\N
simulacion	sbcdc0502da	19	libre	6.48	t	t	\N
simulacion	sbcdc0502da	20	libre	6.48	t	t	\N
simulacion	sbcdc0502da	21	libre	6.48	t	t	\N
simulacion	sbcdc0502da	51	libre	5.38	t	t	\N
simulacion	sbcdc0502da	22	libre	6.48	t	t	\N
simulacion	sbcdc0502da	23	libre	6.48	t	t	\N
simulacion	sbcdc0502da	24	libre	6.48	t	t	\N
simulacion	sbcdc0502da	25	libre	6.48	t	t	\N
simulacion	sbcdc0502da	26	libre	6.48	t	t	\N
simulacion	sbcdc0502da	27	libre	6.48	t	t	\N
simulacion	sbcdc0502da	28	libre	6.48	t	t	\N
simulacion	sbcdc0502da	29	libre	6.48	t	t	\N
simulacion	sbcdc0502da	30	libre	6.48	t	t	\N
simulacion	sbcdc0502da	31	libre	6.48	t	t	\N
simulacion	sbcdc0502da	32	libre	6.48	t	t	\N
simulacion	sbcdc0502da	33	libre	6.48	t	t	\N
simulacion	sbcdc0502da	34	libre	5.38	t	t	\N
simulacion	sbcdc0502da	35	libre	5.38	t	t	\N
simulacion	sbcdc0502da	36	libre	5.38	t	t	\N
simulacion	sbcdc0502da	49	libre	5.38	t	t	\N
simulacion	sbcdc0502da	37	libre	5.38	t	t	\N
simulacion	sbcdc0502da	38	libre	5.38	t	t	\N
simulacion	sbcdc0502da	50	libre	5.38	t	t	\N
simulacion	sbcdc0502da	39	libre	5.38	t	t	\N
simulacion	sbcdc0502da	40	libre	5.38	t	t	\N
simulacion	sbcdc0502da	41	libre	5.38	t	t	\N
simulacion	sbcdc0502da	42	libre	5.38	t	t	\N
simulacion	sbcdc0502da	43	libre	5.38	t	t	\N
simulacion	sbcdc0502da	52	libre	5.38	t	t	\N
simulacion	sbcdc0502da	44	libre	5.38	t	t	\N
simulacion	sbcdc0502da	45	libre	5.38	t	t	\N
simulacion	sbcdc0502da	46	libre	5.38	t	t	\N
simulacion	sbcdc0502da	53	libre	5.38	t	t	\N
simulacion	sbcdc0502da	47	libre	5.38	t	t	\N
simulacion	sbcdc0502da	54	libre	1.8	f	t	\N
simulacion	sbcdc0502da	55	libre	1.8	f	t	\N
simulacion	sbcdc0502da	56	libre	1.8	f	t	\N
simulacion	sbcdc0502da	57	libre	1.8	f	t	\N
simulacion	sbcdc0502da	58	libre	1.8	f	t	\N
simulacion	sbcdc0502da	59	libre	1.8	f	t	\N
simulacion	sbcdc0502da	60	libre	1.8	f	t	\N
simulacion	sbcdc0502da	61	libre	6.48	t	t	\N
simulacion	se75f401cdf	31	libre	6.48	t	t	\N
simulacion	se75f401cdf	32	libre	6.48	t	t	\N
simulacion	se75f401cdf	33	libre	6.48	t	t	\N
simulacion	se75f401cdf	34	libre	5.38	t	t	\N
simulacion	se75f401cdf	35	libre	5.38	t	t	\N
simulacion	se75f401cdf	36	libre	5.38	t	t	\N
simulacion	se75f401cdf	49	libre	5.38	t	t	\N
simulacion	se75f401cdf	37	libre	5.38	t	t	\N
simulacion	se75f401cdf	38	libre	5.38	t	t	\N
simulacion	sc1195efed5	1	libre	6.48	t	t	\N
simulacion	s0f4dd06250	1	libre	6.48	t	t	\N
simulacion	s0f4dd06250	2	libre	6.48	t	t	\N
simulacion	s0f4dd06250	3	libre	6.48	t	t	\N
simulacion	s0f4dd06250	4	libre	6.48	t	t	\N
simulacion	s0f4dd06250	5	libre	6.48	t	t	\N
simulacion	s0f4dd06250	6	libre	6.48	t	t	\N
simulacion	s0f4dd06250	7	libre	6.48	t	t	\N
simulacion	s0f4dd06250	8	libre	6.48	t	t	\N
simulacion	s0f4dd06250	9	libre	6.48	t	t	\N
simulacion	s0f4dd06250	10	libre	6.48	t	t	\N
simulacion	s0f4dd06250	11	libre	6.48	t	t	\N
simulacion	s0f4dd06250	12	libre	6.48	t	t	\N
simulacion	s0f4dd06250	13	libre	6.48	t	t	\N
simulacion	s0f4dd06250	14	libre	6.48	t	t	\N
simulacion	s0f4dd06250	15	libre	6.48	t	t	\N
simulacion	s0f4dd06250	48	libre	6.48	t	t	\N
simulacion	s0f4dd06250	16	libre	6.48	t	t	\N
simulacion	s0f4dd06250	17	libre	6.48	t	t	\N
simulacion	s0f4dd06250	18	libre	6.48	t	t	\N
simulacion	s0f4dd06250	19	libre	6.48	t	t	\N
simulacion	s0f4dd06250	20	libre	6.48	t	t	\N
simulacion	s0f4dd06250	21	libre	6.48	t	t	\N
simulacion	s0f4dd06250	51	libre	5.38	t	t	\N
simulacion	s0f4dd06250	22	libre	6.48	t	t	\N
simulacion	s0f4dd06250	23	libre	6.48	t	t	\N
simulacion	s0f4dd06250	24	libre	6.48	t	t	\N
simulacion	s0f4dd06250	25	libre	6.48	t	t	\N
simulacion	s0f4dd06250	26	libre	6.48	t	t	\N
simulacion	s0f4dd06250	27	libre	6.48	t	t	\N
simulacion	s0f4dd06250	28	libre	6.48	t	t	\N
simulacion	s0f4dd06250	29	libre	6.48	t	t	\N
simulacion	s0f4dd06250	30	libre	6.48	t	t	\N
simulacion	s0f4dd06250	31	libre	6.48	t	t	\N
simulacion	s0f4dd06250	32	libre	6.48	t	t	\N
simulacion	s0f4dd06250	33	libre	6.48	t	t	\N
simulacion	s0f4dd06250	34	libre	5.38	t	t	\N
simulacion	s0f4dd06250	35	libre	5.38	t	t	\N
simulacion	s0f4dd06250	36	libre	5.38	t	t	\N
simulacion	s0f4dd06250	49	libre	5.38	t	t	\N
simulacion	s0f4dd06250	37	libre	5.38	t	t	\N
simulacion	s0f4dd06250	38	libre	5.38	t	t	\N
simulacion	s0f4dd06250	50	libre	5.38	t	t	\N
simulacion	s0f4dd06250	39	libre	5.38	t	t	\N
simulacion	s0f4dd06250	40	libre	5.38	t	t	\N
simulacion	s0f4dd06250	41	libre	5.38	t	t	\N
simulacion	s0f4dd06250	42	libre	5.38	t	t	\N
simulacion	s0f4dd06250	43	libre	5.38	t	t	\N
simulacion	s0f4dd06250	52	libre	5.38	t	t	\N
simulacion	s0f4dd06250	44	libre	5.38	t	t	\N
simulacion	s0f4dd06250	45	libre	5.38	t	t	\N
simulacion	s0f4dd06250	46	libre	5.38	t	t	\N
simulacion	s0f4dd06250	53	libre	5.38	t	t	\N
simulacion	s0f4dd06250	47	libre	5.38	t	t	\N
simulacion	s0f4dd06250	54	libre	1.8	f	t	\N
simulacion	s0f4dd06250	55	libre	1.8	f	t	\N
simulacion	s0f4dd06250	56	libre	1.8	f	t	\N
simulacion	s0f4dd06250	57	libre	1.8	f	t	\N
simulacion	s0f4dd06250	58	libre	1.8	f	t	\N
simulacion	s0f4dd06250	59	libre	1.8	f	t	\N
simulacion	s0f4dd06250	60	libre	1.8	f	t	\N
simulacion	s0f4dd06250	61	libre	6.48	t	t	\N
simulacion	se75f401cdf	50	libre	5.38	t	t	\N
simulacion	se75f401cdf	39	libre	5.38	t	t	\N
simulacion	se75f401cdf	40	libre	5.38	t	t	\N
simulacion	se75f401cdf	41	libre	5.38	t	t	\N
simulacion	se75f401cdf	42	libre	5.38	t	t	\N
simulacion	se75f401cdf	43	libre	5.38	t	t	\N
simulacion	se75f401cdf	52	libre	5.38	t	t	\N
simulacion	se75f401cdf	44	libre	5.38	t	t	\N
simulacion	se75f401cdf	45	libre	5.38	t	t	\N
simulacion	se75f401cdf	46	libre	5.38	t	t	\N
simulacion	prueba	1	libre	6.48	t	t	\N
simulacion	prueba	2	libre	6.48	t	t	\N
simulacion	prueba	3	libre	6.48	t	t	\N
simulacion	prueba	4	libre	6.48	t	t	\N
simulacion	prueba	5	libre	6.48	t	t	\N
simulacion	prueba	6	libre	6.48	t	t	\N
simulacion	prueba	7	libre	6.48	t	t	\N
simulacion	prueba	8	libre	6.48	t	t	\N
simulacion	prueba	9	libre	6.48	t	t	\N
simulacion	prueba	10	libre	6.48	t	t	\N
simulacion	prueba	11	libre	6.48	t	t	\N
simulacion	prueba	12	libre	6.48	t	t	\N
simulacion	prueba	13	libre	6.48	t	t	\N
simulacion	prueba	14	libre	6.48	t	t	\N
simulacion	prueba	15	libre	6.48	t	t	\N
simulacion	prueba	48	libre	6.48	t	t	\N
simulacion	prueba	16	libre	6.48	t	t	\N
simulacion	prueba	17	libre	6.48	t	t	\N
simulacion	prueba	18	libre	6.48	t	t	\N
simulacion	prueba	19	libre	6.48	t	t	\N
simulacion	prueba	20	libre	6.48	t	t	\N
simulacion	prueba	21	libre	6.48	t	t	\N
simulacion	prueba	51	libre	5.38	t	t	\N
simulacion	prueba	22	libre	6.48	t	t	\N
simulacion	prueba	23	libre	6.48	t	t	\N
simulacion	prueba	24	libre	6.48	t	t	\N
simulacion	prueba	25	libre	6.48	t	t	\N
simulacion	prueba	26	libre	6.48	t	t	\N
simulacion	prueba	27	libre	6.48	t	t	\N
simulacion	prueba	28	libre	6.48	t	t	\N
simulacion	prueba	29	libre	6.48	t	t	\N
simulacion	prueba	30	libre	6.48	t	t	\N
simulacion	prueba	31	libre	6.48	t	t	\N
simulacion	prueba	32	libre	6.48	t	t	\N
simulacion	prueba	33	libre	6.48	t	t	\N
simulacion	prueba	34	libre	5.38	t	t	\N
simulacion	prueba	35	libre	5.38	t	t	\N
simulacion	prueba	36	libre	5.38	t	t	\N
simulacion	prueba	49	libre	5.38	t	t	\N
simulacion	prueba	37	libre	5.38	t	t	\N
simulacion	prueba	38	libre	5.38	t	t	\N
simulacion	prueba	50	libre	5.38	t	t	\N
simulacion	prueba	39	libre	5.38	t	t	\N
simulacion	prueba	40	libre	5.38	t	t	\N
simulacion	prueba	41	libre	5.38	t	t	\N
simulacion	prueba	42	libre	5.38	t	t	\N
simulacion	prueba	43	libre	5.38	t	t	\N
simulacion	prueba	52	libre	5.38	t	t	\N
simulacion	prueba	44	libre	5.38	t	t	\N
simulacion	prueba	45	libre	5.38	t	t	\N
simulacion	prueba	46	libre	5.38	t	t	\N
simulacion	prueba	53	libre	5.38	t	t	\N
simulacion	prueba	47	libre	5.38	t	t	\N
simulacion	prueba	54	libre	1.8	f	t	\N
simulacion	prueba	55	libre	1.8	f	t	\N
simulacion	prueba	56	libre	1.8	f	t	\N
simulacion	prueba	57	libre	1.8	f	t	\N
simulacion	prueba	58	libre	1.8	f	t	\N
simulacion	prueba	59	libre	1.8	f	t	\N
simulacion	prueba	60	libre	1.8	f	t	\N
simulacion	prueba	61	libre	6.48	t	t	\N
simulacion	se75f401cdf	53	libre	5.38	t	t	\N
simulacion	se75f401cdf	47	libre	5.38	t	t	\N
simulacion	se75f401cdf	54	libre	1.8	f	t	\N
simulacion	se75f401cdf	55	libre	1.8	f	t	\N
simulacion	se75f401cdf	56	libre	1.8	f	t	\N
simulacion	se75f401cdf	57	libre	1.8	f	t	\N
simulacion	se75f401cdf	58	libre	1.8	f	t	\N
simulacion	se75f401cdf	59	libre	1.8	f	t	\N
simulacion	se75f401cdf	60	libre	1.8	f	t	\N
simulacion	se75f401cdf	61	libre	6.48	t	t	\N
simulacion	s61cd91a577	49	libre	5.38	t	t	\N
simulacion	s61cd91a577	37	libre	5.38	t	t	\N
simulacion	s61cd91a577	38	libre	5.38	t	t	\N
simulacion	s61cd91a577	50	libre	5.38	t	t	\N
simulacion	s61cd91a577	39	libre	5.38	t	t	\N
simulacion	s61cd91a577	40	libre	5.38	t	t	\N
simulacion	s61cd91a577	41	libre	5.38	t	t	\N
simulacion	s61cd91a577	42	libre	5.38	t	t	\N
simulacion	s61cd91a577	43	libre	5.38	t	t	\N
simulacion	s61cd91a577	52	libre	5.38	t	t	\N
simulacion	s61cd91a577	44	libre	5.38	t	t	\N
simulacion	s61cd91a577	45	libre	5.38	t	t	\N
simulacion	s61cd91a577	46	libre	5.38	t	t	\N
simulacion	s61cd91a577	53	libre	5.38	t	t	\N
simulacion	s61cd91a577	47	libre	5.38	t	t	\N
simulacion	s61cd91a577	54	libre	1.8	f	t	\N
simulacion	s61cd91a577	55	libre	1.8	f	t	\N
simulacion	s61cd91a577	56	libre	1.8	f	t	\N
simulacion	s61cd91a577	57	libre	1.8	f	t	\N
simulacion	s61cd91a577	58	libre	1.8	f	t	\N
simulacion	s61cd91a577	59	libre	1.8	f	t	\N
simulacion	s61cd91a577	60	libre	1.8	f	t	\N
simulacion	s61cd91a577	61	libre	6.48	t	t	\N
simulacion	saa7ac3c714	1	libre	6.48	t	t	\N
simulacion	saa7ac3c714	2	libre	6.48	t	t	\N
simulacion	saa7ac3c714	3	libre	6.48	t	t	\N
simulacion	saa7ac3c714	4	libre	6.48	t	t	\N
simulacion	saa7ac3c714	5	libre	6.48	t	t	\N
simulacion	saa7ac3c714	6	libre	6.48	t	t	\N
simulacion	saa7ac3c714	7	libre	6.48	t	t	\N
simulacion	saa7ac3c714	8	libre	6.48	t	t	\N
simulacion	saa7ac3c714	9	libre	6.48	t	t	\N
simulacion	saa7ac3c714	10	libre	6.48	t	t	\N
simulacion	saa7ac3c714	11	libre	6.48	t	t	\N
simulacion	saa7ac3c714	12	libre	6.48	t	t	\N
simulacion	s57a27c547d	1	libre	6.48	t	t	\N
simulacion	s57a27c547d	2	libre	6.48	t	t	\N
simulacion	s57a27c547d	3	libre	6.48	t	t	\N
simulacion	s57a27c547d	4	libre	6.48	t	t	\N
simulacion	s57a27c547d	5	libre	6.48	t	t	\N
simulacion	s57a27c547d	6	libre	6.48	t	t	\N
simulacion	s57a27c547d	7	libre	6.48	t	t	\N
simulacion	s57a27c547d	8	libre	6.48	t	t	\N
simulacion	s57a27c547d	9	libre	6.48	t	t	\N
simulacion	s57a27c547d	10	libre	6.48	t	t	\N
simulacion	s57a27c547d	11	libre	6.48	t	t	\N
simulacion	s57a27c547d	12	libre	6.48	t	t	\N
simulacion	s57a27c547d	13	libre	6.48	t	t	\N
simulacion	s57a27c547d	14	libre	6.48	t	t	\N
simulacion	s57a27c547d	15	libre	6.48	t	t	\N
simulacion	s57a27c547d	48	libre	6.48	t	t	\N
simulacion	saa7ac3c714	13	libre	6.48	t	t	\N
simulacion	saa7ac3c714	14	libre	6.48	t	t	\N
simulacion	saa7ac3c714	15	libre	6.48	t	t	\N
simulacion	saa7ac3c714	48	libre	6.48	t	t	\N
simulacion	saa7ac3c714	16	libre	6.48	t	t	\N
simulacion	s50bd328e7f	1	libre	6.48	t	t	\N
simulacion	s50bd328e7f	2	libre	6.48	t	t	\N
simulacion	s50bd328e7f	3	libre	6.48	t	t	\N
simulacion	s50bd328e7f	4	libre	6.48	t	t	\N
simulacion	s50bd328e7f	5	libre	6.48	t	t	\N
simulacion	s50bd328e7f	6	libre	6.48	t	t	\N
simulacion	s50bd328e7f	7	libre	6.48	t	t	\N
simulacion	s50bd328e7f	8	libre	6.48	t	t	\N
simulacion	s50bd328e7f	9	libre	6.48	t	t	\N
simulacion	s50bd328e7f	10	libre	6.48	t	t	\N
simulacion	s50bd328e7f	11	libre	6.48	t	t	\N
simulacion	s50bd328e7f	12	libre	6.48	t	t	\N
simulacion	s50bd328e7f	13	libre	6.48	t	t	\N
simulacion	s50bd328e7f	14	libre	6.48	t	t	\N
simulacion	s50bd328e7f	15	libre	6.48	t	t	\N
simulacion	s50bd328e7f	48	libre	6.48	t	t	\N
simulacion	s50bd328e7f	16	libre	6.48	t	t	\N
simulacion	s50bd328e7f	17	libre	6.48	t	t	\N
simulacion	s50bd328e7f	18	libre	6.48	t	t	\N
simulacion	s50bd328e7f	19	libre	6.48	t	t	\N
simulacion	s50bd328e7f	20	libre	6.48	t	t	\N
simulacion	s50bd328e7f	21	libre	6.48	t	t	\N
simulacion	s50bd328e7f	51	libre	5.38	t	t	\N
simulacion	s50bd328e7f	22	libre	6.48	t	t	\N
simulacion	s50bd328e7f	23	libre	6.48	t	t	\N
simulacion	s50bd328e7f	24	libre	6.48	t	t	\N
simulacion	s50bd328e7f	25	libre	6.48	t	t	\N
simulacion	s50bd328e7f	26	libre	6.48	t	t	\N
simulacion	s50bd328e7f	27	libre	6.48	t	t	\N
simulacion	s50bd328e7f	28	libre	6.48	t	t	\N
simulacion	s50bd328e7f	29	libre	6.48	t	t	\N
simulacion	s50bd328e7f	30	libre	6.48	t	t	\N
simulacion	s50bd328e7f	31	libre	6.48	t	t	\N
simulacion	s50bd328e7f	32	libre	6.48	t	t	\N
simulacion	s50bd328e7f	33	libre	6.48	t	t	\N
simulacion	s50bd328e7f	34	libre	5.38	t	t	\N
simulacion	s50bd328e7f	35	libre	5.38	t	t	\N
simulacion	s50bd328e7f	36	libre	5.38	t	t	\N
simulacion	s50bd328e7f	49	libre	5.38	t	t	\N
simulacion	s50bd328e7f	37	libre	5.38	t	t	\N
simulacion	s50bd328e7f	38	libre	5.38	t	t	\N
simulacion	s50bd328e7f	50	libre	5.38	t	t	\N
simulacion	s50bd328e7f	39	libre	5.38	t	t	\N
simulacion	s50bd328e7f	40	libre	5.38	t	t	\N
simulacion	s50bd328e7f	41	libre	5.38	t	t	\N
simulacion	s50bd328e7f	42	libre	5.38	t	t	\N
simulacion	s50bd328e7f	43	libre	5.38	t	t	\N
simulacion	s50bd328e7f	52	libre	5.38	t	t	\N
simulacion	s50bd328e7f	44	libre	5.38	t	t	\N
simulacion	s50bd328e7f	45	libre	5.38	t	t	\N
simulacion	s50bd328e7f	46	libre	5.38	t	t	\N
simulacion	s50bd328e7f	53	libre	5.38	t	t	\N
simulacion	s50bd328e7f	47	libre	5.38	t	t	\N
simulacion	s50bd328e7f	54	libre	1.8	f	t	\N
simulacion	s50bd328e7f	55	libre	1.8	f	t	\N
simulacion	s50bd328e7f	56	libre	1.8	f	t	\N
simulacion	s57a27c547d	28	libre	6.48	t	t	\N
simulacion	s57a27c547d	29	libre	6.48	t	t	\N
simulacion	s57a27c547d	30	libre	6.48	t	t	\N
simulacion	s57a27c547d	31	libre	6.48	t	t	\N
simulacion	s57a27c547d	32	libre	6.48	t	t	\N
simulacion	s57a27c547d	33	libre	6.48	t	t	\N
simulacion	s57a27c547d	34	libre	5.38	t	t	\N
simulacion	s57a27c547d	35	libre	5.38	t	t	\N
simulacion	s57a27c547d	36	libre	5.38	t	t	\N
simulacion	s57a27c547d	49	libre	5.38	t	t	\N
simulacion	s57a27c547d	37	libre	5.38	t	t	\N
simulacion	s57a27c547d	38	libre	5.38	t	t	\N
simulacion	s57a27c547d	50	libre	5.38	t	t	\N
simulacion	s57a27c547d	39	libre	5.38	t	t	\N
simulacion	s57a27c547d	40	libre	5.38	t	t	\N
simulacion	s57a27c547d	41	bloqueada_parcial	2.826629800656718	f	t	21
simulacion	s57a27c547d	42	bloqueada_parcial	1.3558599403204346	f	t	19
simulacion	s57a27c547d	43	bloqueada_parcial	1.266161052976729	f	t	19
simulacion	s57a27c547d	52	bloqueada_parcial	1.266161052976729	f	t	19
simulacion	s57a27c547d	44	libre	5.38	t	t	\N
simulacion	s57a27c547d	45	libre	5.38	t	t	\N
simulacion	s57a27c547d	46	libre	5.38	t	t	\N
simulacion	s57a27c547d	53	libre	5.38	t	t	\N
simulacion	s57a27c547d	47	libre	5.38	t	t	\N
simulacion	s57a27c547d	54	libre	1.8	f	t	\N
simulacion	s57a27c547d	55	libre	1.8	f	t	\N
simulacion	s57a27c547d	56	libre	1.8	f	t	\N
simulacion	s57a27c547d	57	libre	1.8	f	t	\N
simulacion	s57a27c547d	58	libre	1.8	f	t	\N
simulacion	s57a27c547d	59	libre	1.8	f	t	\N
simulacion	s57a27c547d	60	libre	1.8	f	t	\N
simulacion	s50bd328e7f	57	libre	1.8	f	t	\N
simulacion	s50bd328e7f	58	libre	1.8	f	t	\N
simulacion	s50bd328e7f	59	libre	1.8	f	t	\N
simulacion	s50bd328e7f	60	libre	1.8	f	t	\N
simulacion	s50bd328e7f	61	libre	6.48	t	t	\N
simulacion	s1662d29df5	1	libre	6.48	t	t	\N
simulacion	s1662d29df5	2	libre	6.48	t	t	\N
simulacion	s1662d29df5	3	libre	6.48	t	t	\N
simulacion	s57a27c547d	61	libre	6.48	t	t	\N
simulacion	s1662d29df5	4	libre	6.48	t	t	\N
simulacion	s1662d29df5	5	libre	6.48	t	t	\N
simulacion	s1662d29df5	6	libre	6.48	t	t	\N
simulacion	s1662d29df5	7	libre	6.48	t	t	\N
simulacion	s1662d29df5	8	libre	6.48	t	t	\N
simulacion	s1662d29df5	9	libre	6.48	t	t	\N
simulacion	s1662d29df5	10	libre	6.48	t	t	\N
simulacion	s1662d29df5	11	libre	6.48	t	t	\N
simulacion	s1662d29df5	12	libre	6.48	t	t	\N
simulacion	s1662d29df5	13	libre	6.48	t	t	\N
simulacion	s1662d29df5	14	libre	6.48	t	t	\N
simulacion	s1662d29df5	15	libre	6.48	t	t	\N
simulacion	s1662d29df5	48	libre	6.48	t	t	\N
simulacion	s1662d29df5	16	libre	6.48	t	t	\N
simulacion	s1662d29df5	17	libre	6.48	t	t	\N
simulacion	s1662d29df5	18	libre	6.48	t	t	\N
simulacion	s1662d29df5	19	libre	6.48	t	t	\N
simulacion	s1662d29df5	20	libre	6.48	t	t	\N
simulacion	s1662d29df5	21	libre	6.48	t	t	\N
simulacion	s1662d29df5	51	libre	5.38	t	t	\N
simulacion	s1662d29df5	22	libre	6.48	t	t	\N
simulacion	s1662d29df5	23	libre	6.48	t	t	\N
simulacion	s1662d29df5	24	libre	6.48	t	t	\N
simulacion	s1662d29df5	25	libre	6.48	t	t	\N
simulacion	s1662d29df5	26	libre	6.48	t	t	\N
simulacion	s1662d29df5	27	libre	6.48	t	t	\N
simulacion	s1662d29df5	28	libre	6.48	t	t	\N
simulacion	s1662d29df5	29	libre	6.48	t	t	\N
simulacion	s1662d29df5	30	libre	6.48	t	t	\N
simulacion	s1662d29df5	31	libre	6.48	t	t	\N
simulacion	s1662d29df5	32	libre	6.48	t	t	\N
simulacion	s1662d29df5	33	libre	6.48	t	t	\N
simulacion	s1662d29df5	34	libre	5.38	t	t	\N
simulacion	s1662d29df5	35	libre	5.38	t	t	\N
simulacion	s1662d29df5	36	libre	5.38	t	t	\N
simulacion	s1662d29df5	49	libre	5.38	t	t	\N
simulacion	s1662d29df5	37	libre	5.38	t	t	\N
simulacion	s1662d29df5	38	libre	5.38	t	t	\N
simulacion	s1662d29df5	50	libre	5.38	t	t	\N
simulacion	s1662d29df5	39	libre	5.38	t	t	\N
simulacion	s1662d29df5	40	libre	5.38	t	t	\N
simulacion	s1662d29df5	41	libre	5.38	t	t	\N
simulacion	s1662d29df5	42	libre	5.38	t	t	\N
simulacion	s1662d29df5	43	libre	5.38	t	t	\N
simulacion	s1662d29df5	52	libre	5.38	t	t	\N
simulacion	s1662d29df5	44	libre	5.38	t	t	\N
simulacion	s1662d29df5	45	libre	5.38	t	t	\N
simulacion	s1662d29df5	46	libre	5.38	t	t	\N
simulacion	s1662d29df5	53	libre	5.38	t	t	\N
simulacion	s1662d29df5	47	libre	5.38	t	t	\N
simulacion	s1662d29df5	54	libre	1.8	f	t	\N
simulacion	s1662d29df5	55	libre	1.8	f	t	\N
simulacion	s1662d29df5	56	libre	1.8	f	t	\N
simulacion	s1662d29df5	57	libre	1.8	f	t	\N
simulacion	s1662d29df5	58	libre	1.8	f	t	\N
simulacion	s1662d29df5	59	libre	1.8	f	t	\N
simulacion	s1662d29df5	60	libre	1.8	f	t	\N
simulacion	s1662d29df5	61	libre	6.48	t	t	\N
simulacion	s61cd91a577	1	libre	6.48	t	t	\N
simulacion	s61cd91a577	2	libre	6.48	t	t	\N
simulacion	s61cd91a577	3	libre	6.48	t	t	\N
simulacion	s61cd91a577	4	libre	6.48	t	t	\N
simulacion	s61cd91a577	5	libre	6.48	t	t	\N
simulacion	s61cd91a577	6	libre	6.48	t	t	\N
simulacion	s61cd91a577	7	libre	6.48	t	t	\N
simulacion	s61cd91a577	8	libre	6.48	t	t	\N
simulacion	s61cd91a577	9	libre	6.48	t	t	\N
simulacion	s61cd91a577	10	libre	6.48	t	t	\N
simulacion	s61cd91a577	11	libre	6.48	t	t	\N
simulacion	s61cd91a577	12	libre	6.48	t	t	\N
simulacion	s61cd91a577	13	libre	6.48	t	t	\N
simulacion	s61cd91a577	14	libre	6.48	t	t	\N
simulacion	s61cd91a577	15	libre	6.48	t	t	\N
simulacion	s61cd91a577	48	libre	6.48	t	t	\N
simulacion	s61cd91a577	16	libre	6.48	t	t	\N
simulacion	s61cd91a577	17	libre	6.48	t	t	\N
simulacion	s61cd91a577	18	libre	6.48	t	t	\N
simulacion	s61cd91a577	19	libre	6.48	t	t	\N
simulacion	s61cd91a577	20	libre	6.48	t	t	\N
simulacion	s61cd91a577	21	libre	6.48	t	t	\N
simulacion	s61cd91a577	51	libre	5.38	t	t	\N
simulacion	s61cd91a577	22	libre	6.48	t	t	\N
simulacion	s61cd91a577	23	libre	6.48	t	t	\N
simulacion	s61cd91a577	24	libre	6.48	t	t	\N
simulacion	s61cd91a577	25	libre	6.48	t	t	\N
simulacion	s61cd91a577	26	libre	6.48	t	t	\N
simulacion	s61cd91a577	27	libre	6.48	t	t	\N
simulacion	s61cd91a577	28	libre	6.48	t	t	\N
simulacion	s61cd91a577	29	libre	6.48	t	t	\N
simulacion	s61cd91a577	30	libre	6.48	t	t	\N
simulacion	s61cd91a577	31	libre	6.48	t	t	\N
simulacion	s61cd91a577	32	libre	6.48	t	t	\N
simulacion	s61cd91a577	33	libre	6.48	t	t	\N
simulacion	s61cd91a577	34	libre	5.38	t	t	\N
simulacion	s61cd91a577	35	libre	5.38	t	t	\N
simulacion	s61cd91a577	36	libre	5.38	t	t	\N
simulacion	saa7ac3c714	17	libre	6.48	t	t	\N
simulacion	saa7ac3c714	18	libre	6.48	t	t	\N
simulacion	saa7ac3c714	19	libre	6.48	t	t	\N
simulacion	saa7ac3c714	20	libre	6.48	t	t	\N
simulacion	saa7ac3c714	21	libre	6.48	t	t	\N
simulacion	saa7ac3c714	51	libre	5.38	t	t	\N
simulacion	saa7ac3c714	22	libre	6.48	t	t	\N
simulacion	saa7ac3c714	23	libre	6.48	t	t	\N
simulacion	saa7ac3c714	24	libre	6.48	t	t	\N
simulacion	saa7ac3c714	25	libre	6.48	t	t	\N
simulacion	saa7ac3c714	26	libre	6.48	t	t	\N
simulacion	saa7ac3c714	27	libre	6.48	t	t	\N
simulacion	saa7ac3c714	28	libre	6.48	t	t	\N
simulacion	saa7ac3c714	29	libre	6.48	t	t	\N
simulacion	saa7ac3c714	30	libre	6.48	t	t	\N
simulacion	saa7ac3c714	31	libre	6.48	t	t	\N
simulacion	saa7ac3c714	32	libre	6.48	t	t	\N
simulacion	saa7ac3c714	33	libre	6.48	t	t	\N
simulacion	saa7ac3c714	34	libre	5.38	t	t	\N
simulacion	saa7ac3c714	35	libre	5.38	t	t	\N
simulacion	saa7ac3c714	36	libre	5.38	t	t	\N
simulacion	saa7ac3c714	49	libre	5.38	t	t	\N
simulacion	saa7ac3c714	37	libre	5.38	t	t	\N
simulacion	saa7ac3c714	38	libre	5.38	t	t	\N
simulacion	saa7ac3c714	50	libre	5.38	t	t	\N
simulacion	saa7ac3c714	39	libre	5.38	t	t	\N
simulacion	saa7ac3c714	40	libre	5.38	t	t	\N
simulacion	saa7ac3c714	41	libre	5.38	t	t	\N
simulacion	saa7ac3c714	42	libre	5.38	t	t	\N
simulacion	saa7ac3c714	43	libre	5.38	t	t	\N
simulacion	saa7ac3c714	52	libre	5.38	t	t	\N
simulacion	saa7ac3c714	44	libre	5.38	t	t	\N
simulacion	saa7ac3c714	45	libre	5.38	t	t	\N
simulacion	saa7ac3c714	46	libre	5.38	t	t	\N
simulacion	saa7ac3c714	53	libre	5.38	t	t	\N
simulacion	saa7ac3c714	47	libre	5.38	t	t	\N
simulacion	saa7ac3c714	54	libre	1.8	f	t	\N
simulacion	saa7ac3c714	55	libre	1.8	f	t	\N
simulacion	saa7ac3c714	56	libre	1.8	f	t	\N
simulacion	saa7ac3c714	57	libre	1.8	f	t	\N
simulacion	saa7ac3c714	58	libre	1.8	f	t	\N
simulacion	saa7ac3c714	59	libre	1.8	f	t	\N
simulacion	saa7ac3c714	60	libre	1.8	f	t	\N
simulacion	saa7ac3c714	61	libre	6.48	t	t	\N
simulacion	s8419d72a77	1	libre	6.48	t	t	\N
simulacion	s8419d72a77	2	libre	6.48	t	t	\N
simulacion	s8419d72a77	3	libre	6.48	t	t	\N
simulacion	s8419d72a77	4	libre	6.48	t	t	\N
simulacion	s8419d72a77	5	libre	6.48	t	t	\N
simulacion	s8419d72a77	6	libre	6.48	t	t	\N
simulacion	s8419d72a77	7	libre	6.48	t	t	\N
simulacion	s8419d72a77	8	libre	6.48	t	t	\N
simulacion	s8419d72a77	9	libre	6.48	t	t	\N
simulacion	s8419d72a77	10	libre	6.48	t	t	\N
simulacion	s8419d72a77	11	libre	6.48	t	t	\N
simulacion	s8419d72a77	12	libre	6.48	t	t	\N
simulacion	s8419d72a77	13	libre	6.48	t	t	\N
simulacion	s8419d72a77	14	libre	6.48	t	t	\N
simulacion	s8419d72a77	15	libre	6.48	t	t	\N
simulacion	s8419d72a77	48	libre	6.48	t	t	\N
simulacion	s8419d72a77	16	libre	6.48	t	t	\N
simulacion	s8419d72a77	17	libre	6.48	t	t	\N
simulacion	s8419d72a77	18	libre	6.48	t	t	\N
simulacion	s8419d72a77	19	libre	6.48	t	t	\N
simulacion	s8419d72a77	20	libre	6.48	t	t	\N
simulacion	s8419d72a77	21	libre	6.48	t	t	\N
simulacion	s8419d72a77	51	libre	5.38	t	t	\N
simulacion	s8419d72a77	22	libre	6.48	t	t	\N
simulacion	s8419d72a77	23	libre	6.48	t	t	\N
simulacion	s8419d72a77	24	libre	6.48	t	t	\N
simulacion	s8419d72a77	25	libre	6.48	t	t	\N
simulacion	s8419d72a77	26	libre	6.48	t	t	\N
simulacion	s8419d72a77	27	libre	6.48	t	t	\N
simulacion	s8419d72a77	28	libre	6.48	t	t	\N
simulacion	s8419d72a77	29	libre	6.48	t	t	\N
simulacion	s8419d72a77	30	libre	6.48	t	t	\N
simulacion	s8419d72a77	31	libre	6.48	t	t	\N
simulacion	s8419d72a77	32	libre	6.48	t	t	\N
simulacion	s8419d72a77	33	libre	6.48	t	t	\N
simulacion	s8419d72a77	34	libre	5.38	t	t	\N
simulacion	s8419d72a77	35	libre	5.38	t	t	\N
simulacion	s8419d72a77	36	libre	5.38	t	t	\N
simulacion	s8419d72a77	49	libre	5.38	t	t	\N
simulacion	s8419d72a77	37	libre	5.38	t	t	\N
simulacion	s8419d72a77	38	libre	5.38	t	t	\N
simulacion	s8419d72a77	50	libre	5.38	t	t	\N
simulacion	s8419d72a77	39	libre	5.38	t	t	\N
simulacion	s8419d72a77	40	libre	5.38	t	t	\N
simulacion	s8419d72a77	41	libre	5.38	t	t	\N
simulacion	s8419d72a77	42	libre	5.38	t	t	\N
simulacion	s8419d72a77	43	libre	5.38	t	t	\N
simulacion	s8419d72a77	52	libre	5.38	t	t	\N
simulacion	s8419d72a77	44	libre	5.38	t	t	\N
simulacion	s8419d72a77	45	libre	5.38	t	t	\N
simulacion	s8419d72a77	46	libre	5.38	t	t	\N
simulacion	s8419d72a77	53	libre	5.38	t	t	\N
simulacion	s8419d72a77	47	libre	5.38	t	t	\N
simulacion	s8419d72a77	54	libre	1.8	f	t	\N
simulacion	s8419d72a77	55	libre	1.8	f	t	\N
simulacion	s8419d72a77	56	libre	1.8	f	t	\N
simulacion	s8419d72a77	57	libre	1.8	f	t	\N
simulacion	s8419d72a77	58	libre	1.8	f	t	\N
simulacion	s8419d72a77	59	libre	1.8	f	t	\N
simulacion	s8419d72a77	60	libre	1.8	f	t	\N
simulacion	s8419d72a77	61	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	1	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	2	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	3	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	4	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	5	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	6	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	7	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	8	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	9	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	10	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	11	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	12	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	13	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	14	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	15	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	48	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	16	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	17	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	18	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	19	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	20	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	21	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	51	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	22	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	23	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	24	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	25	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	26	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	27	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	28	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	29	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	30	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	31	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	32	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	33	libre	6.48	t	t	\N
simulacion	s2a33e30ee1	34	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	35	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	36	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	49	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	37	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	38	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	50	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	39	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	40	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	41	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	42	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	43	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	52	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	44	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	45	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	46	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	53	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	47	libre	5.38	t	t	\N
simulacion	s2a33e30ee1	54	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	55	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	56	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	57	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	58	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	59	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	60	libre	1.8	f	t	\N
simulacion	s2a33e30ee1	61	libre	6.48	t	t	\N
simulacion	sadb934d385	1	libre	6.48	t	t	\N
simulacion	sadb934d385	2	libre	6.48	t	t	\N
simulacion	sadb934d385	3	libre	6.48	t	t	\N
simulacion	sadb934d385	4	libre	6.48	t	t	\N
simulacion	sadb934d385	5	libre	6.48	t	t	\N
simulacion	sadb934d385	6	libre	6.48	t	t	\N
simulacion	sadb934d385	7	libre	6.48	t	t	\N
simulacion	sadb934d385	8	libre	6.48	t	t	\N
simulacion	sadb934d385	9	libre	6.48	t	t	\N
simulacion	sadb934d385	10	libre	6.48	t	t	\N
simulacion	sadb934d385	11	libre	6.48	t	t	\N
simulacion	sadb934d385	12	libre	6.48	t	t	\N
simulacion	sadb934d385	13	libre	6.48	t	t	\N
simulacion	sadb934d385	14	libre	6.48	t	t	\N
simulacion	sadb934d385	15	libre	6.48	t	t	\N
simulacion	sadb934d385	48	libre	6.48	t	t	\N
simulacion	sadb934d385	16	libre	6.48	t	t	\N
simulacion	sadb934d385	17	libre	6.48	t	t	\N
simulacion	sadb934d385	18	libre	6.48	t	t	\N
simulacion	sadb934d385	19	libre	6.48	t	t	\N
simulacion	sadb934d385	20	libre	6.48	t	t	\N
simulacion	sadb934d385	21	libre	6.48	t	t	\N
simulacion	sadb934d385	51	libre	5.38	t	t	\N
simulacion	sadb934d385	22	libre	6.48	t	t	\N
simulacion	sadb934d385	23	libre	6.48	t	t	\N
simulacion	sadb934d385	24	libre	6.48	t	t	\N
simulacion	sadb934d385	25	libre	6.48	t	t	\N
simulacion	sadb934d385	26	libre	6.48	t	t	\N
simulacion	sadb934d385	27	libre	6.48	t	t	\N
simulacion	sadb934d385	28	libre	6.48	t	t	\N
simulacion	sadb934d385	29	libre	6.48	t	t	\N
simulacion	sadb934d385	30	libre	6.48	t	t	\N
simulacion	sadb934d385	31	libre	6.48	t	t	\N
simulacion	sadb934d385	32	libre	6.48	t	t	\N
simulacion	sadb934d385	33	libre	6.48	t	t	\N
simulacion	sadb934d385	34	libre	5.38	t	t	\N
simulacion	sadb934d385	35	libre	5.38	t	t	\N
simulacion	sadb934d385	36	libre	5.38	t	t	\N
simulacion	sadb934d385	49	libre	5.38	t	t	\N
simulacion	sadb934d385	37	libre	5.38	t	t	\N
simulacion	sadb934d385	38	libre	5.38	t	t	\N
simulacion	sadb934d385	50	libre	5.38	t	t	\N
simulacion	sadb934d385	39	libre	5.38	t	t	\N
simulacion	sadb934d385	40	libre	5.38	t	t	\N
simulacion	sadb934d385	41	libre	5.38	t	t	\N
simulacion	sadb934d385	42	libre	5.38	t	t	\N
simulacion	sadb934d385	43	libre	5.38	t	t	\N
simulacion	sadb934d385	52	libre	5.38	t	t	\N
simulacion	sadb934d385	44	libre	5.38	t	t	\N
simulacion	sadb934d385	45	libre	5.38	t	t	\N
simulacion	sadb934d385	46	libre	5.38	t	t	\N
simulacion	sadb934d385	53	libre	5.38	t	t	\N
simulacion	sadb934d385	47	libre	5.38	t	t	\N
simulacion	sadb934d385	54	libre	1.8	f	t	\N
simulacion	sadb934d385	55	libre	1.8	f	t	\N
simulacion	sadb934d385	56	libre	1.8	f	t	\N
simulacion	sadb934d385	57	libre	1.8	f	t	\N
simulacion	sadb934d385	58	libre	1.8	f	t	\N
simulacion	sadb934d385	59	libre	1.8	f	t	\N
simulacion	sadb934d385	60	libre	1.8	f	t	\N
simulacion	sadb934d385	61	libre	6.48	t	t	\N
simulacion	sc1195efed5	2	libre	6.48	t	t	\N
simulacion	sc1195efed5	3	libre	6.48	t	t	\N
simulacion	sc1195efed5	4	libre	6.48	t	t	\N
simulacion	sc1195efed5	5	libre	6.48	t	t	\N
simulacion	sc1195efed5	6	libre	6.48	t	t	\N
simulacion	sc1195efed5	7	libre	6.48	t	t	\N
simulacion	sc1195efed5	8	libre	6.48	t	t	\N
simulacion	sc1195efed5	9	libre	6.48	t	t	\N
simulacion	sc1195efed5	10	libre	6.48	t	t	\N
simulacion	sc1195efed5	11	libre	6.48	t	t	\N
simulacion	sc1195efed5	12	libre	6.48	t	t	\N
simulacion	sc1195efed5	13	libre	6.48	t	t	\N
simulacion	sc1195efed5	14	libre	6.48	t	t	\N
simulacion	sc1195efed5	15	libre	6.48	t	t	\N
simulacion	sc1195efed5	48	libre	6.48	t	t	\N
simulacion	sc1195efed5	16	libre	6.48	t	t	\N
simulacion	sc1195efed5	17	libre	6.48	t	t	\N
simulacion	sc1195efed5	18	libre	6.48	t	t	\N
simulacion	sc1195efed5	19	libre	6.48	t	t	\N
simulacion	sc1195efed5	20	libre	6.48	t	t	\N
simulacion	sc1195efed5	21	libre	6.48	t	t	\N
simulacion	sc1195efed5	51	libre	5.38	t	t	\N
simulacion	sc1195efed5	22	libre	6.48	t	t	\N
simulacion	sc1195efed5	23	libre	6.48	t	t	\N
simulacion	sc1195efed5	24	libre	6.48	t	t	\N
simulacion	sc1195efed5	25	libre	6.48	t	t	\N
simulacion	sc1195efed5	26	libre	6.48	t	t	\N
simulacion	sc1195efed5	27	libre	6.48	t	t	\N
simulacion	sc1195efed5	28	libre	6.48	t	t	\N
simulacion	sc1195efed5	29	libre	6.48	t	t	\N
simulacion	sc1195efed5	30	libre	6.48	t	t	\N
simulacion	sc1195efed5	31	libre	6.48	t	t	\N
simulacion	sc1195efed5	32	libre	6.48	t	t	\N
simulacion	sc1195efed5	33	libre	6.48	t	t	\N
simulacion	sc1195efed5	34	libre	5.38	t	t	\N
simulacion	sc1195efed5	35	libre	5.38	t	t	\N
simulacion	sc1195efed5	36	libre	5.38	t	t	\N
simulacion	sc1195efed5	49	libre	5.38	t	t	\N
simulacion	sc1195efed5	37	libre	5.38	t	t	\N
simulacion	sc1195efed5	38	libre	5.38	t	t	\N
simulacion	sc1195efed5	50	libre	5.38	t	t	\N
simulacion	sc1195efed5	39	libre	5.38	t	t	\N
simulacion	sc1195efed5	40	libre	5.38	t	t	\N
simulacion	sc1195efed5	41	libre	4.2442607851477625	t	t	\N
simulacion	sc1195efed5	42	bloqueada_parcial	2.677931701780453	f	t	20
simulacion	sc1195efed5	43	libre	5.254357680381219	t	t	\N
simulacion	sc1195efed5	52	libre	5.38	t	t	\N
simulacion	sc1195efed5	44	libre	5.38	t	t	\N
simulacion	sc1195efed5	45	libre	5.38	t	t	\N
simulacion	sc1195efed5	46	libre	5.38	t	t	\N
simulacion	sc1195efed5	53	libre	5.38	t	t	\N
simulacion	sc1195efed5	47	libre	5.38	t	t	\N
simulacion	sc1195efed5	54	libre	1.8	f	t	\N
simulacion	sc1195efed5	55	libre	1.8	f	t	\N
simulacion	sc1195efed5	56	libre	1.8	f	t	\N
simulacion	sc1195efed5	57	libre	1.8	f	t	\N
simulacion	sc1195efed5	58	libre	1.8	f	t	\N
simulacion	sc1195efed5	59	libre	1.8	f	t	\N
simulacion	sc1195efed5	60	libre	1.8	f	t	\N
simulacion	sc1195efed5	61	libre	6.48	t	t	\N
\.


--
-- Data for Name: vias; Type: TABLE DATA; Schema: sig; Owner: -
--

COPY sig.vias (seg_id, via_id, nombre, tipo_via, ancho_m, estado_obs, source, target, geom) FROM stdin;
1	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	20	17	0102000020CE7F0000030000009D485BDBCEC41C4196CBF87BAC8260414E51883A8EC41C41E0DEBA15AC8260411C14433F70C41C415F6E5FD6AB826041
2	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	17	48	0102000020CE7F0000040000001C14433F70C41C415F6E5FD6AB826041CA4DA8D85DC41C412BF27CAFAB826041D7A6216B38C41C411B0F2016AB82604136FA972F1BC41C41C72FB670AA826041
3	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	48	51	0102000020CE7F00000400000036FA972F1BC41C41C72FB670AA826041E5FF9AFD12C41C41C8A45642AA826041CE01FED2EAC31C4103D5BB42A9826041F6814998CDC31C4161E12CA1A8826041
4	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	51	32	0102000020CE7F000004000000F6814998CDC31C4161E12CA1A882604131C4B99DB8C31C418452382DA8826041C5FA3D0F8AC31C414D1DCC01A7826041E41FA5B580C31C41ADDC21CAA6826041
5	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	32	33	0102000020CE7F000004000000E41FA5B580C31C41ADDC21CAA6826041BA1953CE62C31C4140001A18A6826041E0AC30343FC31C4160FB2170A5826041000CA51430C31C417326F41DA5826041
6	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	33	41	0102000020CE7F000004000000000CA51430C31C417326F41DA58260415CA950D20EC31C41B29A3969A4826041BECDA8C8EFC21C410174A6B2A3826041FB7C3EEAE3C21C41EC21B544A3826041
7	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	41	35	0102000020CE7F000005000000FB7C3EEAE3C21C41EC21B544A3826041D7A57070DEC21C410800FC11A38260413ACAC866BFC21C41CD04E536A28260415440F4E29AC21C41ECFFEC8EA18260412F49AB1196C21C4151074484A1826041
8	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	35	5	0102000020CE7F0000040000002F49AB1196C21C4151074484A182604118EB40FB6FC21C411FA4FC2FA1826041B8A0138255C21C41C4ADDDFCA0826041CDE3641638C21C41580590C8A0826041
9	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	5	43	0102000020CE7F000005000000CDE3641638C21C41580590C8A0826041028B07A534C21C41812671C2A0826041A140DA2B1AC21C415AD46130A0826041BCC03815FCC11C41539CE2259F826041BCC03815FCC11C41E3B15CA39E826041
10	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	43	29	0102000020CE7F000004000000BCC03815FCC11C41E3B15CA39E826041BCC03815FCC11C41CA89E1BB9D8260410CC89E1E07C21C41848DE61C9C826041CEA0AB570BC21C41C8146AAA9B826041
11	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	29	57	0102000020CE7F000003000000CEA0AB570BC21C41C8146AAA9B826041CE6E56FC1AC21C41861A4F029A8260413505285F1EC21C41F2DE7AB698826041
12	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	57	12	0102000020CE7F0000040000003505285F1EC21C41F2DE7AB698826041873E7F661FC21C41017BAB5198826041873E7F661FC21C4167299DE7958260419B692FF51FC21C419358E0AF95826041
13	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	bloqueada_total	12	19	0102000020CE7F0000020000009B692FF51FC21C419358E0AF95826041410EA8D023C21C414338252E94826041
14	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	libre	28	55	0102000020CE7F000004000000712FBB4E2CC21C416EDBFBAF92826041B3ADF9A42CC21C413CDFD2A092826041F15252A03EC21C41734B32EF908260416A76449F3FC21C4153C172C08F826041
15	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	bloqueada_total	55	24	0102000020CE7F0000020000006A76449F3FC21C4153C172C08F826041F2DDB95D40C21C41615647DE8E826041
48	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	bloqueada_total	24	3	0102000020CE7F000002000000F2DDB95D40C21C41615647DE8E826041084FBF303CC21C4188536DBA8C826041
16	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	bloqueada_total	3	40	0102000020CE7F000004000000084FBF303CC21C4188536DBA8C8260416E0237043CC21C4146AC9AA38C8260416BEC678938C21C41452133E68A826041DFE4463A2DC21C410B2EE7C189826041
17	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	20	6	0102000020CE7F0000040000009D485BDBCEC41C4196CBF87BAC8260415B7974A0BAC41C414F406CB6AB82604159B676BBA6C41C41DE600C95AA8260415D156E78A6C41C4150FF2DE7A9826041
18	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	6	15	0102000020CE7F0000040000005D156E78A6C41C4150FF2DE7A982604161722121A6C41C419238BF04A982604153BDC93ABBC41C4166BA4479A782604137CD2547C3C41C41C721C928A7826041
19	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	15	18	0102000020CE7F00000400000037CD2547C3C41C41C721C928A782604165BB1AD0E1C41C4179906FF7A58260418F759CAC00C51C41621B53F0A48260417192B74D01C51C419EAC8AEAA4826041
20	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	18	42	0102000020CE7F0000030000007192B74D01C51C419EAC8AEAA482604118E6727625C51C41A4D0449EA38260415F735D1139C51C417D808788A2826041
21	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	42	26	0102000020CE7F0000040000005F735D1139C51C417D808788A2826041930551533DC51C41E685364CA282604183C9EC4E40C51C412E6022FEA082604122FCA47A2FC51C412B6950B59F826041
51	4	Callejon Losa Este	callejon	5.38	libre	8	44	0102000020CE7F000003000000677AEFDEE9C11C413CDCBBD58482604128AD7581D6C11C41ED3CA3A783826041D613A0E2D2C11C418D36BF5083826041
22	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	26	9	0102000020CE7F00000400000022FCA47A2FC51C412B6950B59F826041368ADC4A2CC51C41C01D0D779F8260415DF826590AC51C41070E85BC9D826041D4215AAFFDC41C4148E23F309D826041
23	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	9	22	0102000020CE7F000003000000D4215AAFFDC41C4148E23F309D82604178975951D9C41C41E9B4699D9B82604133503E48C8C41C41E3B6F1BC9A826041
24	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	22	31	0102000020CE7F00000300000033503E48C8C41C41E3B6F1BC9A826041D8CCC092AEC41C41B7E6306A998260411372303599C41C416671B52998826041
25	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	31	10	0102000020CE7F0000040000001372303599C41C416671B52998826041C22E916690C41C41741C9AA597826041AB90613A72C41C4145C720F595826041F7685E306EC41C41A7A4438795826041
26	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	10	56	0102000020CE7F000004000000F7685E306EC41C41A7A44387958260412264F8A765C41C41F0002C9F94826041DC3A699B62C41C41F9ADF8299382604137E27C0A57C41C41F7C229BC92826041
27	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	56	4	0102000020CE7F00000400000037E27C0A57C41C41F7C229BC92826041627F20EB3CC41C41762728C4918260412BE2E15D20C41C41B85F3B5C90826041F89E28941FC41C419E95ED5590826041
28	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	4	46	0102000020CE7F000003000000F89E28941FC41C419E95ED55908260415E28AF9FFEC31C41EAC9494E8F8260416F341AF6D8C31C41384EF05B8E826041
29	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	46	49	0102000020CE7F0000040000006F341AF6D8C31C41384EF05B8E826041394D0AD3D6C31C416814304E8E826041AB3DFB81A5C31C4117E075858D826041DD61C97183C31C411306B3148D826041
30	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	49	13	0102000020CE7F000004000000DD61C97183C31C411306B3148D8260415B296E5373C31C41845C57DF8C8260411828D99A44C31C418FEDCA0F8D826041C506D9B627C31C4138ED8AC48C826041
31	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	13	54	0102000020CE7F000005000000C506D9B627C31C4138ED8AC48C8260413D5BAE661FC31C4179CBE3AE8C826041CAC2EDB603C31C41A5F8602B8C826041C10D39D6E2C21C41BB03F7468B826041D397A7DFD9C21C415216F11B8B826041
32	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	54	52	0102000020CE7F000005000000D397A7DFD9C21C415216F11B8B826041A796EA34CDC21C417FF123DF8A82604145C0C345A6C21C41B07283168B826041F1FC94CC82C21C418A82970F8B826041521324B47DC21C41A15A460A8B826041
33	2	Carretera Chongos Bajo Losa Pumpunya_02	carretera	6.48	libre	52	40	0102000020CE7F000004000000521324B47DC21C41A15A460A8B826041CC21F0FF5AC21C41A6E10FE68A826041B6EB8F8D3EC21C41B0BDE8718A826041DFE4463A2DC21C410B2EE7C189826041
34	3	Callejon Losa Norte	callejon	5.38	libre	40	14	0102000020CE7F000003000000DFE4463A2DC21C410B2EE7C189826041F55E63C30BC21C41D9486AFF89826041C0C0C6C1D4C11C41A0B8DF9789826041
35	3	Callejon Losa Norte	callejon	5.38	libre	14	27	0102000020CE7F000004000000C0C0C6C1D4C11C41A0B8DF978982604152071487CBC11C41164A8086898260415A9E90E791C11C418E6BEAF6888260413E71D2EF7DC11C41A8F2A2C288826041
36	3	Callejon Losa Norte	callejon	5.38	libre	27	53	0102000020CE7F0000020000003E71D2EF7DC11C41A8F2A2C288826041872605F35DC11C41F32CE36E88826041
49	3	Callejon Losa Norte	callejon	5.38	libre	53	39	0102000020CE7F000002000000872605F35DC11C41F32CE36E888260412EB1A50C29C11C41BBCE12C187826041
37	4	Callejon Losa Este	callejon	5.38	libre	40	30	0102000020CE7F000003000000DFE4463A2DC21C410B2EE7C189826041D26EFE1F1FC21C4127BA056088826041464FA7F013C21C41854FEC8B87826041
38	4	Callejon Losa Este	callejon	5.38	libre	30	1	0102000020CE7F000002000000464FA7F013C21C41854FEC8B87826041F1CC66FB04C21C41D458467086826041
50	4	Callejon Losa Este	callejon	5.38	libre	1	21	0102000020CE7F000002000000F1CC66FB04C21C41D458467086826041305C19D4F3C11C41047B856C85826041
39	4	Callejon Losa Este	callejon	5.38	libre	21	8	0102000020CE7F000002000000305C19D4F3C11C41047B856C85826041677AEFDEE9C11C413CDCBBD584826041
40	4	Callejon Losa Este	callejon	5.38	libre	44	23	0102000020CE7F000003000000D613A0E2D2C11C418D36BF5083826041E3033AF3C8C11C410FA54D62828260419E5AFE64BBC11C41AB0F391581826041
41	5	Callejon Losa Sur	callejon	5.38	bloqueada_total	23	34	0102000020CE7F0000020000009E5AFE64BBC11C41AB0F3915818260410FC7662C79C11C417A99DBCA81826041
42	5	Callejon Losa Sur	callejon	5.38	libre	34	37	0102000020CE7F0000040000000FC7662C79C11C417A99DBCA81826041440CD49D77C11C412AD420CF818260412B79844C44C11C41A998088982826041A1D2D65139C11C41BB4647B082826041
43	5	Callejon Losa Sur	callejon	5.38	libre	37	50	0102000020CE7F000002000000A1D2D65139C11C41BB4647B0828260410C0A73CA16C11C419864B32B83826041
52	5	Callejon Losa Sur	callejon	5.38	libre	50	36	0102000020CE7F0000020000000C0A73CA16C11C419864B32B83826041287A7A8DFFC01C41922BDCDD83826041
44	6	Callejon Entrada Losa Sur	callejon	5.38	bloqueada_total	23	16	0102000020CE7F0000030000009E5AFE64BBC11C41AB0F391581826041877C771FCDC11C41953CADC47F8260416CB646DDCDC11C41B2044E8A7E826041
45	6	Callejon Entrada Losa Sur	callejon	5.38	libre	16	38	0102000020CE7F0000030000006CB646DDCDC11C41B2044E8A7E826041681F0A22CEC11C41D15E6A187E826041EFA1E9A1C6C11C410EDAE0E57B826041
46	6	Callejon Entrada Losa Sur	callejon	5.38	libre	38	11	0102000020CE7F000003000000EFA1E9A1C6C11C410EDAE0E57B8260416208750DC6C11C4112B162BA7B8260416208750DC6C11C41D6B97D977A826041
53	6	Callejon Entrada Losa Sur	callejon	5.38	libre	11	45	0102000020CE7F0000030000006208750DC6C11C41D6B97D977A82604143AB0710C7C11C416B986F6479826041C281F24BC6C11C4192C7173F79826041
47	6	Callejon Entrada Losa Sur	callejon	5.38	libre	45	2	0102000020CE7F000003000000C281F24BC6C11C4192C7173F798260411F4E24B9BCC11C418830596C778260415B87088AC9C11C4166B5ECB876826041
54	7	Sendero 1	sendero	1.8	libre	16	8	0102000020CE7F00000B0000006CB646DDCDC11C41B2044E8A7E8260414588687BECC11C4164D6623D7F826041CCA1FF7703C21C41AD7ABCC87F826041FBBAE04E23C21C41D256CE6980826041C7DE5D873DC21C415B58620381826041C160321153C21C41AAA4FA8D81826041DC897D7A6AC21C4148DE511C828260416ED2631E51C21C41BCD185C682826041DE8D319024C21C412B01697A838260417B9065D6FDC11C4109FE501084826041677AEFDEE9C11C413CDCBBD584826041
55	8	Sendero 2	sendero	1.8	libre	11	37	0102000020CE7F00000E0000006208750DC6C11C41D6B97D977A826041B64A3990B3C11C41FE9CE02B7B826041EE9898407FC11C4158677B707B82604190D9805C39C11C41714F87D07B826041A47D333313C11C410DFCB0F97B826041137EC06D1CC11C418AAF9E897D82604186B5CB6223C11C415A3C78CA7E826041A5599BC02AC11C41692008E47F82604159852A952AC11C41D79BFB66808260419610A09335C11C41007FE40B818260416F646D013CC11C4115172F7681826041F8ECAE4A44C11C418183C31282826041224BAC1548C11C4132D3044982826041A1D2D65139C11C41BB4647B082826041
56	9	Sendero 3	sendero	1.8	libre	24	7	0102000020CE7F000007000000F2DDB95D40C21C41615647DE8E8260412F4AED462EC21C41D5DEF9478E82604187EC5BB6EBC11C41DDD2D6378E826041380FAA79A8C11C41CAEE7D5D8E8260411336722B5DC11C41AB1AA9988E826041EECB72CF32C11C41983650BE8E826041A481C7E9C6C01C41898D8A5B8D826041
57	10	Sendero 4	sendero	1.8	libre	53	47	0102000020CE7F000002000000872605F35DC11C41F32CE36E88826041B0B420D246C11C41F9F27E1D87826041
58	10	Sendero 4	sendero	1.8	libre	47	50	0102000020CE7F000005000000B0B420D246C11C41F9F27E1D878260415CC0FBAF31C11C419A488C128682604171C73BA918C11C411B109EAE84826041B1488E330AC11C418DF933F8838260410C0A73CA16C11C419864B32B83826041
59	11	Sendero 5	sendero	1.8	libre	47	1	0102000020CE7F000005000000B0B420D246C11C41F9F27E1D87826041B09FB3CF79C11C41897EC14286826041B025F7D69EC11C414949362D86826041B0F52E50CFC11C410914AB1786826041F1CC66FB04C21C41D458467086826041
60	13	Sendero 6	sendero	1.8	libre	19	25	0102000020CE7F000003000000410EA8D023C21C414338252E94826041AC9B7C7A0FC21C416C6D8B7A938260419FD01468D9C11C41C93E62AB93826041
61	1	Carretera Chongos Bajo Pumpunya 01	carretera	6.48	bloqueada_total	19	28	0102000020CE7F000002000000410EA8D023C21C414338252E94826041712FBB4E2CC21C416EDBFBAF92826041
\.


--
-- Name: auxilio_id_seq; Type: SEQUENCE SET; Schema: sig; Owner: -
--

SELECT pg_catalog.setval('sig.auxilio_id_seq', 1799, true);


--
-- Name: nodos_id_seq; Type: SEQUENCE SET; Schema: sig; Owner: -
--

SELECT pg_catalog.setval('sig.nodos_id_seq', 57, true);


--
-- Name: sim_historial_id_seq; Type: SEQUENCE SET; Schema: sig; Owner: -
--

SELECT pg_catalog.setval('sig.sim_historial_id_seq', 27, true);


--
-- Name: auxilio auxilio_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.auxilio
    ADD CONSTRAINT auxilio_pkey PRIMARY KEY (id);


--
-- Name: bloqueos bloqueos_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.bloqueos
    ADD CONSTRAINT bloqueos_pkey PRIMARY KEY (escenario, sesion_id, seg_id, predio_id);


--
-- Name: nodos nodos_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.nodos
    ADD CONSTRAINT nodos_pkey PRIMARY KEY (id);


--
-- Name: parametros parametros_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.parametros
    ADD CONSTRAINT parametros_pkey PRIMARY KEY (clave);


--
-- Name: predio_estado predio_estado_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.predio_estado
    ADD CONSTRAINT predio_estado_pkey PRIMARY KEY (escenario, sesion_id, predio_id);


--
-- Name: predios predios_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.predios
    ADD CONSTRAINT predios_pkey PRIMARY KEY (id);


--
-- Name: puntos puntos_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.puntos
    ADD CONSTRAINT puntos_pkey PRIMARY KEY (id);


--
-- Name: sim_historial sim_historial_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.sim_historial
    ADD CONSTRAINT sim_historial_pkey PRIMARY KEY (id);


--
-- Name: via_estado via_estado_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.via_estado
    ADD CONSTRAINT via_estado_pkey PRIMARY KEY (escenario, sesion_id, seg_id);


--
-- Name: vias vias_pkey; Type: CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.vias
    ADD CONSTRAINT vias_pkey PRIMARY KEY (seg_id);


--
-- Name: nodos_geom_idx; Type: INDEX; Schema: sig; Owner: -
--

CREATE INDEX nodos_geom_idx ON sig.nodos USING gist (geom);


--
-- Name: predios_geom_idx; Type: INDEX; Schema: sig; Owner: -
--

CREATE INDEX predios_geom_idx ON sig.predios USING gist (geom);


--
-- Name: puntos_geom_idx; Type: INDEX; Schema: sig; Owner: -
--

CREATE INDEX puntos_geom_idx ON sig.puntos USING gist (geom);


--
-- Name: vias_geom_idx; Type: INDEX; Schema: sig; Owner: -
--

CREATE INDEX vias_geom_idx ON sig.vias USING gist (geom);


--
-- Name: auxilio auxilio_nodo_id_fkey; Type: FK CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.auxilio
    ADD CONSTRAINT auxilio_nodo_id_fkey FOREIGN KEY (nodo_id) REFERENCES sig.nodos(id);


--
-- Name: predio_estado predio_estado_predio_id_fkey; Type: FK CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.predio_estado
    ADD CONSTRAINT predio_estado_predio_id_fkey FOREIGN KEY (predio_id) REFERENCES sig.predios(id) ON DELETE CASCADE;


--
-- Name: via_estado via_estado_seg_id_fkey; Type: FK CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.via_estado
    ADD CONSTRAINT via_estado_seg_id_fkey FOREIGN KEY (seg_id) REFERENCES sig.vias(seg_id) ON DELETE CASCADE;


--
-- Name: vias vias_source_fkey; Type: FK CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.vias
    ADD CONSTRAINT vias_source_fkey FOREIGN KEY (source) REFERENCES sig.nodos(id);


--
-- Name: vias vias_target_fkey; Type: FK CONSTRAINT; Schema: sig; Owner: -
--

ALTER TABLE ONLY sig.vias
    ADD CONSTRAINT vias_target_fkey FOREIGN KEY (target) REFERENCES sig.nodos(id);


--
-- PostgreSQL database dump complete
--

\unrestrict tKgfChdq72bPWGmIQglom8FRtuXvd8prCCelfu0YavXBxEB2AWuWDt6eAKVUmi4

