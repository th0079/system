"""
WAS Tier (Application Tier) : Flask 로그인 서비스

요청 흐름
    호스트 OS 브라우저 → Nginx (0.0.0.0:80, Web Tier)
                       → Gunicorn + Flask (127.0.0.1:8000, WAS Tier)   ← 이 파일
                       → MariaDB (127.0.0.1:3306, DB Tier)

기능 : 로그인 / 로그아웃 / 회원가입 / 로그인 후 메인 화면 / 헬스체크(/health)
보안 : 비밀번호 해시 저장(scrypt), SQL 파라미터 바인딩(SQL Injection 방지),
       CSRF 토큰, HttpOnly 세션 쿠키, 로그인 시 세션 재발급, 동일한 실패 메시지
"""
import hmac
import os
import re
import secrets
import socket
from functools import wraps
from importlib.metadata import PackageNotFoundError, version

import click
import pymysql
import pymysql.cursors
from flask import (Flask, abort, flash, g, jsonify, redirect, render_template,
                   request, session, url_for)
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash, generate_password_hash


def load_env_file(path):
    """KEY=VALUE 형식의 설정 파일을 읽어 환경변수로 등록한다 (이미 있는 값은 유지)."""
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip().strip("'\""))
    except (FileNotFoundError, PermissionError):
        pass


# systemd 의 EnvironmentFile 로 이미 들어온 값이 있으면 그대로 쓰고,
# flask CLI 처럼 직접 실행할 때는 설정 파일을 읽는다.
load_env_file(os.environ.get("LOGINAPP_ENV_FILE", "/etc/loginapp/loginapp.env"))

SECRET_KEY = os.environ.get("SECRET_KEY")
if not SECRET_KEY:
    # 워커마다 키가 달라지면 세션이 깨지므로 임의 값으로 대체하지 않고 바로 실패한다.
    raise RuntimeError("SECRET_KEY 가 없습니다. /etc/loginapp/loginapp.env 를 확인하세요 "
                       "(deploy/setup.sh 가 자동 생성).")

# 정적 파일(/static/*)은 Web Tier(Nginx)가 직접 제공하므로 Flask 의 static 라우트는 끈다.
app = Flask(__name__, static_folder=None)
app.config.update(
    SECRET_KEY=SECRET_KEY,
    SESSION_COOKIE_NAME="loginapp_session",
    SESSION_COOKIE_HTTPONLY=True,       # JavaScript 에서 쿠키 접근 불가
    SESSION_COOKIE_SAMESITE="Lax",      # 다른 사이트에서 보낸 POST 요청에는 쿠키 미전송
    PERMANENT_SESSION_LIFETIME=30 * 60, # 로그인 유지 30분
)
# Nginx 가 넘겨주는 X-Forwarded-For / X-Forwarded-Proto 를 신뢰한다 (프록시 1단계).
# 덕분에 request.remote_addr 이 Nginx(127.0.0.1)가 아닌 실제 접속자 IP 가 된다.
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)

DB_CONFIG = {
    "host": os.environ.get("DB_HOST", "127.0.0.1"),
    "port": int(os.environ.get("DB_PORT", "3306")),
    "user": os.environ.get("DB_USER", "loginapp"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "database": os.environ.get("DB_NAME", "loginapp"),
    "charset": "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
    "autocommit": True,
    "connect_timeout": 5,
}

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{4,20}$")
# 존재하지 않는 ID 로 로그인할 때도 해시 비교를 한 번 수행해서,
# 응답 시간 차이로 "ID 존재 여부"가 드러나지 않게 한다.
DUMMY_HASH = generate_password_hash(secrets.token_hex(16))


# ---------------------------------------------------------------- DB 연결 (DB Tier)
def get_db():
    """요청마다 MariaDB 연결을 하나 만들고 요청이 끝나면 닫는다."""
    if "db" not in g:
        g.db = pymysql.connect(**DB_CONFIG)
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def query_one(sql, args=()):
    with get_db().cursor() as cur:
        cur.execute(sql, args)  # %s 자리표시자 + 인자 분리 → SQL Injection 방지
        return cur.fetchone()


def query_all(sql, args=()):
    with get_db().cursor() as cur:
        cur.execute(sql, args)
        return cur.fetchall()


def execute(sql, args=()):
    with get_db().cursor() as cur:
        cur.execute(sql, args)
        return cur.lastrowid


# ---------------------------------------------------------------- 보안 유틸
def csrf_token():
    """폼에 넣을 CSRF 토큰 (세션마다 1개)."""
    if "csrf_token" not in session:
        session["csrf_token"] = secrets.token_urlsafe(32)
    return session["csrf_token"]


app.jinja_env.globals["csrf_token"] = csrf_token


@app.before_request
def verify_csrf():
    if request.method == "POST":
        sent = request.form.get("csrf_token", "").encode()
        expected = session.get("csrf_token", "").encode()
        if not expected or not hmac.compare_digest(sent, expected):
            abort(400, description="보안 토큰(CSRF)이 유효하지 않습니다. 페이지를 새로고침한 뒤 다시 시도하세요.")


def login_required(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        if "user_id" not in session:
            flash("로그인이 필요합니다.", "info")
            return redirect(url_for("login"))
        return view(*args, **kwargs)
    return wrapped


def client_ip():
    return (request.remote_addr or "-")[:45]


def pkg_version(name):
    try:
        return version(name)
    except PackageNotFoundError:
        return "?"


def validate_signup(username, name, password, password_confirm):
    errors = []
    if not USERNAME_RE.fullmatch(username):
        errors.append("아이디는 영문/숫자/밑줄(_) 4~20자로 입력하세요.")
    if not 1 <= len(name) <= 30:
        errors.append("이름은 1~30자로 입력하세요.")
    if not (8 <= len(password) <= 64 and re.search(r"[A-Za-z]", password)
            and re.search(r"[0-9]", password)):
        errors.append("비밀번호는 8~64자이며 영문과 숫자를 모두 포함해야 합니다.")
    if password != password_confirm:
        errors.append("비밀번호 확인이 일치하지 않습니다.")
    return errors


def tier_info():
    """메인 화면에 보여줄 '이 요청이 거쳐 온 3개 계층' 정보."""
    db_version = query_one("SELECT VERSION() AS v")["v"]
    return {
        "web": {
            "name": request.headers.get("X-Web-Tier", "Nginx 미경유 (WAS 직접 접속)"),
            "detail": "0.0.0.0:80 · 정적 파일 제공 · 리버스 프록시",
        },
        "was": {
            "name": f"{request.environ.get('SERVER_SOFTWARE', 'WSGI')} · Flask {pkg_version('flask')}",
            "detail": f"127.0.0.1:8000 · PID {os.getpid()} @ {socket.gethostname()}",
        },
        "db": {
            "name": db_version,
            "detail": f"{DB_CONFIG['host']}:{DB_CONFIG['port']} · DB '{DB_CONFIG['database']}'",
        },
    }


# ---------------------------------------------------------------- 화면 (라우트)
@app.get("/")
def index():
    return redirect(url_for("home" if "user_id" in session else "login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        if "user_id" in session:
            return redirect(url_for("home"))
        return render_template("login.html")

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")
    if not username or not password:
        flash("아이디와 비밀번호를 모두 입력하세요.", "error")
        return render_template("login.html", username=username), 400

    user = query_one(
        "SELECT id, username, password_hash, name FROM users WHERE username = %s",
        (username,),
    )
    password_ok = check_password_hash(user["password_hash"] if user else DUMMY_HASH, password)
    success = user is not None and password_ok

    execute(
        "INSERT INTO login_logs (user_id, username, ip_address, success) VALUES (%s, %s, %s, %s)",
        (user["id"] if user else None, username[:50], client_ip(), int(success)),
    )
    if not success:
        # ID 가 틀렸는지 비밀번호가 틀렸는지 구분하지 않는다 (계정 존재 여부 노출 방지).
        flash("아이디 또는 비밀번호가 올바르지 않습니다.", "error")
        return render_template("login.html", username=username), 401

    execute("UPDATE users SET last_login_at = NOW() WHERE id = %s", (user["id"],))
    session.clear()            # 로그인 전 세션을 버리고 새로 발급 (세션 고정 공격 방지)
    session.permanent = True
    session["user_id"] = user["id"]
    session["username"] = user["username"]
    session["name"] = user["name"]
    flash(f"{user['name']}님, 로그인되었습니다.", "success")
    return redirect(url_for("home"))


@app.route("/signup", methods=["GET", "POST"])
def signup():
    if request.method == "GET":
        return render_template("signup.html")

    username = request.form.get("username", "").strip()
    name = request.form.get("name", "").strip()
    password = request.form.get("password", "")
    password_confirm = request.form.get("password_confirm", "")

    errors = validate_signup(username, name, password, password_confirm)
    if errors:
        for message in errors:
            flash(message, "error")
        return render_template("signup.html", username=username, name=name), 400

    try:
        execute(
            "INSERT INTO users (username, password_hash, name) VALUES (%s, %s, %s)",
            (username, generate_password_hash(password), name),
        )
    except pymysql.err.IntegrityError:  # UNIQUE(username) 위반
        flash("이미 사용 중인 아이디입니다.", "error")
        return render_template("signup.html", username=username, name=name), 409

    flash("회원가입이 완료되었습니다. 로그인해 주세요.", "success")
    return redirect(url_for("login"))


@app.get("/home")
@login_required
def home():
    user = query_one(
        "SELECT username, name, created_at, last_login_at FROM users WHERE id = %s",
        (session["user_id"],),
    )
    if user is None:  # 세션은 남아 있는데 DB 에서 계정이 삭제된 경우
        session.clear()
        return redirect(url_for("login"))
    logs = query_all(
        "SELECT created_at, ip_address, success FROM login_logs "
        "WHERE user_id = %s ORDER BY id DESC LIMIT 5",
        (session["user_id"],),
    )
    return render_template("home.html", user=user, logs=logs, tiers=tier_info())


@app.post("/logout")
def logout():
    session.clear()
    flash("로그아웃되었습니다.", "info")
    return redirect(url_for("login"))


@app.get("/health")
def health():
    """계층별 상태 확인용 (Nginx 경유 여부 / WAS / DB)."""
    status = {"web": request.headers.get("X-Web-Tier", "direct"), "was": "ok"}
    try:
        status["db"] = "ok" if query_one("SELECT 1 AS ok")["ok"] == 1 else "error"
    except pymysql.MySQLError as e:
        app.logger.error("DB health check failed: %s", e)
        status["db"] = f"error (MySQL {e.args[0] if e.args else '?'})"
    return jsonify(status), (200 if status["db"] == "ok" else 503)


# ---------------------------------------------------------------- 오류 화면
ERROR_MESSAGES = {
    404: "요청한 페이지를 찾을 수 없습니다.",
    405: "허용되지 않은 요청 방식입니다.",
}


@app.errorhandler(400)
@app.errorhandler(404)
@app.errorhandler(405)
def http_error(e):
    message = ERROR_MESSAGES.get(e.code, e.description)
    return render_template("error.html", code=e.code, message=message), e.code


@app.errorhandler(pymysql.MySQLError)
def db_error(e):
    app.logger.error("DB error: %s", e)
    return render_template(
        "error.html", code=503,
        message="DB 서버(DB Tier)에 연결할 수 없습니다. MariaDB 상태를 확인하세요.",
    ), 503


# ---------------------------------------------------------------- 관리용 CLI
@app.cli.command("create-user")
@click.argument("username")
@click.argument("name")
@click.option("--password", prompt=True, hide_input=True, confirmation_prompt=True,
              help="비밀번호 (생략하면 입력 프롬프트가 뜸)")
def create_user_command(username, name, password):
    """계정 생성. 예) flask --app app create-user demo 데모사용자"""
    errors = validate_signup(username, name, password, password)
    if errors:
        raise click.ClickException(" / ".join(errors))
    if query_one("SELECT 1 AS found FROM users WHERE username = %s", (username,)):
        click.echo(f"[skip] 이미 존재하는 계정입니다: {username}")
        return
    execute(
        "INSERT INTO users (username, password_hash, name) VALUES (%s, %s, %s)",
        (username, generate_password_hash(password), name),
    )
    click.echo(f"[ok] 계정을 만들었습니다: {username}")
