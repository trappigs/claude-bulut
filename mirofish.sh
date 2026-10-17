#!/usr/bin/env bash
# MiroFish başlat/durdur/durum betiği (bulut oturumu için, Docker'sız).
# Kullanım:  ./mirofish.sh start | stop | restart | status | logs
# API anahtarları betikte yok; $APP/.env dosyasından okunur (git'e girmez).
set -euo pipefail

APP="${MIROFISH_DIR:-/home/user/666ghj/mirofish}"
RUN="${MIROFISH_RUN_DIR:-/tmp/mirofish-run}"
mkdir -p "$RUN"

up() { curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null; }

start() {
  [ -d "$APP/backend/.venv" ] && [ -d "$APP/frontend/node_modules" ] \
    || { echo "Kurulum eksik: $APP içinde 'npm run setup:all' çalıştırın."; exit 1; }
  if [ ! -f "$APP/.env" ] || grep -qE 'your_api_key_here|your_zep_api_key_here' "$APP/.env"; then
    echo "HATA: $APP/.env yok ya da LLM_API_KEY / ZEP_API_KEY hâlâ örnek değerde."
    echo "      cp $APP/.env.example $APP/.env  ve anahtarları doldurun (sohbete yapıştırmayın)."
    exit 1
  fi
  stop >/dev/null 2>&1 || true
  cd "$APP/backend"
  nohup uv run python run.py >"$RUN/backend.log" 2>&1 & echo $! >"$RUN/backend.pid"
  cd "$APP/frontend"
  # '/' => tarayıcı API'yi aynı origin'den (Vite /api proxy) çağırır; kaynak koda dokunulmaz.
  VITE_API_BASE_URL=/ nohup npx vite --host --no-open >"$RUN/frontend.log" 2>&1 & echo $! >"$RUN/frontend.pid"
  for _ in $(seq 1 60); do
    up http://127.0.0.1:5001/health && up http://127.0.0.1:3000/ && break; sleep 1
  done
  status
}

stop() {
  for n in backend frontend; do
    if [ -f "$RUN/$n.pid" ]; then
      pid=$(cat "$RUN/$n.pid"); pkill -TERM -P "$pid" 2>/dev/null || true; kill "$pid" 2>/dev/null || true
      rm -f "$RUN/$n.pid"
    fi
  done
  pkill -f "vite --host" 2>/dev/null || true
  pkill -f "python run.py" 2>/dev/null || true
}

status() {
  up http://127.0.0.1:5001/health && echo "backend : OK  (http://127.0.0.1:5001)" || echo "backend : KAPALI (log: $RUN/backend.log)"
  up http://127.0.0.1:3000/       && echo "frontend: OK  (http://127.0.0.1:3000)" || echo "frontend: KAPALI (log: $RUN/frontend.log)"
  curl -sI --max-time 3 http://127.0.0.1:3000/api/ 2>/dev/null | grep -qi '^server: werkzeug' \
    && echo "proxy   : OK  (3000/api -> 5001)" || true
}

case "${1:-status}" in
  start) start ;; stop) stop ;; restart) stop; start ;; status) status ;;
  logs) tail -n 40 "$RUN"/backend.log "$RUN"/frontend.log ;;
  *) echo "kullanım: $0 start|stop|restart|status|logs"; exit 2 ;;
esac
