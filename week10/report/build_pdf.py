"""report.html → PDF 변환 (Chromium 인쇄 기능 사용)

사용법:  python3 build_pdf.py [출력파일.pdf]
필요:    pip install playwright && playwright install chromium
대안:    report.html 을 크롬/엣지로 열고 Ctrl+P → 'PDF로 저장' (배경 그래픽 체크)
"""
import os
import pathlib
import sys

from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
OUT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "10주차_과제_AI도구활용_문제해결.pdf"

with sync_playwright() as p:
    # 이미 설치된 크롬/크로미움을 쓰려면: CHROMIUM_PATH=/경로/chrome python3 build_pdf.py
    browser = p.chromium.launch(executable_path=os.environ.get("CHROMIUM_PATH") or None)
    page = browser.new_page()
    page.goto((HERE / "report.html").as_uri(), wait_until="networkidle")
    page.pdf(
        path=str(OUT),
        format="A4",
        print_background=True,
        prefer_css_page_size=True,
        display_header_footer=True,
        header_template="<span></span>",
        footer_template=(
            '<div style="width:100%;font-size:8px;color:#9ca3af;text-align:center;">'
            '<span class="pageNumber"></span> / <span class="totalPages"></span></div>'
        ),
    )
    browser.close()
print(f"PDF 생성: {OUT}")
