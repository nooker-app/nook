# Phase 2 구현 보고서

앱 실행, `tools/perf/run.sh`, push는 하지 않는다.
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

## Fix round 1

main `2b0d275` 기준. 앱 실행, `tools/perf/run.sh`, push는 하지 않았다. main 커밋: `f302715`(리뷰 지적), `5d87545`(C3 선택 invalidation), `ad9da75`(Fix round 1 보고서).

### 리뷰 지적

- **#1 major (데이터 재정렬 = 전체 교체)**: 정렬 순서를 `ListSource.order`에 넣었다. 그래서 정렬 토글은 source 변경으로 처리되어 교체와 `listGeneration` bump가 일어난다. `replacement = !sameIDs && replacesList`이다. 데이터 재정렬(date resolution, 피드 날짜 정정)은 증분 길이 규칙(기존 길이 + 순증가)을 따르며 bump가 없다. 새 rows는 새 full의 prefix이다. `reordered`는 애니메이션 억제에만 쓴다. 테스트: growth로 400행을 만든 뒤 900번째 글의 `publishedAt`을 바꾸면 generation 불변, rows 400, 맨 위가 이동한 글이다. 정렬 토글은 generation +1, rows 200이다. 정렬 테스트는 UserDefaults 선호를 같은 턴에 복원한다.
- **#2 minor (증분 install이 growth 취소)**: `install(..., replacement:)`에서 replacement일 때만 generation을 올리고 growth를 취소한다. 증분 install 뒤 대기 중인 growth Task는 새 prefix에서 이어서 append한다. 테스트: `rowAppeared(row-150)` 직후 증분 install을 해도 rows가 400이 된다.
- **#3 minor (테스트 공백)**: detached 결과 처리 두 경로를 추가했다. 하나는 batch 상태가 바뀌어 버리고 재예약하는 경로로, 실행 횟수 +2를 확인한다. 다른 하나는 윈도가 커져 re-cut하는 경로로, 실행 +1과 rows 750을 확인한다. `computeDisplayDiff` end-to-end 3개 slide(willAnimate, 비교체, rows 203), diff 단위 재정렬/토글 테스트도 추가했다. 오프라인 stand-in은 index, 윈도 patch, 제거 시 index 탈락(prune 근거)을 테스트한다. batch 끝 `hasNew` 플래그는 `batchEndAnimates`로 추출해 네 조합을 테스트한다. stand-in 생성은 순수 static `offlineDisplayArticles(infos:articles:...)`로 분리했다. `OfflineArticleStore.shared`는 테스트 프로세스에서 `~/Library/Application Support/Nook/Offline`에 쓰므로 store 경유 테스트는 하지 않았다. 새 테스트는 수정을 되돌리면 4개가 실패함을 확인했다.
- **NIT 5**: detached 결과가 윈도 확장 때문에만 stale하면 refilter하지 않는다. 대신 메인에서 `rows = full.prefix(max(result.rows.count, current))`로 다시 자른다(비교체 결과만). revision과 batch/bulk가 바뀐 경우에는 기존처럼 재예약한다.
- **NIT 4 (선행 확장 상한)**: 상한을 두지 않기로 했다. List selection은 선택 행이 rows에 있어야 동작하므로 ensureVisible의 깊은 점프는 간격 전체를 한 번에 append한다. 이 append는 이미 `disablesAnimations` 트랜잭션이다(애니메이션 install 안에서 호출돼도 마찬가지). C3 측정의 비용은 append(growMaxMs < 0.3ms)가 아니라 선택마다 일어나는 list body 재평가가 윈도 전체 행 클로저를 다시 실행하는 데서 나왔고, 이는 아래에서 제거했다. 깊은 점프의 1회 비용은 C5 게이트에서 판정한다. 근거는 `ArticleListWindow.ensureVisible` 주석에 남겼다.

### C3/T3 선택 invalidation (Phase 4에서 앞당김)

- 원인: ContentView 루트 body가 `store.selectedArticle`을 읽었다. 읽는 곳은 toolbar의 star 라벨, disabled, share, `readerCommandActions`(focusedSceneValue), 브라우저 overlay였다. `selectedArticle`은 `articles`도 관찰한다. 그래서 ↓ 한 번마다 루트가 재평가됐다. 루트는 매번 새 클로저로 `FeedSidebar`를 만들어 sidebar body도 재실행되고, `ArticleListView` body와 그 안의 inline `ForEach`가 윈도 전체(~1,200행)의 행 클로저를 다시 실행했다(`list.rowcontentx7212`).
- 수정:
  - star/share는 leaf(`SelectedStarToolbarButton`, `SelectedShareToolbarMenu`)로 옮겼다. 메뉴 명령 바인딩은 배경 leaf `ReaderCommandActionsPublisher`가 `focusedSceneValue`로 게시한다. 브라우저 패널은 `SelectedArticleBrowserPanel`로 옮겼다.
  - 루트는 nil ↔ non-nil일 때만 바뀌는 `ReaderStore.hasSelectedArticle`만 읽는다(Mark Read disabled, share 슬롯 존재).
  - `ForEach`는 별도 뷰 `ArticleListRows(store:titleTranslator:)`로 분리했다. 입력이 같은 참조이므로 바깥 list body가 재평가돼도 행 클로저는 다시 실행되지 않는다. 행 클로저는 `listWindow.rows` 변경(install, patch, growth)에서만 실행된다. DEBUG 카운터 `list.rows.body`를 추가했다.
  - `List(selection:)`, 키보드 포커스, ⌘↓/⌘↑, 위젯 딥링크(`onOpenURL` → `selectSmartSource`), 자동 선택 금지 규칙은 변경하지 않았다.
- 검증: `ListSelectionInvalidationTests`가 실제 `NSHostingView` + `List(selection:)`로 확인한다. 분리된 rows 뷰는 선택 5회 이동에서 행 클로저 0회이고 rows 변경 시에는 재실행된다. 대조군인 inline + 선택 관찰 body는 매 이동마다 재실행된다.
- C1/T4 hitchRatio: rowAppeared 자체는 관찰 쓰기가 없다(translator는 `@Observable`이 아님). 하지만 growth와 patch는 `listWindow.rows`를 바꾸고, 수정 전에는 이것이 바깥 `ArticleListView` body 전체(searchable/toolbar/status bar 포함)를 재평가시켰다. 분리 후 growth는 rows 뷰만 무효화한다. 다만 growth 1회는 macOS List 특성상 여전히 윈도 전체 행 클로저를 실행한다(O(window)). 그래서 깊이 fling할수록 비용이 커지는 구조는 남는다. 이 부분은 ArticleRowModel(Phase 4) 또는 NSTableView(Phase 5)에서 판정한다. 성능 PASS는 주장하지 않으며, C1/C3/T3/T4 재측정은 코디네이터 게이트다.

### 검증

- `make build`, iOS `NookiOS` generic device Release 빌드(`CODE_SIGNING_ALLOWED=NO`, `-skipPackagePluginValidation`) 통과.
- `swift test --package-path NookKit`: **631 tests / 85 suites** 통과.
- `git diff --check`와 `plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements` 통과. 생략한 체크 없음.
- 실제 UI 확인(toolbar star/share 표시, 메뉴 명령 활성화, 브라우저 패널 전환 애니메이션, 정렬 토글 후 스크롤 위치)은 코디네이터 게이트다.

## Fix round 2

### 리뷰 지적과 관찰 경계

- **A1**: Star와 Mark Read의 disabled 조건을 각 leaf의 `selectedArticle == nil`로 복원했다. ID만 남은 Downloaded stand-in/피드 제거 직후에는 버튼이 비활성화된다. Share는 루트의 `hasSelectedArticle` 조건을 제거하고 leaf의 `if let`으로 표시를 결정한다. 브라우저 열기 이벤트의 selectedArticle 조회도 별도 메서드로 옮겨 root body 안의 직접 조회를 없앴다.
- **A2**: 선택을 관찰하는 outer body + 별도 rows view 조합을 추가했다. outer 카운터는 선택마다 증가하고 row closure는 증가하지 않아야 한다. 저장소 소스를 읽는 guard로 root의 selectedArticle 재도입과 바깥 ArticleListView의 generation identity/ForEach 재도입도 검사한다. offline stand-in 테스트 이름과 주석은 실제 검증인 제거 후 index 탈락에 맞췄다(선택 prune 실행을 주장하지 않는다).
- **A3**: Fix round 1의 작업 브랜치 언급을 없애고 main의 실제 커밋 참조로 수정했다. 이번 커밋은 cherry-pick 후 해시가 바뀌므로 subject로 기술한다: `fix: coalesce list replacement row evaluation`.

### 교체 publish의 중복 row-content 평가

- fix1은 `.id(store.listGeneration)`을 읽는 부모 List 아래에 `listWindow.rows`를 관찰하는 ArticleListRows를 뒀다. 교체에서 generation과 rows가 함께 바뀌면 이전 자식의 rows 관찰 갱신과 새 identity의 자식 생성이 겹쳐 행 클로저가 두 번 실행될 수 있다.
- ArticleListRows leaf가 rows snapshot과 `.id(listGeneration)`을 함께 읽고 List(selection:)을 만든다. ForEach는 snapshot을 값으로 받는 ArticleListRowContents 자식에 둬 기존 identity의 자식이 새 rows를 직접 관찰하지 않게 했다. 바깥 ArticleListView는 storage/empty/chrome만 관찰하며 generation과 rows는 읽지 않는다. List binding 평가가 leaf를 재실행해도 snapshot 자식의 입력이 같으면 행 클로저는 재실행되지 않는다. per-row tag, 번역 onAppear/onDisappear, 별도 growth callback, deferred menu/swipe child, Enter 및 native List identity reset은 유지한다.
- NSHostingView의 행 클로저 카운터로 기존 구조와 새 구조를 비교한다. headless macOS List는 새로 mount할 때도 200행의 클로저를 400회 실행하므로 절대 1회/행을 주장하지 않는다. 동일 환경의 fresh List 비용을 기준으로 교체 1회가 수정 구조에서는 1배(400회), 기존 구조에서는 2배(800회)인지 검사하고, 선택 5회 이동은 추가 row-content 0회인지 검사한다. 단순히 List/ForEach를 같은 body에 합치면 선택 때 행 클로저가 재실행되어 snapshot 자식을 유지해야 한다. 이 카운터는 DEBUG `list.rowcontent`와 같은 ForEach closure 위치를 센다. 실제 ContentView를 import하는 앱 테스트는 아니므로 C3 root/sidebar=0, rowcontent 약 2.6k/run, T3 약 950 및 A1/A6/A11/A12/T1 재측정은 코디네이터 게이트다.

### Phase 4에 남기는 reader 증거

- 제공된 C3 key-repeat 측정에서 30Hz 선택 이동 때 `reader.body`에 귀속된 0.1–0.36초 stall이 남는다. 새로 선택한 글마다 reader pane이 렌더되는 비용이며 이번 수정 범위에서 reader를 변경하지 않았다.
- fix1 warm lib-5k 측정은 Phase 2 대비 A1 worstStall 173→247ms, A6 170→260ms, A11 172→346ms, A12 178→269ms, T1(번역 off) TTFR 360→537ms였다. rowcontent/switch는 A1/A6 400→800, A11 800→1480이었다. 이는 수정 전 증거이며 이번 수정의 성능 결과로 해석하지 않는다.

### 검증

- 최종 macOS `make build`, iOS `NookiOS` generic device Release 빌드(`CODE_SIGNING_ALLOWED=NO`, `-skipPackagePluginValidation`) 통과.
- `swift test --package-path NookKit`: **635 tests / 85 suites** 통과. 선택을 관찰하는 outer, fresh List 대비 교체 비용, 기존 구조의 2배 대조군, 선택 5회 추가 row-content 0회, 소스 관찰 경계 guard 포함.
- `git diff --check`, `plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements` 통과. 초기 sandbox 캐시 접근 실패 후 외부 실행으로 재시도했다. NSHostingView 테스트의 NSTableView reentrant delegate 경고는 통과 로그에도 나타나며 실제 앱 오류로 단정하지 않는다.
- 로그: `/private/tmp/nook-p2f2-build.log`, `/private/tmp/nook-p2f2-ios.log`, `/private/tmp/nook-p2f2-tests.log`, `/private/tmp/nook-p2f2-selection.log`.
- 필수 체크 생략 없음. 앱 실행, tools/perf/run.sh, push 및 실제 UI/성능 측정은 요청에 따라 수행하지 않았다.
