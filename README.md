# Spice4Mac

Apple Silicon Mac에서 libvirt/QEMU 가상 머신의 SPICE 콘솔을 여는 네이티브 원격 데스크톱 클라이언트입니다.

## 요구 사항 및 설치

- **지원 환경:** Apple Silicon (M1 이상), macOS 26 이상 (Intel Mac 미지원)

1. [Releases](https://github.com/uz-it-one/spice4mac/releases)에서 최신 `Spice4Mac-버전-arm64.zip`을 다운로드합니다.
2. 압축을 풀고 `Spice4Mac.app`을 `응용 프로그램` 폴더로 옮깁니다.
3. 앱 실행 후 서버 주소와 포트를 입력하거나 **Open .vv…**로 연결 파일을 열어 접속합니다. TLS 서버는 CA 인증서와 필요 시 인증서 subject를 지정합니다.

> **실행이 차단되는 경우:** 현재 릴리스는 Apple 공증을 받지 않아 macOS가 실행을 차단할 수 있습니다. **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**로 실행하십시오.

## 주요 기능

- **연결 및 인증:** 서버 주소, `spice://` URI, `.vv` 파일 접속을 지원합니다. TLS(CA 인증서, subject), SPICE ticket, HTTP(S) 프록시를 사용할 수 있으며 평문 연결은 명시적으로 허용해야 합니다.
- **프로필 저장:** 연결 프로필을 저장할 수 있으며, ticket은 선택한 경우에만 macOS Keychain에 보관됩니다.
- **클립보드·소리·자동 해상도:** 텍스트 클립보드 공유, 게스트 소리 출력, 창 크기에 맞춘 해상도 자동 조절이 기본 활성화되어 있으며 연결 전 설정에서 끌 수 있습니다. (클립보드와 자동 해상도는 게스트 OS의 SPICE agent 필요)
- **입력 제어:** 키보드, 마우스, 스크롤, 원격 커서 및 도구 막대의 **Ctrl-Alt-Delete** 전송을 지원합니다.

| 단축키 | 동작 |
| --- | --- |
| `⌘0` | 창 크기에 맞추기 |
| `⌘1` | 실제 픽셀 크기 |
| `⌃⌘F` | 전체 화면 전환 |
| `Control + Option` | 원격 입력 해제 |

게스트가 서버 마우스 모드(SPICE agent 없음)이면 클릭 시 포인터를 잠가 상대 이동을 전달하며, `Control + Option`으로 해제합니다. 마우스 뒤로/앞으로 버튼은 게스트로 전달하지만, SPICE 프로토콜에 가로 스크롤 버튼이 없어 가로 스크롤은 전달하지 않습니다.

## CLI 사용 (선택)

ZIP에 포함된 `spice4mac` 바이너리로 터미널에서도 연결할 수 있습니다. 앱이 같은 폴더나 `/Applications`에 있으면 자동으로 실행됩니다.

```sh
# .vv 파일 또는 TLS 서버 연결
./spice4mac connection.vv
./spice4mac --host vm.example --tls-port 5901 --ca-file /path/to/ca.pem

# 로컬 포트 포워딩 등 평문 연결
./spice4mac --host 127.0.0.1 --port 5900 --insecure
```

전체 옵션과 자동화 기능은 `./spice4mac --help` 또는 [CLI 안내](docs/CLI.md)를 참고하십시오.

## 현재 제한 사항

- **단일 화면만 지원:** 다중 모니터, USB 전달, 마이크, 파일·폴더 공유, 스마트카드, SASL, 자동 재연결은 지원하지 않습니다.
- **입력기(IME):** macOS IME 조합 문자열을 직접 전송하지 않으므로 한글 등은 게스트 OS의 입력기를 사용해야 합니다.
- 일부 동영상 코덱과 관리 포털별 `.vv` 확장 옵션은 지원하지 않을 수 있습니다.

## 개발자 안내

소스에서 직접 빌드하거나 릴리스 패키지를 만드는 방법은 [빌드 안내](docs/BUILDING.md)를 참고하십시오. 실제 VM 수동 검증 항목은 [실제 VM 체크리스트](docs/REAL_VM_CHECKLIST.md)에 있습니다.

## 라이선스

Spice4Mac의 자체 코드는 [MIT License](LICENSE)를 따릅니다. `spice-gtk` 등 포함된 외부 라이브러리는 각 프로젝트의 라이선스가 유지되며, 상세 내역은 앱 번들의 `Contents/Resources/Licenses`와 [외부 라이브러리 안내](docs/THIRD_PARTY.md)에서 확인할 수 있습니다.

이 프로젝트는 SPICE, QEMU, libvirt 또는 Apple의 공식 제품이 아닙니다.
