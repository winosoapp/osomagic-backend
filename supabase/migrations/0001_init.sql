-- OSOMAGIC - Migración inicial de esquema
-- Recomendado: nombrar este archivo algo como:
-- 20251119150000_init_osomagic.sql

BEGIN;

------------------------------------------------------------
-- 0. Extensiones necesarias
------------------------------------------------------------

-- En Supabase normalmente ya está, pero por si acaso:
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

------------------------------------------------------------
-- 1. Función genérica para updated_at
------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

------------------------------------------------------------
-- 2. Tabla de usuarios (perfil público + flag admin)
--    Referencia a auth.users
------------------------------------------------------------

CREATE TABLE public.users (
  id          uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  email       text,
  full_name   text,
  avatar_url  text,
  is_admin    boolean NOT NULL DEFAULT FALSE,
  created_at  timestamptz NOT NULL DEFAULT NOW(),
  updated_at  timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON public.users (email);

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- El propio usuario puede ver su fila
CREATE POLICY "Users can view own profile"
  ON public.users
  FOR SELECT
  USING ( auth.uid() = id );

-- El propio usuario puede actualizar su fila
CREATE POLICY "Users can update own profile"
  ON public.users
  FOR UPDATE
  USING ( auth.uid() = id )
  WITH CHECK ( auth.uid() = id );

-- Admin puede ver todos los usuarios
CREATE POLICY "Admins can view all users"
  ON public.users
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

-- Admin puede actualizar cualquier usuario
CREATE POLICY "Admins can update all users"
  ON public.users
  FOR UPDATE
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_users_set_updated_at
BEFORE UPDATE ON public.users
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 3. Planes de suscripción y relación usuario-plan
------------------------------------------------------------

CREATE TABLE public.plans (
  id                  bigserial PRIMARY KEY,
  code                text NOT NULL UNIQUE,        -- ej: FREE, PRO, TEAM
  name                text NOT NULL,
  description         text,
  monthly_price_eur   numeric(10,2) NOT NULL DEFAULT 0,
  yearly_price_eur    numeric(10,2) NOT NULL DEFAULT 0,
  max_projects        integer,
  max_team_members    integer,
  ai_tokens_per_month integer,
  is_active           boolean NOT NULL DEFAULT TRUE,
  created_at          timestamptz NOT NULL DEFAULT NOW(),
  updated_at          timestamptz NOT NULL DEFAULT NOW()
);

ALTER TABLE public.plans ENABLE ROW LEVEL SECURITY;

-- Todos los usuarios autenticados pueden leer planes activos
CREATE POLICY "Anyone can read active plans"
  ON public.plans
  FOR SELECT
  USING ( is_active = TRUE );

-- Solo admins pueden insertar/actualizar/borrar planes
CREATE POLICY "Admins manage plans"
  ON public.plans
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_plans_set_updated_at
BEFORE UPDATE ON public.plans
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();


CREATE TABLE public.user_plans (
  id                      bigserial PRIMARY KEY,
  user_id                 uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  plan_id                 bigint NOT NULL REFERENCES public.plans (id),
  status                  text NOT NULL DEFAULT 'active', -- active, cancelled, past_due
  valid_from              timestamptz NOT NULL DEFAULT NOW(),
  valid_to                timestamptz,
  billing_customer_id     text,      -- id de cliente en Stripe / etc
  billing_subscription_id text,      -- id de suscripción externa
  created_at              timestamptz NOT NULL DEFAULT NOW(),
  updated_at              timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_plans_user_id ON public.user_plans (user_id);

ALTER TABLE public.user_plans ENABLE ROW LEVEL SECURITY;

-- Usuario ve solo sus user_plans
CREATE POLICY "Users can view own user_plans"
  ON public.user_plans
  FOR SELECT
  USING ( auth.uid() = user_id );

-- Usuario NO modifica directamente (normalmente gestiona el sistema / webhook)
-- Solo admins pueden tocar todo
CREATE POLICY "Admins manage user_plans"
  ON public.user_plans
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_user_plans_set_updated_at
BEFORE UPDATE ON public.user_plans
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 4. Proyectos y versiones
------------------------------------------------------------

CREATE TABLE public.projects (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id           uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  name               text NOT NULL,
  slug               text,
  description        text,
  visibility         text NOT NULL DEFAULT 'private', -- private, unlisted, public
  status             text NOT NULL DEFAULT 'draft',   -- draft, active, archived
  current_version_id uuid,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW(),
  deleted_at         timestamptz
);

CREATE UNIQUE INDEX idx_projects_owner_slug
  ON public.projects (owner_id, slug)
  WHERE slug IS NOT NULL;

ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;

-- El dueño ve su proyecto
CREATE POLICY "Users can view own projects"
  ON public.projects
  FOR SELECT
  USING ( auth.uid() = owner_id );

-- El dueño puede gestionar su proyecto
CREATE POLICY "Users can manage own projects"
  ON public.projects
  FOR ALL
  USING ( auth.uid() = owner_id )
  WITH CHECK ( auth.uid() = owner_id );

-- Proyectos públicos visibles para cualquiera autenticado
CREATE POLICY "Anyone can view public projects"
  ON public.projects
  FOR SELECT
  USING ( visibility = 'public' );

-- Admins pueden ver/gestionar todo
CREATE POLICY "Admins can manage all projects"
  ON public.projects
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_projects_set_updated_at
BEFORE UPDATE ON public.projects
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();


CREATE TABLE public.project_versions (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id     uuid NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
  version_number integer NOT NULL,
  label          text,
  is_current     boolean NOT NULL DEFAULT FALSE,
  created_by     uuid NOT NULL REFERENCES auth.users (id),
  created_at     timestamptz NOT NULL DEFAULT NOW(),
  updated_at     timestamptz NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX idx_project_versions_project_version
  ON public.project_versions (project_id, version_number);

ALTER TABLE public.project_versions ENABLE ROW LEVEL SECURITY;

-- Usuarios pueden ver versiones de sus proyectos
CREATE POLICY "Users can view versions of own projects"
  ON public.project_versions
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  );

-- Usuarios pueden gestionar versiones de sus proyectos
CREATE POLICY "Users can manage versions of own projects"
  ON public.project_versions
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  );

-- Admins pueden ver/gestionar todas las versiones
CREATE POLICY "Admins can manage all project_versions"
  ON public.project_versions
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_project_versions_set_updated_at
BEFORE UPDATE ON public.project_versions
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 5. Diseños (canvas / layouts / componentes)
------------------------------------------------------------

CREATE TABLE public.designs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id       uuid NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
  version_id       uuid NOT NULL REFERENCES public.project_versions (id) ON DELETE CASCADE,
  name             text NOT NULL,
  design_type      text NOT NULL DEFAULT 'page', -- page, component, layout, section...
  route_path       text,
  canvas_json      jsonb,                        -- estado completo del editor
  preview_image_url text,
  created_by       uuid NOT NULL REFERENCES auth.users (id),
  updated_by       uuid REFERENCES auth.users (id),
  created_at       timestamptz NOT NULL DEFAULT NOW(),
  updated_at       timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_designs_project_version ON public.designs (project_id, version_id);
CREATE INDEX idx_designs_route_path ON public.designs (route_path);

ALTER TABLE public.designs ENABLE ROW LEVEL SECURITY;

-- Usuarios pueden ver diseños de sus proyectos
CREATE POLICY "Users can view own designs"
  ON public.designs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  );

-- Usuarios pueden gestionar diseños de sus proyectos
CREATE POLICY "Users can manage own designs"
  ON public.designs
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.projects p
      WHERE p.id = project_id
        AND p.owner_id = auth.uid()
    )
  );

-- Admins pueden ver/gestionar todos los diseños
CREATE POLICY "Admins can manage all designs"
  ON public.designs
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_designs_set_updated_at
BEFORE UPDATE ON public.designs
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 6. Logs de IA (prompts, respuestas, tokens, coste)
------------------------------------------------------------

CREATE TABLE public.ai_logs (
  id            bigserial PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE SET NULL,
  project_id    uuid REFERENCES public.projects (id) ON DELETE SET NULL,
  design_id     uuid REFERENCES public.designs (id) ON DELETE SET NULL,
  provider      text NOT NULL,          -- openai, gemini, claude, etc
  model         text,
  prompt        text,
  response      text,
  temperature   numeric(4,2),
  tokens_input  integer,
  tokens_output integer,
  total_tokens  integer,
  cost_usd      numeric(12,6),
  created_at    timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ai_logs_user ON public.ai_logs (user_id, created_at DESC);
CREATE INDEX idx_ai_logs_project ON public.ai_logs (project_id, created_at DESC);

ALTER TABLE public.ai_logs ENABLE ROW LEVEL SECURITY;

-- Usuario ve solo sus logs
CREATE POLICY "Users can view own ai_logs"
  ON public.ai_logs
  FOR SELECT
  USING ( auth.uid() = user_id );

-- Admins pueden ver todos los logs
CREATE POLICY "Admins can view all ai_logs"
  ON public.ai_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

-- Inserciones normalmente las hará el backend/service-role, así que:
CREATE POLICY "Service role can insert ai_logs"
  ON public.ai_logs
  FOR INSERT
  WITH CHECK ( auth.role() = 'service_role' );

------------------------------------------------------------
-- 7. Tabla de tokens / uso agregado por día
------------------------------------------------------------

CREATE TABLE public.tokens (
  id            bigserial PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  usage_date    date NOT NULL,
  tokens_input  integer NOT NULL DEFAULT 0,
  tokens_output integer NOT NULL DEFAULT 0,
  total_tokens  integer NOT NULL DEFAULT 0,
  cost_usd      numeric(12,6) NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT NOW(),
  updated_at    timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT tokens_user_date_unique UNIQUE (user_id, usage_date)
);

CREATE INDEX idx_tokens_user_date ON public.tokens (user_id, usage_date DESC);

ALTER TABLE public.tokens ENABLE ROW LEVEL SECURITY;

-- Usuario ve solo sus totales
CREATE POLICY "Users can view own tokens"
  ON public.tokens
  FOR SELECT
  USING ( auth.uid() = user_id );

-- Solo service_role o admin actualizan/agregan
CREATE POLICY "Service role or admin manage tokens"
  ON public.tokens
  FOR ALL
  USING (
    auth.role() = 'service_role'
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    auth.role() = 'service_role'
    OR EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_tokens_set_updated_at
BEFORE UPDATE ON public.tokens
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 8. Exports (descargas de código, imágenes, etc.)
------------------------------------------------------------

CREATE TABLE public.exports (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  project_id     uuid NOT NULL REFERENCES public.projects (id) ON DELETE CASCADE,
  version_id     uuid REFERENCES public.project_versions (id) ON DELETE SET NULL,
  export_type    text NOT NULL,       -- code_zip, image, pdf, figma_json...
  storage_path   text NOT NULL,       -- ruta en bucket de Supabase
  status         text NOT NULL DEFAULT 'pending', -- pending, processing, ready, error
  error_message  text,
  created_at     timestamptz NOT NULL DEFAULT NOW(),
  completed_at   timestamptz
);

CREATE INDEX idx_exports_user ON public.exports (user_id, created_at DESC);
CREATE INDEX idx_exports_project ON public.exports (project_id, created_at DESC);

ALTER TABLE public.exports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own exports"
  ON public.exports
  FOR SELECT
  USING ( auth.uid() = user_id );

CREATE POLICY "Users can insert own exports"
  ON public.exports
  FOR INSERT
  WITH CHECK ( auth.uid() = user_id );

CREATE POLICY "Users can delete own exports"
  ON public.exports
  FOR DELETE
  USING ( auth.uid() = user_id );

CREATE POLICY "Admins can manage all exports"
  ON public.exports
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

------------------------------------------------------------
-- 9. Templates (plantillas base reutilizables)
------------------------------------------------------------

CREATE TABLE public.templates (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by       uuid NOT NULL REFERENCES auth.users (id) ON DELETE SET NULL,
  name             text NOT NULL,
  description      text,
  category         text,          -- landing, dashboard, ecommerce...
  tags             text[],
  base_project_id  uuid REFERENCES public.projects (id) ON DELETE SET NULL,
  base_design_id   uuid REFERENCES public.designs (id) ON DELETE SET NULL,
  is_public        boolean NOT NULL DEFAULT FALSE,
  created_at       timestamptz NOT NULL DEFAULT NOW(),
  updated_at       timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_templates_public ON public.templates (is_public);
CREATE INDEX idx_templates_category ON public.templates (category);

ALTER TABLE public.templates ENABLE ROW LEVEL SECURITY;

-- Todo usuario autenticado puede ver templates públicos
CREATE POLICY "Anyone can view public templates"
  ON public.templates
  FOR SELECT
  USING ( is_public = TRUE );

-- Creador ve sus propias plantillas aunque no sean públicas
CREATE POLICY "Users can view own templates"
  ON public.templates
  FOR SELECT
  USING ( auth.uid() = created_by );

-- Creador gestiona sus propias plantillas
CREATE POLICY "Users can manage own templates"
  ON public.templates
  FOR ALL
  USING ( auth.uid() = created_by )
  WITH CHECK ( auth.uid() = created_by );

-- Admin puede gestionar todas
CREATE POLICY "Admins can manage all templates"
  ON public.templates
  FOR ALL
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_templates_set_updated_at
BEFORE UPDATE ON public.templates
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- 10. user_apis (claves de API externas por usuario)
------------------------------------------------------------

CREATE TABLE public.user_apis (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  provider           text NOT NULL,   -- openai, google, anthropic...
  label              text,
  api_key_encrypted  text NOT NULL,   -- nunca guardar en texto plano
  is_active          boolean NOT NULL DEFAULT TRUE,
  created_at         timestamptz NOT NULL DEFAULT NOW(),
  updated_at         timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_apis_user_provider
  ON public.user_apis (user_id, provider);

ALTER TABLE public.user_apis ENABLE ROW LEVEL SECURITY;

-- Usuario ve solo sus claves
CREATE POLICY "Users can view own user_apis"
  ON public.user_apis
  FOR SELECT
  USING ( auth.uid() = user_id );

-- Usuario gestiona solo sus claves
CREATE POLICY "Users can manage own user_apis"
  ON public.user_apis
  FOR ALL
  USING ( auth.uid() = user_id )
  WITH CHECK ( auth.uid() = user_id );

-- Opcionalmente, admins pueden ver todas (por si hay soporte)
CREATE POLICY "Admins can view all user_apis"
  ON public.user_apis
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.users u
      WHERE u.id = auth.uid()
        AND u.is_admin = TRUE
    )
  );

CREATE TRIGGER trg_user_apis_set_updated_at
BEFORE UPDATE ON public.user_apis
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();

------------------------------------------------------------
-- FIN
------------------------------------------------------------

COMMIT;
