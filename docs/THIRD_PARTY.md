# 외부 라이브러리와 소스

Spice4Mac 자체 코드는 MIT입니다. 외부 코드를 MIT로 재라이선스하지 않습니다. 의존성별 원본 라이선스와 copyright 고지는 앱의 `Contents/Resources/Licenses`에 보존합니다. 파일별 조건이 요약보다 우선합니다.

- spice-client-glib (spice-gtk), GLib, GStreamer, gst-plugins-base, JSON-GLib, gettext의 libintl: LGPL-2.1-or-later.
- Pixman: MIT 계열 고지.
- OpenSSL 3: Apache-2.0.
- Opus: BSD-3-Clause 및 포함 고지.
- libjpeg-turbo: IJG, BSD-3-Clause, Zlib.
- PCRE2: BSD-3-Clause 및 포함 고지.
- libffi (포함되는 경우): MIT.
- CA 인증서 묶음: Mozilla 인증서 데이터의 해당 고지. Homebrew ca-certificates의 원본과 생성 recipe를 의존성 소스 묶음에 포함합니다.

릴리스의 `Spice4Mac-버전-dependency-sources.tar.gz`에는 프로젝트에서 내려받은 원본 아카이브, 실제 SPICE checkout과 submodule 소스, 패치·빌드 지침, 번들에 포함된 Homebrew 라이브러리의 원본 소스 및 설치 시 recipe를 담습니다. 매니페스트에는 다운로드 URL과 SHA-256을 기록합니다. 앱 소스는 같은 릴리스 태그의 GitHub 소스 아카이브에서 받을 수 있습니다.

LGPL 라이브러리는 동적으로 링크됩니다. 수정한 라이브러리로 교체하거나 프로젝트를 다시 빌드할 수 있으며, 교체 후에는 macOS 코드 서명을 다시 적용해야 합니다. MIT 라이선스는 이 권리를 제한하지 않습니다. 빌드 방법은 [BUILDING.md](BUILDING.md)를 참고하십시오.

테스트 서버 libspice-server는 GPL-2.0-or-later이며 앱에 포함하지 않습니다. 테스트·빌드 도구의 라이선스는 각 원본 소스에 있습니다.
