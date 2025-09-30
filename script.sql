-- ======================================================================
-- REINICIO DE ESQUEMA
-- ======================================================================
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- ======================================================================
-- TABLAS BASE (igual a tu modelo original)
-- ======================================================================

-- Catálogos
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

-- Núcleo de dispositivos
create table if not exists validador (
  id_validador serial primary key,
  amid text not null unique,
  modelo text,
  id_tipo int references tipo_area(id_tipo),
  created_at timestamptz default now()
);

-- Movimiento (un “ciclo” del validador)
create table if not exists movimiento (
  id_movimiento serial primary key,
  id_validador int not null references validador(id_validador),
  fecha_ingreso date not null,
  id_origen int not null references origen(id_origen),
  observacion_inicial text,
  fecha_salida date,
  id_envio int references envio(id_envio),
  id_estado_final int references estado(id_estado), -- 'Operativo' / 'No operativo'
  created_by int references usuario(id_usuario),
  created_at timestamptz default now()
);

create index if not exists idx_mov_validador_fecha on movimiento(id_validador, fecha_ingreso);
create index if not exists idx_mov_created_at      on movimiento(created_at);

-- Diagnóstico (técnico de terreno)
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

-- Revisión del Supervisor (solo Terreno; veredicto sobre diagnóstico)
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

-- Preparación (técnicos de preparación)
create table if not exists preparacion (
  id_prep serial primary key,
  id_movimiento int not null references movimiento(id_movimiento) on delete cascade,
  id_usuario int references usuario(id_usuario),   -- técnico
  id_estado_preparacion int not null references estado(id_estado), -- 'OK'/'NO OK'/'Pendiente'
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
-- REGLAS E INTEGRIDAD (SQL): Unicidades 1:1 por etapa
-- ======================================================================

-- Un registro por movimiento en cada tabla hija
alter table diagnostico         add constraint unq_diag_mov unique (id_movimiento);
alter table revision_supervisor add constraint unq_rev_mov  unique (id_movimiento);
alter table preparacion         add constraint unq_prep_mov unique (id_movimiento);

-- ======================================================================
-- HELPERS: funciones para obtener IDs por nombre (catálogos)
-- ======================================================================

create or replace function fx_id_origen(p_nombre text) returns int language sql stable as $$
  select id_origen from origen where origen_nombre = p_nombre
$$;

create or replace function fx_id_estado(p_nombre text) returns int language sql stable as $$
  select id_estado from estado where nombre_estado = p_nombre
$$;

-- Diagnóstico “completo”: regla mínima (ajústala si quieres más campos)
create or replace function fx_diag_completo(p_id_movimiento int) returns boolean
language sql stable as $$
  select exists(
    select 1
    from diagnostico d
    where d.id_movimiento = p_id_movimiento
      and d.es_falla is not null
      and d.conectado is not null
  )
$$;

-- ======================================================================
-- TRIGGERS DE NEGOCIO
-- ======================================================================

-- (A) AFTER INSERT en movimiento
--   - Terreno: crea Diagnóstico (borrador) y Revisión Supervisor (Pendiente)
--   - Garantía/Nuevo: crea Preparación (Pendiente)
create or replace function trg_movimiento_post_insert()
returns trigger language plpgsql as $$
declare
  v_origen_nombre text;
  v_estado_pendiente int := fx_id_estado('Pendiente');
begin
  select o.origen_nombre into v_origen_nombre
  from origen o where o.id_origen = new.id_origen;

  if v_origen_nombre = 'Terreno' then
    -- Diagnóstico inicial (borrador)
    insert into diagnostico(id_movimiento, created_by, created_at)
    values (new.id_movimiento, new.created_by, now());

    -- Revisión de supervisor (Pendiente) para diagnóstico
    insert into revision_supervisor(id_movimiento, id_estado_diagnostico, created_by, created_at)
    values (new.id_movimiento, v_estado_pendiente, new.created_by, now());

  elsif v_origen_nombre in ('Garantía','Nuevo') then
    -- Preparación inicial (Pendiente)
    insert into preparacion(id_movimiento, id_estado_preparacion, created_at)
    values (new.id_movimiento, v_estado_pendiente, now());
  end if;

  return new;
end$$;

drop trigger if exists trg_movimiento_ai on movimiento;
create trigger trg_movimiento_ai
after insert on movimiento
for each row execute function trg_movimiento_post_insert();

-- (B) Reglas de Terreno: si Revisión DIAG = NO OK => final = 'No operativo'
--     si Revisión DIAG = OK y Diagnóstico completo => abrir/asegurar Preparación (Pendiente)
create or replace function fx_procesar_revision_diag(p_id_mov int) returns void
language plpgsql as $$
declare
  v_estado_ok int := fx_id_estado('OK');
  v_estado_no_ok int := fx_id_estado('NO OK');
  v_estado_pendiente int := fx_id_estado('Pendiente');
  v_origen_terreno int := fx_id_origen('Terreno');
  v_id_origen_mov int;
  v_id_estado_rev int;
  v_prep_existe boolean;
begin
  select id_origen into v_id_origen_mov from movimiento where id_movimiento = p_id_mov;

  -- Solo aplica si el movimiento es de Terreno
  if v_id_origen_mov is distinct from v_origen_terreno then
    return;
  end if;

  select id_estado_diagnostico into v_id_estado_rev
  from revision_supervisor where id_movimiento = p_id_mov;

  if v_id_estado_rev = v_estado_no_ok then
    -- Cierre inmediato en No operativo
    update movimiento
      set id_estado_final = fx_id_estado('No operativo')
    where id_movimiento = p_id_mov;
    return;
  end if;

  if v_id_estado_rev = v_estado_ok and fx_diag_completo(p_id_mov) then
    -- Asegurar Preparación (si no existe) en Pendiente
    select exists(select 1 from preparacion where id_movimiento = p_id_mov) into v_prep_existe;
    if not v_prep_existe then
      insert into preparacion(id_movimiento, id_estado_preparacion, created_at)
      values (p_id_mov, v_estado_pendiente, now());
    end if;
  end if;
end$$;

-- Disparadores para aplicar la regla anterior
create or replace function trg_revision_supervisor_au()
returns trigger language plpgsql as $$
begin
  perform fx_procesar_revision_diag(new.id_movimiento);
  return new;
end$$;

drop trigger if exists trg_revision_supervisor_au on revision_supervisor;
create trigger trg_revision_supervisor_au
after update on revision_supervisor
for each row execute function trg_revision_supervisor_au();

create or replace function trg_diagnostico_aiu()
returns trigger language plpgsql as $$
begin
  -- al crear/actualizar diagnóstico, re-evaluar si se puede abrir preparación
  perform fx_procesar_revision_diag(coalesce(new.id_movimiento, old.id_movimiento));
  return new;
end$$;

drop trigger if exists trg_diagnostico_ai on diagnostico;
create trigger trg_diagnostico_ai
after insert on diagnostico
for each row execute function trg_diagnostico_aiu();

drop trigger if exists trg_diagnostico_au on diagnostico;
create trigger trg_diagnostico_au
after update on diagnostico
for each row execute function trg_diagnostico_aiu();

-- (C) Preparación define el ESTADO FINAL (para todos los orígenes)
--     - si id_estado_preparacion = 'OK' => movimiento.estado_final = 'Operativo'
--     - si id_estado_preparacion = 'NO OK' => movimiento.estado_final = 'No operativo'
create or replace function trg_preparacion_aiu_set_final()
returns trigger language plpgsql as $$
declare
  v_ok int := fx_id_estado('OK');
  v_no_ok int := fx_id_estado('NO OK');
begin
  if new.id_estado_preparacion = v_ok then
    update movimiento
       set id_estado_final = fx_id_estado('Operativo')
     where id_movimiento = new.id_movimiento;

  elsif new.id_estado_preparacion = v_no_ok then
    update movimiento
       set id_estado_final = fx_id_estado('No operativo')
     where id_movimiento = new.id_movimiento;
  end if;

  return new;
end$$;

drop trigger if exists trg_prep_ai on preparacion;
create trigger trg_prep_ai
after insert on preparacion
for each row execute function trg_preparacion_aiu_set_final();

drop trigger if exists trg_prep_au on preparacion;
create trigger trg_prep_au
after update on preparacion
for each row execute function trg_preparacion_aiu_set_final();

-- (D) Guardas de consistencia por origen (opcional, pero recomendado)
--     - diagnostico solo permitido para movimientos Terreno
--     - revision_supervisor solo permitido para movimientos Terreno
create or replace function trg_guard_diag_only_terreno()
returns trigger language plpgsql as $$
declare
  v_terr int := fx_id_origen('Terreno');
  v_mov_origen int;
begin
  select id_origen into v_mov_origen from movimiento where id_movimiento = coalesce(new.id_movimiento, old.id_movimiento);
  if v_mov_origen is distinct from v_terr then
    raise exception 'Solo se permite diagnóstico para movimientos de origen Terreno';
  end if;
  return new;
end$$;

drop trigger if exists trg_guard_diag_bi on diagnostico;
create trigger trg_guard_diag_bi
before insert or update on diagnostico
for each row execute function trg_guard_diag_only_terreno();

create or replace function trg_guard_rev_only_terreno()
returns trigger language plpgsql as $$
declare
  v_terr int := fx_id_origen('Terreno');
  v_mov_origen int;
begin
  select id_origen into v_mov_origen from movimiento where id_movimiento = coalesce(new.id_movimiento, old.id_movimiento);
  if v_mov_origen is distinct from v_terr then
    raise exception 'Solo se permite revisión de supervisor (diagnóstico) para movimientos de origen Terreno';
  end if;
  return new;
end$$;

drop trigger if exists trg_guard_rev_bi on revision_supervisor;
create trigger trg_guard_rev_bi
before insert or update on revision_supervisor
for each row execute function trg_guard_rev_only_terreno();

-- (E) BLOQUEO DE EDICIÓN tras fecha_salida alcanzada
--     (bloquea si hoy >= fecha_salida del movimiento)
create or replace function fx_mov_bloqueado(p_id_mov int) returns boolean
language sql stable as $$
  select exists(
    select 1
    from movimiento m
    where m.id_movimiento = p_id_mov
      and m.fecha_salida is not null
      and current_date >= m.fecha_salida
  )
$$;

create or replace function trg_block_after_salida()
returns trigger language plpgsql as $$
declare
  v_id_mov int := coalesce(new.id_movimiento, old.id_movimiento);
begin
  if fx_mov_bloqueado(v_id_mov) then
    raise exception 'Edición bloqueada: el movimiento % tiene fecha_salida alcanzada', v_id_mov;
  end if;
  return new;
end$$;

-- Aplicar bloqueo a las tablas operativas
drop trigger if exists trg_block_mov_au on movimiento;
create trigger trg_block_mov_au
before update on movimiento
for each row execute function trg_block_after_salida();

drop trigger if exists trg_block_diag_au on diagnostico;
create trigger trg_block_diag_au
before update on diagnostico
for each row execute function trg_block_after_salida();

drop trigger if exists trg_block_rev_au on revision_supervisor;
create trigger trg_block_rev_au
before update on revision_supervisor
for each row execute function trg_block_after_salida();

drop trigger if exists trg_block_prep_au on preparacion;
create trigger trg_block_prep_au
before update on preparacion
for each row execute function trg_block_after_salida();

-- ======================================================================
-- LISTO
-- ======================================================================

-- Recordatorio:
-- 1) Inserta primero en catálogos los valores necesarios:
--    - origen: 'Terreno', 'Garantía', 'Nuevo'
--    - estado: 'Pendiente', 'OK', 'NO OK', 'Operativo', 'No operativo'
-- 2) Luego crea movimientos con el origen correcto.
-- 3) El flujo se encadena solo por triggers según las reglas acordadas.
