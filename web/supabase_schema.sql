-- ============================================================
-- Locky — Esquema Completo y Unificado de Base de Datos Supabase
-- ============================================================
-- Copiar y ejecutar este archivo en el SQL Editor de Supabase:
-- Dashboard → SQL Editor → New Query → Pegar todo y Ejecutar (RUN)
-- ============================================================

-- ============================
-- 1. EXTENSIONES
-- ============================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================
-- 2. TABLA: profiles
-- ============================
-- Extiende auth.users de Supabase Auth
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================
-- 3. TABLA: folders
-- ============================
-- Sistema jerárquico de carpetas
CREATE TABLE IF NOT EXISTS public.folders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES public.folders(id) ON DELETE SET NULL,
    name_encrypted TEXT NOT NULL,
    icon TEXT NOT NULL DEFAULT 'folder',
    color TEXT NOT NULL DEFAULT '#6366F1',
    sort_order INT NOT NULL DEFAULT 0,
    iv TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================
-- 4. TABLA: vault_items
-- ============================
-- Credenciales y elementos sensibles encriptados
CREATE TABLE IF NOT EXISTS public.vault_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    folder_id UUID REFERENCES public.folders(id) ON DELETE SET NULL,
    item_type TEXT NOT NULL DEFAULT 'password'
        CHECK (item_type IN ('password', 'card', 'note', 'identity', 'api_key', 'pattern', 'custom')),
    title_encrypted TEXT NOT NULL,
    data_encrypted TEXT NOT NULL,
    iv TEXT NOT NULL,
    is_favorite BOOLEAN NOT NULL DEFAULT false,
    sort_order INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================
-- 5. TABLA: item_links
-- ============================
-- Relaciones y enlaces entre credenciales
CREATE TABLE IF NOT EXISTS public.item_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_item_id UUID NOT NULL REFERENCES public.vault_items(id) ON DELETE CASCADE,
    target_item_id UUID NOT NULL REFERENCES public.vault_items(id) ON DELETE CASCADE,
    link_type TEXT NOT NULL DEFAULT 'related'
        CHECK (link_type IN ('related', 'derived', 'parent')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (source_item_id, target_item_id)
);

-- ============================
-- 6. TABLA: item_audit_logs
-- ============================
-- Registro de auditoría e historial de cambios
CREATE TABLE IF NOT EXISTS public.item_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    item_id UUID,
    item_title TEXT NOT NULL,
    action TEXT NOT NULL, -- 'CREADO', 'EDITADO', 'ELIMINADO'
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    details JSONB
);

-- ============================
-- 7. ÍNDICES DE RENDIMIENTO
-- ============================
CREATE INDEX IF NOT EXISTS idx_folders_user_id ON public.folders(user_id);
CREATE INDEX IF NOT EXISTS idx_folders_parent_id ON public.folders(parent_id);
CREATE INDEX IF NOT EXISTS idx_vault_items_user_id ON public.vault_items(user_id);
CREATE INDEX IF NOT EXISTS idx_vault_items_folder_id ON public.vault_items(folder_id);
CREATE INDEX IF NOT EXISTS idx_vault_items_type ON public.vault_items(item_type);
CREATE INDEX IF NOT EXISTS idx_vault_items_favorite ON public.vault_items(is_favorite) WHERE is_favorite = true;
CREATE INDEX IF NOT EXISTS idx_item_links_source ON public.item_links(source_item_id);
CREATE INDEX IF NOT EXISTS idx_item_links_target ON public.item_links(target_item_id);
CREATE INDEX IF NOT EXISTS idx_item_audit_logs_user ON public.item_audit_logs(user_id);

-- ============================
-- 8. FUNCIONES AUXILIARES
-- ============================

-- Función para actualizar updated_at
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Función para crear perfil automáticamente al registrar usuario
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, display_name)
    VALUES (
        NEW.id,
        COALESCE(NEW.raw_user_meta_data->>'display_name', split_part(NEW.email, '@', 1))
    )
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================
-- 9. TRIGGERS AUTOMÁTICOS
-- ============================

-- Auto-crear perfil para usuarios nuevos
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Migrar perfiles de usuarios existentes en auth.users
INSERT INTO public.profiles (id, display_name)
SELECT id, COALESCE(raw_user_meta_data->>'display_name', split_part(email, '@', 1))
FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- Auto-actualizar updated_at
DROP TRIGGER IF EXISTS on_profiles_updated ON public.profiles;
CREATE TRIGGER on_profiles_updated
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS on_folders_updated ON public.folders;
CREATE TRIGGER on_folders_updated
    BEFORE UPDATE ON public.folders
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

DROP TRIGGER IF EXISTS on_vault_items_updated ON public.vault_items;
CREATE TRIGGER on_vault_items_updated
    BEFORE UPDATE ON public.vault_items
    FOR EACH ROW EXECUTE FUNCTION public.handle_updated_at();

-- ============================
-- 10. ROW LEVEL SECURITY (RLS)
-- ============================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.folders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_audit_logs ENABLE ROW LEVEL SECURITY;

-- POLÍTICAS: PROFILES
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can insert own profile" ON public.profiles;
CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- POLÍTICAS: FOLDERS
DROP POLICY IF EXISTS "Users can view own folders" ON public.folders;
CREATE POLICY "Users can view own folders" ON public.folders FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create own folders" ON public.folders;
CREATE POLICY "Users can create own folders" ON public.folders FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own folders" ON public.folders;
CREATE POLICY "Users can update own folders" ON public.folders FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own folders" ON public.folders;
CREATE POLICY "Users can delete own folders" ON public.folders FOR DELETE USING (auth.uid() = user_id);

-- POLÍTICAS: VAULT_ITEMS
DROP POLICY IF EXISTS "Users can view own items" ON public.vault_items;
CREATE POLICY "Users can view own items" ON public.vault_items FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create own items" ON public.vault_items;
CREATE POLICY "Users can create own items" ON public.vault_items FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own items" ON public.vault_items;
CREATE POLICY "Users can update own items" ON public.vault_items FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own items" ON public.vault_items;
CREATE POLICY "Users can delete own items" ON public.vault_items FOR DELETE USING (auth.uid() = user_id);

-- POLÍTICAS: ITEM_LINKS
DROP POLICY IF EXISTS "Users can view own links" ON public.item_links;
CREATE POLICY "Users can view own links" ON public.item_links FOR SELECT
    USING (EXISTS (SELECT 1 FROM public.vault_items WHERE id = source_item_id AND user_id = auth.uid()));

DROP POLICY IF EXISTS "Users can create own links" ON public.item_links;
CREATE POLICY "Users can create own links" ON public.item_links FOR INSERT
    WITH CHECK (
        EXISTS (SELECT 1 FROM public.vault_items WHERE id = source_item_id AND user_id = auth.uid()) AND
        EXISTS (SELECT 1 FROM public.vault_items WHERE id = target_item_id AND user_id = auth.uid())
    );

DROP POLICY IF EXISTS "Users can delete own links" ON public.item_links;
CREATE POLICY "Users can delete own links" ON public.item_links FOR DELETE
    USING (EXISTS (SELECT 1 FROM public.vault_items WHERE id = source_item_id AND user_id = auth.uid()));

-- POLÍTICAS: ITEM_AUDIT_LOGS
DROP POLICY IF EXISTS "Users can view own audit logs" ON public.item_audit_logs;
CREATE POLICY "Users can view own audit logs" ON public.item_audit_logs FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own audit logs" ON public.item_audit_logs;
CREATE POLICY "Users can insert own audit logs" ON public.item_audit_logs FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own audit logs" ON public.item_audit_logs;
CREATE POLICY "Users can delete own audit logs" ON public.item_audit_logs FOR DELETE USING (auth.uid() = user_id);
