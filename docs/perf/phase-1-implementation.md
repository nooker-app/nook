# Phase 1 구현 보고서

작업 기준: `8d8d17e`, 작업 브랜치 `feature/perf-p1`. 앱 실행과 성능 측정은 하지 않았으며 push하지 않는다.
체크리스트에는 개별 ID가 없어 아래의 `§그룹.항목순서` 표기를 이 보고서의 식별자로 사용한다.

## 항목별 결과

| 계획 항목 | 상태 | 구현과 검증 |
|---|---|---|
| 1.8 전체 교체 identity | 구현, UI/실측 게이트 대기 | 설치되는 유효 소스(피드 집합/스마트 소스/카테고리)와 검색어가 바뀔 때만 macOS `listGeneration` 증가. List에만 `.id`를 붙이고 행 `.tag`/Identifiable은 유지. 20회 반복 전환의 identity·선택 유지 테스트 통과. 실제 20회 전환 뒤 swipe 버튼과 context menu 렌더링은 코디네이터가 확인해야 한다. |
| 1.1 필터 합치기 | 완료 | selection 변경을 동기 트랜잭션으로 묶고 retention을 필터 전에 해제. 세 didSet에 equality guard 유지. 같은 소스 재선택은 기존처럼 retention을 해제하고 한 번 다시 필터한다(두 플랫폼 동일). 직접 feed binding과 빈 폴더도 같은 경로. iOS의 feed+smart 연속 쓰기는 `selectFeed`로 합침. detached 작업 자체를 취소하고 후보 루프·정렬 전후에 취소 검사. |
| 1.2 leaf 관찰 | 완료 | macOS 오프라인 다운로드 toolbar와 검색/선택에 따른 empty state를 각각 child View로 분리. |
| 1.3 인덱스/카운트 | 완료 | 전체 articles ID→index 사전으로 selectedArticle/article(withID:)/read/star/category 변경/AI 루프 조회. suppressed 전체 install에서도 사전을 다시 만듦. `allCount`는 일반 recount 및 precomputed install에서 갱신. |
| 1.4 throttle/애니메이션 | 완료 | batch 데이터 필터는 1.5초 고정 trailing, 사용자 필터는 즉시. batch·전체 교체·기존 행 상대 순서 변경은 애니메이션 제외. merge의 withAnimation 제거, batch 최종 publish에 mode/new-article 조건 전달. |
| 1.5 가짜 변경 | 완료 | dateless 시간·사용자 상태 보정 후 MergeProjection 비교. transient 날짜 출처 제외, 비보유 본문 hydration 제외, 보유 본문의 실제 수정 포함. bodyCache는 no-op이어도 갱신. reloadMerged의 전체 동등성 비교 유지. B1 fixture: `new=0 changed=0 republishedFeeds=0`. |
| 1.6 seen 일괄 기록 | 완료 | foreground+storage 조건에서 전체 표시 unread 중 아직 seen이 아닌 글만 모아 HLC 한 번, 로컬 shard 복사→일괄 변경→한 번 대입. 새 기록이 있을 때만 shard save 예약. |
| 1.7 작은 guard | 부분 완료 | badge는 실제 내보낸 값 기준 guard, consumer 교체 시 재전송. endFeedFetch는 양쪽 set 검사 후 실제 제거 시 두 set과 isRefreshing 갱신. `persistReplica` detached 이동은 보류: replica 기록/발행/자기 revision 갱신과 notification 예약 순서를 함께 감사해야 하며 우선순위 1~5의 변경 범위를 넘기지 않음. |

## 검증

- `make build`: macOS Debug 통과.
- `swift test --package-path NookKit`: 610 tests / 83 suites 통과. ListRowMenuEagernessTests 포함.
- iOS `NookiOS` scheme: `xcodebuild -project Nook.xcodeproj -scheme NookiOS -destination 'generic/platform=iOS' -derivedDataPath DerivedData-iOS -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build` 통과(Release). 생성물은 검증 후 `/private/tmp/nook-p1-ios-derived-task_b9bda6a371a0`으로 옮겨 작업 트리에서 제외했다.
- `git diff --check`: 통과.
- `plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements`: 통과.
- 샌드박스 캐시 접근 오류 뒤 macOS build와 SwiftPM tests는 승인된 sandbox 외 실행으로 재검증했다.
- 최종 검증 로그: `/private/tmp/nook-p1-build.log`, `/private/tmp/nook-p1-ios-build.log`, `/private/tmp/nook-p1-tests.log`.
- `tools/perf`, `docs/perf/measurement.md`, PerfDriver 변경 없음.

## 체크리스트 대응

자동 테스트/소스 검토로 확인:

- §2.1: 세 selection equality guard, clear-before-capture, compound filter 한 번.
- §2.2: 같은 소스 재선택은 retention 해제 + refilter 한 번, identity 유지.
- §2.3, §2.8: direct feed binding/iOS selectFeed/category→빈 폴더, 제거 경로의 selection 쓰기 감사.
- §2.4, §2.5: 목록 설치가 자동 선택하지 않음, 여전히 표시되는 ID의 선택 유지와 숨겨진 ID 해제. applyDisplayed의 동일 결과 분기도 prune 실행.
- §2.6, §2.7: retain의 source-ignoring-read 조건 유지, fallback `.all` 경로는 selectSmartSource 사용.
- §2.9, §3.7: 사용자 트리거는 debounce 취소, 검색 clear 즉시, query는 off-main, canceled detached 결과 미설치.
- §3.1: visibleArticles/displayedArticles는 윈도가 아닌 정렬된 전체 결과 유지.
- §3.11: 기존 list.body/rowcontent/row/publish/filter 계측 위치 유지.
- §4.1–§4.3: 애니메이션 predicate 한 곳, 겹친 행의 상대 순서 확인, merge withAnimation 제거, 검색 animated=false 유지.
- §5.1: 내보낸 badge 값 guard, callback 교체와 off/on 테스트.
- §6.1: seen의 foreground/storage/unread/기록됨 skip, copy→assign 사이 await 없음, 1 HLC. 단위 테스트에서 두 unseen의 HLC 동일, 이미 seen인 결과의 shard 불변, background/no-storage 기록 없음 확인.
- §6.5: removeFolder의 feedSelection도 집합 subtract 한 번으로 변경; 기존 removeFolders의 일괄 대입 유지.
- §7.1–§7.2: 행 단위 `.id` 없음, 기존 menu/swipe child 유지, Enter/List selection 유지, 메뉴 eager 생성 회귀 테스트 통과.
- §9.3–§9.4: endFeedFetch 양쪽 set 처리, macOS progress leaf 관찰.

실제 앱 검증은 **미수행**:

- §7.1–§7.2: 20회 이상 실제 전환 후 swipe 버튼/label, context menu, Enter 동작.
- §2.4–§2.9: UI 선택/scroll-top/재선택/빈 폴더/foreground refresh 동작.
- §4.1–§4.3: interactive 신규 소량 slide, ambient 무애니메이션 시각 확인.
- §6.1: 실제 foreground/background notification 및 peer seen 동작.
- A1/A6/A11/A12, B1 및 나머지 시나리오 수치/PASS 판정. Phase 2 윈도 상한 게이트는 이번 단계에 적용했다고 주장하지 않는다.

## 커밋

- `988913a`: 코어 필터/인덱스/merge/seen 변경과 회귀 테스트, iOS 탐색 호출 통합.
- macOS List identity 및 leaf View 연결은 별도 후속 커밋이며 최종 SHA는 코디네이터 전달 메시지에 기록한다.
