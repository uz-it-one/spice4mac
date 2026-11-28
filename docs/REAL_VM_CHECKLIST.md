# 실제 VM 수동 검증 체크리스트

자동 시험(`Build/test.sh`, `Tests/Integration/run-gui.py`, `run-display.py`)은 저장소의 loopback `spice-fixture`만 사용합니다. fixture에는 게스트 에이전트, 오디오, 비디오 스트림, 실제 프록시가 없으므로, 릴리스 전에는 아래 항목을 실제 QEMU/libvirt 게스트에서 확인하십시오.

## 준비

- 게스트 A: Linux 데스크톱 + `spice-vdagent` (QXL 또는 virtio-gpu)
- 게스트 B: Windows + virtio-win 게스트 도구(SPICE agent 포함)
- libvirt 도메인에 `<graphics type='spice' autoport='yes'>`를 설정하고 TLS 포트와 ticket을 구성합니다.
- 결과를 기록할 때는 진단 로그(`SPICE4MAC_DIAGNOSTICS=1`)만 첨부합니다. 연결 파일·인증서·ticket·클립보드 내용은 첨부하지 마십시오.

## 항목

| # | 항목 | 확인 방법 | 기대 결과 |
| --- | --- | --- | --- |
| 1 | TLS + CA 검증 | `--tls-port` + `--ca-file`로 연결, 잘못된 CA로 재시도 | 정상 연결 / 종료 코드 2 |
| 2 | ticket 만료 | 만료된 ticket으로 연결 | "Authentication failed" 표시, 종료 코드 2 |
| 3 | `.vv` 파일 | virt-manager 또는 관리 포털의 `.vv` 열기 | 자동 연결, `delete-this-file` 무시 |
| 4 | 프록시 | HTTP(S) 프록시 경유 연결 | 정상 연결, 프록시 오류 시 종료 코드 2 |
| 5 | 클립보드 양방향 | macOS ↔ 게스트 텍스트 복사, 1 MiB 초과 텍스트 | 양방향 동기화, 초과분은 전송 안 됨 |
| 6 | 자동 해상도 | 창 크기 변경, 전체 화면 전환 | 0.2초 후 게스트 해상도 변경, 세션 유지 |
| 7 | 오디오 | 게스트에서 음악·시스템 소리 재생 | 끊김 없이 재생, `--no-audio` 시 채널 미연결 |
| 8 | 클라이언트 마우스 모드 | 에이전트 연결 상태에서 커서 이동 | 원격 커서와 위치 일치 |
| 9 | 서버 마우스 모드 | 에이전트를 끄거나 PS/2 마우스만 있는 게스트에서 클릭 | 클릭 시 포인터가 잠기고 상대 이동, `Control + Option`으로 해제 |
| 10 | 마우스 측면 버튼 | 뒤로/앞으로 버튼(버튼 4/5) | 게스트에서 뒤로/앞으로 동작 |
| 11 | 키보드 | `Ctrl-Alt-Delete` 도구 막대, 방향키, 기능키, Caps Lock | 각 키가 게스트에 정확히 전달 |
| 12 | 비디오 스트림 | 게스트에서 동영상 전체 화면 재생 | 화면 갱신 유지, 진단 로그 `received_fps` 기록 |
| 13 | 부분 갱신 성능 | 4K 게스트에서 타이핑·창 이동, Activity Monitor로 CPU 확인 | 전체 갱신보다 낮은 CPU 사용률 |
| 14 | 원격 종료 | CLI로 연결 후 게스트 종료(`virsh shutdown`) | CLI 종료 코드 5 |
| 15 | 마이그레이션 | `virsh migrate --live` 중 세션 유지 | 상태 `Migrating` 후 화면 재개 |
