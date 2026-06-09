-- CDN CHAT Additional RPCs for Flutter app integration

-- Get all groups (for channel discovery)
CREATE OR REPLACE FUNCTION public.get_all_groups(p_user_id UUID DEFAULT NULL)
RETURNS TABLE(
  id UUID,
  group_name TEXT,
  description TEXT,
  created_at TIMESTAMPTZ,
  is_sponsored BOOLEAN,
  sponsor_name TEXT,
  member_count BIGINT
)
LANGUAGE sql
AS $$
  SELECT 
    g.id,
    g.group_name,
    g.description,
    g.created_at,
    COALESCE(g.is_sponsored, false) AS is_sponsored,
    g.sponsor_name,
    COALESCE(gm.member_count, 0) AS member_count
  FROM public.groups g
  LEFT JOIN (
    SELECT group_id, COUNT(*)::BIGINT AS member_count
    FROM public.group_members
    GROUP BY group_id
  ) gm ON gm.group_id = g.id
  ORDER BY g.created_at DESC;
$$;
GRANT EXECUTE ON FUNCTION public.get_all_groups TO authenticated;

-- Increment referral count
CREATE OR REPLACE FUNCTION public.increment_referral_count(p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.profiles 
  SET referral_count = COALESCE(referral_count, 0) + 1 
  WHERE id = p_user_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.increment_referral_count TO authenticated;