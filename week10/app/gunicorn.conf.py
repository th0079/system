# WAS Tier : Gunicorn 설정 (Flask 앱을 실행하는 WSGI 애플리케이션 서버)
# 127.0.0.1 에만 바인딩 → 호스트 OS 에서는 8000 포트로 직접 접근할 수 없고
# 같은 VM 의 Nginx(Web Tier)를 통해서만 접근된다.
bind = "127.0.0.1:8000"
workers = 2
timeout = 30
accesslog = "-"   # 표준출력 → journalctl -u loginapp 로 확인
errorlog = "-"
proc_name = "loginapp"
