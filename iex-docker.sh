docker compose exec mosaic iex --sname cli_iex_$(shuf -i 1000-9999 -n 1)@$(hostname) --cookie supersecretcookie 
     --remsh mosaic_app@mosaic
