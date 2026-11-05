#!/usr/bin/env bash
# =====================================================================
# 3-Tier 로그인 서비스 E2E(종단 간) 테스트 : curl 로 브라우저 동작을 흉내 낸다.
#
# 사용법 : bash tests/e2e_test.sh [BASE_URL]
#   VM 안에서            bash tests/e2e_test.sh                       (기본 http://127.0.0.1)
#   VM 안에서(root)      sudo bash tests/e2e_test.sh                  (포트 바인딩·DB 저장 방식까지 검사)
#   호스트 OS 에서       bash tests/e2e_test.sh http://192.168.56.101
#   VirtualBox NAT 포워딩 bash tests/e2e_test.sh http://localhost:8080
# =====================================================================
set -uo pipefail

BASE=${1:-http://127.0.0.1}
BASE=${BASE%/}
DEMO_USER=${DEMO_USER:-demo}
DEMO_PASSWORD=${DEMO_PASSWORD:-Demo1234!}
NEW_USER="e2e_$(date +%H%M%S)_$RANDOM"
NEW_USER=${NEW_USER:0:20}
NEW_PASSWORD="E2eTest$RANDOM"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0; SKIP=0; STATUS=000; LOCATION=""

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n       (HTTP %s %s)\n' "$1" "$STATUS" "$LOCATION"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
t()    { if eval "$2"; then ok "$1"; else bad "$1"; fi; }   # t "설명" "조건식"

new_session() { : > "$WORK/jar"; }
# _curl PATH [curl 옵션...] → STATUS, LOCATION, $WORK/body, $WORK/headers
_curl() {
  local path=$1; shift
  STATUS=$(curl -sS -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}' \
                -b "$WORK/jar" -c "$WORK/jar" "$@" "$BASE$path" 2>"$WORK/err") || STATUS=000
  LOCATION=$(grep -i '^location:' "$WORK/headers" 2>/dev/null | tail -1 | tr -d '\r' | cut -d' ' -f2-)
}
get()  { _curl "$1"; }
post() {  # post PATH key=value ...  (값은 URL 인코딩되어 전송)
  local path=$1 kv args=(); shift
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  _curl "$path" "${args[@]}"
}
csrf()       { grep -o 'name="csrf_token" value="[^"]*"' "$WORK/body" | head -1 | sed 's/.*value="//; s/"$//'; }
body_has()   { grep -q -- "$1" "$WORK/body"; }
header_has() { grep -qi -- "$1" "$WORK/headers"; }

echo "▶ 테스트 대상: $BASE"
new_session

echo "[1] Web Tier (Nginx)"
get /health
if [ "$STATUS" = 000 ]; then
  echo "  서버에 연결할 수 없습니다: $(cat "$WORK/err")"
  echo "  → VM IP/포트, 방화벽, 포트 포워딩 설정을 확인하세요."
  exit 1
fi
t "GET /health → 200" '[ "$STATUS" = 200 ]'
t "헬스체크: WAS·DB 정상 (db=ok)" 'grep -Eq "\"db\": ?\"ok\"" "$WORK/body"'
t "요청이 Nginx 를 거쳐 WAS 로 전달됨 (web=nginx/…)" 'body_has "nginx/"'
get /static/style.css
t "정적 파일 /static/style.css → 200 (Nginx 가 직접 응답)" '[ "$STATUS" = 200 ]'
t "정적 파일에 Nginx 캐시 헤더 (Cache-Control: max-age=3600)" 'header_has "cache-control: max-age=3600"'
t "보안 헤더 X-Frame-Options: DENY" 'header_has "x-frame-options: DENY"'

echo "[2] WAS Tier (Flask) : 접근 제어 / CSRF"
get /
t "비로그인 GET / → /login 으로 리다이렉트" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */login ]]'
get /home
t "비로그인 GET /home → /login 으로 리다이렉트 (접근 차단)" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */login ]]'
get /login
TOKEN=$(csrf)
t "GET /login → 200, 로그인 폼 + CSRF 토큰 포함" '[ "$STATUS" = 200 ] && [ -n "$TOKEN" ] && body_has "name=\"password\""'
post /login "username=$DEMO_USER" "password=$DEMO_PASSWORD"
t "CSRF 토큰 없이 POST /login → 400 거부" '[ "$STATUS" = 400 ]'

echo "[3] WAS + DB Tier : 로그인 / 회원가입"
post /login "csrf_token=$TOKEN" "username=$DEMO_USER" "password=wrong-password1"
t "틀린 비밀번호 → 401 + 실패 메시지" '[ "$STATUS" = 401 ] && body_has "아이디 또는 비밀번호가 올바르지 않습니다"'
post /login "csrf_token=$TOKEN" "username=no_such_user_x" "password=whatever123"
t "없는 아이디 → 401 + 같은 메시지 (계정 존재 여부 비노출)" '[ "$STATUS" = 401 ] && body_has "아이디 또는 비밀번호가 올바르지 않습니다"'
post /login "csrf_token=$TOKEN" "username=' OR '1'='1' -- " "password=' OR '1'='1"
t "SQL Injection 시도 (' OR '1'='1' --) → 401 차단" '[ "$STATUS" = 401 ]'

get /signup
TOKEN=$(csrf)
post /signup "csrf_token=$TOKEN" "username=$NEW_USER" "name=테스트" "password=short" "password_confirm=short"
t "회원가입: 약한 비밀번호 → 400 + 안내 메시지" '[ "$STATUS" = 400 ] && body_has "영문과 숫자를 모두 포함"'
post /signup "csrf_token=$TOKEN" "username=$NEW_USER" "name=테스트사용자" "password=$NEW_PASSWORD" "password_confirm=$NEW_PASSWORD"
t "회원가입: 신규 계정($NEW_USER) → 302 /login" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */login ]]'
post /signup "csrf_token=$TOKEN" "username=$NEW_USER" "name=중복" "password=$NEW_PASSWORD" "password_confirm=$NEW_PASSWORD"
t "회원가입: 중복 아이디 → 409" '[ "$STATUS" = 409 ] && body_has "이미 사용 중인 아이디"'

get /login
TOKEN=$(csrf)
post /login "csrf_token=$TOKEN" "username=$NEW_USER" "password=$NEW_PASSWORD"
t "신규 계정 로그인 성공 → 302 /home" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */home ]]'
t "세션 쿠키에 HttpOnly 속성" 'grep -i "^set-cookie: loginapp_session=" "$WORK/headers" | grep -qi httponly'
get /home
t "GET /home → 200, 사용자 이름 + 로그인 기록 표시" '[ "$STATUS" = 200 ] && body_has "테스트사용자님, 환영합니다" && body_has "login_logs"'
t "메인 화면에 3계층 정보 (nginx / gunicorn / MariaDB)" 'body_has "nginx/" && body_has "gunicorn" && body_has "MariaDB"'
TOKEN=$(csrf)
post /logout "csrf_token=$TOKEN"
t "로그아웃 → 302 /login" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */login ]]'
get /home
t "로그아웃 후 GET /home → 다시 /login 으로 (세션 삭제 확인)" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */login ]]'

new_session
get /login
TOKEN=$(csrf)
post /login "csrf_token=$TOKEN" "username=$DEMO_USER" "password=$DEMO_PASSWORD"
t "데모 계정($DEMO_USER) 로그인 → 302 /home" '[ "$STATUS" = 302 ] && [[ "$LOCATION" == */home ]]'

echo "[4] 계층 분리 / 저장 방식 (VM 내부에서 root 로 실행할 때만)"
case $BASE in
  http://127.0.0.1*|http://localhost*) LOCAL=1 ;;
  *) LOCAL=0 ;;
esac
if [ "$LOCAL" = 1 ] && command -v ss >/dev/null; then
  LISTEN=$(ss -ltnH 2>/dev/null | awk '{print $4}')
  t "Web 80 포트는 모든 인터페이스(0.0.0.0)에 공개" 'grep -Eq "^(0\.0\.0\.0|\*|\[::\]):80$" <<<"$LISTEN"'
  t "WAS 8000 포트는 127.0.0.1 에만 바인딩 (외부 직접 접근 불가)" 'grep -q "^127.0.0.1:8000$" <<<"$LISTEN" && ! grep -Eq "^(0\.0\.0\.0|\*|\[::\]):8000$" <<<"$LISTEN"'
  t "DB 3306 포트는 127.0.0.1 에만 바인딩 (외부 직접 접근 불가)" 'grep -q "^127.0.0.1:3306$" <<<"$LISTEN" && ! grep -Eq "^(0\.0\.0\.0|\*|\[::\]):3306$" <<<"$LISTEN"'
else
  skip "포트 바인딩 검사 (VM 내부에서 실행 시 수행)"
fi
if [ "$LOCAL" = 1 ] && [ "$(id -u)" -eq 0 ] && command -v mysql >/dev/null; then
  HASH=$(mysql -N -B -e "SELECT password_hash FROM loginapp.users WHERE username='$NEW_USER'" 2>/dev/null)
  t "DB 에 비밀번호가 평문이 아닌 해시(scrypt:…)로 저장됨" '[[ "$HASH" == scrypt:* ]] && [[ "$HASH" != *"$NEW_PASSWORD"* ]]'
  CNT=$(mysql -N -B -e "SELECT COUNT(*) FROM loginapp.login_logs WHERE username='$NEW_USER'" 2>/dev/null)
  t "로그인 시도가 login_logs 테이블에 기록됨 (${CNT:-0}건)" '[ "${CNT:-0}" -ge 1 ]'
else
  skip "DB 저장 방식 검사 (VM 내부에서 sudo 로 실행 시 수행)"
fi

echo
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m결과: %d/%d 통과\033[0m (건너뜀 %d)\n' "$PASS" "$TOTAL" "$SKIP"
else
  printf '\033[1;31m결과: %d/%d 통과, %d 실패\033[0m (건너뜀 %d)\n' "$PASS" "$TOTAL" "$FAIL" "$SKIP"
fi
[ "$FAIL" -eq 0 ]
