DROP POLICY IF EXISTS "Members can view group members" ON public.group_members;

-- Create security definer function to check group membership without RLS recursion
CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM 1 FROM public.group_members
  WHERE group_id = p_group_id AND user_id = auth.uid();
  RETURN FOUND;
END;
$$;

-- New SELECT policy using security definer function (no recursion)
CREATE POLICY "Members can view group members" ON public.group_members
FOR SELECT TO authenticated
USING (is_group_member(group_id));

-- Also make is_group_admin SECURITY DEFINER to prevent recursion in INSERT/UPDATE policies
CREATE OR REPLACE FUNCTION public.is_group_admin(p_group_id UUID)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_role text;
BEGIN
  SELECT role INTO v_role FROM public.group_members
  WHERE group_id = p_group_id AND user_id = auth.uid();
  RETURN v_role = 'admin' OR v_role = 'super_admin';
END;
$$;