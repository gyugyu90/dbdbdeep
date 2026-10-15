# dbdbdeep

밝은 크림색과 라벤더, 작은 이모지로 만든 macOS용 데이터베이스 워크스페이스입니다. SwiftUI/AppKit으로 작성했으며 Oracle 연결은 공식 JDBC Thin 드라이버를 사용합니다.

## 실행

빌드된 앱은 `build/dbdbdeep.app`에 있습니다. Finder에서 더블클릭하거나 프로젝트 디렉터리에서 실행합니다.

```sh
open build/dbdbdeep.app
```

첫 실행에서는 실제 SQLite 파일을 사용하는 **Little playground**가 열립니다. 샘플 데이터로 쿼리와 북마크를 둘러볼 수 있습니다.

## Oracle 연결

1. 왼쪽 **Add connection** 또는 `⌘N`을 누릅니다.
2. 연결 이름, 호스트, 포트, 서비스명 또는 SID, 계정과 비밀번호를 입력합니다.
3. **Test connection**으로 확인한 뒤 **Save & connect**를 누릅니다.
4. 현재 사용자가 소유한 테이블·뷰·컬럼과 기본키가 왼쪽 스키마 트리에 표시됩니다. 테이블을 클릭하면 처음 100개 행을 조회합니다.

비밀번호는 macOS Keychain에 저장하며 연결 설정 JSON에는 포함하지 않습니다. 연결을 편집하거나 제거하려면 연결 항목을 우클릭합니다. 여러 연결을 전환해도 각 Oracle 세션은 유지됩니다.

## 콘솔

- `⌘↵`: SQL 실행. 선택한 텍스트가 있으면 선택 영역만 실행합니다.
- Oracle에서는 한 번에 SQL 문 하나 또는 PL/SQL 블록 하나를 실행합니다. SQL의 마지막 세미콜론은 처리하며, PL/SQL의 세미콜론은 유지합니다.
- INSERT·UPDATE·DELETE는 **수동 커밋**입니다. 체크 아이콘 또는 `⌘⇧↵`로 Commit, 되돌리기 아이콘으로 Rollback합니다. **Oracle DDL은 DB 규칙에 따라 자동 커밋됩니다.**
- 세션이 종료되면 커밋하지 않은 변경은 롤백됩니다. Playground도 수동 커밋을 사용합니다.
- 조회 결과는 최대 1,000행을 표시합니다. 한도에 도달하면 결과 영역에 표시합니다. 큰 문자열과 CLOB은 최대 16,384자 미리보기, 바이너리는 타입 표시로 제공합니다.
- 결과 필터는 가져온 행 안에서 검색합니다. 값을 더블클릭하면 복사합니다.
- 공유 아이콘 또는 `⌘⇧E`로 가져온 결과 전체를 CSV로 내보냅니다. 화면의 검색 필터는 CSV에 적용되지 않습니다. 미리보기의 행·문자 제한은 CSV에도 적용됩니다.
- History는 현재 앱 세션에서 성공한 쿼리를 보여 줍니다.

## 북마크

`⌘D` 또는 오른쪽 `+`로 이름·이모지·컬러·SQL을 저장합니다. 연결을 지정할 수 있고, 카드 클릭 시 해당 연결과 SQL을 불러옵니다. 자동 실행하지 않습니다. 우클릭으로 편집·복사·삭제합니다. 검색과 컬러 필터를 지원합니다.

연결 프로필, 북마크, 연결별 SQL 초안은 `~/Library/Application Support/DBDeep/workspace.json`에 저장합니다. 샘플 DB는 같은 폴더의 `playground.sqlite`입니다. 저장한 초안의 DML을 앱 시작 시 자동 실행하지 않습니다.

## 소스에서 빌드

필요한 개발 도구는 macOS 14+, Xcode/Swift 5.10 이상, JDK 21, curl입니다. 현재 생성된 앱은 빌드한 Mac의 CPU 아키텍처를 대상으로 합니다.

```sh
./scripts/build-app.sh
swift test
```

빌드 스크립트는 Maven Central에서 `ojdbc11` **23.26.3.0.0**을 내려받고 SHA-256을 확인합니다. JDK의 `jlink`로 작은 Java 런타임을 만들고 드라이버·브리지와 함께 `.app` 안에 포함합니다. 빌드된 앱 실행 시 별도 Java 설치는 필요하지 않습니다. 현재 빌드는 로컬 실행용 ad-hoc 서명이며 배포용 notarization은 포함하지 않습니다.

```text
Sources/DBDeepApp/       SwiftUI 화면, AppKit SQL 편집기, 작업 공간 상태
Sources/DBDeepCore/      Oracle/SQLite 어댑터, 모델, Keychain 저장
OracleBridge/           같은 JDBC 세션에서 쿼리·Commit·Rollback 실행
Tests/DBDeepCoreTests/   CRUD, 롤백, 스키마, 결과 제한, 저장, CSV 검증
scripts/                앱 번들 및 네이티브 아이콘 생성
```

Swift ↔ Java 통신은 길이 기반 프레임을 stdin/stdout으로 주고받습니다. 자격 증명은 프로세스 인자나 파일로 넘기지 않습니다. JDBC 연결은 최대 10초, 쿼리는 60초 타임아웃을 설정합니다.

## 검증 범위

SQLite CRUD, Commit/Rollback, 스키마 제약조건, 행 제한과 RETURNING, 파일 저장 복원, 북마크 직렬화, CSV 이스케이프의 자동 테스트를 통과했습니다. 네이티브 앱에서 SQL 실행과 Rollback을 확인했으며, 번들 JDBC 드라이버의 실행과 Oracle 리스너 연결 오류 표시를 확인했습니다.

실제 Oracle 서버의 인증·CRUD·스키마 조회는 서버 주소와 계정이 제공되지 않아 검증하지 않았습니다. 현재 연결 창은 기본 TCP 및 서비스명/SID 방식이며 Wallet·SSH 터널·다른 스키마 탐색은 포함하지 않습니다.

Oracle 트랜잭션 동작과 JDBC 설정은 [Oracle JDBC 문서](https://docs.oracle.com/en/database/oracle/oracle-database/26/jjdbc/JDBC-coding-tips.html), SQLite 실행은 [SQLite C API 문서](https://sqlite.org/c3ref/prepare.html)를 따릅니다. 포함된 런타임의 라이선스는 번들 내 `Contents/Resources/Oracle/jre/legal`과 JDBC JAR의 배포 메타데이터를 참고합니다.
