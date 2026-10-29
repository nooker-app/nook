# Phase 4 구현 보고서 (행 비용, reader 비용, 번역 행 높이)

main `2668222` 기준. 앱 실행, `tools/perf/run.sh`, push는 하지 않았다. 체크리스트 ID는 Phase 1·2 보고서와 같은 `§그룹.항목순서` 표기다. 성능 PASS는 주장하지 않는다. 숫자는 코디네이터 측정 게이트다.

## 결론

- 행 1개를 만들 때 하던 일 가운데 행이 그리는 데 필요 없는 일을 걷어냈다. 이제 행은 off-main에서 만든 `ArticleRowModel` 값만 그린다. 번역 블록은 번역이 생긴 행에만 생성한다. feed, 오프라인, 카테고리 조회는 행 생성 경로 밖으로 옮겼다.
- reader pane은 키 반복 중에 렌더하지 않는다. 선택이 멈춘 뒤 150 ms가 지나면 마지막 글만 렌더한다. 단독 선택(클릭, 키 1회, D1)은 같은 트랜잭션에서 즉시 반영된다.
- 번역 box는 행의 첫 body에서 생성한다. 목록이 교체되면 작업이 없는 box를 해제한다. macOS 스크롤은 `onScrollPhaseChange`를 `setScrolling`에 연결했다. 행 높이 무효화는 run-loop 턴당 테이블마다 `noteHeightOfRows` 1회로 합쳤다. 동기 `layoutSubtreeIfNeeded`는 제거하지 않았고, 대신 테이블당 1회로 줄였다(이유는 아래).
- 사이드바(항목 5)는 보류했다.

## 행 1개의 비용: 무엇을, 왜 덜어냈나

앱을 실행할 수 없어서 프로파일 대신 행 뷰 트리를 읽었다. 측정 trace에 나온 비용 단위와 대조했다.
- 전환: `list.rowx33` 동안 0.187 s, 즉 행당 약 5 ms.
- growth: `list.title.boxx101`.

| 위치 | 이전 | 문제 | 변경 |
|---|---|---|---|
| ForEach 클로저 (윈도 전체 200–1,200행 × 매 rows 변경) | `store.feed(for:)`, `titleTranslator.box(for:)` | 화면에 나오지 않는 행까지 rows가 바뀔 때마다 feed 사전을 조회하고 box를 intern했다. growth 1회에 box 약 100개가 생겼다. 클로저가 `feedsByID`를 읽으므로 피드 메타데이터가 바뀔 때도 행 패스가 다시 돌았다. | 클로저는 model을 감싸기만 한다. box는 행 body에서 만든다(항목 3). |
| 행 입력 값 | `Article` 전체 (bodyParagraphs, contentHTML 포함) | SwiftUI가 패스마다 행 입력을 필드 단위로 비교하는데, 비교 대상에 본문이 포함됐다. | `ArticleRowModel` 11개 필드. `ArticleRow`는 model 기준 `Equatable`이고 `.equatable()`을 붙였다. |
| 번역 블록 | 모든 행이 `ListTitleTranslationBlock` 전체를 생성했다. 구성은 Image + 반복 `symbolEffect(.pulse)`, `String(localized:)` 2회, RoundedRectangle 배경, padding ×3, transaction, `ExpandRevealModifier`(@State 3개 + onChange), AnimatableModifier, 사용자 Layout, preference다. | 번역이 꺼져 있거나 아직 dwell 전인 행, 즉 거의 모든 행이 보이지도 않는 0높이 서브트리를 만들었다. 이 블록은 행에서 가장 큰 서브트리다. | `ListTitleTranslationSlot`을 추가했다. box에 상태가 생긴 적이 있을 때만 블록을 만든다. 상태는 `layoutRevision > 0`이거나 캐시 hit이다. |
| 행 body 조회 | `OfflineArticleStore.shared.isSaved`(`loadIfNeeded` + 사전), `ReaderStore.shared.categories(forArticle:)` | 카테고리 조회가 `categoriesByID` 관찰을 모든 행에 등록했다. 그래서 카테고리 정의가 바뀌면 보이는 행 전부가 무효화됐다. | 오프라인 여부는 model에 넣었다. 카테고리는 `ArticleRowCategoryBadges` leaf로 옮겨, 카테고리가 있는 행만 정의를 live로 해석하고 관찰한다. |

유지한 비용(필요하거나 측정 없이 줄일 근거가 없는 것):
- 제목과 요약 2줄 텍스트 레이아웃.
- `RelativeTimeText`. formatter는 이미 locale별로 캐시된다. 27cf8fa, c56e8f7에 따라 렌더러를 유지한다.
- 행 루트의 `MacListRowHeightInvalidator` NSView. 번역 높이를 맞추는 데 필요하다. 지연 생성하면 첫 샘플을 무시하는 규칙과 충돌해 첫 번역의 높이 무효화를 놓친다.
- `Text("·")`와 `"%lld min"`. 문자열 카탈로그 항목이 있어서 verbatim으로 바꾸지 않았다.

C3에서 측정한 행당 20–35 ms에는 같은 stall에 묶인 `reader.body` 5–15회가 섞여 있다. 따라서 그 값은 행 생성 비용만이 아니다. 이 부분은 항목 2가 다룬다.

### ArticleRowModel과 diff

- 필드는 `id, feedID, title, summary, isRead, isStarred, publishedAt(Date), feedDisplayTitle, readMinutes, categories(ids), isSavedOffline`이다. `RowProjection`을 제거하고, `computeDisplayDiff`의 identical 판정을 model 비교로 바꿨다. 행이 그리는 필드가 바뀌면 재게시되고, 본문 hydration이나 `hasExplicitPublishDate`만 바뀌면 재게시되지 않는다. 이를 테스트로 확인한다.
- diff와 행에는 feed의 **display title**(사용자 이름)을 넘긴다. 검색은 기존처럼 feed `title`을 쓴다. 이름을 바꾸면 `feeds` didSet의 debounced 필터가 비교에서 차이를 잡아 install한다. 이전에는 행이 feed를 live로 읽었으므로, 이제는 debounce(배치 중 1.5 s)만큼 늦게 반영된다.
- `DisplayResult.rows`는 off-main에서 만든 model prefix다. 메인에서 model을 만드는 경우는 셋뿐이다.
  - growth와 ensureVisible이 append한 구간
  - patch한 행 1개
  - 윈도 확장 re-cut
- 윈도가 install 때 받은 feed title과 saved 집합으로 만든다.
- 오프라인 저장과 제거는 `listWindow.setSavedOffline`으로 행을 즉시 패치한다. bulk 다운로드도 글마다 반영된다. 이어지는 refilter가 install 1회로 정리한다.
- 메뉴와 swipe child는 id만 받는다. body에서 `store.listedArticle(withID:)`로 다시 조회하는데, 조회 순서는 library, 그다음 표시 결과다. 표시 결과를 보는 이유는 오프라인 stand-in이 거기에만 있기 때문이다. 라벨은 현재 read/star 상태를 따른다.

## Reader pane: settle (항목 2)

- `ReaderSelectionSettler`가 판정한다. 직전 선택 변경으로부터 150 ms 이상 지난 변경과 nil은 같은 트랜잭션에서 즉시 반영된다. 150 ms 안에 들어온 변경은 반복으로 보고 보류하며, 선택이 150 ms 동안 멈추면 마지막 id만 반영한다.
- `selectedArticleID` didSet(macOS)이 값이 실제로 바뀔 때만 이를 호출한다. `ReaderDetailView`는 `store.readerArticle`을 읽는다.
- 그 결과 다음은 그대로다.
  - 목록 선택, toolbar, 브라우저 패널, 메뉴 명령은 즉시 선택을 따른다.
  - 자동 선택은 없다(78f5655).
  - D1(500번째 행 선택)은 단독 변경이므로 이전과 같은 경로로 즉시 렌더된다.
- 측정 의미의 변화: C3 같은 키 반복에서는 첫 키에 reader가 1회 렌더되고, 반복이 끝난 뒤 150 ms가 지나 1회 렌더된다. 그래서 C3의 `readerTTFR`(selection 시작부터 첫 reader.body까지)은 첫 키 기준으로 기록된다. 보류된 선택마다 DEBUG `reader.selection.held`를 센다. 측정 도구와 카운터의 의미는 바꾸지 않았다.

## 번역 box (항목 3)

- `box(for:title:)`는 행 body에서 처음 호출될 때 box를 만든다. 즉 box는 행이 처음 body를 평가할 때 이미 존재한다. 새로 만든 box는 `state(for:title:)`와 같은 cache 조회로 seed한다. seed는 `layoutRevision`을 올리지 않는다. 그래서 캐시된 행이 나타나도 높이 무효화가 생기지 않는다.
- `releaseIdleBoxes()`는 `activeTasks`와 `dwellTasks`가 모두 없는 box를 버린다. 목록 교체 install에서 `ArticleListWindow.onReplacement` 훅으로 호출되며, 새 List identity가 렌더되기 전 메인 액터 안에서 실행된다. 교체 뒤에는 이전 행 뷰가 모두 사라지므로, box를 쥔 행이 남지 않는다.
- `rowDisappeared` 시점에는 해제하지 않는다. 숨겨진 행의 hosting cell은 body를 다시 돌리지 않고 다시 보일 수 있다. 그 행은 버려진 box를 계속 관찰하게 되고, "Translating…"에서 멈출 수 있다. 그래서 box 수의 상한은 교체 사이에 사용자가 본 행 수다.
- `setState`는 기존 box에만 쓰고 고아 box를 만들지 않는다. 결과는 cache에만 남는다. `cancelAll`은 같은 참조를 유지하고, `layoutRevision`은 단조 증가한다.
- slot이 스트리밍 상태(`.translating`)로 블록을 삽입하면, 삽입한 레이아웃에서 바로 전체 높이를 차지하고 내용만 fade in한다(`opensInsertedHeight`). 이전에는 0.32 s 동안 높이가 커졌고, 프레임마다 행 높이 무효화가 일어났다. 이제 행 높이는 1회만 바뀐다. 블록이 이미 있던 행이 다시 보일 때와 hide 경로는 기존 애니메이션을 그대로 쓴다. iOS는 기본값 false라서 변화가 없다.

## 스크롤 훅과 높이 무효화 (항목 4)

- `ArticleListRows`의 List는 `onScrollPhaseChange`로 `setScrolling(phase != .idle)`을 호출한다. iOS RootView와 같은 계약이다. 교체되거나 사라진 List는 `.idle`을 보내지 않으므로 `onDisappear`에서 `setScrolling(false)`를 호출한다. DEBUG `list.scroll.phase`로 macOS List에서 phase가 실제로 오는지 측정에서 확인한다. T2/T4에서 0이면 이 훅은 동작하지 않는 것이고, 그때는 NSScrollView live-scroll 알림으로 바꿔야 한다.
- `MacListRowHeightCoalescer`의 동작은 다음과 같다.
  - 한 턴에 무효화를 요청한 probe를 weak 집합에 모은다.
  - `Task.yield()` 다음에 모은 probe를 한 번에 처리한다.
  - 처리 시점에 `row(for:)`/`row(at:)`로 index를 다시 계산하고, 테이블마다 IndexSet `noteHeightOfRows`를 1회 호출한다.
  - 기존 규칙은 그대로 유지한다: 첫 샘플 무시(`ListRowHeightInvalidationTracker`), `needsAttachmentRetry`와 `viewDidMoveToWindow` 재시도, NSCollectionView fallback, `invalidateHostingHierarchy`, 카운터 `list.row.height`(probe당)와 `list.row.height.flush`(턴당).
- **동기 `layoutSubtreeIfNeeded`는 유지했다. 단, 테이블·턴당 1회다.** 7fc1767의 조건은 "캐시된 번역 행이 첫 레이아웃부터 맞는 높이"다. 이 조건은 실제 창에서 빠르게 위로 스크롤해 봐야만 확인할 수 있다. 헤드리스 테스트는 NSTableView의 행 높이 캐시와 화면 표시 주기를 재현하지 못한다. 확인할 방법이 없으므로 제거하지 않았다. 행이 N개면 레이아웃 N회가 1회로 줄고, 행이 처음 삽입될 때 높이를 한 번에 여는 변경으로 프레임마다 생기던 요청도 없어졌다. 제거 여부는 C6/C7과 수동 확인을 거친 뒤 결정할 일이다.

## 리뷰 nit (항목 6)

- `rootSelectionObservationGuard`는 이제 `struct ContentView`부터 첫 leaf struct 직전까지 검사한다. 그래서 `private extension ContentView`도 포함된다. 멤버 선언 단위로 `store.selectedArticle` 읽기를 찾고, 이벤트 전용인 `resolvePresentedBrowserMode`만 허용한다. `browserGrabber`에 읽기를 넣으면 실패하는 것을 확인했다.
- `replacementEvaluatesRowsOnce`에 generation을 올리지 않고 rows만 바꾸는 경우 2개를 추가했다. append(500)와 `rows[0] = 900`이다. snapshot 자식이 다시 실행되고 ForEach가 새 값을 받았는지(카운터에 기록한 값) 검사한다.
- 새 소스 guard `rowAndReaderSourceGuard`를 추가했다. 행 클로저와 행 body에 feed, offline, category, box, 블록 조회가 없는지, 메뉴와 swipe가 id를 받는지, 날짜가 `RelativeTimeText(model.publishedAt)`인지, reader가 `readerArticle`을 쓰는지 검사한다.

## 보류

- **사이드바(항목 5)**: 피드별 관찰 box나 Equatable 행, `ungroupedFeeds`/`feeds(inFolder:)` 캐시. 이번 측정의 stall은 사이드바에 귀속되지 않았다. Phase 2 fix에서 선택 시 sidebar.body가 이미 0이 됐다. §9의 아이콘 슬롯, flash, 섹션 순서 회귀 위험을 감안해 이번 범위에서는 뺐다.
- `rowDisappeared` 시점의 box 해제(위 이유).
- `layoutSubtreeIfNeeded` 제거(위 이유).
- reader의 첫 렌더 비용 자체(HTMLContentView). settle로 렌더 횟수만 줄였다.

## 체크리스트

| ID | 확인 |
|---|---|
| §3.5 | model이 행이 그리는 모든 필드를 포함하고, body와 hasExplicitPublishDate는 제외. 테스트 `modelEquality`(hydration은 identical, 이름·saved·category·minutes 변경은 아님). reader는 id로 library를 조회 |
| §3.9 | 행마다 translator `rowAppeared`/`rowDisappeared`와 별도 growth onAppear 유지 |
| §3.10 | stand-in: 메뉴·swipe가 `listedArticle`(표시 결과 fallback)로 해석. `windowBuildsModels`의 `article(withID:)` |
| §3.11 | 기존 카운터 위치와 의미 유지. 추가: `list.scroll.phase`, `reader.selection.held`. 기존 `list.title.box.release`(deinit)는 이제 실제로 증가할 수 있음 |
| §3.12 | ArticleListWindow init은 빈 값만 만들고 I/O·Task 없음 |
| §7.1 | 행 단위 `.id` 없음 |
| §7.2 | `.contextMenu { ArticleRowMenu(store:id:) }`, `.swipeActions { ArticleRowSwipeActions(store:id:) }` 각 child 1개, body에서 재조회. ListRowMenuEagernessTests 통과 |
| §7.3 | model은 `publishedAt: Date`만 갖고, 행은 `RelativeTimeText(model.publishedAt)`로 그림(소스 guard) |
| §7.4 | inline badge + 0폭 투명 칩 유지, `.animation(..., value: model.categories)` |
| §7.5 | `isBulkCategorizing`은 렌더 시점에 live로 읽고, badge는 `categoriesByID`로 live 해석 |
| §8.1 | box는 첫 body에서 생성, cache seed, 작업 중에는 해제 안 함, 고아 없음, cancelAll 참조 유지(`boxLifetime`, `noOrphanBox`) |
| §8.2 | (a)–(f) 유지, IndexSet 병합 |
| §8.3 | IntrinsicRevealLayout 피드백 없음, @State seed, 동기 cache 조회(seed 포함), `guard clamped > 0` 유지. 병합은 첫 레이아웃을 미루지 않음(삽입은 즉시 전체 높이) |
| §8.4 | macOS `setScrolling` 연결, fillSlots는 `!isScrolling`일 때만, configure의 reset 유지 |

## 검증

- `make build` 통과.
- iOS `NookiOS` generic device Release 빌드(`CODE_SIGNING_ALLOWED=NO`, `-skipPackagePluginValidation`) 통과.
- `swift test --package-path NookKit` 전체: 커밋 분할 전 최종 트리에서 645개 테스트, 86개 suite 통과. 분할 뒤 한 번 더 돌린 전체 실행은 Phase 4와 무관한 AppKit HTML import 테스트(`ReaderTypographyTests.importPathsAgree` 등)에서 멈춰 코디네이터가 중단했다. 전체 suite는 코디네이터가 main에서 다시 돌린다.
- 커밋마다 Phase 4 관련 suite만 `--filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness"`로 돌려 통과했다(최종 58개 테스트, 9개 suite).
- `git diff --check`와 `plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements` 통과.
- 커밋마다 `make build` 통과. iOS 빌드는 최종 트리에서만 실행했다.

### 코디네이터 게이트

- A1–A12: `list.row`가 있는 stall의 행당 비용과 TTFR.
- C3: 반복 중 `reader.body` 약 0, `reader.selection.held` > 0, worstStall.
- T3: `list.title.box`가 growth에 묶이지 않는지, `list.title.box.release` > 0.
- T2/T4: `list.scroll.phase` > 0, `list.row.height.flush` ≤ `list.row.height`.
- 수동 확인:
  - 번역이 처음 나타날 때 높이가 즉시 열리고 fade되는지
  - 캐시된 번역 행을 빠르게 위로 스크롤할 때 밀림이 없는지
  - 키 반복 중 reader가 첫 글에 머물다가 멈춘 위치로 바뀌는지
  - 메뉴와 swipe 라벨이 바뀌는지
  - Downloaded stand-in의 메뉴가 동작하는지
  - 피드 이름을 바꾼 뒤 행에 반영되는지

## Fix round 1

main `ea35ab6` 기준. 이번에는 워크트리에서 `make perf-build`와 `tools/perf/run.sh`로 직접 측정했다(lib-5k, warm, median/worst ms). 기준선(`ea35ab6`)도 같은 머신에서 다시 쟀다. 코디네이터 측정과 절대값이 다르다. 예를 들어 이 머신의 T4 hitchRatio는 기준선에서 이미 62였다. 그래서 아래 비교는 같은 머신의 before/after로만 읽어야 한다. 원인은 추측하지 않고 `--xctrace 'Time Profiler'`로 A1, A14, T4를 기록한 뒤 메인 스레드 샘플을 시나리오 구간별로 집계해 찾았다.

### 결론

- 전환 1회의 메인 스레드 작업량은 약 250 ms에서 약 190 ms로 줄었다. 가장 큰 단일 항목은 행이 아니라 **사이드바**였다. 전환마다 사이드바 body가 피드 300개 행과 그 컨텍스트 메뉴를 다시 만들었고, 비용은 전환당 40–70 ms였다.
- 행 1개를 만드는 비용은 이제 대부분 AppKit이 정한다. 남은 비용은 약 3–4 ms/행이다. 이 가운데 NSTableView 자동 행 높이(`_automaticRowHeightsUpdateVisibleRowViews` → 행마다 `NSHostingView` `sizeThatFits`)가 35행 기준 약 69 ms이고, 그중 텍스트 측정이 약 22 ms다. 행의 SwiftUI 그래프 생성(swipe, contextMenu, onAppear, equatable)은 35행에 약 7 ms뿐이다. 코디네이터 로그의 "행당 6–11 ms"는 같은 stall에 묶인 사이드바 재렌더와 자동 높이 측정이 합쳐진 값이었다.
- **A 게이트(<100 ms)는 SwiftUI List로는 닿지 않는다고 본다.** 남은 stall(약 130 ms)의 구성은 보이는 행 약 35개의 자동 높이 측정과 첫 레이아웃·렌더, 툴바 갱신, 200행 윈도의 outline diff다. 앱 코드에서 더 걷어낼 덩어리가 없다. 이 비용을 없애려면 고정 또는 캐시된 행 높이, 셀 재사용, 전환마다 테이블을 다시 만들지 않는 구조가 필요하다. 이것은 Phase 5(NSTableView)의 범위다.

### 커밋과 각각이 줄인 것

| 커밋 | 내용 | 측정 |
|---|---|---|
| fix: clear row offline badge when expired downloads are purged | 리뷰 LOW. `purgeExpiredOffline`이 지운 id를 `offlineCopiesRemoved`에 넘긴다. 이 함수는 `listWindow.setSavedOffline(id, false)`로 행을 패치한 뒤 refilter한다. 테스트 `purgeClearsOfflineBadge` | 동작 수정 |
| perf: keep source switches from re-running the sidebar's feed rows | 사이드바 섹션을 equatable child(`FeedSidebarSections`)로 옮겼다. 선택 하이라이트는 행별 `SidebarSelectionState`가 읽는다. 피드와 폴더 메뉴는 열 때만 만든다(`DeferredMenuContent`) | A1 프로파일에서 전환당 `FeedSidebar.feedRow`/`feedContextMenu`(`feedFolders` 정렬) 약 40 ms, outline diff와 메뉴 preference 약 25 ms가 사라짐. A1 TTFR 271→201 |
| perf: build plain macOS list rows while title translation is off | 번역이 꺼져 있으면 box, slot, reveal preference, 행 높이 probe NSView를 만들지 않는다. 설정을 토글하면 List identity에 포함된 값이 바뀌어 다시 측정한다. 행의 onAppear 훅 2개를 1개로 합쳤다 | 번역 off에서 titleBox: 전환당 35→0, T4 150→0, C1 142→0 |
| perf: clear a hidden selection inside the list install transaction | 선택이 숨겨지는 전환에서 prune을 install 트랜잭션 안으로 옮겼다. 이전에는 교체되는 List와 reader가 이를 별도 변경으로 처리했다 | A14 readerBody 2→1 |
| fix: keep the push transition on quick reader-pane navigation | 리뷰 NIT. `ReaderSelectionSettler.passingThrough`로 reader-pane next/previous는 hold를 거치지 않는다. 호출자의 `withAnimation` 안에서 반영되고, 목록 키 반복은 그대로 합쳐진다. 테스트 `navigationPassesThrough` | 동작 수정 |

### 측정 (같은 머신, `ea35ab6` → `0447bc2`)

| 시나리오 | 지표 | before | after |
|---|---|---|---|
| A1 | worstStall / ttfr | 147/157 · 271/292 | 128/129 · 201/201 |
| A6 (`--only`) | worstStall / ttfr / stalls100 | 145/147 · 271/284 · 2 | 130/143 · 203/217 · 1 |
| A8 (`--only`) | worstStall / ttfr / stalls100 | 147/152 · 282/300 · 2 | 135/157 · 206/222 · 1 |
| A14 | worstStall / ttfr / readerBody | 205/211 · 329/337 · 2 | 201/225 · 246/258 · 1 |
| C1 | hitchRatio / stalls100 | 30.7 · 0 | 32.6 · 0 |
| C3 | worstStall / stalls100 | 236/256 · 9/11 | 122/226 · 1/4 |
| T3 off | worstStall / stalls100 | 250/271 · 14.5/17 | 274/379 · 12.5/15 |
| T4 off | worstStall / hitchRatio / titleBox | 89/177 · 62 · 150 | 90/181 · 68 · 0 |
| T3 on | worstStall / stalls100 | 444/467 · 14/16 | 506/659 · 14.5/16 |
| T4 on | worstStall / hitchRatio | 175/176 · 43 | 89/178 · 60 |

전체 switch.json 1회(after)의 A2–A13 worstStall은 130–153 ms였다. 코디네이터의 p4 실행은 150–180 ms였다. A10은 66, A13은 0이다. 예외가 하나 있다. 전체 실행의 A8은 242/260이었고, 5회 중 3회에서 install과 행 생성이 한 run-loop 턴에 합쳐졌다. `--only A6,A8`로 따로 돌리면 기준선보다 낫다(위 표). 앞 시나리오에 따라 달라지는 타이밍 문제로 보이며, 코디네이터의 전체 재측정에서 확인해야 한다. T는 반복 1회 × 2실행이라 잡음이 크다.

### 항목별 결과

1. **오프라인 badge (LOW)**: 수정과 테스트를 마쳤다. **NIT**: 수정과 테스트를 마쳤다.
2. **행 생성 비용**: 위 결론 참고. 번역 off 행에는 번역 장치가 없다. 행 안의 조건부 뷰(`if isStarred`, `if isSavedOffline`, badge `.transition`)는 `DynamicLayoutViewAdaptor`로 전환당 약 8 ms다. 행 모양이 바뀌지 않으면 없앨 수 없어서 남겼다.
3. **A14**: 코디네이터 로그의 `reader.bodyx3, list.rowcontentx402` stall은 A14의 **setup**(`selectIndex 499` → ensureVisible이 윈도를 549행으로 늘리고 reader가 렌더) 구간이었다. 시나리오 측정 구간이 아니다. 시나리오 안에서 A1보다 더 드는 비용은 두 가지다. 하나는 선택 해제에 따른 reader 처리로, prune을 옮겨 줄였다. 다른 하나는 breadcrumb의 글 제목 crumb가 사라지면서 생기는 NSToolbar 재배치(`NSToolbarView layout`, toolbar preference)로, 전환당 약 30 ms다. 공유 버튼을 비활성 상태로 남겨 보는 실험은 효과가 없어서 되돌렸다.
4. **T4 off**: 남은 stall은 등속 스크롤 중 윈도 growth(`list.window.grow`, rowcontent 602, relativetime 32)다. 기준선에서도 2회 중 1회 나타나므로 Phase 4 배선 때문이 아니다. 프로파일에서 `onScrollPhaseChange`/`setScrolling`이 차지하는 샘플은 없었다. 코디네이터 측정의 T3 stalls100 "두 배"는 이 머신에서 재현되지 않았다(기준선 14.5, after 12.5).
5. **install + 재생성**: 전환당 비용은 outline이 200행 윈도 전체를 훑는 `diffRows`(행마다 `isGroupRow` → ForEach item) 약 12 ms와 테이블 teardown 약 3 ms다. `.id` 재생성 자체는 싸다. 큰 비용은 새 테이블의 첫 레이아웃이다. 교체 윈도를 200행보다 줄이면 diff는 줄지만, 보이는 행이 35개라 첫 렌더 직후 growth가 바로 일어난다. 그래서 바꾸지 않았다.

### 기타

- `sidebar.body` 카운터는 전환당 여전히 1이다. 임시 프로브 테스트로 확인한 결과, `List(selection:)`을 가진 body는 바인딩을 `@Bindable`로 만들든 `Binding(get:set:)`으로 만들든 선택이 바뀔 때마다 다시 실행된다. 다시 실행되는 것은 껍데기뿐이고, 섹션과 피드 행은 다시 만들어지지 않는다(`sidebarRow` 0).
- 검증 결과는 다음과 같다.
  - 커밋마다 `make build` 통과. 헝크로 나눈 사이드바 커밋은 따로 checkout해서 빌드했다.
  - `git diff --check` 통과.
  - `swift test --filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness"`(600 s 제한): 61개 통과.
  - iOS 빌드는 하지 않았다. 변경은 `#if os(macOS)` 경로와 macOS 앱 타깃에 한정된다. 공용 코드에서 바뀐 것은 `offlineCopiesRemoved`(iOS에서는 refilter만 한다)와 settler의 `passingThrough`(macOS에서만 호출)다.
- 수동 확인이 필요한 것:
  - 번역 설정을 켤 때 캐시된 번역 행의 높이. List가 다시 만들어지므로 화면 행의 번역은 dwell(1.5 s) 뒤에 시작된다.
  - 사이드바 하이라이트, 폴더 접기, 드래그 앤 드롭 대상 표시.
  - 피드와 폴더 컨텍스트 메뉴의 내용(다중 선택 라벨 포함).
  - reader에서 next/previous를 빠르게 두 번 눌렀을 때 push 전환이 보이는지.

## Fix round 2

main `53e39c7` 기준. 측정은 이 worktree의 `make perf-build`와 `tools/perf/run.sh`로 했다. push는 하지 않았다.

### 결론

- **T4 회귀의 원인은 행의 지역화 문자열 조회였다.** 행 메타데이터 줄의 `Text("·")` 2개와 `Text("\(n) min")`이 새 행이 나타날 때마다 키를 environment locale로 해석했다. macOS에서는 이 경로(`localizedAttributedStringForKey:` → `_copyStringTable` → plist 파싱)가 매번 string table을 다시 읽는다. 등속 스크롤 13 s 동안 메인 스레드 샘플 3,685개 중 645개(약 17%, 새 행당 약 4 ms)가 여기에 쓰였다. 문자열을 한 번만 해석해 verbatim으로 그리도록 바꿨다. 이 비용은 p2f2에도 있었다. 수정 후 T4는 p2f2보다 낫다.
- **스크롤 중 rowcontent 증가는 회귀가 아니었다.** T4만 단독으로 실행하는 스크립트(T3 종료 상태에 의존하지 않음)로 재면 rowcontent가 p2f2, a94b0e9, HEAD 모두 829–833으로 같다. 코디네이터 표의 262 대 474 차이는 T3가 끝난 위치(선택 행과 윈도 길이)가 달라서 생긴다. growth stall에서 `rowcontent x436`도 p2f2에 있던 동작이다(p2f2 growth stall에도 `list.rowcontentx1682`, `x1414`가 있다). closure 실행은 값 하나를 감쌀 뿐이라 싸다. stall의 실제 비용은 보이는 행의 높이 측정이다.
- **f27c9d0(plain row)는 CPU를 늘리지 않았다.** bisect에서 hitch가 a94b0e9→f27c9d0 사이에서 올라 보였다(T4 단독 평균 43→60). 하지만 Time Profiler로 보면 plain row와 translating row의 T4 메인 스레드 작업량은 같다(3,685 대 3,844 샘플). hitch 지표는 실행마다 ±15 정도 흔들린다. 다른 worktree의 빌드와 실행이 같은 머신에서 돌았기 때문으로 보인다. plain row는 그대로 두었다.
- 사이드바 MEDIUM, 번역 토글 LOW, NIT 2개는 모두 수정했다. A14(약 200 ms, breadcrumb 툴바 재배치)는 손대지 않았다.

### 커밋

| 커밋 | 내용 |
|---|---|
| fix: redraw the sidebar's My Nook row while following it | 리뷰 MEDIUM. `FeedSidebarSections`가 `isFollowingOwnFeed`를 필드로 갖고 `==`에서 비교한다. 타입 문서에 규칙을 적었다: `sections`가 읽는 `FeedSidebar`의 모든 `@State`/`@AppStorage`는 비교 필드여야 한다. 감사 결과 나머지 state는 action에서만 쓰이거나 `body` modifier(alert, sheet, action bar)에서만 읽힌다. 소스 guard `sidebarSectionsCompareReadState`를 추가했다. action 전용 allowlist에 없는 state가 섹션 필드와 `==`에 없으면 실패한다 |
| perf: resolve list row metadata strings once | T4 회귀. `ArticleRowStrings`가 `·`, `Unknown Feed`, `%lld min`(값별 캐시, `AppLanguage.formattingLocale`)을 한 번만 해석한다. UI 언어는 재실행할 때만 바뀌므로 캐시가 낡지 않는다. 문자열 카탈로그 키는 그대로다 |
| fix: translate on-screen list titles as soon as translation turns on | 리뷰 LOW. 리뷰의 (b)안에 순서 문제 대응을 더했다. ① `ListTitleTranslator`가 id마다 보이는 행 뷰 수를 센다. 교체 중에는 이전 테이블과 새 테이블의 행이 함께 보이므로, 마지막 행 뷰가 사라질 때만 작업을 취소한다. AppKit이 appear와 disappear 중 무엇을 먼저 부르든 결과가 같다. ② 켠 뒤(또는 언어·provider 변경 뒤) 1 s 안에 나타난 행은 dwell을 건너뛴다. `finish`의 재스케줄은 카운트를 올리지 않도록 `scheduleTranslation`을 직접 부른다. 테스트 `enableRebuildTranslatesAtOnce`가 두 순서를 모두 검사하고, 창 밖 행은 여전히 dwell을 기다리는지도 검사한다 |
| fix: keep an animated publish's hidden-selection clear outside its spring | NIT. install 안의 prune은 `!result.willAnimate`일 때만 한다. 애니메이션 in-place publish는 전처럼 install 뒤에 prune한다. 전환(A14)은 애니메이션이 없으므로 install 안에서 prune한다 |
| test: drive the offline badge purge test through purgeExpiredOffline | NIT. `purgeExpiredOffline(maxAge:purge:)`로 store 호출을 주입한다. 테스트가 실제 전달 경로를 거치고, 공유 오프라인 저장소(디스크)는 건드리지 않는다. 윈도 밖 행(row-250)이 나중에 growth로 만들어질 때 badge가 없는지도 검사한다 |

### T4 bisect (T4 단독 스크립트, translation off, hitchRatio)

스크립트는 `{"setup": selectSmart all, "action": constantScroll 1500 px/s × 12 s}`이다. rowcontent는 모든 빌드에서 829–833, worstStall은 0이다.

| 빌드 | hitchRatio (실행별) |
|---|---|
| p2f2 `2668222` | 49.6, 47.3, 36.1 |
| a94b0e9 | 40.3, 41.3, 48.6 |
| f27c9d0 | 60.1, 49.7, 69.0 |
| HEAD 이전(`0b64bb1`, p4f1+사이드바) | 67.6, 59.0, 65.1 |
| 같은 빌드, `onScrollPhaseChange` 제거(실험) | 65.2, 61.5, 58.2, 77.5 (`T3,T4` 실행) |
| 같은 빌드, 항상 translating row(실험) | 25.3, 56.9, 38.7 |
| **문자열 수정 후 (`3e34996`)** | **32.2, 29.0, 30.4, 26.5** |

Time Profiler(T4 구간, 메인 스레드)의 결과는 다음과 같다.
- 수정 전에는 `NSTableRowData _doAutomaticRowHeightForRowView` 1,387샘플 중 `LocalizedStringKey.resolve` 645, `_copyStringTable` 459, plist 파싱 353이었다.
- 수정 후에는 `_doAutomaticRowHeightForRowView` 1,221샘플이고, 지역화 관련 샘플은 0이다.
- 남은 행 비용은 SwiftUI 텍스트 레이아웃(`NSStringDrawingEngine`, 약 600)과 stack layout이다.

### 측정 (코디네이터 방식, before = `53e39c7`/`0b64bb1`, after = `3e34996`/`911de1b`)

| 시나리오 | 지표 | before | after |
|---|---|---|---|
| T4 off (`--only T3,T4`) | hitchRatio (실행별) | 71.9, 64.2, 73.6, 87.7, 85.2, 69.1 | 27.1, 33.8, 46.6 |
| T4 off | worstStall | 0 ×5, 177(growth) ×1 | 0, 0, 0 |
| T3 off | worstStall / stalls100 | 288–717 (중앙값 435) / 3–16 | 222, 177, 169 / 6, 4, 5 |
| T4 on (`--only T3,T4`) | hitchRatio / worstStall | 81.0 / 0, 68.4 / 181 | 43.9 / 0, 51.4 / 0 |
| T3 on | worstStall / stalls100 | 273 / 6, 565 / 15 | 324 / 8, 200 / 7 |
| A1 (warm 중앙값, 2회) | worstStall / ttfr | 128 / 202, 131 / 196 | 125 / 195, 122 / 185 |
| A14 (warm 중앙값, 2회) | worstStall / ttfr | 206 / 246, 201 / 245 | 200 / 242, 200 / 243 |

A1과 A14의 after는 `911de1b`(최종 HEAD)에서, T4 off의 after는 `3e34996`에서 쟀다. 이후 커밋은 번역기 visibility 카운트, prune 위치, 테스트뿐이며 번역 off 스크롤 경로를 바꾸지 않는다.

### 남은 것

- **A 게이트(<100 ms)와 A14**: 그대로다. A1의 남은 stall 약 120 ms는 전환 1회에 보이는 행 35개의 자동 높이 측정(텍스트 레이아웃)과 첫 렌더다. A14에는 breadcrumb 재배치 약 30 ms와 reader 처리가 더해진다. 문자열 수정이 행 생성 비용을 조금 줄였지만(A1 ttfr 약 −10 ms) 게이트에는 닿지 않는다. fix round 1의 판단은 그대로다. 고정 또는 캐시된 행 높이와 셀 재사용이 필요하고, 이는 Phase 5 범위다.
- **growth stall**: growth는 ForEach closure를 윈도 전체에 대해 다시 실행한다(p2f2와 같다). stall이 될 때의 비용은 같은 턴에 다시 측정되는 보이는 행이다. 이번 after 실행에서는 T4에서 growth stall이 재현되지 않았다(T4 on 1회에서 growth가 있었지만 stall은 50 ms 미만). 근본 처리는 Phase 5 범위다.
- **A그룹 hitchRatio 상승**: 이번 A1과 A14의 before/after는 같은 범위(420–890)였다. T4에서 확인했듯 이 지표는 머신 부하에 따라 ±15% 흔들린다. 같은 시점에 같은 머신에서 다시 재야 비교할 수 있다.
- **수동 확인**:
  - 번역을 켰을 때 화면 행이 1.5 s를 기다리지 않고 바로 번역되는지.
  - My Nook을 처음 팔로우할 때 spinner가 나타났다가 사라지는지, 버튼이 비활성화되는지.
  - 행 메타데이터 줄(`·`, "n min")이 ja/ko/zh-Hans에서 이전과 같은지.

### 검증

- 커밋마다 `make build` 통과. `git diff --check` 통과.
- `swift test --package-path NookKit --filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness"`(600 s 제한): 63개 통과.
- 전체 suite와 iOS 빌드는 실행하지 않았다. 공용 코드에서 바뀐 것은 다음과 같다.
  - `ListTitleTranslator`의 visibility 카운트. iOS도 같은 rowAppeared/rowDisappeared 쌍을 부르므로 동작이 같다.
  - `ReaderStore`의 macOS 블록 안 prune 조건과 `purgeExpiredOffline` 분리.
