# Phase 2 구현 보고서

작업 브랜치: `feature/perf-p2`. 앱 실행, `tools/perf/run.sh`, push는 하지 않는다.
체크리스트 ID는 Phase 1 보고서와 같은 `§그룹.항목순서` 표기다.

## Phase 1 리뷰 수정

- 동기 필터는 호출자 Task의 취소를 무시하고, detached 필터만 취소 predicate를 전달한다. 취소된 Task에서 작은 라이브러리를 다시 필터해도 목록과 선택을 유지하는 테스트를 추가했다.
- 배치 시작 때 기존 debounce를 취소한 뒤 1.5초 trailing에 재등록한다. 연속 데이터 변경은 deadline을 미루지 않고, 사용자 전환은 즉시 실행하며 대기 필터를 취소한다.
- latest-wins fixture 절반을 읽음으로 설정해 All 1,000개와 Unread 500개를 구분한다. precomputed install의 library index/All count, trailing deadline, animation predicate 회귀 테스트를 추가했다.
- `listGeneration`은 source 변경과 row ID 변경이 함께 있을 때만 증가한다. 같은 ID 결과를 반환하는 All→Unread나 단일 피드→동일 폴더는 기존 스크롤을 보존한다. 별도 scroll-to-top 이벤트는 추가하지 않았다.
- 필터/카테고리 fallback 전환 후 중복 필터 예약을 제거하고, toggleStarred 조회를 library index로 변경했다.
- 본문이 비보유 상태인 글의 새 본문은 bodyCache에만 들어가는 Phase 1 정책은 유지한다. 다음 hydration 전 reader가 본문 없는 기존 사본을 볼 수 있는 트레이드오프다.

## Phase 2 구현

- `ArticleListWindow`의 관찰 표면은 `rows`와 `totalCount`다. full/index/generation/growth task는 관찰에서 제외한다. 초기화는 빈 값만 만들며 I/O나 Task를 시작하지 않는다.
- 전체 결과와 윈도는 `ArticleListContents` 참조를 공유한다. full 배열을 두 프로퍼티가 각각 보관해 매 토글마다 전체 CoW 복사가 생기는 것을 피한다. `displayedArticles`는 observable revision을 읽는 computed full result이며 `visibleArticles`/iOS/OfflineDownloadPicker의 전체 목록 계약을 유지한다. 관찰 회귀 테스트로 off-window patch도 full consumer에 통지되고 macOS rows는 재게시되지 않는 것을 확인한다.
- 필터 executor에서 `computeDisplayDiff → DisplayResult`가 ID 배열/전체 index/행 비교/애니메이션 조건/초기 prefix를 준비한다. 메인 설치는 준비된 참조/배열을 대입한다. 빈 query와 600개 미만 동기 경로는 유지한다. Downloaded의 capped offline index 경로도 기존처럼 동기다.
- row 비교는 title/summary/read/star/date/feed/readMinutes/categories와 feed title/offline saved snapshot을 포함한다. body와 hasExplicitPublishDate는 제외한다. filteredIDs와 articles는 한 메인 액터 턴에서 함께 캡처한다.
- 전체 교체는 `min(total, max(200, selectedIndex + 50))`, 작은 변경은 기존 길이 + 양의 순증가를 유지한다. 정렬로 겹친 행의 상대 순서가 바뀌면 source 변경 없이도 bounded prefix를 재생성한다. 동일 ID 소스 전환은 기존 윈도와 스크롤 위치를 유지한다.
- 끝 50행의 onAppear는 번역기의 rowAppeared/rowDisappeared와 별개로 growth를 요청한다. single-flight Task가 yield 뒤 최대 200개를 append하며 애니메이션을 끈다. 강제 전체 prefetch나 임의 상한은 도입하지 않았다. 한 번의 요청이 앞서가는 범위는 +200이며 이후 sentinel이 실제 나타나야 다음 요청이 발생한다.
- selection didSet에서 ensureVisible을 호출해 직접 binding, ⌘↓/next/previous, openArticle을 모두 포함한다. 필터 install 중 선택이 바뀌면 최신 선택을 다시 보장한다. navigation/prune/retain은 전체 결과 index를 사용한다.
- read/star는 index lookup으로 공유 full 원소와 윈도 안의 원소만 패치한다. detached 결과가 그 사이의 flag patch를 덮지 못하도록 revision과 request generation을 검사한다. detached 작업 중 윈도가 확장됐으면 새 길이로 재계산해 stale prefix로 축소하지 않는다. 완료 Task 참조도 해제해 결과 배열을 불필요하게 보유하지 않는다.
- macOS ContentView만 `ForEach(store.listWindow.rows)`와 totalCount 기반 empty state를 사용한다. per-row id를 추가하지 않았고, menu/swipe child와 translator visibility callback을 유지한다.

## 검증 및 체크리스트

Phase 1 리뷰 수정 커밋: `d8d7d22`.

- Phase 1 macOS `make build`, iOS generic device Release 빌드, SwiftPM 614 tests / 83 suites, diff check, plutil 통과.
- 초기 sandbox 캐시 권한 실패 뒤 승인된 외부 실행으로 검증했다. cold 빌드가 끝나기 전 재시도한 중복 실행은 Xcode DB lock으로 실패했으며, 종료 뒤 각각 재실행해 성공을 확인했다.
- Phase 2 `make build`와 SwiftPM **621 tests / 84 suites** 통과(ListRowMenuEagernessTests 포함), `git diff --check`와 plutil 통과. iOS `NookiOS` generic device Release 빌드도 통과. 최종 검증 생략 항목 없음. `MainThreadLog`/tools/perf/measurement.md는 변경하지 않고 recordListPublish 호출 인자만 실제 macOS List의 window 길이에 맞춘다. 성장/ensureVisible은 list.window.grow/행 관찰로 별도 추적한다.

소스 감사와 자동 테스트 대응:

| 체크리스트 | 검증 |
|---|---|
| §2.1–§2.3, §2.7–§2.9 | Phase 1 navigation/filter 테스트 유지; fallback 중복 필터 제거, latest-wins 구분 fixture |
| §2.4–§2.6, §2.10–§2.11 | full index 기반 prune/retain/navigation; 900번째 선택 보존, previous/next, missing ID nil 테스트; browser sync 호출 유지 |
| §3.1–§3.4 | full observable 결과와 window rows 구분, 200행 시작/900번째 확장, full flag patch와 full navigation 테스트 |
| §3.5–§3.7 | row projection 필드 감사, 동일 캡처 generation, request generation/revision guard, 600 threshold와 query detached 유지 |
| §3.8–§3.10 | macOS empty totalCount, 별도 growth onAppear와 기존 translator 콜백, offline stand-in/menu fallback 경로 유지 |
| §3.11–§3.12 | 기존 list counter 의미 유지: publish는 result install당 1회이며 rows=a→b와 publishRows에는 macOS List에 전달하는 window 길이를 기록, grow counter 추가, init I/O/Task 없음 |
| §4.1–§4.3 | animation predicate 회귀 테스트, replacement/reorder/growth 무애니메이션, batch/search 전달 조건 유지 |
| §6.1 | seen은 full displayed result를 계속 사용; Phase 1 HLC/skip 테스트 유지 |
| §7.1–§7.2 | 행 id 없음, 단일 menu/swipe child 유지; ListRowMenuEagernessTests 실행 대상 포함 |

메인 설치의 diff/index/prefix 계산은 제거했지만, 기존 foreground `markVisibleArticlesSeen`의 full 스캔과 새 register 기록은 유지한다. 선택이 detached capture 이후 윈도 밖으로 이동한 예외에서는 ensureVisible이 필요한 prefix를 메인에서 append한다. Swift Array가 외부 consumer나 in-flight snapshot과 공유될 때의 CoW 비용은 여전히 발생할 수 있으므로 실제 O(1) wall time을 보장한다고 주장하지 않는다.

## 보류와 측정 게이트

- C3/T3 선택의 root/sidebar invalidation은 Phase 4로 보류한다. 제공된 측정은 30Hz ↓ 입력에서 worst stall 0.59–0.82초, 5초당 ≥100ms stall 13–14회, sidebar.body 약 30회다. ContentView의 toolbar selectedArticle 읽기와 `readerCommandActions`/`focusedSceneValue`가 루트 관찰을 만들며, 이를 옮기려면 명령/브라우저/toolbar 관찰 경계를 함께 분리해야 한다.
- `MacListRowHeightInvalidator`는 변경하지 않는다. 윈도 축소 뒤 C6/C7 재측정은 코디네이터가 담당한다.
- 실제 UI의 swipe/context menu 20회 전환, List focus/selection, 스크롤바 thumb/End, 번역 높이, widget, iOS 튜토리얼/picker 검증은 코디네이터 게이트다.
- first publish, TTFR, worstStall, growMaxMs 등 성능 PASS를 빌드/테스트로 주장하지 않는다.
- 최종 로그: `/private/tmp/nook-p2-build.log`, `/private/tmp/nook-p2-ios.log`, `/private/tmp/nook-p2-tests.log`. Phase 1 로그는 같은 이름의 `nook-p2-p1-*` 파일이다.
- `tools/perf`, `docs/perf/measurement.md`, PerfDriver, native row-height invalidator 변경 없음. push와 앱 실행 없음.
