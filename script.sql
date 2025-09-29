-- ======================================================================
-- ESQUEMA + TRIGGERS CORREGIDOS (PostgreSQL)
-- ======================================================================
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- Catálogos
-- -------------------------
create table if not exists tipo_area (
  id_tipo serial primary key,
  nombre_tipo text not null unique
);

create table if not exists origen (
  id_origen serial primary key,
  origen_nombre text not null unique      -- 'Garantía','Terreno','Nuevo'
);

create table if not exists envio (
  id_envio serial primary key,
  origen_envio text not null unique       -- 'Operativo','Reparación Externa','Reparación Interna'
);

create table if not exists estado (
  id_estado serial primary key,
  nombre_estado text not null unique      -- 'OK','NO OK','Operativo','No operativo','Pendiente', etc.
);

create table if not exists rol (
  id_rol serial primary key,
  nombre_rol text not null unique
);

create table if not exists usuario (
  id_usuario serial primary key,
  nombre_usuario text not null,
  apellido_usuario text not null,
  correo_usuario text not null unique,
  password_hash text not null,
  id_rol int not null references rol(id_rol),
  activo boolean default true
);

-- -------------------------
-- Núcleo de dispositivos
-- -------------------------
create table if not exists validador (
  id_validador serial primary key,
  amid text not null unique,
  modelo text,
  id_tipo int references tipo_area(id_tipo),
  created_at timestamptz default now()
);

-- -------------------------
-- Movimiento (un “ciclo” del validador)
-- -------------------------
create table if not exists movimiento (
  id_movimiento serial primary key,
  id_validador int not null references validador(id_validador),
  fecha_ingreso date not null,
  id_origen int not null references origen(id_origen),
  observacion_inicial text,
  fecha_salida date,
  id_envio int references envio(id_envio),
  id_estado_final int references estado(id_estado),
  created_by int references usuario(id_usuario),
  created_at timestamptz default now()
);

create index if not exists idx_mov_validador_fecha on movimiento(id_validador, fecha_ingreso);
create index if not exists idx_mov_created_at      on movimiento(created_at);

-- -------------------------
-- Diagnóstico (técnico de terreno)
-- -------------------------
create table if not exists diagnostico (
  id_diag serial primary key,
  id_movimiento int not null references movimiento(id_movimiento) on delete cascade,
  ppu_inicial text,
  falla_tarjeton text,
  es_falla boolean,
  conectado boolean,
  hora_conectado time,
  observacion_diagnostico text,
  created_by int references usuario(id_usuario),
  created_at timestamptz default now()
);

create index if not exists idx_diag_mov        on diagnostico(id_movimiento);
create index if not exists idx_diag_created_at on diagnostico(created_at);

-- -------------------------
-- Revisión del Supervisor (veredicto sobre diagnóstico)
-- -------------------------
create table if not exists revision_supervisor (
  id_rev serial primary key,
  id_movimiento int not null references movimiento(id_movimiento) on delete cascade,
  trx_pendientes_ok boolean default false,
  patente_asignada text,
  id_estado_diagnostico int not null references estado(id_estado), -- 'OK' / 'NO OK' / 'Pendiente'
  nota_supervisor text,
  fecha_revision date,
  created_by int references usuario(id_usuario),
  created_at timestamptz default now()
);

create index if not exists idx_rev_mov        on revision_supervisor(id_movimiento);
create index if not exists idx_rev_created_at on revision_supervisor(created_at);

-- -------------------------
-- Preparación (técnicos de preparación)
-- -------------------------
create table if not exists preparacion (
  id_prep serial primary key,
  id_movimiento int not null references movimiento(id_movimiento) on delete cascade,
  id_usuario int references usuario(id_usuario),   -- técnico
  id_estado_preparacion int not null references estado(id_estado), -- 'Operativo'/'No operativo'/'Pendiente'
  cambio_patente boolean default false,
  detalle_preparacion text,
  ppu_final text,
  fecha_preparacion date,
  created_at timestamptz default now(),
  constraint chk_ppu_final_si_cambio
    check ( (cambio_patente is false) or (cambio_patente is true and ppu_final is not null) )
);

create index if not exists idx_prep_mov        on preparacion(id_movimiento);
create index if not exists idx_prep_created_at on preparacion(created_at);


-- ======================================================================
-- TRIGGERS CORREGIDOS (comparan por ID, no por nombre)
-- ======================================================================

-- 1) AFTER INSERT ON movimiento
--    - Si origen = Terreno  -> crea diagnostico + revision_supervisor (veredicto 'Pendiente')
--    - Si origen = Garantía/Nuevo -> crea preparacion en 'Pendiente'
create or replace function trg_movimiento_autocrear()
returns trigger
language plpgsql
as $$
declare
  v_id_origen_terreno int;
  v_id_estado_pendiente int;
  v_id_usuario_sistema int;
begin
  -- ID de 'Terreno'
  select id_origen into v_id_origen_terreno
  from origen
  where lower(origen_nombre) = 'terreno'
  limit 1;

  -- Estado 'Pendiente'
  select id_estado into v_id_estado_pendiente
  from estado
  where lower(nombre_estado) = 'pendiente'
  limit 1;

  -- Usuario 'sistema' (opcional). Si no existe, usa el que creó el movimiento.
  select id_usuario into v_id_usuario_sistema
  from usuario
  where lower(correo_usuario) = 'sistema@local'
  limit 1;

  if v_id_usuario_sistema is null then
    v_id_usuario_sistema := NEW.created_by;
  end if;

  if NEW.id_origen = v_id_origen_terreno then
    -- Terreno: crear Diagnóstico + Revisión (Pendiente)
    insert into diagnostico (id_movimiento, created_by)
    values (NEW.id_movimiento, v_id_usuario_sistema);

    insert into revision_supervisor (
      id_movimiento, trx_pendientes_ok, patente_asignada,
      id_estado_diagnostico, nota_supervisor, fecha_revision, created_by
    ) values (
      NEW.id_movimiento, false, null,
      v_id_estado_pendiente, 'Autocreado al ingresar por Terreno',
      current_date, v_id_usuario_sistema
    );

  else
    -- No Terreno (Garantía/Nuevo): crear Preparación base (Pendiente)
    insert into preparacion (
      id_movimiento, id_usuario, id_estado_preparacion,
      cambio_patente, detalle_preparacion, ppu_final, fecha_preparacion
    ) values (
      NEW.id_movimiento, v_id_usuario_sistema, v_id_estado_pendiente,
      false, 'Autocreado por ingreso no-Terreno', null, current_date
    );
  end if;

  return NEW;
end
$$;

drop trigger if exists movimiento_autocrear on movimiento;
create trigger movimiento_autocrear
after insert on movimiento
for each row execute function trg_movimiento_autocrear();

-- ============================================================
-- Opción A: Una sola revisión por movimiento + Trigger simple
-- ============================================================

-- 1) Garantiza UNA (y solo una) revisión por movimiento
CREATE UNIQUE INDEX IF NOT EXISTS ux_revision_supervisor_mov
  ON revision_supervisor (id_movimiento);

-- 2) Función de trigger: bloquea inserciones en PREPARACION
--    si el movimiento viene de Terreno y la revisión NO es OK
CREATE OR REPLACE FUNCTION trg_preparacion_validar_ok()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_id_origen_terreno   INT;
  v_id_estado_ok        INT;
  v_id_origen_mov       INT;
  v_veredicto           INT;
BEGIN
  -- Obtener IDs base (Terreno / OK)
  SELECT id_origen INTO v_id_origen_terreno
  FROM origen
  WHERE lower(origen_nombre) = 'terreno'
  LIMIT 1;

  IF v_id_origen_terreno IS NULL THEN
    RAISE EXCEPTION 'Config: no existe origen "Terreno" en tabla ORIGEN.';
  END IF;

  SELECT id_estado INTO v_id_estado_ok
  FROM estado
  WHERE lower(nombre_estado) = 'ok'
  LIMIT 1;

  IF v_id_estado_ok IS NULL THEN
    RAISE EXCEPTION 'Config: no existe estado "OK" en tabla ESTADO.';
  END IF;

  -- Origen del movimiento que se intenta preparar
  SELECT id_origen INTO v_id_origen_mov
  FROM movimiento
  WHERE id_movimiento = NEW.id_movimiento;

  IF v_id_origen_mov IS NULL THEN
    RAISE EXCEPTION 'Movimiento % no existe.', NEW.id_movimiento;
  END IF;

  -- Validación solo aplica a movimientos provenientes de Terreno
  IF v_id_origen_mov = v_id_origen_terreno THEN
    -- Con índice único, debe haber a lo sumo UNA revisión
    SELECT rs.id_estado_diagnostico
      INTO v_veredicto
    FROM revision_supervisor rs
    WHERE rs.id_movimiento = NEW.id_movimiento;

    -- Si no hay revisión o no es OK → bloquear
    IF v_veredicto IS DISTINCT FROM v_id_estado_ok THEN
      RAISE EXCEPTION
        'No se puede crear PREPARACIÓN: el veredicto del supervisor para el movimiento % no es OK.',
        NEW.id_movimiento;
    END IF;
  END IF;

  RETURN NEW;
END
$$;

-- 3) (Re)crear el trigger en PREPARACION
DROP TRIGGER IF EXISTS preparacion_validar_ok ON preparacion;

CREATE TRIGGER preparacion_validar_ok
BEFORE INSERT ON preparacion
FOR EACH ROW
EXECUTE FUNCTION trg_preparacion_validar_ok();
