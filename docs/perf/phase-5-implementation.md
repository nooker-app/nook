# Phase 5 구현 보고서 (macOS 글 목록을 NSTableView로)

main `452dedf` 기준. 측정은 이 worktree에서 `make perf-build`와 `tools/perf/run.sh`로 했다(lib-5k, warm 5회 median/worst ms, 같은 머신·같은 트리에서 두 백엔드). push는 하지 않았다. 체크리스트 ID는 이전 보고서와 같은 `§그룹.항목순서` 표기다.

## 결론

- **A 게이트를 처음으로 통과했다.** 소스 전환의 worstStall이 A1–A13 모두 median 0(List 백엔드는 A10·A13을 빼면 128–146), TTFR median 40–81 ms(List 91–202)다. A14만 median 102/worst 127로 남았고, 남은 비용은 목록 밖이다(아래 "남은 것").
- 바꾼 것은 macOS 글 목록 컬럼 하나다. SwiftUI `List`를 AppKit `NSTableView`(view-based, 1컬럼, 헤더 없음)로 교체했다. 데이터 레이어(`ArticleListWindow`, `DisplayResult`)는 그대로이고, 윈도가 "무엇이 바뀌었는지"를 테이블에 알려 주는 관찰자 하나만 더했다.
- 행 높이는 행을 레이아웃하기 전에 안다. 제목·요약의 한 줄 폭을 한 번 재 두고 컬럼 폭과 비교해 줄 수(각 최대 2)를 정하며, 줄 수별 높이는 실제 행 뷰로 보정한다. List가 행마다 하던 SwiftUI 자동 높이 측정(행당 약 2 ms)이 없어졌다. 이 추정은 SwiftUI 실제 레이아웃과 300개 제목 × 70개 폭에서 줄 수가 하나도 다르지 않았고, 측정 실행에서 높이 보정(`list.row.height`)은 번역 off에서 0이다.
- 기본값은 `table`이다. `-macListBackend list`(또는 `defaults write com.tim.nook macListBackend list`) 하나로 List 백엔드가 그대로 돌아온다. 값은 실행 시 한 번 읽는다.

## 구조

```mermaid
flowchart LR
  F[filter executor<br/>computeDisplayDiff] -->|rows + 텍스트 폭 prefill| S[ReaderStore.applyDisplayed]
  S --> W[ArticleListWindow]
  W -->|observer: replaced / installed / appended / patched| C[ArticleTableController]
  C -->|reloadData / insertRows / removeRows / 셀 재구성| T[NSTableView]
  T -->|heightOfRow| H[ArticleTableRowHeights]
  T -->|didAdd rowView| W
  T -->|selectionDidChange| S
  S -->|selectedID (host body)| C
```

| 변경 | 테이블 동작 |
|---|---|
| 소스 교체(`replaced`) | `reloadData` 1회, 맨 위로(이미 맨 위면 스크롤러 갱신 생략). 테이블·셀은 컬럼이 살아 있는 동안 유지 |
| 같은 소스의 데이터 변경(`installed`) | id diff로 `removeRows`/`insertRows`, 모델이 바뀐 행만 보이는 셀 재구성 + `noteHeightOfRows`. `result.willAnimate`일 때만 slide |
| growth·`ensureVisible`(`appended`) | `insertRows`, 애니메이션 없음 |
| 행 패치(`patched`, 읽음·별표·오프라인) | 보이는 셀만 재구성 |

- growth는 sentinel `onAppear` 대신 `tableView(_:didAdd:forRow:)`에서 `listWindow.rowAppeared`를 부른다. 윈도 끝 50행 안의 행이 실제로 화면에 들어올 때다.
- 셀: `NSTableCellView` 안에 `NSHostingView<ArticleTableCellContent>` 하나. `sizingOptions = []`로 hosting view가 제약을 내보내지 않고, 셀은 `makeView(withIdentifier:)`로 재사용하며 `rootView`만 바꾼다. 행 모양은 List와 같은 `ArticleRowLayout`이고, List의 행 inset(위아래 4 pt)과 `.inset` 스타일, 구분선을 맞췄다(하네스 스크린샷으로 비교).
- 선택 행의 글자색은 `backgroundStyle == .emphasized`일 때 `backgroundProminence = .increased`로 List와 같게 바뀐다.

### 높이

- `ArticleTableRowHeights`(NookKit)가 높이를 낸다. 줄 수별 높이 6개, 별·오프라인 글리프 폭, 텍스트 inset은 실행 후 첫 사용 때 실제 `ArticleRowLayout`을 `NSHostingController.sizeThatFits`로 재서 정한다(`list.table.calibrate`, 약 9 ms 1회).
- 텍스트 폭(`ArticleRowTextWidths`)은 컬럼 폭과 무관하다. 그래서 창·분할 폭이 바뀌면 전체 행 `noteHeightOfRows`가 재측정 없이 산술로 끝난다. 폭은 filter executor가 설치할 prefix를, growth가 다음 200행을 **off-main에서 병렬로** 미리 채운다. 처음에는 `heightOfRow`가 메인에서 쟀는데, growth 1회가 41 ms였다(C1 growMaxMs 41 → 0.6).
- 표시된 행은 자기 SwiftUI 레이아웃 높이를 `onGeometryChange`로 보고한다(`fixedSize`로 자연 높이를 보고하므로 피드백 루프가 없다). 다르면 그 행만 run-loop 턴당 1회 `noteHeightOfRows`로 고친다(행 index는 실행 시점에 다시 계산). 번역 블록의 스트리밍·reveal도 이 경로로 높이를 맞춘다. `MacListRowHeightInvalidator`는 테이블 백엔드에서 쓰지 않는다.
- 카테고리 칩이 있는 행은 0.5 pt 짧고, 번역 행은 0.5 pt 길게 레이아웃됐다. 종류별 첫 보고에서 이 차이를 배워 나머지 행에 적용한다. 그 뒤 보정은 번역 off 0, T2 1회다.

### 선택·키보드·메뉴·swipe·번역

- 선택: 테이블 → store는 `tableViewSelectionDidChange`, store → 테이블은 `updateNSView`(부모가 `store.selectedArticleID`만 읽는 작은 host)다. 테이블은 store가 선택한 글만 선택하고(`ArticleTableSelection.row(following:in:)`), store를 따라 바꾸는 동안에는 되쓰지 않는다. 프로그램 선택(위젯 딥링크, ⌘↓, openArticle)은 `scrollRowToVisible`로 보이게 한다. 모든 테이블 변경 뒤에 다시 맞춘다.
- 키: ↑↓는 NSTableView 기본, ⌘↓/⌘↑는 기존 메뉴 명령, Return/키패드 Enter는 선택 글이 있을 때 브라우저를 연다(이전 `onKeyPress(.return)`). type-select는 껐다(List도 텍스트 행이라 동작하지 않았다). 더블클릭 동작은 이전에도 없었다. 글 드래그는 이전에도 없었다.
- 컨텍스트 메뉴: 오른쪽 클릭 때 그 행에 대해 `NSHostingMenu(rootView: ArticleRowMenu(store:id:))`를 만든다. List와 같은 뷰라 항목·라벨·Categories 하위 메뉴·Open in Browser가 같다. `super.menu(for:)`가 clicked row 윤곽을 그린다.
- swipe: `rowActionsForRow`의 leading에 읽음(accent, `checkmark.circle.fill`/`circle`)과 별표(systemYellow, `star.fill`/`star.slash.fill`). 라벨은 요청 시점의 현재 상태다. full swipe는 첫 action(AppKit 기본).
- 번역: 행 표시/숨김은 `didAdd`/`didRemove` row view에서 `rowAppeared`/`rowDisappeared`, 스크롤 상태는 `NSScrollView` live-scroll 알림에서 `setScrolling`, 테이블이 사라지면 `setScrolling(false)`. box는 셀을 구성할 때(첫 body 전) 넘긴다. 교체 시 `releaseIdleBoxes` 뒤 `reloadData`가 보이는 셀에 새 box를 준다. 높이 계산은 box를 만들지 않는 `displayedState(for:title:)`를 쓴다. 번역 토글은 높이 보고를 비우고 `reloadData`(행 재생성 없이 레이아웃만 교체)하며, 화면 행은 기존 visibility 카운트와 immediate window로 바로 번역된다.

## 측정 (lib-5k, warm median/worst ms, 같은 머신, 최종 HEAD `ee41fdb`)

### A 전환 (게이트: worstStall <100, TTFR ≤150)

| 시나리오 | table worstStall | table ttfr | list worstStall | list ttfr |
|---|---|---|---|---|
| A1 feed-small→All | 0/0 | 59/89 | 129/134 | 189/201 |
| A2 | 0/0 | 79/82 | 144/159 | 174/192 |
| A3 | 0/0 | 81/82 | 146/155 | 183/192 |
| A4 | 0/0 | 74/89 | 138/144 | 167/188 |
| A5 | 0/0 | 54/82 | 142/147 | 191/200 |
| A6 All→feed-big | 0/0 | 65/91 | 132/259 | 199/206 |
| A7 | 0/0 | 66/81 | 139/151 | 193/205 |
| A8 | 0/50 | 72/99 | 128/137 | 175/220 |
| A9 | 0/57 | 66/78 | 130/131 | 202/212 |
| A10 | 0/0 | – | 0/65 | – |
| A11 연속 전환 | 0/0 | 40/47 | 133/305 | 145/148 |
| A12 검색 | 0/0 | – | 131/138 | – |
| A13 | 0/0 | 66/81 | 0/0 | 91/100 |
| A14 선택 있는 전환 | 102/127 | 141/170 | 206/222 | 250/276 |

전환 1회에 구성되는 셀은 8개(`list.rowcontent`, List는 200–400)다. 보이는 행만 만들고 재사용한다.

### B/C/T (게이트: stall ≥100 없음, hitchRatio가 List보다 나쁘지 않음)

| 시나리오 | table | list |
|---|---|---|
| B1 새로고침 none | stall 0, hitch 24 | stall 0, hitch 25 |
| B2 trickle | stall 0, hitch 24 | stall 0, hitch 26 |
| C1 fling | worstStall 0/53, hitch 5.9/27, growMaxMs 0.5 | 0/0, hitch 25.8/26.3, growMaxMs 0.2 |
| C3 ↓ 30 Hz | worstStall 108/144, stalls100 1/2, hitch 388, missed 0 | 235/319, stalls100 5/9, hitch 603, missed 0 |
| T2 번역 on 스크롤 | stall 0, hitch 0 | stall 0, hitch 37 |
| T3 ↓ 30 Hz 번역 on | worstStall 99, stalls100 0 | 507, stalls100 12 |
| T3 번역 off | 129, stalls100 1 | 189, stalls100 1 |
| T4 등속 스크롤 on/off | stall 0, hitch 0 / 1.4 | 139 / 0, hitch 52 / 37 |

T는 1회 실행이라 잡음이 크다. 이전 실행(`p5a`, 이 보고서의 중간 빌드)에서도 같은 방향이었다(T3 on 107 vs 175, T4 hitch 3.3 vs 42).

## 남은 것

- **A14 (median 102, worst 127)**: Time Profiler로 A14 전환 구간을 집계하면 큰 덩어리는 선택이 해제될 때 SwiftUI가 툴바를 다시 만드는 비용이다(`ToolbarBridge.makeStorage`/`updateToolbarBridge` + `NSToolbarView layout`, 해당 구간 샘플의 약 24%). 나머지는 reader pane과 root hosting view의 레이아웃이다. 테이블 쪽은 `reload` 약 6%, 셀 body 약 8%다. 툴바는 이번 범위(목록 컬럼만) 밖이라 손대지 않았다.
- **C3/T3 off (108/129)**: 남은 stall은 키 반복 중 reader의 첫 렌더(`reader.body`)와 선택 이동에 붙은 행 생성 5–6개가 한 턴에 겹친 것이다. 두 백엔드 모두 게이트(stalls100 = 0)를 못 넘지만, 테이블은 stalls100 5 → 1, worst 319 → 144로 줄었다.
- **C1 hitch worst 27**: 5회 중 1회(첫 fling에서 처음 보는 행 다수). median 5.9.
- 사이드바·reader·툴바는 바꾸지 않았다.

## 체크리스트

| ID | 확인 |
|---|---|
| §2.4 | 테이블은 store가 선택한 글만 선택한다. `followStoreSelection`은 store 값만 따르고, 따르는 동안의 selection 변경은 store에 쓰지 않는다. 테스트 `selectionNeverAutoSelects`(교체·숨김 뒤 nil 유지) |
| §2.5 | prune은 store 그대로(전체 결과 기준). 테스트에서 900번째 선택이 윈도를 키워 행 900을 가리킴 |
| §3.1 | `displayedArticles`/`visibleArticles` 경로 변경 없음 |
| §3.3 | `ensureVisible` → `appended` → `insertRows`, 프로그램 선택은 `scrollRowToVisible`. 테스트 `windowChangesMapToTableUpdates`(ensureVisible 700 → insert 400..<750) |
| §3.8 | 빈 상태는 `ArticleListView`가 그대로 `totalCount == 0`으로 판정 |
| §3.9 | `didAdd`/`didRemove` row view에서 translator 호출, growth는 같은 콜백의 `listWindow.rowAppeared`(끝 50행 조건 유지). 화면에 없는 행은 호출되지 않음 |
| §3.10 | 메뉴·swipe 모두 `listedArticle(withID:)`로 해석(stand-in 포함) |
| §3.11 | `list.publish`/`list.body` 그대로. `list.rowcontent` = 셀 구성, `list.row` = 셀 body, `list.row.height`(.flush) = 높이 보정. 신규 `list.table.reload`/`.update`/`.height`(ms)/`.cell.make`/`.cell.reuse`/`.measure`/`.calibrate`, 보정 상세 note `list.table.height.fix` |
| §3.12 | `ArticleListWindow` init 변경 없음. observer는 weak |
| §4.1 | 애니메이션은 `installed(animated: result.willAnimate)`일 때만. reload·growth·ensureVisible은 애니메이션 없음 |
| §7.1 | 행 단위 `.id` 없음(셀 재사용 identifier만) |
| §7.2 | 메뉴는 클릭할 때 `ArticleRowMenu` 하나로, swipe는 요청할 때 만든다. `ListRowMenuEagernessTests` 통과, 측정에서 `rowMenu` 0 |
| §7.3–7.5 | 행은 공용 `ArticleRowLayout`(RelativeTimeText, inline badge, live `isBulkCategorizing`) |
| §8.1 | box는 셀 구성 시(첫 body 전) 전달, 교체 때 idle box 해제 후 reload가 새 box 전달, `displayedState`는 box를 만들지 않음. T2 titleBox 141(List 112) |
| §8.2 | 테이블 백엔드는 invalidator 대신 높이 보고 경로: `Task.yield()` 뒤 턴당 1회, 실행 시점 index, 카운터 유지. (c)(d) retry/NSCollectionView fallback은 해당 없음 |
| §8.3 | 높이는 첫 레이아웃 전에 정해진다(보정 0). 캐시된 번역 행은 `displayedState`의 캐시로 블록 높이를 포함해 추정 |
| §8.4 | live-scroll 알림 → `setScrolling`, 테이블 해체 시 `setScrolling(false)`. 측정에서 `list.scroll.phase`는 PerfDriver의 프로그램 스크롤에서 0(실제 휠만 알림을 보냄) |

## 수동 확인이 필요한 것 (코디네이터/사용자)

- swipe: 트랙패드로 열리는지, 색·아이콘·full swipe 느낌, 두 번째 swipe에서 라벨이 바뀌는지.
- 컨텍스트 메뉴: 모양, Categories 하위 메뉴 체크 표시, Open in Browser, Downloaded stand-in 행의 Remove Download.
- VoiceOver: 행 읽기 순서와 내용(셀은 SwiftUI hosting view, 표는 "Articles" 레이블).
- 라이트 모드 선택 행 색, 비활성 창의 회색 선택.
- 실제 휠 스크롤 중 번역이 시작되지 않는지(live-scroll 알림), 캐시된 번역 행을 빠르게 위로 스크롤할 때 밀림이 없는지.
- 창·분할 폭을 끌 때 행 높이가 따라오는지(재측정 없이 산술).
- 하단 상태 막대: List는 내용이 막대 뒤로 스크롤됐지만, 테이블은 막대 위에서 끝난다(상단 툴바 아래로는 스크롤된다).
- 위젯 딥링크로 오래된 글을 열 때 선택·스크롤(ff13245).
- ja/ko/zh-Hans 등에서 행 높이 보정 수(`list.table.height.fix` note)가 0에 가까운지. 대체 폰트가 더 높은 문자(태국어 등)는 첫 표시 때 1회 보정된다.

## 검증

- 커밋마다 `make build` 통과. 최종 트리에서 iOS `NookiOS` Release 빌드(generic iOS, `CODE_SIGNING_ALLOWED=NO`) 통과.
- `swift test --package-path NookKit --filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness|ArticleTableModel"`: 72개 통과. 신규 `ArticleTableModelTests` 9개(교체/growth/패치 매핑, 증분 diff, body-only 무변경, 자동 선택 없음, 폭별 높이, 보고 높이 무효화, 종류별 보정 학습, prefill 일치, growth prefill).
- `git diff --check`, `plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements` 통과.
- 개발 중 발견한 교착: 폰트를 `NSFont.preferredFont`로 만들면 filter 스레드와 메인 스레드가 같은 static 초기화에서 서로 기다렸다(테스트에서 재현). 고정 크기 system font로 바꿨다.
