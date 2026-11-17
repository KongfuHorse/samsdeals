-- 价格规则支持按苹果型号区分（category = apple 时填 apple_model）
alter table price_rules add column if not exists apple_model text;

create or replace function admin_save_rule(p_token text, p_rule jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint := (p_rule->>'id')::bigint;
        v_apple text := case when p_rule->>'category' = 'apple' then nullif(p_rule->>'apple_model', '') end;
        v_gpu text := case when p_rule->>'category' = 'apple' then null else nullif(p_rule->>'gpu', '') end;
begin
  perform _admin_check(p_token);
  if v_id is null then
    insert into price_rules (category, gpu, apple_model, ram_gb, capacity_tb, price_mode, max_price, resale_price, note, active)
    values (p_rule->>'category', v_gpu, v_apple, nullif(p_rule->>'ram_gb','')::int,
            nullif(p_rule->>'capacity_tb','')::numeric, coalesce(nullif(p_rule->>'price_mode',''),'total'),
            (p_rule->>'max_price')::numeric, nullif(p_rule->>'resale_price','')::numeric,
            p_rule->>'note', coalesce((p_rule->>'active')::boolean, true))
    returning id into v_id;
  else
    update price_rules set category = p_rule->>'category', gpu = v_gpu, apple_model = v_apple,
      ram_gb = nullif(p_rule->>'ram_gb','')::int, capacity_tb = nullif(p_rule->>'capacity_tb','')::numeric,
      price_mode = coalesce(nullif(p_rule->>'price_mode',''),'total'), max_price = (p_rule->>'max_price')::numeric,
      resale_price = nullif(p_rule->>'resale_price','')::numeric, note = p_rule->>'note',
      active = coalesce((p_rule->>'active')::boolean, true)
    where id = v_id;
  end if;
  return v_id;
end $$;
notify pgrst, 'reload schema';
