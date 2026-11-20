# Spice4Mac

**Apple Silicon Mac에서 가상 머신의 SPICE 화면을 여는 네이티브 원격 데스크톱 클라이언트입니다.**

libvirt/QEMU의 SPICE 콘솔을 Mac의 창이나 전체 화면으로 사용할 수 있습니다. SwiftUI와 AppKit으로 만든 인터페이스에 Liquid Glass를 적용하고, 원격 화면은 Metal로 표시합니다.

## 다운로드 및 시작하기

**Apple Silicon(M1 이상), macOS 26 이상**이 필요합니다. Intel Mac은 지원하지 않습니다.

1. [Releases](https://github.com/uz-it-one/spice4mac/releases)에서 최신 `Spice4Mac-버전-arm64.zip`을 받습니다.
2. 압축을 풀고 `Spice4Mac.app`을 응용 프로그램 폴더로 옮깁니다.
3. 앱에서 서버 주소와 SPICE 포트를 입력하거나 **Open .vv…**로 연결 파일을 엽니다.
4. TLS 서버라면 CA 인증서와 필요한 경우 인증서 subject를 지정한 뒤 연결합니다.

현재 릴리스는 ad-hoc 서명되어 있으며 Apple 공증을 받지 않았습니다. macOS가 실행을 차단할 수 있습니다. 다운로드 출처를 확인한 경우 시스템 설정의 **개인정보 보호 및 보안 → 그래도 열기**를 사용할 수 있습니다.

## 주요 기능

### 원격 화면에 집중하기

연결하면 왼쪽 설정 패널이 사라지고 원격 화면이 창을 채웁니다. **View** 메뉴에서 창에 맞추기(`⌘0`) 또는 실제 픽셀 크기(`⌘1`)를 선택할 수 있습니다.

전체 화면에서는 상태 표시와 도구 막대를 숨깁니다. 커서를 화면 상단으로 가져가면 macOS 메뉴와 도구 막대가 내려옵니다. 전체 화면 전환 단축키는 `⌃⌘F`입니다.

### 클립보드, 소리, 자동 해상도

텍스트 클립보드 공유, 게스트 소리 출력, 창 크기에 맞춘 게스트 해상도 변경이 기본으로 켜져 있습니다. 연결 전 설정에서 각각 끌 수 있습니다. 클립보드와 자동 해상도에는 게스트의 SPICE agent 지원이 필요합니다.

키보드·마우스·스크롤·원격 커서를 지원하며, 도구 막대에서 **Ctrl-Alt-Delete**를 보낼 수 있습니다. `Control + Option`을 누르면 원격 입력을 해제합니다.

### 연결과 인증

- 서버 주소, `spice://` URI, `.vv` 연결 파일로 접속합니다.
- TLS, CA 인증서, 인증서 subject, SPICE ticket 인증을 지원합니다.
- 평문 연결은 명시적으로 허용해야 합니다.
- 연결 프로필을 저장할 수 있으며, ticket은 선택한 경우에만 macOS Keychain에 저장합니다.
- HTTP(S) SPICE 프록시 설정을 전달할 수 있습니다. 관리 포털별 `.vv` 확장 옵션은 모두 지원하지는 않습니다.

## 터미널에서 실행하기

ZIP에 함께 들어 있는 `spice4mac`은 GUI를 실행하는 네이티브 CLI입니다. 앱 옆에 두거나 앱을 `/Applications`에 설치하면 자동으로 찾습니다. 아래 명령은 ZIP을 푼 폴더에서 실행합니다.

```sh
./spice4mac connection.vv
./spice4mac --host vm.example --tls-port 5901 --ca-file /path/to/ca.pem
```

서버 주소와 인증서 경로는 실제 환경에 맞게 바꾸십시오. 로컬 포트 포워딩 등에서 평문 연결이 필요하면 다음과 같이 실행합니다.

```sh
./spice4mac --host 127.0.0.1 --port 5900 --insecure
```

CLI는 **GUI가 실행되는 동안 셸에서 기다리고, 연결이 종료되면 GUI도 닫습니다.** 비밀번호를 명령행에 노출하지 않도록 `--password-stdin`으로 전달할 수 있습니다.

```sh
./spice4mac --host vm.example --tls-port 5901 \
  --ca-file /path/to/ca.pem --password-stdin < /path/to/ticket.txt
```

첫 화면을 저장하고 종료하는 자동화도 지원합니다.

```sh
./spice4mac --host 127.0.0.1 --port 5900 --insecure \
  --timeout 15 --screenshot /tmp/spice-frame.png --exit-after-connect
```

클립보드·소리·자동 해상도를 끄려면 `--no-clipboard`, `--no-audio`, `--no-auto-resize`를 사용하십시오. 전체 옵션은 `./spice4mac --help`, 종료 코드와 진단 방법은 [CLI 안내](docs/CLI.md)에 있습니다. GUI 자동화에는 로그인된 macOS 그래픽 세션이 필요합니다.

## 0.1.0의 지원 범위

현재는 **단일 원격 화면**을 지원하는 첫 공개 버전입니다. 다중 모니터, USB 전달, 마이크, 파일·폴더 공유, 스마트카드, SASL, 자동 재연결은 지원하지 않습니다. 모든 동영상 코덱을 포함하지 않으며, macOS IME의 조합 문자열을 직접 전송하는 기능도 없습니다. 한글은 게스트 OS의 IME를 사용합니다.

실제 SPICE 서버를 이용한 화면·입력·TLS·인증·연결 종료 시험과 로컬 4K 갱신 시험을 수행했습니다. 모든 libvirt/QEMU 구성과 게스트 OS의 호환성을 보장하지는 않습니다. 클립보드·소리·자동 해상도는 게스트 구성에 따라 동작이 달라질 수 있습니다.

## 라이선스와 감사의 말

Spice4Mac에서 새로 작성한 코드는 [MIT License](LICENSE)로 공개합니다. **외부 라이브러리에는 MIT를 일괄 적용하지 않으며 각 프로젝트의 라이선스가 유지됩니다.**

| 구성 요소 | 라이선스 |
| --- | --- |
| spice-gtk / spice-client-glib | LGPL-2.1-or-later |
| GLib, GStreamer, gst-plugins-base, JSON-GLib | LGPL-2.1-or-later (개별 파일 고지 포함) |
| GNU gettext의 libintl | LGPL-2.1-or-later |
| Pixman | MIT 계열 |
| OpenSSL 3 | Apache-2.0 |
| Opus | BSD-3-Clause 및 포함 고지 |
| libjpeg-turbo | IJG, BSD-3-Clause, Zlib |
| PCRE2 | BSD-3-Clause 및 포함 고지 |
| libffi (포함되는 빌드의 경우) | MIT |

앱 번들의 `Contents/Resources/Licenses`에 외부 라이선스 문서를 포함합니다. 각 릴리스에는 빌드에 사용한 의존성 소스 묶음도 함께 제공합니다. 자세한 내용은 [외부 라이브러리 안내](docs/THIRD_PARTY.md)를 참고하십시오.

SPICE 프로젝트의 통신·디코딩 엔진을 사용합니다. 이 프로젝트는 SPICE, QEMU, libvirt 또는 Apple의 공식 제품이 아닙니다.

소스에서 빌드하거나 릴리스를 만드는 방법은 [빌드 안내](docs/BUILDING.md)에 있습니다.
