# 빌드 및 릴리스

Apple Silicon, macOS 26 이상, macOS 26 SDK 이상이 포함된 Xcode, Python 3.12 이상과 Homebrew가 필요합니다. 개발 의존성은 `Brewfile`, SPICE/GStreamer 소스와 패치의 고정 버전은 `Dependencies/native-lock.json`에서 확인할 수 있습니다.

```sh
brew bundle --file Brewfile
python3 Build/build-dependencies.py --server
./Build/build-app.sh
./Build/test.sh
python3 Build/archive-app.py
python3 Build/archive-sources.py
```

앱은 `dist/Spice4Mac.app`, CLI는 `dist/spice4mac`에 생성됩니다. 빌드 도구·네이티브 소스는 `.build-native`에 설치됩니다. Homebrew 전이 의존성의 버전은 설치 환경에 따라 달라질 수 있습니다. 바이너리별 아키텍처·최소 OS·소스 해시는 공개 경로 정보만 담은 `dist/native-audit.json`에 기록합니다. 번들에 포함된 라이브러리가 지원 최소 버전(macOS 26.0)보다 새 OS를 요구하면 패키징이 실패합니다. 의도적으로 최소 버전을 올릴 때만 `SPICE4MAC_ALLOW_MINIMUM_OS=27.0`처럼 지정하십시오.

GUI와 Metal 시험에는 로그인된 그래픽 세션이 필요합니다. 일반 CI의 필수 검사와 구분합니다.

```sh
python3 Tests/Integration/run-gui.py
SPICE_FIXTURE_WIDTH=3840 SPICE_FIXTURE_HEIGHT=2160 python3 Tests/Integration/run-display.py
```

## 태그 기반 릴리스

1. `VERSION`을 새 버전으로 변경하고 `python3 Build/version.py`를 실행합니다.
2. 변경 사항을 커밋하고 push합니다.
3. 해당 커밋에 `0.1.0` 또는 `v0.1.0` 형태의 태그를 push합니다.

```sh
git tag -a 0.1.0 -m 'Spice4Mac 0.1.0'
git push origin 0.1.0
```

`Release` workflow는 **태그 이벤트의 커밋 SHA를 checkout**하고, 태그와 VERSION 일치 여부를 검사합니다. arm64 macOS runner에서 의존성·앱을 빌드하고 Swift/upstream/SPICE 통합 시험을 실행한 후 앱·CLI ZIP, 의존성 소스, SHA-256, native audit를 GitHub Release에 게시합니다. 태그를 붙인 커밋의 코드를 빌드하며 main의 최신 코드를 대신 사용하지 않습니다.

수동 `workflow_dispatch`는 릴리스 전 빌드 검증용이며 **릴리스를 게시하지 않습니다**. 일반 branch push에는 실행하지 않습니다. 실패한 빌드는 릴리스를 공개하지 않고 로그를 Actions artifact에 남깁니다. 배포에는 job 범위의 `contents: write` 권한과 기본 GITHUB_TOKEN만 사용하며 별도 토큰이 필요하지 않습니다.

현재 릴리스는 ad-hoc 서명이며 Developer ID 서명·공증은 수행하지 않습니다. 의존성 소스는 함께 배포하며, 기존 공개 릴리스 자산을 재실행으로 덮어쓰지 않습니다.
