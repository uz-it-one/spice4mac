# 외부 라이브러리 및 소스 안내

Spice4Mac의 자체 코드는 MIT License를 따르며, 포함된 외부 라이브러리는 각 프로젝트의 원본 라이선스를 유지합니다. 개별 라이선스 전문과 저작권 고지는 앱 번들의 `Contents/Resources/Licenses`에서 확인할 수 있으며, 아래 요약보다 각 파일의 원문 조건이 우선합니다.

## 포함된 외부 라이브러리

| 구성 요소 | 라이선스 | 비고 |
| --- | --- | --- |
| spice-client-glib (spice-gtk), GLib, GStreamer, gst-plugins-base, JSON-GLib, libintl (gettext) | LGPL-2.1-or-later | 동적 링크 |
| Pixman | MIT 계열 | |
| OpenSSL 3 | Apache-2.0 | |
| Opus | BSD-3-Clause | 포함 고지 적용 |
| libjpeg-turbo | IJG, BSD-3-Clause, Zlib | |
| PCRE2 | BSD-3-Clause | 포함 고지 적용 |
| libffi | MIT | 포함되는 빌드에 한함 |
| CA 인증서 묶음 | Mozilla 인증서 데이터 고지 | Homebrew `ca-certificates` 원본 및 생성 recipe 포함 |

## 앱에 포함되지 않는 구성 요소

- 테스트 및 빌드 도구의 라이선스는 각 원본 소스를 따릅니다.
