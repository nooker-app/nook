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
