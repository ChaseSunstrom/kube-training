#!/bin/sh
# A deliberately tiny JSON "API" for the capstone, so the course needs no
# custom image. It runs in the postgres:16-alpine image (for psql) behind
#   nc -lk -p 8080 -e /app/api.sh
# which starts this script once per TCP connection with the socket on
# stdin/stdout. In a real project this would be your own application image.
#
# Endpoints:
#   GET /healthz      200 if the process is up (used by the probes)
#   GET /api/health   DB connectivity: {"db":"up"} or 503 {"db":"down"}
#   GET /api/items    the "items" table as a JSON array
#   anything else     404
# Connection settings come from the standard libpq env vars PGHOST, PGUSER,
# PGPASSWORD, PGDATABASE (set in the Deployment from the Secret).

respond() {   # $1 = status line, $2 = JSON body
  printf 'HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
    "$1" "${#2}" "$2"
}

read -r method path _proto || exit 0
path=$(printf '%s' "$path" | tr -d '\r')
# Consume the request headers up to the empty line.
while read -r header; do
  [ -z "$(printf '%s' "$header" | tr -d '\r')" ] && break
done

echo "$(date -Iseconds) $method $path" >&2

if [ "$method" != "GET" ]; then
  respond "405 Method Not Allowed" '{"error":"only GET is supported"}'
  exit 0
fi

case "$path" in
  /healthz)
    respond "200 OK" '{"status":"ok"}'
    ;;
  /api/health)
    if pg_isready -q -t 2; then
      respond "200 OK" '{"db":"up"}'
    else
      respond "503 Service Unavailable" '{"db":"down"}'
    fi
    ;;
  /api/items)
    if body=$(psql -X -q -t -A -v ON_ERROR_STOP=1 \
        -c "SELECT coalesce(json_agg(i ORDER BY i.id), '[]'::json) FROM (SELECT id, name, price FROM items) i" 2>/tmp/psql.err); then
      respond "200 OK" "$body"
    else
      echo "psql failed: $(cat /tmp/psql.err)" >&2
      respond "503 Service Unavailable" '{"error":"database unavailable"}'
    fi
    ;;
  *)
    respond "404 Not Found" '{"error":"not found"}'
    ;;
esac
