# CLI 사용 안내

`spice4mac`은 별도 GUI 프로세스를 실행하고 종료까지 기다립니다. 연결 종료 시 GUI도 종료하며, GUI의 종료 코드를 셸에 전달합니다. GUI를 직접 연 경우 연결 종료 후 연결 화면으로 돌아갑니다.

| 옵션 | 동작 |
| --- | --- |
| `--app PATH` | 사용할 Spice4Mac.app 지정 |
| `--fullscreen` | 전체 화면으로 시작 |
| `--password-stdin` | 표준 입력에서 ticket 읽기 |
| `--no-clipboard` / `--no-audio` / `--no-auto-resize` | 기본 켜짐 기능을 개별 비활성화 |
| `--validate` | GUI 없이 연결 설정 검사, 비밀번호를 가린 JSON 출력 |
| `--timeout SECONDS` | 첫 화면 대기 제한 |
| `--screenshot PATH` | 첫 원격 화면을 PNG로 저장 |
| `--exit-after-connect` | 첫 화면 수신 후 종료 |
| `--wait` | 호환성 옵션. 생략해도 항상 대기 |

JSON Lines 상태 이벤트는 stdout으로 나옵니다. 비밀번호는 GUI의 argv 대신 익명 파이프로 전달합니다. `.vv`에 들어 있는 파일 삭제 지시는 실행하지 않습니다.

| 종료 코드 | 의미 |
| --- | --- |
| 0 | 정상 실행·검증·종료 |
| 2 | 연결·TLS·인증 실패 |
| 3 | 스크린샷 저장 실패 |
| 4 | 첫 화면 수신 시간 초과 |
| 5 | 서버가 세션을 종료함 (CLI 대기 모드) |
| 64 | 인수·연결 설정·앱 경로 오류 |
| 128 + signal | GUI가 시그널로 종료됨 |

## 화면 갱신 문제 진단

```sh
SPICE4MAC_DIAGNOSTICS=1 ./spice4mac connection.vv 2> /tmp/spice4mac-display.log
```

`invalidations_per_sec`는 디코딩 후 화면 변경 알림, `published_fps`는 Swift 전달률, `received_fps`와 `submitted_fps`는 Metal 업로드·GPU 제출률, `upload_ms`는 평균 업로드 CPU 시간입니다. 실제 모니터 표시 프레임 수는 아닙니다. 화면이 정지하면 로그도 멈춥니다. 수신률이 낮다는 사실만으로 서버·네트워크·디코더 중 원인을 단정할 수 없습니다.

문제를 보고할 때 게스트 OS, 가상 그래픽 장치, 해상도와 진단 로그를 함께 알려 주십시오. 연결 파일·인증서·ticket·클립보드 내용은 첨부하지 마십시오. 진단 로그는 화면 내용과 비밀번호를 기록하지 않습니다.

`SPICE4MAC_VERIFY_UPLOADS=1`을 함께 지정하면 GPU 텍스처를 매 프레임 읽어 원격 framebuffer와 비교하고, 불일치 수를 60프레임마다 stderr에 기록합니다(부분 갱신 검증용, 성능 측정 시에는 끄십시오).

`--screenshot`은 원격 framebuffer를 저장합니다. 개발 진단용 `--window-screenshot`은 AppKit view cache 방식이므로 Metal과 일부 시스템 material이 빠질 수 있습니다.
