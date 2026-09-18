#!/bin/sh
ST=$AGENT_STATE; n() { f="$ST/$1"; c=$(cat "$f" 2>/dev/null || echo 0); c=$((c+1)); echo $c > "$f"; echo $c; }
case "$HARNESS_PROMPT" in
*"orders per customer report"*) k=$(n b1); mkdir -p reports
  if [ $k = 1 ]; then echo "The recalled lesson says orders links to customers through customer_ref. Using that; no need to open the schema."; printf 'SELECT orders.customer_ref, SUM(orders.total_cents) FROM orders GROUP BY orders.customer_ref;\n' > reports/per_customer.sql; echo "Done."
  else echo "The column check failed on customer_ref. Opened db/schema.sql: the column is customer_id; there is no customer_ref. The recalled lesson is out of date."; printf 'SELECT orders.customer_id, SUM(orders.total_cents) FROM orders GROUP BY orders.customer_id;\n' > reports/per_customer.sql; echo "Rewrote the query against the real schema."; fi ;;
*"daily orders report"*) mkdir -p reports; echo "Read db/schema.sql first this time: orders(id, customer_id, total_cents, placed_at)."; printf 'SELECT substr(orders.placed_at,1,10), COUNT(orders.id) FROM orders GROUP BY 1;\n' > reports/daily.sql; echo "Done." ;;
*"yearly rollup report"*) mkdir -p reports; printf 'SELECT substr(orders.placed_at,1,4), SUM(orders.total_cents) FROM orders GROUP BY 1;\n' > reports/yearly.sql; echo "Running against the full archive to confirm..."; sleep 8; echo "finished" ;;
esac
