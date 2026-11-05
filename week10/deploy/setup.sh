#!/usr/bin/env bash
# =====================================================================
# 3-Tier 로그인 서비스 자동 설치 스크립트
#   Web Tier : Nginx            0.0.0.0:80      ← 호스트 OS 브라우저가 접속
#   WAS Tier : Gunicorn + Flask 127.0.0.1:8000  ← Nginx 만 접근
#   DB Tier  : MariaDB          127.0.0.1:3306  ← WAS 만 접근
#
# 사용법 : sudo bash deploy/setup.sh
# 옵션   : DEMO_USER / DEMO_NAME / DEMO_PASSWORD   데모 계정 (기본 demo / Demo1234!)
#          MYSQL_ROOT_PASSWORD                     MariaDB root 비밀번호를 따로 설정한 경우
# 지원   : Ubuntu 22.04 / 24.04, Rocky Linux 9 (RHEL 계열)
# 여러 번 실행해도 안전하다 (기존 비밀번호·데이터 유지).
# =====================================================================
set -euo pipefail

APP_USER=loginapp
APP_HOME=/opt/loginapp
WEB_ROOT=/var/www/loginapp
CONF_DIR=/etc/loginapp
ENV_FILE=$CONF_DIR/loginapp.env
DB_NAME=loginapp
DB_USER=loginapp
DEMO_USER=${DEMO_USER:-demo}
DEMO_NAME=${DEMO_NAME:-데모사용자}
DEMO_PASSWORD=${DEMO_PASSWORD:-Demo1234!}
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

step() { printf '\n\033[1;36m==> [%s] %s\033[0m\n' "$1" "$2"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[경고] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[오류] %b\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 권한이 필요합니다:  sudo bash $0"
[ -f "$SRC_DIR/app/app.py" ] || die "소스 디렉터리를 찾을 수 없습니다: $SRC_DIR"

# ------------------------------------------------------------------ OS 판별
# shellcheck disable=SC1091
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
  *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) OS_FAMILY=rhel ;;
  *) die "지원하지 않는 배포판입니다: ${PRETTY_NAME:-unknown}" ;;
esac
if [ -d /run/systemd/system ]; then HAS_SYSTEMD=1; else HAS_SYSTEMD=0; fi
info "OS: ${PRETTY_NAME:-$ID} ($OS_FAMILY), systemd: $([ $HAS_SYSTEMD -eq 1 ] && echo yes || echo no)"

# 서비스 시작/재시작 : systemd 가 없는 환경(컨테이너 등)에서는 service 명령으로 대체
svc_restart() {
  if [ "$HAS_SYSTEMD" -eq 1 ]; then
    systemctl enable -q "$1"
    systemctl restart "$1"
  else
    service "$1" restart
  fi
}

wait_for() {  # wait_for <설명> <명령...> : 최대 30초 동안 성공할 때까지 재시도
  local desc=$1; shift
  for _ in $(seq 1 30); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "$desc 이(가) 30초 안에 응답하지 않습니다."
}

# ------------------------------------------------------------------ 1. 패키지
step 1/7 "패키지 설치 (nginx, mariadb-server, python3-venv)"
if [ "$OS_FAMILY" = debian ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q nginx mariadb-server python3 python3-venv python3-pip curl
  NGINX_SITE=/etc/nginx/sites-available/loginapp.conf
  MARIADB_CNF=/etc/mysql/mariadb.conf.d/60-loginapp.cnf
else
  PKGS="nginx mariadb-server python3 python3-pip"
  command -v curl >/dev/null || PKGS="$PKGS curl"
  # shellcheck disable=SC2086
  dnf install -y -q $PKGS
  NGINX_SITE=/etc/nginx/conf.d/loginapp.conf
  MARIADB_CNF=/etc/my.cnf.d/zz-loginapp.cnf
fi
PYTHON=$(command -v /usr/bin/python3 || command -v python3)
"$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 8))' \
  || die "Python 3.8 이상이 필요합니다 (현재: $("$PYTHON" -V 2>&1))"
info "Python: $("$PYTHON" -V 2>&1)"

# 서비스 전용 OS 계정 (로그인 불가) : WAS 는 root 가 아닌 이 계정으로 실행
if ! id "$APP_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_HOME" --shell "$(command -v nologin || echo /usr/sbin/nologin)" "$APP_USER"
  info "OS 계정 생성: $APP_USER"
fi

# ------------------------------------------------------------------ 2. 비밀값
step 2/7 "설정 파일 생성 ($ENV_FILE)"
mkdir -p "$CONF_DIR"
if [ -f "$ENV_FILE" ]; then
  info "기존 설정 파일을 그대로 사용합니다 (비밀번호 유지)"
else
  gen() { "$PYTHON" -c "import secrets; print(secrets.token_urlsafe($1))"; }
  cat > "$ENV_FILE" <<EOF
# loginapp 설정 (deploy/setup.sh 가 자동 생성) - 외부에 공개하지 말 것
SECRET_KEY=$(gen 48)
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$(gen 24)
EOF
  info "SECRET_KEY, DB_PASSWORD 를 무작위로 생성했습니다"
fi
chown root:"$APP_USER" "$ENV_FILE"
chmod 0640 "$ENV_FILE"
DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)

# ------------------------------------------------------------------ 3. DB Tier
step 3/7 "DB Tier: MariaDB 설정 (127.0.0.1 전용) + 스키마/계정 생성"
install -m 0644 "$SRC_DIR/db/60-loginapp.cnf" "$MARIADB_CNF"
svc_restart mariadb
wait_for "MariaDB" mysqladmin ping

MYSQL=(mysql --user=root)
if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then MYSQL+=(--password="$MYSQL_ROOT_PASSWORD"); fi
"${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1 \
  || die "MariaDB root 로 접속할 수 없습니다.\n    root 비밀번호를 설정했다면:  sudo MYSQL_ROOT_PASSWORD='비밀번호' bash $0"

"${MYSQL[@]}" < "$SRC_DIR/db/schema.sql"
# WAS 전용 DB 계정 : 필요한 권한(SELECT/INSERT/UPDATE)만 부여 (최소 권한 원칙)
# 'localhost'(소켓) 와 '127.0.0.1'(TCP) 은 MariaDB 에서 다른 호스트로 취급하므로 둘 다 만든다.
"${MYSQL[@]}" <<SQL
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT SELECT, INSERT, UPDATE ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
GRANT SELECT, INSERT, UPDATE ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
info "DB '$DB_NAME', 테이블(users, login_logs), 계정 '$DB_USER' 준비 완료"

# ------------------------------------------------------------------ 4. WAS Tier
step 4/7 "WAS Tier: Flask 앱 배포 + Python 가상환경 + Gunicorn 서비스"
mkdir -p "$APP_HOME"
rm -rf "$APP_HOME/app"
cp -r "$SRC_DIR/app" "$APP_HOME/app"
find "$APP_HOME/app" -name '__pycache__' -prune -exec rm -rf {} +
chown -R root:root "$APP_HOME/app"          # 앱 코드는 root 소유 → 서비스 계정이 수정 불가
chmod -R u=rwX,go=rX "$APP_HOME/app"
if [ ! -x "$APP_HOME/venv/bin/python" ]; then
  "$PYTHON" -m venv "$APP_HOME/venv"
fi
"$APP_HOME/venv/bin/pip" install -q --upgrade pip || warn "pip 업그레이드 실패 (계속 진행)"
"$APP_HOME/venv/bin/pip" install -q -r "$APP_HOME/app/requirements.txt"
info "설치된 패키지: $("$APP_HOME/venv/bin/pip" freeze | grep -iE '^(flask|gunicorn|pymysql|werkzeug)=' | tr '\n' ' ')"

if [ "$HAS_SYSTEMD" -eq 1 ]; then
  install -m 0644 "$SRC_DIR/deploy/loginapp.service" /etc/systemd/system/loginapp.service
  systemctl daemon-reload
  svc_restart loginapp
else
  warn "systemd 가 없어 Gunicorn 을 백그라운드로 직접 실행합니다 (재부팅 시 자동 시작 안 됨)"
  PIDFILE=/run/loginapp/gunicorn.pid
  mkdir -p /run/loginapp /var/log/loginapp
  chown "$APP_USER:$APP_USER" /run/loginapp /var/log/loginapp
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    kill "$(cat "$PIDFILE")"
    sleep 2
  fi
  runuser -u "$APP_USER" -- "$APP_HOME/venv/bin/gunicorn" \
    --config "$APP_HOME/app/gunicorn.conf.py" --chdir "$APP_HOME/app" \
    --daemon --pid "$PIDFILE" \
    --access-logfile /var/log/loginapp/access.log --error-logfile /var/log/loginapp/error.log \
    app:app
fi
wait_for "WAS(Gunicorn 127.0.0.1:8000)" curl -fsS http://127.0.0.1:8000/health
info "Gunicorn 이 127.0.0.1:8000 에서 응답합니다"

# ------------------------------------------------------------------ 5. Web Tier
step 5/7 "Web Tier: Nginx 정적 파일 + 리버스 프록시 설정"
mkdir -p "$WEB_ROOT"
rm -rf "$WEB_ROOT/static"
cp -r "$SRC_DIR/web/static" "$WEB_ROOT/static"
install -m 0644 "$SRC_DIR/web/50x.html" "$WEB_ROOT/50x.html"
chmod -R a+rX "$WEB_ROOT"
install -m 0644 "$SRC_DIR/web/nginx-loginapp.conf" "$NGINX_SITE"
if [ "$OS_FAMILY" = debian ]; then
  ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/loginapp.conf
  rm -f /etc/nginx/sites-enabled/default     # 기본 환영 페이지 비활성화
else
  # nginx.conf 의 기본 server 블록에 default_server 가 있으면 떼어내 우리 설정이 기본 서버가 되게 한다.
  if grep -qE 'listen[[:space:]]+(\[::\]:)?80[[:space:]]+default_server' /etc/nginx/nginx.conf; then
    [ -f /etc/nginx/nginx.conf.orig ] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
    sed -i -E 's/(listen[[:space:]]+(\[::\]:)?80)[[:space:]]+default_server/\1/' /etc/nginx/nginx.conf
    info "nginx.conf 기본 server 블록의 default_server 제거 (원본: nginx.conf.orig)"
  fi
fi
nginx -t 2>&1 | sed 's/^/    /'
if command -v ss >/dev/null; then
  OTHER=$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -v '"nginx"' || true)
  [ -z "$OTHER" ] || die "80번 포트를 다른 프로그램이 사용 중입니다 (예: apache2/httpd).\n$OTHER\n    중지 후 다시 실행하세요:  sudo systemctl disable --now apache2   (Rocky: httpd)"
fi
svc_restart nginx
wait_for "Nginx(:80)" curl -fsS http://127.0.0.1/health

# ------------------------------------------------------------------ 6. 방화벽
step 6/7 "방화벽 / SELinux"
if command -v ufw >/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null
  info "ufw: 80/tcp 허용"
else
  info "ufw 비활성 또는 미설치 → 변경 없음"
fi
if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd -q --permanent --add-service=http
  firewall-cmd -q --reload
  info "firewalld: http(80) 허용"
fi
if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
  setsebool -P httpd_can_network_connect 1   # Nginx → 127.0.0.1:8000 프록시 연결 허용
  restorecon -R "$WEB_ROOT" || true
  info "SELinux: httpd_can_network_connect = on"
fi

# ------------------------------------------------------------------ 7. 데모 계정
step 7/7 "데모 계정 생성 및 동작 확인"
(cd "$APP_HOME/app" && runuser -u "$APP_USER" -- "$APP_HOME/venv/bin/flask" --app app \
   create-user "$DEMO_USER" "$DEMO_NAME" --password "$DEMO_PASSWORD") | sed 's/^/    /'
info "헬스체크: $(curl -fsS http://127.0.0.1/health)"

IPS=$(hostname -I 2>/dev/null || ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
echo
printf '\033[1;32m설치 완료!\033[0m 호스트 OS 의 웹 브라우저에서 접속하세요.\n'
for ip in $IPS; do
  case $ip in *:*) continue ;; esac   # IPv6 생략
  echo "  - http://$ip/        (VMware NAT / VirtualBox 호스트 전용·브리지 어댑터)"
done
echo "  - http://localhost:8080/  (VirtualBox NAT + 포트 포워딩: 호스트 8080 → 게스트 80)"
echo "  데모 계정: $DEMO_USER / $DEMO_PASSWORD   (회원가입 화면에서 새 계정도 만들 수 있음)"
echo "  테스트  : bash $SRC_DIR/tests/e2e_test.sh"
