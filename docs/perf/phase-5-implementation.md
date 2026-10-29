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

## Fix round 1

main `1cf6234` 기준. 리뷰(review-p5) 7건을 고쳤고, C3/T3·A14의 남은 stall은 원인을 확인했지만 줄이지 못했다. 측정은 이 worktree에서 `make perf-build` + `tools/perf/run.sh`로 했다(lib-5k, warm 5회 median/worst ms, T는 1회).

### 고친 것

| # | 문제 | 수정 |
|---|---|---|
| 1 | growth나 교체 install이 먼저 행을 선택하면 store의 선택(⌘↓, 위젯 딥링크, openArticle)이 화면 밖에 남음 | 선택 동기화를 NookKit `ArticleTableSelectionSync`로 옮겼다. store가 바꾼 선택은 `pendingScrollID`로 기억하고, 그 행이 생기는 첫 `follow`에서(이미 선택돼 있어도) `scrollRowToVisible`한다. 사용자가 고른 선택은 스크롤하지 않는다 |
| 2 | `reloadData`/`insertRows`/`removeRows`/이동으로 테이블 선택이 빠지면 store에 nil을 써 reader가 닫힘 | 모든 테이블 변경을 `selection.mutate { }`로 감싼다. 그 안의 selection 변경은 store로 가지 않고, 끝나면 store 선택을 다시 맞춘다 |
| 3 | 재사용·패치된 셀은 레이아웃 높이가 같으면 보고하지 않아 틀린 추정이 남음 | 셀이 구성될 때마다 `version`을 올리고 `onGeometryChange(for: HeightReport(version, height))`로 보고한다. 같은 높이여도 구성마다 한 번 보고된다(독립 AppKit 하네스로 확인: 버전 없는 보고는 재사용 때 0회, 버전 보고는 1회) |
| 4 | 테이블이 사라질 때 화면 행의 translator visibility가 남음 | 컨트롤러가 `didAdd`/`didRemove`로 화면 id 개수를 세고, `dismantle`에서 남은 개수만큼 `rowDisappeared`를 부른다 |
| 5 | 애니메이션 없는 갱신·`noteHeightOfRows`가 0초 context 밖에서 돌았음 | `willAnimate`가 아닌 insert/remove/move, `refresh`·리사이즈·보정의 `noteHeightOfRows`를 모두 `withoutAnimation`(duration 0, implicit animation off)에서 실행한다 |
| 6 | `rowIndex(of:)`가 `rows.count`를 tracked read | `_rows.count` |
| 7 | 폭·높이 캐시가 계속 커짐 | `ArticleRowTextWidths`는 filter executor에서 prefill 전에 `max(10_000, 결과 크기)`를 넘으면 설치할 결과의 id만 남긴다(off-main). `ArticleTableRowHeights.measured`는 소스 교체 때 2,000개를 넘으면 새 전체 결과에 있는 id만 남긴다 |

- 추가로 찾은 교착: `+[NSFont initialize]`가 prefill 작업 스레드에서 처음 돌면 메인 스레드를 기다리는 알림을 보내고, 그동안 메인이 그 스레드를 기다리면 멈춘다. 테스트 묶음 실행에서 재현됐다(`ListSelectionInvalidationTests` 레이아웃 중 메인 대기). 앱은 시작 때 메인에서 NSFont를 이미 만들지만, `ArticleRowTextWidths.prepareFonts()`를 메인에서 prefill을 켜기 전에 부르게 했다(앱 시작, 테스트 suite init).
- 테스트: 실제 `NSTableView`(view-based) 하네스로 3개를 더했다. growth가 먼저 선택한 store 선택의 스크롤, 설치 전에 선택된 딥링크의 스크롤, 선택 행 이동·교체 뒤 행 수를 넘는 선택에서 store에 쓰지 않음과 사용자 선택은 store로 감. 그리고 캐시 상한 테스트 1개. 수정을 되돌리면 앞의 3개가 실패한다(store에 `nil`이 써지고, `scrolledTo == []`).

### 측정 (before = 코디네이터 측정 `1cf6234`, after = 이 라운드)

| 시나리오 | before | after | 게이트 |
|---|---|---|---|
| A1–A13 worstStall | 0 (A8/A9 worst 56–60) | 0 (A2/A8 worst 46/58) | <100 PASS |
| A1–A13 ttfr | 43–85 (worst ≤117) | 35–80 (worst ≤96) | ≤150 PASS |
| A14 worstStall / ttfr | 92/110, 137/149 | 92/101, 143/155 (최종 트리) | <100 경계 |
| C1 worstStall / hitchRatio | 0, 3 | 0/0, 5.1/30 | PASS |
| C3 worstStall / stalls100 | 123/1 | 106/124, 1/1 | stalls100 = 0 FAIL |
| T3 번역 on / off worstStall (stalls100) | 104 / 115 | 107 (1) / 115 (3) | |
| T1 on/off, T2, T4 | stall 0 | stall 0 | PASS |

- 스위치·스크롤·T 실행은 `36d14bb`(아래 툴바 실험 포함)에서, A14 최종값은 실험을 뺀 최종 트리 `1a77627`에서 쟀다. B1/B2는 이번 라운드에 다시 돌리지 않았다(테이블 변경 경로만 바뀜).
- A14 setup(All에서 499번째 선택)에는 0.17–0.25 s stall이 있다. before도 같은 자리에 reader 첫 렌더로 0.17–0.22 s가 있었고, 지금은 선택 행으로 스크롤하는 비용(growth + `heightOfRow` 101회)이 더해졌다. 이게 수정 1의 올바른 동작이다. 측정 구간 밖이다.

### 남은 것

- **C3/T3 (단일 ~105–125 ms)**: STALL은 모두 `reader.body` 1–2회이며, 행은 5–8개다(`list.row`). 키 반복이 끝난 뒤 settle된 선택으로 reader가 처음 렌더되는 턴이다. 테이블 쪽 비용은 아니고 reader 첫 렌더를 줄여야 한다. 이번 라운드에서는 안전하게 할 방법을 찾지 못했다.
- **A14 (~90–100 ms)**: A14 Time Profiler에서 메인 스레드 busy 샘플의 20%가 툴바다. `-[NSToolbarView layout]` 632, `updateToolbarBridge`(preferencesDidChange) 162, `NSToolbarItemViewer dealloc` 31이고, 이것이 setup과 전환마다 한 번씩 난다. 두 가지를 시험했다.
  - 선택이 없을 때 Share 항목을 지우지 않고 disabled로 두기: 툴바 비율 19.8%, A14 89/119로 차이가 없었다.
  - breadcrumb(principal)를 고정 폭 520으로: A14 72/86으로 내려갔지만, 툴바 샘플 비율은 20.0%로 그대로라 잡음 범위다. 게다가 시각 변경(좁은 창의 overflow, 가운데 정렬)이라 검증 없이 넣을 수 없다.
  - 그래서 둘 다 넣지 않았다. 다음 후보는 breadcrumb의 폭 변화를 막는 것이다. 툴바 재구성의 실제 trigger(어떤 항목의 preference 변화인지)를 SwiftUI 쪽에서 더 좁혀야 한다.
- **A6 hitchRatio 이상값(worst 1729)**: 4번 실행한 worst가 256 / 0 / 842 / 763, median은 0–215다. 측정 구간의 frame이 1–2개뿐이라, frame 하나가 늦으면 수백이 된다. 잡음이다. worstStall은 4번 모두 0(worst ≤60)이다.
- 수동 확인: 위젯 딥링크·⌘↓로 깊은 글을 열 때 행이 보이는지(수정 1). 정렬이 바뀌는 새로고침에서 reader가 닫히지 않는지(수정 2). 대체 폰트 제목이 재사용 셀에서 잘리지 않는지(수정 3).

### 검증

- `make build` 통과, iOS `NookiOS` Release(generic iOS, `CODE_SIGNING_ALLOWED=NO`) 통과.
- `swift test --package-path NookKit --filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness|ArticleTableModel"`: 76개 통과, 3회 연속. 폰트 수정 전에는 이 묶음이 교착으로 멈췄다.
- `git diff --check` 통과.

## Fix round 2

main `dec200e` 기준. 남은 두 stall(C3/T3의 키 반복, A14의 선택 있는 전환)을 없앴다. 원인은 둘 다 목록 밖이었다. 하나는 선택이 바뀔 때마다 SwiftUI가 툴바 항목을 전부 다시 만드는 것이고, 다른 하나는 글이 바뀔 때마다 reader 뷰 전체를 새로 만드는 것이다. 측정은 이 worktree에서 `make perf-build` + `tools/perf/run.sh`로 했다(lib-5k, warm median/worst ms, A/B/C/D/R은 5–7회, T는 1회). before는 같은 머신에서 `dec200e`를 다시 빌드해 잰 값이다. 이번 라운드 이전 값은 코디네이터 측정이다.

### 1. 툴바: breadcrumb 격리, Share는 지우지 않고 비활성 (`2577220`)

- C3 Time Profiler에서 메인 스레드 샘플의 12.7%가 `AppKitWindowController.updateToolbarBridge`였고, 9.4%가 그 안의 `ToolbarBridge.makeStorage` → `AppKitToolbarItem.makeGroupItem`이었다. 이 경로는 ↓ 한 번마다 툴바 항목을 새로 만든다.
- trigger를 실험으로 좁혔다.
  - Star/Mark Read/Share 버튼이 선택을 읽지 않게 상수로 바꿨다: 12.7% 그대로였다. 이 버튼들은 원인이 아니다.
  - breadcrumb(principal 항목)가 선택 글을 읽지 않게 바꿨다: 0.4%로 떨어졌다. breadcrumb의 글 제목·피드 segment가 바뀌면 SwiftUI는 툴바 항목 목록이 바뀐 것으로 보고 전부 다시 만든다.
- 수정: `WindowBreadcrumbToolbarHost`(NSViewRepresentable)가 `WindowBreadcrumb`를 자기 `NSHostingView`에 담는다. 툴바 항목의 SwiftUI 내용은 이제 바뀌지 않는다. breadcrumb는 store를 직접 관찰하고, 바뀐 크기만 intrinsic size로 툴바에 전한다. 폭은 전처럼 내용을 따라 늘고 줄며 최대 520이다.
- A14에서는 선택이 비워질 때 Share 항목이 툴바에서 사라지는 것도 같은 재구성을 일으켰다(`NSToolbarItemViewer dealloc`, `updateToolbarBridge` 약 6%). 그래서 Share를 Star·Mark Read처럼 남겨 두고, 선택이 없으면 비활성으로 둔다. fix round 1에서는 이것만 따로 시험해 차이가 없었는데, breadcrumb가 매번 재구성을 일으키고 있었기 때문이다.

**시각 변화** (`docs/perf/phase-5-fix2-toolbar.png`, 위에서부터 before/after 쌍. 전체 글 + 선택, feed-big + 선택, 안 읽음 + 선택 없음. perf 빌드 창을 `screencapture -l`로 찍었다)

- 글이 선택돼 있을 때: breadcrumb와 버튼 모양·위치가 before와 같다.
- 선택이 없을 때: 툴바에 비활성 Share 버튼(`square.and.arrow.up` + 화살표)이 보인다. before에는 Share가 없었다. 그 폭만큼 오른쪽 검색 필드가 좁아지고 버튼 묶음이 왼쪽으로 옮겨진다.
- breadcrumb가 별도 hosting view라 툴바의 SwiftUI environment는 상속하지 않는다. 쓰는 것은 `.font(.callout)`과 foreground style뿐이라 화면상 차이는 없었다. hover 펼침(MiddleCrumbSegment)은 hosting view 안에서 그대로 동작한다. 다만 자동 측정이 없으므로 수동 확인이 필요하다.

### 2. reader를 글마다 새로 만들지 않고 제자리 갱신 (`5965233`)

- lib-5k 글은 HTML 없이 짧은 문단 하나다. 그런데도 reader 렌더 한 턴이 70–120 ms였다. 비용은 본문이 아니었다. 글이 바뀔 때마다 `articleReader`의 `.id(article.id)`가 reader 그래프 전체를 새로 만들었다. 다시 만들어지는 것은 버튼·메뉴(AppKit pop-up), confirmationDialog, translationPresentation, swipe 모니터, overlay다.
- 실험 R1(글 0 → 1 선택, 7회): 그대로는 worstStall 108/114, readerTTFR 116이었다. 머리말만 렌더하면 71이었다. `.id`를 빼면 0/53, readerTTFR 51이었다.
- 수정:
  - reader의 identity는 `readerPushID`이고, reader 이전/다음(`navigateReader`)에서만 바뀐다. push 전환(`.transition(.push)`)은 이전/다음에서만 보이던 것이므로 그대로다. 목록 클릭·키·메뉴 명령은 애니메이션이 없어 전에도 전환이 보이지 않았다. 이제 이런 변경은 제자리 갱신이다.
  - 스크롤: `ScrollPosition`을 두고 `onChange(of: article.id)`에서 `scrollTo(edge: .top)`. 임시 계측으로 확인했다. reader를 아래로 스크롤한 뒤 다른 글(문서 788 pt > 화면 692 pt)을 고르면 첫 프레임부터 offset이 맨 위(-52, 툴바 inset)였고, 같은 NSScrollView가 재사용됐다.
  - 글별 `@State`가 있는 하위 뷰만 `.id(article.id)`를 단다: 요약 카드/버튼(`isExpanded`), `HTMLContentView` 두 곳(anchor namespace, flash), 댓글(`showsAll`). 본문 전체(`readerBody`)에 id를 달면 방문한 글(“더 이상 온라인에 없음” 알림)로 바꿀 때 64/77이 남아서 `HTMLContentView`에만 달았다.
  - 하단 Share 메뉴(`ArticleShareMenu`)에는 id를 달지 않는다. pop-up 버튼 재생성만으로 한 번에 약 35 ms였다(R2 readerTTFR 78 → 40). 이 메뉴의 상태는 1.5초짜리 "copied" 체크 표시와, 열려 있는 동안 창을 막는 저장 sheet뿐이다. 따라서 복사 직후 1.5초 안에 다른 글로 바꾸면 체크 표시가 새 글의 Share 버튼에 남았다가 꺼진다. 받아들인 차이다.
  - 제자리 갱신이라 글이 바뀌는 것 자체가 애니메이션되면 안 된다. `.animation(value: translationBusy/isReparsing)`은 `SameArticleFlag`(같은 글에서 값이 바뀔 때만 다름)로 바꿨다. 추출 완료 시 번역을 다시 시작하는 `onChange`는 같은 글의 상태 변화에서만 동작한다(`ReaderContentChange`).
  - `.task(id: article.id)`(번역 리셋, 언어 감지, 읽음 dwell), 요약 task, typography(AppStorage)는 그대로다. reader에는 find 기능이 없다. iOS 코드는 바꾸지 않았다.

### 측정 (before = `dec200e` 같은 머신, after = `5965233`)

| 시나리오 | before | after | 게이트 |
|---|---|---|---|
| C3 ↓ 30 Hz worstStall / stalls100 | 111/123, 1/1 | **0/72, 0/0** | stalls100 = 0 PASS |
| T3 번역 on worstStall (stalls100) | 120/136 (1), 코디네이터 | **50 (0)** | PASS |
| T3 번역 off | 88/117, 코디네이터 | **0 (0)** | PASS |
| A14 worstStall / ttfr | 96/109, 145/160 | **65/69, 111/113** (다른 실행 0/0, 93/110) | <100 / ≤150 PASS |
| A1–A13 worstStall / ttfr | 0, 70–80 | 0 (A2/A12 worst 43/46), 38–80 (worst ≤92) | PASS |
| D5 이전/다음 20회 worstStall / readerTTFR | 107/118, 274/307 | **0/0, 206/216** | |
| R2 방문한 글로 선택 worstStall / readerTTFR (신규 스크립트) | 97/123, 99/129 | **0/58, 49/60** | |
| C1 worstStall / hitchRatio | 0, 3 (코디네이터) | 0/0, 8/49 | |
| B1 / B2 worstStall | 0 / 0 | 0 / 0 | PASS |
| T1/T2/T4 on·off | stall 0 | stall 0 | PASS |

- 툴바 수정만 넣은 중간 빌드에서는 C3가 115/118로 그대로였다. 툴바는 키마다 일어나던 일이지만 stall 턴의 주인은 reader였다. 툴바만으로 줄어든 것은 A14다(0/0, ttfr 93/110).
- C3 stall 턴은 키 반복이 끝난 뒤가 아니라 시작에서 났다. 첫 ↓는 settler를 그대로 통과해 reader를 즉시 렌더한다. 같은 턴에 이어지는 키 3–4개와 행 6개가 붙어 110–125 ms가 됐다. 끝의 settle 렌더는 70–120 ms였다. 둘 다 reader 재생성 비용이라 2번으로 함께 사라졌다.
- R2 스크립트(전체 → 1·0을 차례로 방문 → 1 선택)는 scratchpad의 `r2.json`이다. 저장소에는 넣지 않았다.
- A의 hitchRatio(수백)는 before에서도 같은 크기다(A1 236/425 → 287/345, A14 601/716 → 502/554). 측정 구간의 frame이 1–2개라 생기는 잡음이다(fix round 1 참고).

### 남은 것

- C3 worst 72, R2 worst 58: 남은 reader 갱신 턴의 비용은 SwiftUI 레이아웃이다(`ScrollViewLayoutComputer` 27%, AppKit 버튼 intrinsic size 12%). 게이트 안이라 더 손대지 않았다.
- 수동 확인:
  - breadcrumb hover 펼침과 피드 segment 클릭
  - 좁은 창에서 breadcrumb가 줄어들고 overflow되는 모양
  - 선택이 없을 때 비활성 Share의 모양
  - reader 이전/다음(풀 제스처, 메뉴 명령)의 push 전환 방향
  - 글을 바꾸면 맨 위에서 시작하는지(긴 HTML 글)
  - HTML 글의 각주 anchor 이동·flash
  - 요약 켜짐 상태에서 글을 바꿀 때 요약 카드가 리셋되는지
  - 번역 중에 글을 바꿀 때 배너와 애니메이션

### 검증

- `make build` 통과, iOS `NookiOS` Release(generic iOS, `CODE_SIGNING_ALLOWED=NO`) 통과.
- `swift test --package-path NookKit --filter "ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness|ArticleTableModel"`(600 s 제한): 76개 통과. 바뀐 코드는 앱 타깃의 `ContentView`뿐이라 새 단위 테스트는 없다.
- `git diff --check`, `plutil -lint` 통과.

## Fix round 3

main `f007cc6` 기준. fix round 2에서 reader를 제자리 갱신으로 바꾸면서 reader의 `@State`가 글을 넘어 살아남게 됐다. 리뷰(`review-p5f2`)의 MEDIUM 2개와 LOW 2개를 고치고, reader 하위 트리의 글별 상태를 다시 점검했다. reader를 다시 통째로 만드는 방식(`.id(article.id)`)은 되돌리지 않았다.

### 1. 글별 상태를 `ReaderArticleSession`으로 (`c9cd884`)

- 새 타입 `NookKit/Sources/NookKit/ReaderArticleSession.swift`(`@MainActor @Observable`). reader의 번역기(`NativeArticleTranslator`), 요약(`ArticleSummaryController`), 감지 언어, 시스템 Translation overlay 플래그, 평문 번역(제목/문단/표시 여부/진행 중)을 한곳에 두고, 이 상태가 어느 글의 것인지(`articleID`)를 함께 기록한다.
- 모든 읽기는 글 id를 받는다(`translator(for:)`, `summary(for:)`, `detectedLanguage(for:)`, `plainTranslation(for:)`, `isTranslating(for:)` …). bound된 글이 아니면 nil/false를 돌려준다. 그래서 새 글의 첫 body는 `begin(articleID:)`가 돌기 전에도 깨끗하다. 이전 글의 번역 제목, `HTMLContentView`에 넘기던 번역기(`completedMarkdownBlocks()`/`translatedBlock(at:)`), "Translated by …" 라벨, 요약 카드, Translate 버튼 노출(감지 언어)이 모두 여기에 해당한다(MEDIUM 2).
- `begin(articleID:)`는 `.onChange(of: article.id, initial: true)`에서 부른다. 안전을 위해 글 task·요약 task·`toggleTranslation`·`requestSummary`에서도 부른다. 같은 글이면 아무것도 하지 않는다. 글이 바뀌면 `translator.stop()`과 `summary.reset()`을 하고, 평문 번역 task를 취소하고, 나머지 값을 비운다. 값이 이미 기본값이면 쓰지 않는다(Observation 무효화 방지, `stop()`과 같은 방식).
- 평문 번역(MEDIUM 1): `translatePlainBody(articleID:…)`는 bound된 글에서만 시작한다. 실행마다 `plainRun`을 올리고, `begin`도 이 값을 올린다. 늦게 끝난 결과는 run이 맞지 않으면 버린다. 그래서 A의 결과가 B에 들어가지 않는다. B에서 배너와 Translate 비활성은 `isTranslating(for: B)`를 따르므로 A의 요청이 끝나기를 기다리지 않는다.
- 삭제 확인(LOW 3): 휴지통을 누를 때 `pendingDeleteID`에 글 id를 담고 `confirmationDialog(…, presenting:)`로 그 id를 지운다. 글이 바뀌면 다이얼로그를 닫는다(전에는 reader 재생성이 닫았다).
- 스크롤 리셋(LOW 4): 고칠 것이 없었다. `ScrollPosition`은 `scrollTo(edge: .top)`를 부를 때마다 이전 값과 다른 값이 된다(`.top`에서 `.top`으로 가도 마찬가지, 내부 seed). 그래서 바인딩이 `.top`으로 남아 있어도 리셋은 매번 적용된다. 테스트로 고정했다. 초기 호출(`initial: true`)에서는 스크롤하지 않는다.
- 하단 Share 메뉴(`ArticleShareMenu`, NookKit): `articleURL`이 바뀌면 "copied" 체크를 끈다. 타이머는 자기 run일 때만 끈다. 그래서 이전 복사의 1.5초 타이머가 나중 체크를 일찍 끄지 않는다. 팝업 버튼을 다시 만들지 않으므로 round 2의 비용 절감은 그대로다. iOS도 같은 컴포넌트를 쓴다. 동작은 같은 글 안에서는 같고, 글이 바뀌면 체크가 꺼지는 것만 다르다.

### 점검한 나머지 상태

| 상태 | 결과 |
|---|---|
| find bar | reader에 없음 |
| 각주 anchor/flash (`HTMLContentView` `@State`) | `.id(article.id)` 그대로 |
| 요약 카드 펼침, 요약 버튼 | 요약 `Group`의 `.id(article.id)` + session 게이트 |
| 댓글 `showsAll` | `.id(article.id)`. 번역기는 session 게이트 |
| 읽음 dwell 타이머 | `.task(id: article.id)`가 취소 |
| full-article web reader | `store.isBrowserPresented`, reader 밖이고 `ArticleWebView` identity는 글 기준 |
| 오프라인/재파싱/파서/카테고리 | store에서 읽음. 하위 뷰(`ReaderUnavailableNotice`, `ReaderReparsingBanner`, `ReaderDroppedEmbedsNotice`, `ReaderLoadingPlaceholder`, `CategoryMenuItems`, `ReaderParserMenuItems`, `ReaderTitleButtonStyle`)에 `@State` 없음 |
| swipe pull/armed | 스크롤 geometry에서 다시 계산되고, commit 시 리셋. 글 상태가 아님 |
| `summaryRequestedArticleID` | 글 id와 비교해 읽음. 글이 바뀌면 nil |

### 측정 (lib-5k, warm median/worst ms, A/C는 5회, T3는 1회씩 3번)

| 시나리오 | f007cc6 (코디네이터) | 이번 | 게이트 |
|---|---|---|---|
| A1 worstStall / ttfr | 0, 39–85 | 0/0, 84/85 | PASS |
| A14 worstStall / ttfr | 59/66, 85/111 | 0/64, 106/116 | PASS |
| C3 worstStall / stalls100 | 0/63, 0 | 0/0, 0/0 | PASS |
| C1 worstStall / hitchRatio | 0 | 0/0, 3.8/16.9 | |
| T3 번역 on worstStall (stalls100) | 0 | 60, 0, 0 (모두 0) | PASS |
| T3 번역 off worstStall (stalls100) | 25/50 | 63, 60, 0 (모두 0) | PASS |

- T3의 60 ms 안팎 값은 실행마다 나왔다가 사라진다(on 60/0/0, off 63/60/0). stalls100은 모두 0이다. 측정 잡음으로 본다.

### 테스트와 검증

- `NookKit/Tests/NookKitTests/ReaderArticleSessionTests.swift`(6개). 내용:
  - A의 평문 번역이 B로 바꾼 뒤에 끝나도 B에 아무것도 들어가지 않는다.
  - bound 전 B에 대한 읽기는 모두 비어 있다(번역기, 요약, 감지 언어, overlay, 평문 번역, 진행 중).
  - bound되지 않은 글에 대한 쓰기는 무시된다.
  - 같은 글을 다시 bind하면 상태가 유지된다.
  - 평문 번역은 제목 길이 가드와 표시/숨김을 지킨다.
  - `scrollTo(edge: .top)`는 매번 새 값이다.
- `swift test --package-path NookKit --filter "ReaderArticleSession|ArticleSummaryTests|ReaderSelectionSettler|ArticleRowCost|ArticleListWindow|ListSelectionInvalidation|ReaderStorePhaseOne|ListTitleTranslat|ExpandReveal|ListRowMenuEagerness|ArticleTableModel|ArticleMarkdownTests|ReaderSwipeNavigation"`(600 s 제한): 102개 통과.
- `make build`, `NookiOS` Release(generic iOS, `CODE_SIGNING_ALLOWED=NO`), `git diff --check`, `plutil -lint` 통과.
- 수동 확인(앱 실행 필요):
  - HTML 글 A에서 번역을 켠 뒤 B를 선택(클릭, ↓, 사이드바). B의 첫 화면에 A의 번역 제목·본문·"Translated by" 라벨이 보이지 않아야 한다.
  - 평문 글 A에서 Translate를 누르고 곧바로 B로 바꾼다. B에 "Translating…" 배너가 없어야 하고, Translate 버튼이 활성이어야 하며, 나중에 A의 번역이 B에 들어가지 않아야 한다.
  - 요약을 켠 채 글을 바꾼다. 이전 글의 요약 카드가 한 프레임도 보이지 않아야 한다.
  - 삭제 확인을 띄운 상태에서 메뉴의 다음/이전 명령으로 글을 바꾼다. 다이얼로그가 닫혀야 한다.
  - 각주 anchor로 점프한 뒤 다른 글을 고른다. 맨 위에서 시작해야 한다.
  - Copy as Markdown 직후 다른 글로 바꾼다. 체크 표시가 바로 꺼져야 한다.
