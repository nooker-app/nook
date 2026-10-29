# Phase 6 — iOS 회귀 확인과 기대 이득 비교

main `4833d50` 기준(이 worktree는 그 위에 DEBUG 드라이버 커밋 `d62eafb` 하나). iOS 제품 동작은 바꾸지 않았다. 측정은 iOS Simulator(iPhone 17 Pro, iOS 26.5, Debug `-Onone`)에서 골든 `lib-5k`(5,000글·300피드·unread 3,000)와 `tools/perf/feedserver.py`(trickle)로 했다. 비교 기준은 같은 드라이버를 붙인 `8d8d17e`(perf 작업 직전)이다.

## 결론

- **iOS 회귀 없음.** 8d8d17e..4833d50 사이 iOS 타깃에 들어가는 변경 20건을 대조했다. 그중 동작이 보이게 달라진 것은 4건이다(새로고침 중 목록 갱신 1.5 s 묶음·무애니메이션, 같은 소스 재선택 없이 피드 전환 시 retained 해제, 배지 초기 반영, 공유 메뉴 체크 표시 리셋). 넷 다 의도한 공유 Phase 1 변경이거나 개선이다. 깨진 것은 없다. 시뮬레이터 smoke(실행, 소스 전환 7종, 스크롤, 글 열기/뒤로, pull-to-refresh)가 모두 통과했다.
- **iOS에는 macOS의 정지가 처음부터 없다.** 같은 lib-5k에서 iOS 기준선(8d8d17e)의 A1(feed-small → All)은 최악 메인 작업 31 ms, ≥100 ms 정지 0회다. macOS 같은 시나리오의 24,157 ms와 대조된다. 4833d50도 같다(26 ms, 0회). 원인은 플랫폼 List 구현 차이다. iOS 26 SwiftUI `List`는 `UICollectionView` 위에서 보이는 셀만 만든다. 그래서 메인 스레드의 publish 비용이 행 수와 거의 무관하다(541행 21 ms ↔ 5,000행 35 ms).
- **측정된 작은 퇴행 1건: TTFR이 늘었다.** 전환 후 새 목록이 처음 보일 때까지의 시간(TTFR) median이 A1 60 → 70 ms, A2 39 → 68 ms다. 메인 스레드 비용은 오히려 줄었다(A2 publish 37 → 29 ms). 늘어난 시간은 off-main 필터 executor 쪽이다. 여기서 Phase 1·2의 `computeDisplayDiff`(행 모델·색인·순서 비교)를 publish 전에 계산하는데, iOS는 그 행 모델을 쓰지 않는다. 정지가 아니라 30 fps 기준 1 프레임 안팎의 지연이고, 원인 일부(Debug 6–7 ms)만 귀속했다. 아래 "남은 것" 참고.
- **같은 기법을 iOS에 적용했을 때의 기대 이득은 작다.** 윈도 큐는 ≤10 ms(추정 상한), Phase 5 상당의 `UICollectionView` 직접 구현은 publish당 약 15–30 ms(Debug 시뮬레이터 기준 추정), reader settle은 iPhone에서 0이다. macOS처럼 수 초를 없애는 개선은 iOS에 해당 사항이 없다. 실기기 Release에서 ≥100 ms 정지가 확인되기 전에는 적용하지 않기를 권한다.

## 측정 방법

`NookiOS/IOSPerfDriver.swift`(`#if DEBUG`, 커밋 `d62eafb`)를 추가했다. macOS `PerfDriver`·`MainThreadLog`는 AppKit 전용이라 iOS에서 쓸 수 없다. 반면 `-NookPerfLibrary` 훅은 NookKit `ReaderStore.restoreStorageIfPossible`에 `#if DEBUG`로 이미 있어서 iOS도 그대로 쓴다. 이 훅은 bookmark·폴더 defaults에 쓰지 않는다. 그래서 별도 라이브러리 훅은 추가하지 않았다.

```sh
xcrun simctl launch <udid> com.tim.nook.ios \
  -NookPerfLibrary <lib-5k 복사본> -autoRefreshEnabled NO -NookFaviconFetch NO \
  -NookAICategorize NO -NookFreezeRelativeTime \
  -hasCompletedWelcome YES -translateTitlesPromoSeen YES -seenListTapHint YES \
  -NookIOSPerfSteps A1,A2,C1,B2 -NookIOSPerfReps 6 -NookPerfLog <log>
```

- 온보딩·번역 안내는 launch argument(인자 도메인, 저장 안 됨)로 건너뛴다. 매 실행 전에 골든 라이브러리를 `rsync --delete`로 복원한다.
- 지표는 rep마다 `scenario.stats` 한 줄로 남는다.
  - `mainMaxMs`: 메인 run loop 한 바퀴(wake→sleep)의 최장 시간, 곧 정지 길이. `CFRunLoopObserver`로 ms 단위까지 잰다.
  - `publishMs`: 새 목록이 설치된 바퀴와 그다음 바퀴의 합. List diff, 셀 생성, 레이아웃, commit을 포함한다.
  - `ttfrMs`: 동작 시작부터 바뀐 목록이 처음 관측된 display-link tick까지.
  - `stalls100/250`: 프레임 간격 ≥100/≥250 ms 횟수.
- 시나리오:
  - A1: feed-small(30) → All(5,000)
  - A2: All → Unread(3,000)
  - A3: feed-small → Unread
  - A7: feed-small → 폴더(541)
  - A8: feed-small → 카테고리(625)
  - B2: Refresh All(trickle). cold rep만 새 글 30개를 가져오고, warm rep는 새 글 0개라 B1에 해당한다.
  - C1: 3화면씩 animated offset 8회. 손가락 fling의 근사다.
- 시뮬레이터 한계:
  - 호스트(Apple Silicon Mac) CPU로 돌아서 실기기와 절대값이 다르다.
  - 표시는 약 30 fps로 갱신된다(`frames≈34/1.1s`). 그래서 프레임 간격 지표는 33 ms 단위로 반올림된다. 정지 판정에는 run-loop 기반 `mainMaxMs`를 쓴다.
  - `xcrun xctrace record`는 `--launch`(앱이 정지 상태 `T`로 멈춤), `--attach`, `--all-processes` 모두 이 호스트의 시뮬레이터 대상에서 끝나지 않았다. 120 s alarm으로 종료했다. `sample <pid>`는 앱의 SwiftUI/ReaderStore 프레임을 전혀 잡지 못했다. 그래서 함수 단위 귀속(Time Profiler)은 없다. 귀속은 행 수를 바꾼 시나리오 비교(아래)와 NookKit 단위 마이크로벤치로 대신했다.

## Part A — 회귀 확인

### 빌드·테스트

| 검사 | 결과 |
|---|---|
| `NookiOS` Debug, iOS Simulator | BUILD SUCCEEDED |
| `make build`(macOS) | BUILD SUCCEEDED |
| `perl -e 'alarm 900' swift test --package-path NookKit --skip "ReaderTypographyTests\|NativeInlineHTML\|AnchorFlash"` | 85 suites, 627 tests passed |
| `plutil -lint Nook.xcodeproj/project.pbxproj` / `git diff --check` | OK |

### iOS에 컴파일되는 변경과 판정

`git diff 8d8d17e..4833d50`에서 NookiOS 타깃에 들어가는 파일은 `NookiOS/RootView.swift`와 NookKit 소스다. `ArticleTableModel.swift`와 `ExpandReveal`의 coalescer는 `#if os(macOS)`이고 `Nook/`은 macOS 타깃 전용이라 제외했다.

| # | 변경(파일) | iOS 동작 | 판정·근거 |
|---|---|---|---|
| 1 | RootView 3곳(`RegularShell` My Nook follow, `CompactShell` 피드, `Sidebar` 피드)의 `feedSelection = [id]; smartSelection = nil` → `store.selectFeed(id)` | 끝 상태 같음(category는 feedSelection didSet이 해제). 필터 2회 → 1회. 소스가 바뀌면 retained 해제 | 안전. 소스 전환 시 retained 해제는 체크리스트 의도대로다(6e4ee22). 새 피드에는 읽은 글도 보이므로 화면 차이가 없다. smoke `feed-small` 30행 확인 |
| 2 | `withSelectionChange`: `selectSmartSource`/`selectCategory`/`selectFolder`/`openArticle`/세 didSet이 retained clear + 필터 1회 | 같은 소스 재선택도 clear + refilter("as before" 주석). 동기 `pruneSelectionIfHidden` 제거, 설치 시 prune | 안전. iPhone 리더는 `pushed` 바인딩으로 열리고 `selectedArticleID`로 열리지 않는다. 그래서 prune이 TTFR(~70 ms)만큼 늦어도 화면 영향이 없다. Home 세그먼트(`homeFilter` onChange → `selectSmartSource`)는 그대로 |
| 3 | 필터 파이프라인: `DisplayResult`, generation·revision guard, 취소 확인, `displayedArticles`를 `ArticleListContents` + `displayRevision`으로 | `visibleArticles`는 여전히 정렬된 전체 결과이고 `displayRevision`으로 관찰된다 | 안전. RootView의 `visibleArticles` 사용처(2162 `first(where:)`, 2395/2418 spotlight, 2881, 2890 `List`, 2901/2985/2986 첫/끝 행, 3027 empty)가 모두 전체 목록 기준이다. smoke에서 7종 목록(0/30/541/625/3,000/5,000/5,030행)이 렌더됐다 |
| 4 | `shouldAnimateDisplay`: replacement·배치 새로고침·순서 변경이면 애니메이션 없음. merge의 `withAnimation` 제거. 배치 끝 publish는 새 글이 있는 대화형 새로고침에서만 slide | **보이는 변화.** pull-to-refresh 중 중간 publish는 무애니메이션이고, 끝 publish만 slide | 의도된 공유 Phase 1 변경(e549ab2, 87a0aa6 규칙 유지). smoke 새로고침 5,000 → 5,030 정상. slide 모양은 육안 확인 안 함 |
| 5 | 배치 새로고침 중 필터 1.5 s trailing throttle(`beginBatchFiltering`) | **보이는 변화.** 긴 Refresh All 중 목록 갱신 간격 ≤1.5 s(이전 ~400 ms 단위) | 의도(체크리스트 §새로고침). 끝 필터는 즉시. B2 warm 메인 최장 34 ms(이전 31 ms), 정지 0 |
| 6 | `MergeProjection`: 변경 없는 새로고침은 `articles`에 쓰지 않음 | B2 warm(새 글 0) 행 수 불변, publish 없음 | 안전·개선 |
| 7 | `markVisibleArticlesSeen` HLC 1회 일괄 | shard 의미 동일(같은 스탬프로 LWW) | 안전 |
| 8 | `updateUnreadBadge` 내보낸 값 guard, `onUnreadBadgeChange` didSet이 즉시 1회 내보냄 | **보이는 변화.** 앱 아이콘 배지가 핸들러 설치 즉시 맞춰진다(이전에는 다음 변경 때) | 개선. 설정 토글은 `showsUnreadBadge` didSet → 값이 달라지므로 통과 |
| 9 | `articleIndexByID` O(1) 조회(`article(withID:)`, `setRead`/`setStarred`, AI 분류, `openArticle`) | 결과 동일 | 안전. 색인은 `articles` didSet과 `apply`에서 재생성한다. suppress 경로 2곳은 제자리 비트 변경뿐이다(4175, 4301) |
| 10 | `allCount` 저장 프로퍼티 | 사이드바 All 카운트 동일 | 안전 |
| 11 | `removeFolder`/`removeFolders`/피드 삭제의 동기 prune 제거 | 설치 시 prune | 안전(끝 상태 동일) |
| 12 | 필터·카테고리 삭제 시 `.all`로 이동 후 counts·badge 1회 | 동일 결과, 중복 계산 제거 | 안전 |
| 13 | `computeDisplayDiff`가 iOS에서도 행 모델(창 prefix 최대 200)·`indexByID`·순서 비교를 계산 | 화면 동일, **TTFR +10–29 ms**(아래) | 경미한 성능 퇴행. iOS는 `listWindow`를 reset 외에 쓰지 않아 행 모델은 버려진다 |
| 14 | `ListTitleTranslator.setState`가 기존 box에만 씀 | 결과가 늦게 도착해도 box가 없으면 cache만 갱신 | 안전. iOS 행은 body에서 `titleTranslator.box(for:)`(RootView 3127)로 먼저 box를 만든다 |
| 15 | `ListTitleTranslator.visibleCounts` 참조 계수 | 한 id의 마지막 onDisappear에서만 비가시 처리 | 안전(SwiftUI onAppear/onDisappear는 짝을 이룸). 짝이 깨지면 화면 밖 행의 번역이 취소되지 않을 뿐이다(낮음) |
| 16 | `immediateUntil`: 번역을 켠 뒤 1 s 동안 나타나는 행은 dwell 생략 | iOS에서 켜는 곳은 설정·안내 시트. 이미 보이는 행은 이전에도 즉시 번역됐다 | 안전 |
| 17 | `ListTitleTranslationSlot`, `expandReveal(opensInsertedHeight:)` | iOS는 slot을 쓰지 않고 `opensInsertedHeight` 기본값 false → `_revealed = isVisible` 그대로, onAppear guard 통과 안 함 | 변화 없음 |
| 18 | `ArticleShareMenu` `.onChange(of: articleURL)` + `copiedRun` | **보이는 변화.** iPhone 리더에서 이전/다음 스와이프로 글이 제자리에서 바뀌면 "복사됨" 체크가 리셋된다. 이전 복사의 타이머가 새 체크를 지우지 않는다 | 개선(ReaderView 1111) |
| 19 | `ReaderSelectionSettler`·`ReaderArticleSession` | iOS에 컴파일되지만 사용처 없음(`readerSelection`은 `#if os(macOS)`) | 변화 없음 |
| 20 | `purgeExpiredOffline` → `offlineCopiesRemoved` → 필터 예약, `cacheURL`의 PerfLaunch 분기 | 만료 다운로드가 있으면 Downloaded가 즉시 갱신. perf 분기는 DEBUG + perf 실행 전용 | 안전 |

### 체크리스트의 iOS 항목

| 항목 | 확인 |
|---|---|
| `visibleArticles` 사용처(RootView) | 위 #3. 전부 전체 결과 기준이고 관찰 가능. smoke 렌더 확인 |
| retained 의미 | 위 #1·#2. 소스 전환 시에만 해제, 읽음 변경·merge install로는 해제되지 않음(필터의 retained 조건 유지) |
| `setScrolling` | RootView 3009–3010 `onScrollPhaseChange { setScrolling(newPhase != .idle) }` 변경 없음 |
| 튜토리얼 spotlight | 코드 대조만. `visibleArticles.first`/`.onChange(of: visibleArticles.count)`가 `displayRevision` 관찰로 계속 갱신된다. 실제 투어는 starter 사이트를 네트워크로 추가해야 해서 실행하지 않음 |
| OPML import | 코드 대조만. `isBulkImporting`이면 애니메이션 없음(`shouldAnimateDisplay`)이고 throttle은 배치 데이터 트리거에만 걸린다. 파일 선택기가 필요해 시뮬레이터에서 실행하지 않음 |
| `ArticleShareMenu` onChange | 위 #18 |
| pull-to-refresh 스피너 | smoke에서 `UIRefreshControl` 액션 → `refreshAllAndWait` 완료 후 5,030행 확인. 스피너가 새 행 뒤에 멈추는 순서는 이전과 같은 비동기 경로 |

### 시뮬레이터 smoke (`-NookIOSPerfSteps S`)

시뮬레이터 창 클릭(`orca computer`)은 포커스를 얻지 못해(`window_not_focused`) 쓸 수 없었다. 대신 탭과 같은 진입점을 앱 안에서 호출했다. 진입점은 store 내비게이션, List의 `collectionView(_:didSelectItemAt:)`, `UIRefreshControl`의 valueChanged다. 단계마다 창 스냅샷을 찍었다.

| 단계 | 결과 |
|---|---|
| launch | Unread 3,000행 렌더 |
| Unread / Today / feed-small / 폴더 / 카테고리 / All | 3,000 / 0(골든 기준일이 과거) / 30 / 541 / 625 / 5,000행, 각 화면 정상 |
| fling 후 맨 위로 | 정상 |
| 글 열기(List selection delegate) | 리더 push, 본문 표시(오프라인 배너는 feedserver가 글 페이지를 내주지 않아서) |
| 뒤로(pop) | 목록 복귀. `selectedArticleID`는 의도대로 유지(RootView 628 주석) |
| pull-to-refresh | 5,000 → 5,030글, 새 글이 목록 맨 위 |

Home 상단 세그먼트는 `HomeTab`의 로컬 `@State homeFilter`라서 드라이버가 store를 직접 바꾸면 표시가 따라오지 않는다. 8d8d17e부터 같은 코드이고 회귀가 아니다.

### 성능: 8d8d17e vs 4833d50 (iOS, 같은 드라이버, warm 12회씩)

| 시나리오 | 빌드 | TTFR median/max | 메인 최장 median/max | publish median/max | ≥100 ms 정지 |
|---|---|---|---|---|---|
| A1 30→5,000 | before | 60.3 / 68.2 | 30.6 / 74.9 | 40.3 / 57.3 | 0 |
| | after | 70.0 / 86.1 | 25.7 / 73.6 | 34.0 / 47.8 | 0 |
| A2 5,000→3,000 | before | 39.2 / 74.2 | 35.4 / 39.7 | 36.9 / 39.8 | 0 |
| | after | 68.2 / 88.1 | 25.1 / 29.1 | 28.9 / 29.9 | 0 |
| B2(warm=새 글 0) | before | – | 31.2 / 32.9 | – | 0 |
| | after | – | 34.2 / 34.6 | – | 0 |
| C1 fling | before | – | 14.7 / 16.3 | – | 0 |
| | after | – | 14.6 / 28.2 | – | 0 |

- 단위 ms. 앞선 독립 실행(5회, 10회×2)도 TTFR이 같은 방향이었다. A1 +5–17, A2 +13–29.
- B2 rep 5는 두 빌드 모두 활동 시간이 22.6 s다. feedserver의 결정적 지연 패턴이 만든 값이고 메인 정지는 없다. 회귀가 아니다.
- TTFR 귀속: NookKit 테스트 빌드(Debug, 호스트)에서 5,000글 `computeDisplayDiff` 비용과, 그것이 대체한 이전 메인 계산을 비교했다.

  | 계산 | 비용 |
  |---|---|
  | `computeDisplayDiff` A1 30→5,000 | 6.4 ms |
  | `computeDisplayDiff` A2 5,000→3,000 | 7.4 ms |
  | `computeDisplayDiff` 동일 5,000(변경 없는 refilter) | 16.1 ms |
  | 대체한 이전 메인 계산(id 배열 + Set) | 3.5 ms |

  publish 전에 off-main으로 더해진 몫은 Debug에서 약 4–7 ms다. 나머지 증가분(A2에서 ~20 ms)은 프로파일러 없이 귀속하지 못했다. 후보는 필터 루프의 원소별 `isCancelled` 클로저 호출과, A2에서 이전에는 없던 `reordered` 판정(두 배열 filter)이다.

## Part B — 기대 이득 비교

### iOS 기준선의 귀속(측정)

행 수만 바꾼 전환 4종을 4833d50에서 warm 8회씩 쟀다. 출발은 모두 feed-small이다.

| 대상 | 행 | TTFR median | publish median(메인) | 메인 최장 median |
|---|---|---|---|---|
| A7 폴더 | 541 | 27.2 | 20.8 | 26.8 |
| A8 카테고리 | 625 | 26.6 | 38.0 | 27.4 |
| A3 Unread | 3,000 | 57.2 | 35.2 | 22.6 |
| A1 All | 5,000 | 57.7 | 34.5 | 27.4 |

- **메인 스레드(List diff + 셀 생성 + 레이아웃 + commit)는 행 수에 거의 비례하지 않는다.** 541 → 5,000행(9배)에서 publish가 21 → 35 ms다. 카테고리(625행)가 38 ms로 더 큰 것은 보이는 셀마다 카테고리 배지가 붙어 있어서로 보인다. iPhone 17 Pro에서 보이는 행은 5–7개다. 비용의 대부분은 보이는 셀 생성·self-sizing과 고정 비용이고, 행 수 비례분(id diff, ForEach 식별자 수집)은 기울기로 약 3 ms/1,000행이다((34.5 − 20.8)/4.46k).
- **off-main(필터 + `computeDisplayDiff`)은 행 수에 비례한다.** TTFR이 27 → 57 ms다.
- macOS와 대조된다. macOS의 정지 본체는 SwiftUI `List`(NSTableView 기반)가 패스마다 `ForEach` 클로저를 전체 행에 대해 실행하는 것이었다(250a6a3: body 650 vs closure 8,865). 거기에 신규 행 노드 생성과 NSTableView 삽입이 더해졌다. iOS `List`는 `UICollectionView` 위에서 보이는 셀만 만들어 이 증폭이 없다.

### 기법별 예상 이득

macOS 수치는 측정값이고(lib-5k, 코디네이터 측정), iOS 이득은 위 기준선에 대입한 **추정**이다.

| 기법(macOS Phase) | macOS 측정 | iOS 기준선(측정) | iOS 예상 이득(추정) | 노력·위험 |
|---|---|---|---|---|
| 전환 1회 = 필터 1회, 조용한 새로고침, merge 비교 축소(P1·P3 공유) | A1 worstStall 24,157 → P1/P2 ~179(윈도와 합산), B1/B2 ~120 → 0 | **이미 iOS에 적용됨**. before → after 메인 최장 A2 35 → 25, B2 31 → 34, 정지 0 → 0 | 측정 완료: 메인 −0~10 ms. 대신 TTFR +10–29 ms | 없음(적용 완료). TTFR 회수는 아래 "남은 것" |
| 윈도 큐 `ArticleListWindow`(P2) | A1 ~179 → P4 ~131의 기반, TTFR 24,267 → 76–85 | publish 21–35 ms 중 행 수 비례분은 약 3 ms/1,000행 | 5,000 → 200행으로 줄이면 publish **≤10–14 ms** 감소(상한). TTFR은 off-main이 전체 결과를 계속 계산하므로 변화 작음 | 중간. `List(store.listWindow.rows)`, growth sentinel, `ensureVisible`(위젯 딥링크·이전/다음), spotlight 첫 행, 스크롤 인디케이터 길이 변화. 이득 대비 비권장 |
| 행 모델·문자열 1회 해석 `ArticleRowModel`(P4) | T1 번역 on 전환 32,369 → 0, T3 1,721 → 0 | iOS 행 body는 보이는 셀만 실행. C1 메인 최장 14.6 ms, ≥16 ms 바퀴는 12회 fling 중 1회 | 셀당 상대시간·카테고리·피드 제목 해석 몇 ms 이하(미측정). T1류 병리(번역 토글 시 List 재구성 + 전 행 재평가)는 iOS 구조에 없음 | 낮음–중간. 이미 NookKit에 모델이 있어 iOS 행만 바꾸면 된다. 메뉴·swipe는 child에서 id 재조회. 120 Hz fling 여유가 필요할 때만 |
| reader settle `ReaderSelectionSettler`(P4) | C3 702 → 0, stalls100 14 → 0 | iPhone은 키 반복 목록 이동이 없다. 리더는 push이고 이전/다음은 제스처 1회 = 1글 | iPhone **0**. iPad + 하드웨어 키보드(RegularShell `List(selection:)`)에서만 해당. 미측정 | 낮음(NookKit에 있음). iPad 키보드 측정 후 판단 |
| 직접 그린 목록 + 높이 캐시(P5 NSTableView의 iOS 대응 = `UICollectionView` + diffable + 높이 캐시) | A1 P4 ~131 → 0, TTFR 76–85 | publish 21–38 ms 대부분이 셀 생성·self-sizing·SwiftUI 갱신 | publish를 id diff + 보이는 셀 구성 정도(추정 5–10 ms)로 → **약 15–30 ms 감소**. 120 Hz 기준 2–4 프레임 → 0–1 프레임 | 큼. swipe actions, context menu, `refreshable`, selection 기반 push, 번역 reveal 높이, spotlight, iPad 다중 컬럼을 다시 만들어야 함. 실기기 Release에서 ≥100 ms 정지가 확인될 때만 |

### iOS 고유 요소

- **iOS 26의 `List`는 UIKit(`UICollectionView`) 위에 있다.** 셀 재사용과 보이는 셀만 생성하는 구조라서, macOS NSTableView 기반 `List`의 "패스마다 전체 행" 증폭이 없다. 이 차이 하나로 macOS 24 s ↔ iOS 31 ms가 설명된다.
- **화면이 작다.** iPhone은 보이는 행이 5–7개라 셀 생성 비용 자체가 작다. iPad(RegularShell, 사이드바 + 목록 + 리더)는 보이는 행이 2–3배이고, 하드웨어 키보드로 목록을 연속 이동할 수 있다. reader settle과 행 모델의 이득이 생긴다면 iPad 쪽이다.
- **ProMotion.** 실기기 120 Hz의 프레임 예산은 8.3 ms다. 측정한 publish 21–38 ms(Debug, Mac CPU)는 전환 1회에 2–4 프레임을 떨어뜨리는 크기다. 정지로 느껴지지는 않지만 매끄러운 전환은 아니다. Release 최적화는 줄이고 A-시리즈 실기기는 늘리는 방향이라 실제 배수는 미측정이다.
- **메모리.** 4833d50은 iOS에서도 `displayedArticles`(전체) 외에 `indexByID`(5,000 항목)와 행 모델(최대 200)을 만든다. lib-5k에서 프로세스 footprint는 약 83 MB였다(`sample` 헤더). 20k 라이브러리에서는 색인·모델 몫이 4배가 되므로, iOS에서 쓰지 않는 행 모델은 생략할 가치가 있다.

## 남은 것

- **TTFR +10–29 ms(iOS).** 정지는 아니지만 측정된 퇴행이다. 가장 작은 후속 조치는 `computeDisplayDiff`에서 iOS에 쓰이지 않는 `rowModels` 계산을 `#if os(macOS)`로 빼는 것이다(이번 Phase 범위 밖, iOS 코드 변경). 나머지 ~20 ms의 귀속에는 실기기나 동작하는 Time Profiler가 필요하다.
- **xctrace 미사용.** 이 호스트에서 시뮬레이터 대상 `xctrace record`가 끝나지 않았다. 실기기(또는 다른 호스트)에서 Hangs·Time Profiler로 A1/A2/B2를 다시 재면 위 추정 칸을 측정값으로 바꿀 수 있다. 드라이버의 `OSSignposter` interval(`scenario id=… rep=…`)이 그때 구간 표시가 된다.
- 튜토리얼 spotlight와 OPML import는 코드 대조만 했다(네트워크 starter 사이트, 파일 선택기 필요).
- 시뮬레이터 창 클릭이 포커스 문제로 동작하지 않아, smoke는 탭과 같은 진입점을 앱 안에서 호출했다. 실제 터치 제스처(스와이프 액션, 길게 누르기 메뉴)는 확인하지 않았다.
