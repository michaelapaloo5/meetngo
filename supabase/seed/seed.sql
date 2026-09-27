insert into promos (code, percent_off, max_discount_ghs, active)
values ('RIDE30', 30.00, 40.00, true)
on conflict (code) do nothing;
