# Nook 대량 목록 성능 측정 프로토콜 (before/after 실측)

## 결론
지금 있는 계측은 "250ms 넘는 정지가 있었다"까지만 보여줍니다. 탭 전환, 새로고침, 스크롤, 토글 각각의 개선을 숫자로 증명하려면 **Phase 0 커밋** 하나에 다음 다섯 가지를 먼저 넣어야 합니다. 모두 DEBUG 전용입니다.
1. 시나리오 마커와 시나리오별 통계 줄
2. 더 촘촘한 stall watchdog
3. displayLink 기반 프레임 히치 측정
4. 결정적(deterministic) 대형 라이브러리와 로컬 피드 서버
5. 앱 안에서 도는 스크립트 드라이버

기준선(before)은 `ebd5ee6`에 이 계측만 더한 빌드에서 잽니다. 이후 Phase마다 같은 스크립트와 같은 라이브러리로 다시 재고 `perfreport.py`로 표를 비교합니다. `xcrun xctrace`(v16.0, 이 머신에서 확인)는 Hangs, Animation Hitches, Time Profiler 템플릿을 헤드리스로 돌릴 수 있어 보조 검증으로 씁니다.

---

## 1. 계측: 이미 있는 것과 추가할 것

### 이미 있는 것
위치는 `NookKit/Sources/NookKit/MainThreadLog.swift`이고 `#if DEBUG && os(macOS)`로 감싸져 있습니다.

| 기능 | 현재 상태 | 한계 |
|---|---|---|
| Stall watchdog | 50ms heartbeat, **250ms threshold 고정**(`sample(threshold: 0.25)`) | 100~250ms 끊김은 안 보이고 해상도가 ±50ms입니다 |
| Run-loop phase 귀속 | `CFRunLoopObserver`, `runloop:beforeWaiting` 등 | 충분합니다 |
| 정지 구간 카운터 diff | `ran list.rowcontentx847 …` | 충분합니다 |
| 카운터 | `list.body`(ContentView:1510), `list.rowcontent`(:1542), `list.row`(:1729), `list.row.menu`/`list.row.swipe`(:1659/:1689), `list.row.height`(ExpandReveal:130), `relativetime.body`, `import.webkit` | 시나리오별로 끊을 수 없습니다(프로세스 누적) |
| ms 측정 | `list.filter`(동기 경로만, ReaderStore:857) | 백그라운드 필터, merge, didSet, markSeen이 빠져 있습니다 |
| 이벤트 줄 | `list.publish rows=a->b animated=` (ReaderStore:963) | 충분합니다 |
| SUMMARY | resign/terminate 시점(NookApp.swift:154,162) | 누적값이라 before/after를 가를 수 없습니다 |
| 파서 | `.claude/skills/ui-behavior-forensics/readlog.py` | GeometryLog 전용입니다. stall/시나리오 집계 기능이 없습니다 |

**재현용 라이브러리, fixture, launch argument는 없습니다.** grep 결과 `ProcessInfo.arguments`/`environment`를 쓰는 곳이 0건이고, `LiveFeedFixture.swift`는 피드 하나짜리 테스트 문자열입니다.

### 추가할 것 (Phase 0, DEBUG만)

**① 시나리오 마커와 통계** (`MainThreadLog`에 추가)
- `scenarioBegin(name:)`은 `totals` 스냅샷, stall 목록 길이, 프레임 카운터를 저장합니다.
- `scenarioEnd()`는 그 차이를 한 줄로 기록합니다(줄 형식은 4절).
- 시작할 때 한 번 `run.begin label=<NookPerfLabel> sha=<build-id.sh> binarySha=<NookBuildSHA> lib=<id> hz=<display Hz> opt=<-O|-Onone> log=<MainThreadLog.url>`를 남깁니다. `opt`는 컴파일 시점에 정해지는 `_isDebugAssertConfiguration()`에서 옵니다.
- 로그 경로는 서명/샌드박스 여부에 따라 바뀝니다. `CODE_SIGNING_ALLOWED=NO` 빌드는 entitlement가 없어 컨테이너 밖 `$TMPDIR`에 씁니다. 그래서 경로를 추측하지 말고 로그에 찍힌 `log=` 값을 씁니다.

**② Watchdog을 촘촘하게**
- launch arg `-NookStallMs 50`을 받으면 heartbeat는 8ms, threshold는 50ms로 바꿉니다. 기본값 250은 그대로 둡니다.
- stall을 길이별로 셉니다: ≥50, ≥100, ≥250, ≥500, ≥1000ms.
- stall 길이 = (돌아온 첫 heartbeat) − (마지막 heartbeat) − heartbeat 간격. watchdog이 다음에 깨어난 시각이 아니라 heartbeat 자체로 끝을 잡으므로 샘플링 주기만큼 부풀지 않습니다. 놓친 heartbeat 시점부터 세는 **하한값**이라 최대 한 간격(8ms)만큼 짧게 나올 수 있습니다.
- 카운터는 라벨별 `(calls, ms)` 누계만 유지합니다. 분포(p95/max)가 필요한 `store.merge`, `store.updateInPlace`, `list.window.grow`만 시나리오 진행 중에 호출별 값을 따로 모읍니다. STALL 줄의 `ran …`은 정지 동안 ms가 큰 순서로 상위 4개입니다.

**③ 프레임 히치 측정**
- 목록 `List`에 `.background(PerfDisplayLinkProbe())`로 붙인 `NSViewRepresentable`에서 `NSView.displayLink(target:selector:)`(macOS 14+)를 엽니다. 행(row)이 아니라 List에 붙이므로 스크롤로 행 뷰가 제거·재사용돼도 링크가 끊기지 않습니다. 드라이버가 움직일 `NSScrollView`는 probe에서 상위 뷰를 거슬러 올라가며 probe와 겹치는 테이블 스크롤 뷰를 찾습니다(사이드바 List는 고르지 않습니다).
- 링크는 `-NookPerfScript`가 있을 때만 만들고, 드라이버가 `scenarioBegin`/`scenarioEnd`에 맞춰 `isPaused`를 끕니다/켭니다. 그래서 settle 중이나 일반 Debug 세션에서는 메인 스레드 작업이 없습니다.
- 프레임마다 실제 간격 `Δ = timestamp − prevTimestamp`와 기대 간격 `E = targetTimestamp − timestamp`를 구하고, `Δ > 1.5E`이면 히치로 셉니다. 히치 시간은 `hitchMs += Δ − E`로 누적합니다.
- 집계 항목은 `frames`, `dropped`, `droppedPct`, `hitchMs`, `hitchRatio = hitchMs / activeDur 초`(Apple 기준 ms/s), `p99Frame`, `worstFrame`입니다. 모두 **활성 구간**(아래 4절 `activeDur`)의 프레임만 셉니다. quiesce 꼬리 1.5초가 비율을 희석하지 않게 하기 위해서입니다.
- 이 측정은 **메인 스레드가 프레임을 놓친 경우**만 잡습니다. 렌더 서버 쪽 히치는 xctrace Animation Hitches로 따로 봅니다(6절).

**④ ms scope와 카운터** (`MainThreadLog.measure`/`add`. 같은 이름으로 `OSSignposter(subsystem:"com.tim.nook", category:"perf")` interval도 함께 남겨 Instruments 타임라인과 맞춥니다)

| 라벨 | 위치 | 용도 |
|---|---|---|
| `store.applyDisplayed` ms | ReaderStore:909~ | Phase 2 이후 O(1)인지 확인 |
| `bg.filter` ms (off-main, stall 아님) | detached filter task | 첫 행까지 걸린 시간 분해 |
| `store.merge` ms, `store.merge.flush` 횟수 | `merge(batch:)` 4724 / `flushBatchMerges` 4937 | flush당 메인 ms |
| `store.merge.changedNoNew` 카운터 | 새 글 0인데 changed=true인 경우 | MergeProjection 검증 |
| `store.merge.fallback` 카운터 | Phase 3 generation 불일치 | off-main install이 실패한 비율 |
| `store.didset.articles` ms | articles didSet | O(N) 패스 비용 |
| `store.markSeen` ms, `store.hlc.tick` 카운터 | 2343 | 일괄 기록 검증(tick=1) |
| `store.updateInPlace` ms | 3939 / Phase 2 indexByID | 토글 비용 |
| `select.begin source=…` note | selection didSet, `selectSmartSource` 1070 | TTFR(첫 행까지 시간)의 시작점 |
| `list.settled` note | publish 직후 첫 heartbeat | TTFR의 끝점. heartbeat는 CA commit이 끝나야 돌 수 있으므로 "첫 행이 화면에 나온 시점"의 근사치입니다 |
| `list.window.grow` ms + `rows=a->b` | ArticleListWindow.requestGrowth | 윈도 경계 비용 |
| `list.title.box` 생성 / `list.title.box.release` 해제 카운터 | ListTitleTranslator `box(for:)` / `StateBox` deinit | box 수명 검증 (현재 box는 번역기 수명 동안 interning되므로 release는 0이 정상) |
| `list.row.height.flush` 카운터 | MacListRowHeightInvalidator (`MainThreadLog.addOncePerTurn`) | 행 높이 무효화가 있었던 run-loop 턴 수. `list.row.height`(요청 수)보다 작아야 coalescing이 되는 것 |
| `sidebar.row` 카운터 | FeedSidebarRow body | 사이드바 재계산 범위 |

**⑤ 설정 고정** (launch arg, `NSArgumentDomain`이라 `@AppStorage`보다 우선합니다)
- 고정값: `-autoRefreshEnabled NO`. 활성화 새로고침과 주기 타이머가 다른 시나리오를 오염시키지 않게 합니다. B3도 이 값으로 돌고, 드라이버가 `refreshOnActivation(honorThrottle:false)`을 직접 부릅니다(아래 B3 참고).

---

## 2. 재현 가능한 대형 라이브러리

### 생성기 (신규, 결정적)
`NookKit/Tests/NookKitTests/PerfLibraryGenerator.swift`에 Swift Testing 테스트를 하나 둡니다. env `NOOK_GEN_PERF_LIB=<dir>`가 없으면 skip합니다.
- 실제 `ReaderLibrary`/`Feed`/`Article` 모델과 `ReaderStorage.save`, `saveShard`로 씁니다. 그래서 스키마가 실제 앱과 정확히 같고, 손으로 JSON을 만들 때보다 안전합니다.
- 읽음/별표는 shard(`.nook/state/<perfDeviceID>.json`)에 LWW로 기록합니다. 프로젝트 규칙인 "user state는 shard"를 따르는 방식입니다.
- `SplitMix64(seed: 42)`를 써서 같은 입력이면 항상 같은 바이트가 나옵니다.

| 프로필 | 글 | 피드 | 폴더 | 카테고리(키워드) | Unread | Starred | 최대 피드 |
|---|---|---|---|---|---|---|---|
| `lib-5k` | 5,000 | 300 | 12 | 8 | 60% | 2% | ~500 |
| `lib-10k` | 10,000 | 300 | 12 | 8 | 60% | 2% | ~1,000 |
| `lib-20k` | 20,000 | 300 | 12 | 8 | 60% | 2% | ~2,000 |

- 피드별 글 수는 Zipf 분포입니다(상위 10개 피드가 30%). 작은 피드 `feed-small`은 30개로 고정해 "피드에서 All로" 원래 증상(5초 정지)을 재현합니다.
- 글 길이는 실제와 비슷하게: 제목 40~90자(한/영 혼합), summary 200자, body는 `NookContent.json`에 최근 일부만 넣습니다.
- body는 앱의 보존 정책과 같게 `ReaderStore.recentArticleIDs(from:)`가 남기는 최근 600개(`Article.isOrderedBefore` 순, `bodyRetentionLimit`)에만 넣습니다. 그래서 재실행 후의 실제 정상 상태와 같고, 600개 밖의 피드 윈도 글은 body 없이 로드됩니다. 따라서 현재 코드에서 `none` 새로고침은 `mergeChangedNoNew > 0`을 냅니다(lib-5k 기준 3,440개 글, 296개 피드). 이것이 Phase 1의 `MergeProjection`이 고치는 가짜 changed이며, B1 `changedNoNew = 0` 기준은 Phase 1 이후에 통과해야 합니다.
- `publishedAt`는 고정 기준일 `2026-10-01T00:00Z`부터 거꾸로 분포시킵니다. 실행 시각과 무관하게 같은 값이 나옵니다.
- 모든 `feedURL`은 `http://127.0.0.1:8765/f/<n>.xml`입니다. 외부 네트워크 호출은 0이어야 합니다.
- 실행 예:

```sh
NOOK_GEN_PERF_LIB=$PERF/golden/lib-10k NOOK_GEN_N=10000 swift test --package-path NookKit --filter PerfLibraryGenerator
```

### 새로고침용 피드 XML과 로컬 서버
- 같은 생성기가 `$PERF/feeds/<lib>/<variant>/f/<n>.xml`을 만듭니다. guid는 라이브러리와 같습니다.
  - `none`: 새 글 0. 가짜 changed가 나는지 봅니다.
  - `trickle`: 30개 피드에 새 글 +1.
  - `burst`: 모든 피드에 새 글 +5.
  - `big1`: `feed-big`에만 새 글 +3.
- 서버는 `tools/perf/feedserver.py --root $PERF/feeds/<lib>/<variant> --port 8765 --latency-seed 7`입니다. 요청마다 50~800ms 지연을 결정적으로 주어 실제 flush 간격(400ms)과 비슷하게 만듭니다. `Info.plist`의 ATS 설정이 cleartext를 허용하는지 첫 실행에서 `run.begin` 이후 fetch 에러 수로 확인합니다.

### 앱이 생성 라이브러리를 쓰게 하기 (DEBUG launch arg)
- `-NookPerfLibrary <dir>`를 주면 `restoreStorageIfPossible`(ReaderStore:4157)이 bookmark 대신 `ReaderStorage(directoryURL: dir)`를 씁니다.
- 이 모드에서는 ReplicaStore SQLite도 `~/Library/Application Support/Nook/Replicas`가 아니라 `<dir>/.nook-perf-replica/`에 둡니다. 아래 rsync `--delete` 복원이 DB까지 지우므로, 이전 실행이 merge한 글이 다음 실행으로 새지 않습니다. 앱은 `perf.replica dir=…`로 경로를 남깁니다.
- 이 모드에서는 **UserDefaults의 bookmark, display path, `usesLocalLibrary`에 아무것도 쓰지 않습니다.** 사용자의 실제 iCloud 라이브러리를 보호하기 위해서입니다.
- dir은 샌드박스에서 읽을 수 있는 위치여야 합니다. 서명된 빌드라면 `~/Library/Containers/com.tim.nook/Data/Documents/perf/…`, 서명 안 된 빌드라면 아무 경로나 됩니다.
- 실행 전마다 `rsync -a --delete $PERF/golden/lib-10k/ <dir>/`로 원본을 복원합니다. 이전 실행의 읽음 처리나 새로고침이 다음 실행을 오염시키지 않게 하려는 것입니다.
- 앱은 로드 후 `perf.library articles=10000 unread=6000 starred=200 feeds=300`을 note로 남깁니다. 이 숫자가 기대값과 다르면 그 실행은 무효입니다.

---

## 3. 자동화: 앱 안에서 도는 스크립트 드라이버

`Nook/PerfDriver.swift`(`#if DEBUG`, `@MainActor`)를 둡니다. `-NookPerfScript <json>`을 받으면 라이브러리 로드가 끝난 뒤 단계를 차례로 실행하고, 끝나면 `MainThreadLog.flush()`를 부르고 `NSApp.terminate`합니다.
- 한 단계만 별도 실행할 때는 `tools/perf/run.sh --only B3 …`처럼 `--only`를 주면 `-NookPerfOnly B3`로 넘어갑니다. 쉼표로 여러 ID를 지정할 수도 있습니다. `run-all.sh`는 refresh 단계(B 전부, `trickle`의 C4/E3)를 그룹 JSON에서 반복 1회·`coldFirst:false`로 파생한 스크립트와 `--only <ID>`로 단계·반복마다 별도 실행하므로 B2/B3/B5가 서로 오염되지 않습니다.
- 드라이버는 공개 API를 **어댑터 한 겹**을 거쳐 호출합니다: `selectSmartSource`, `feedSelection`, 카테고리 선택, `refreshAll()`, `refresh(feedID:)`, `refreshOnActivation(honorThrottle:false)`, `setRead`, `toggleStarred`, `selectedArticleID`. 그래서 Phase 사이에 이름이 바뀌어도 고칠 곳은 어댑터뿐입니다.
- 모든 단계의 형태는 같습니다: `settle`(2초 동안 stall 0, `isRefreshing == false`) → `scenarioBegin` → 동작 → `quiesce`(1.5초 동안 publish·settle·stall 0 + refresh 끝, 최대 180초) → `scenarioEnd`.
- 시나리오마다 5회 반복합니다. **cold**(실행 직후 첫 전환)는 A1에만 `coldFirst:true`로 rep 0을 붙여 따로 1회 기록합니다(`cold=1`). 실행 후 처음 도는 단계가 `coldFirst`를 적지 않았다면(예: `scroll.json`의 C1, `--only A2`) 드라이버가 rep 0을 `cold=1`로 더 돌리고 stats에 `warmup=1`을 붙입니다. perfreport는 이 rep을 warm 중앙값에서도, A1의 cold 기준에서도 빼고 `warmup`으로 셉니다. 실행당 1회가 표본인 파생 스크립트는 `coldFirst:false`를 적어 이 rep을 붙이지 않습니다. 그 밖의 rep은 모두 warm입니다.
- 창은 드라이버가 1440×900으로 고정하고, split view의 사이드바 270pt·목록 420pt도 고정합니다(`perf.layout listWidth=…`로 확인). 행 수 = 보이는 높이이기 때문입니다. 창 frame/divider autosave는 끄고 시작하므로 앱 defaults에 1440×900이 저장되지 않습니다.
- `quiesce`는 새로고침·publish·list/reader settle·stall이 1.5초 동안 없을 때 끝나고, 마지막 활동 시각을 시나리오의 활성 구간 끝으로 넘깁니다. 180초(300개 피드 ambient 새로고침이 동시 2개로 ~64초 걸리므로) 안에 조용해지지 않으면 `perf.quiesce.timeout id=…`(settle이면 `perf.settle.timeout`)을 남기며, 그 rep은 버립니다.
- 대상(피드/폴더/카테고리/행 index)을 찾지 못하거나 목록 스크롤 뷰가 없으면 `perf.driver.error …`를 남깁니다. 이 줄이 있는 실행은 무효입니다. 카테고리는 `"1"`/`"perf-cat-1"` 모두 id `perf-cat-1`로 찾습니다.

### 시나리오 (ID는 로그와 표에서 그대로 씁니다)

**A. 소스/탭 전환** (`lib-5k`, `lib-10k`, `lib-20k`)
- A1 `feed-small` → All (원래 5초 정지 증상)
- A2 All → Unread
- A3 Unread → All
- A4 All → Starred
- A5 Starred → All
- A6 All → `feed-big`
- A7 `feed-big` → 폴더(~25개 피드)
- A8 폴더 → 카테고리
- A9 다중 선택 50개 피드
- A10 다중 선택 전체 300개 피드 (8b88880 케이스)
- A11 피드 → All 전환 뒤 2초 이내에 → Unread (최신 결과만 반영되는지, latest-wins)

**B. 새로고침** (목록은 All, 피드 서버 실행 중)
- B1 수동 전체, `none` (가짜 변경 0인지 확인)
- B2 수동 전체, `trickle`
- B3 ambient, `trickle`: `refreshOnActivation(honorThrottle:false)`만 측정합니다. 드라이버는 ContentView가 자동 새로고침 루프를 시작하기 전에 돌고 `-autoRefreshEnabled NO`로 실행되므로 주기 타이머 경로는 이 측정에 포함되지 않습니다.
- B4 단일 피드 `refresh(feedID: feed-big)`, `big1`
- B5 B2와 같은 조건에서 목록을 Unread로 두고 실행

B 스크립트는 변형별로 나뉘고 `repetitions:1`입니다: `refresh-none.json`(B1), `refresh-trickle.json`(B2, B3, B5), `refresh-big1.json`(B4). 한 번 실행 안에서 rep을 반복하면 2회째부터는 이미 받은 XML을 다시 받는 "새 글 없음"이 되기 때문입니다. 5회는 run-all이 run.sh를 5번 돌려(매번 라이브러리 복원) 채우고, perfreport가 파일들을 모읍니다.

**C. 스크롤** (All, `lib-10k`/`lib-20k`)

드라이버가 목록 스크롤 뷰의 clip view를 **display-link 콜백마다 한 번씩** 움직입니다(probe의 콜백이 드라이버의 continuation을 깨웁니다). 타이머 slack과 무관하게 vsync당 이동이 정확히 1회이므로 결정적입니다. 250ms fallback은 링크가 살아 있고 재생 중이면 다시 무장하며, 링크가 없거나 일시 정지된 경우에만 `perf.frame.timeout`을 남기고 진행합니다. 재생 중인 링크가 연속 20번(5초) 콜백을 주지 않으면(창이 가려지거나 디스플레이가 잠든 경우) `perf.driver.error reason=displaylink-stalled`를 남기고 앱을 종료하므로, `open -W`로 기다리는 run.sh가 멈추지 않습니다. 따라서 측정 대상인 긴 메인 스레드 stall 자체가 실행을 무효화하지 않습니다.
- C1 fling: 맨 위에서 시작해 초기 속도 6000pt/s, 프레임당 감쇠 0.95로 8회 연속
- C2 스크롤바 드래그: 1초 동안 30단계로 끝까지, 그다음 `scrollToEndOfDocument` 즉시 점프 1회
- C3 키 반복: 먼저 목록 `NSTableView`를 first responder로 만듭니다(사이드바가 키를 가져가 피드 선택을 바꾸지 않게). 그다음 메인 액터와 독립된 wall-clock dispatch timer가 `NSApp.postEvent`로 ↓ keyDown/keyUp 쌍을 30Hz로 5초간 보냅니다(`postEvent`는 서브스레드에서 호출할 수 있고, List의 네이티브 선택을 이동시키며 첫 keyDown만 `isARepeat=false`). ⌘↓(Next Article, 리더를 엶)는 `target:"commandDown"`으로 같은 방식입니다. 앱에 j/k 단축키는 없으므로 ↓와 ⌘↓를 씁니다. 보내기 전에 테이블의 선택 행을 store의 선택 index(setup의 `selectIndex 0`)로 맞춥니다. ↓는 테이블 자신의 선택 행에서 움직이므로, 이걸 하지 않으면 이전 rep이 끝난 행에서 시작해 `moved`가 `posted`를 넘었습니다. 끝나면 테이블 선택이 1초간 멈출 때까지 기다린 뒤 **테이블 선택 행**의 변화로 이동 수를 세어 `perf.keys posted=N moved=M storeMoved=… startRow=… responder=table keysPostedOverMs=… achievedHz=…`와 stats의 `missedSelection = N − M`을 남깁니다. 시작 행이 store와 다르거나 `M`이 0..N 밖이면 `perf.driver.error`로 실행을 무효로 합니다.
- C4 C1 도중에 B2 시작 (새로고침 중 스크롤)
- C5 윈도 경계: 1500pt/s 등속으로 150행에서 450행까지 내려가며 200/400 경계를 넘깁니다. 이어서 `lib-20k`에서 끝까지 내립니다(스크롤로만 윈도가 커지는 구간).

**T. 목록 제목 번역 중** (`translate.json`, `lib-5k`, 실행당 1회. 대조군 `translate-off.json`은 같은 동작에서 번역만 끔)
- 스크립트의 `launchArgs`로 `-translateListTitles YES -appLanguage ja -NookFakeTranslator 20`을 넘깁니다(argument domain만, 저장 안 함). 일본어 대상이라 픽스처의 한국어·영어 제목이 모두 번역 대상이 됩니다. 실제 Apple Intelligence로 돌리려면 `-NookFakeTranslator`를 뺀 사본을 씁니다.
- 측정 모드에서는 번역 캐시 파일을 읽지도 쓰지도 않으므로(`ListTitleTranslator.cacheURL`), 매 실행이 번역 전 상태에서 시작합니다.
- T1 `feed-small` → All (전환 직후 보이는 행이 번역됨) · T2 fling 8회 · T3 ↓ 키 30Hz 5초 · T4 1500pt/s 등속 12초. 판정은 C군 기준이고, 번역 켬/끔의 차이(`list.row.height` 귀속 stall, hitchRatio)를 함께 봅니다.

실제 휠과 관성의 경로는 위 방식과 다릅니다. 그래서 Phase마다 한 번 `tools/perf/wheel.swift`(CGEvent scrollWheel, phase/momentumPhase 포함, Accessibility 권한 필요, Nook이 frontmost여야 함)로 C1을 검증합니다. 스킬 문서에 따르면 앱이 frontmost가 아니면 posted event가 사라지므로, 받은 이벤트 수를 로그로 확인합니다. computer-use는 화면 확인 용도로만 쓰고 타이밍 측정에는 쓰지 않습니다(스크린샷 지연 때문).

**D. 글 열기와 토글** (All, `lib-10k`)
- D1 500번째 행 선택 → 리더 첫 표시까지
- D1의 `readerTTFR`: 드라이버가 행을 선택하기 직전(`selectIndex`, `nextArticle`)에 시작하고, 그 뒤 첫 `reader.body`가 실행된 다음 heartbeat에서 끝납니다(`reader.settled sinceSelect=…`). `list.settled`와 같은 근사입니다.
- D2 ⌘⇧M 읽음 토글 20회 (2Hz)
- D3 ⌘⇧S 별표 토글 20회
- D4 Unread 목록에서 읽음 처리 → retained 행 유지
- D5 ⌘↓ 20회 (열 때마다 읽음 처리)

### 실행 스크립트
`tools/perf/run.sh [--only <ID>] <label> <lib> <script>`가 다음을 순서대로 합니다.
1. rsync로 라이브러리 복원
2. 피드 서버 실행
3. `DerivedData-perf/Build/Products/Debug/Nook.app/Contents/MacOS/Nook -NookPerfLibrary … -NookPerfScript … -NookPerfLabel <label> -NookPerfLog <launch.XXXXXX>/ui-forensics.log -NookStallMs 50 -autoRefreshEnabled NO -SUEnableAutomaticChecks NO -nookPlusSessionConfigured NO -geminiKeyConfigured NO …`를 **직접 실행**하고 그 PID를 기다립니다. `open`은 쓰지 않습니다. watchdog이 60초 안에 `perf.library`가 없거나 전체 상한(600초, `refresh*`는 300초)을 넘으면 그 자식 PID에만 TERM→KILL을 보내고 `perf.driver.error reason=launch-timeout`을 남긴 뒤 124로 끝냅니다.
4. 로그를 `perf-runs/<label>/<lib>-<script>[-<ID>]-<variant>-<n>.log`로 옮기고, `run.begin opt=`가 `-O`인지 확인하기

로그는 append 방식이므로 실행마다 파일을 옮겨 **실행 단위로 분리**합니다. 시간 간격으로 실행을 가르는 방식에는 의존하지 않습니다.

`run.begin` 뒤 `perf.library`까지 가지 못하던 실행의 원인은 `sample`로 두 가지를 확인했습니다. 두 수정 모두 DEBUG 전용이고 릴리스 동작은 그대로입니다.
- **서명 안 된 빌드의 Keychain 프롬프트.** `ContentView.init`이 만드는 `PlusStore`가 `PlusCredential.current`(`SecItemCopyMatching`)를 읽다가, 아무도 응답하지 않는 Keychain 접근 프롬프트에서 메인 스레드가 멈췄습니다. `-NookPerfLibrary`가 있으면(`PerfLaunch.isActive`) `PlusCredential.current`와 `GeminiCredential.apiKey`는 Keychain을 건드리지 않고 nil을 돌려줍니다. 그러면 Plus 호출이 `.sessionInvalid`로 실패해 sign-out을 부르므로, 쓰기 경로(`PlusCredential.store`/`signOut`, `GeminiCredential.setAPIKey`, `PlusOwnFeed.remember`, 로컬 앱 초기화)도 perf 실행에서는 아무것도 하지 않거나 실패합니다. 실제 Keychain 항목과 그 UserDefaults 플래그는 지워지지도 다시 쓰이지도 않습니다.
- **초기 창 없음.** 저장된 앱 상태 없이 직접 실행한 자식은 `Window("main")`을 받지 못했습니다. 실행 1초 뒤에도 보이는 창이 없으면 DEBUG launch hook이 자기 프로세스에 `kAEReopenApplication`(Dock 클릭과 같은 이벤트)을 보내고, 3초에 한 번 더 시도합니다. 창은 SwiftUI의 기본 reopen 처리로 열리고, `Window`는 단일 인스턴스라 두 번째 창이 생기지 않습니다.

run.sh는 `/Applications/Nook.app`, 저장소 밖의 앱(`NOOK_PERF_ALLOW_EXTERNAL_APP=1`이 없으면), 팀 서명된 앱, 현재 HEAD와 dirty 상태에 맞는 perf-build stamp가 없는 빌드를 띄우지 않습니다. `make perf-build`는 incremental build에서도 Debug 결과물의 Info.plist에 `tools/perf/build-id.sh`가 계산한 체크아웃 식별자를 `NookBuildSHA`로 기록하고, 앱이 이를 `run.begin binarySha=`로 읽습니다. 깨끗한 트리면 전체 HEAD SHA이고, 아니면 `<HEAD>-dirty-<12 hex>`입니다. 이 hex는 `git diff HEAD --binary`와 ignore되지 않은 untracked 파일의 경로·내용을 합친 SHA-256이라 미커밋 수정 내용과 새 파일(NookKit과 synchronized 폴더는 untracked 파일도 컴파일합니다)까지 구분합니다. run.sh는 같은 스크립트로 식별자를 계산해 `-NookPerfSHA`로 넘기므로 `sha=`와 `binarySha=`를 그대로 비교할 수 있습니다. 커밋(문서만 바뀐 경우 포함), 소스 수정, untracked 파일 추가·삭제 뒤에는 다시 빌드합니다. 경로 비교에는 심볼릭 링크를 해소한 실제 경로를 씁니다. 실행마다 `perf-runs/.work/<label>/launch.XXXXXX/`에 `stdout.log`/`stderr.log`가 남고, 실패 메시지가 그 `stderr.log`를 알려줍니다.

perf 모드의 `UpdateController`는 pending update를 읽거나 Sparkle을 생성하기 전에 반환하므로 appcast fetch, 업데이트 chip, Sparkle의 SU* 및 pending-update defaults 쓰기가 없습니다. `@AppStorage`나 sort order 같은 나머지 defaults 쓰기는 서명 안 된 개발 빌드의 preferences 도메인에 생길 수 있으며, 설치된 sandbox 앱의 container 도메인과는 별개입니다.

run-all은 자신의 INT/TERM trap이 실행된 경우에만 전체 matrix를 중단하고 해당 그룹을 `groups.txt`에 aborted로 남깁니다. 자식의 130/143 종료만으로는 matrix를 중단하지 않습니다. run.sh는 app/xctrace의 signal 종료를 `perf.driver.error reason=signal`로 기록하고 1로 정규화하며, 자신의 INT/TERM trap에만 130/143을 사용합니다.

### 노이즈 통제
- 같은 머신, 전원 연결, 다른 앱 종료, Low Power 꺼짐
- 실행 전 `pmset -g therm`이 정상인지 확인
- 디스플레이 Hz를 `run.begin`에 기록합니다. ProMotion이면 120Hz와 60Hz를 섞어서 비교하지 않습니다.
- before와 after는 모두 `make perf-build`로 빌드하고 같은 서명 여부로 측정합니다. 이 타깃은 DEBUG 계측을 유지하면서 Swift 앱 코드를 `-O`로 최적화하므로, `-Onone`이 대형 SwiftUI 목록 비용을 과장해 비교 실행을 수십 초씩 늘리는 문제를 피합니다. 결과물은 `DerivedData-perf/`에 따로 쌓이므로 `make build`(`-Onone`, `DerivedData/`)가 덮어쓰지 않고, run.sh는 기본으로 이 앱을 띄웁니다. 실행 로그의 `run.begin opt=`가 `-O`가 아니면 run.sh는 실패하고(stamp 검사에 이은 이중 방어입니다), perfreport는 opt가 섞인 실행을 요약하거나 비교하지 않습니다.

---

## 4. 로그 형식과 집계

```
<t> run.begin        label=before-ebd5ee6 sha=ebd5ee6c0d6b1f4e9a2c3b7d8e5f60718293a4b5 binarySha=ebd5ee6c0d6b1f4e9a2c3b7d8e5f60718293a4b5 lib=lib-10k hz=120 opt=-O log=/…/ui-forensics.log
<t> perf.replica     dir=/…/lib-10k/.nook-perf-replica/
<t> perf.library     articles=10000 unread=6000 starred=200 feeds=300
<t> perf.layout      window=1440x900 listWidth=420 columns=0+270,0+691,692+748
<t> scenario.begin   id=A1 rep=2 cold=0
<t> select.begin     source=all
<t> list.publish     rows=30->10000 animated=false
<t> list.settled     sinceSelect=812ms
<t> STALL            for 0.78s during list.publish  ran list.rowcontentx20000, …
<t> scenario.stats   id=A1 rep=2 cold=0 dur=2310 activeDur=812 stalls50=3 … ttfr=812 readerTTFR=-1 publish=1 …
```

### `scenario.stats` 키 (순서 고정, 공백 구분 `key=value`)

항상 나오는 키:

| 키 | 뜻 |
|---|---|
| `id`, `rep`, `cold` | 시나리오 ID, 반복 번호, `cold=1`이면 실행 직후 첫 전환(A1의 rep 0). perfreport는 cold를 warm 통계에서 빼고 따로 봅니다 |
| `dur` | `scenarioBegin`부터 `scenarioEnd`까지의 벽시계 ms (quiesce 꼬리 1.5초 포함) |
| `activeDur` | 활성 구간 ms: 시작부터 max(동작 종료, 마지막 publish, 마지막 list/reader settle, 마지막 stall 종료, 새로고침 종료)까지. 비율 지표의 분모입니다 |
| `stalls50`/`100`/`250`/`500`/`1000`, `worstStall`, `stalledMs` | 시나리오 중 stall 개수(길이별 누적), 최장 ms, 합계 ms |
| `ttfr` | select.begin → 다음 publish 후 첫 heartbeat(ms). **`-1`이면 이 시나리오 안에서 선택→settle이 일어나지 않았다는 뜻**입니다(새로고침·스크롤·토글, 같은 결과라 publish가 없는 선택 등). perfreport는 음수를 건너뜁니다. 시작 전 setup의 선택 상태는 `scenarioBegin`에서 지웁니다 |
| `readerTTFR` | 드라이버의 글 선택 → 첫 `reader.body` 후 첫 heartbeat(ms). 시나리오 안에서 여러 번이면 최댓값. `-1`은 측정 안 됨 |
| `publish`, `publishAnimated` | `list.publish` + `list.publish.animated` 호출 합, 그중 animated 수. 두 라벨은 예전처럼 서로 배타적으로 셉니다 |
| `publishRows` | 시나리오 첫 publish의 새 행 수 |
| `body`, `rowcontent`, `row`, `rowHeight`, `rowHeightFlush`, `rowMenu`, `relTime`, `rootBody`, `sidebarBody`, `sidebarRow`, `readerBody`, `titleBox`, `titleBoxRelease` | 카운터 호출 수: `list.body`, `list.rowcontent`, `list.row`, `list.row.height`, `list.row.height.flush`, `list.row.menu`+`list.row.swipe`, `relativetime.body`, `root.body`, `sidebar.body`, `sidebar.row`, `reader.body`, `list.title.box`, `list.title.box.release` |
| `frames`, `dropped`, `droppedPct`, `hitchMs`, `hitchRatio`, `p99Frame`, `worstFrame` | 활성 구간의 display-link 프레임 통계. `droppedPct = dropped / (frames + dropped) × 100`, `hitchRatio = hitchMs / (activeDur/1000)` |
| `applyMs`, `didsetMs`, `markSeenMs` | `store.applyDisplayed`, `store.didset.articles`, `store.markSeen` 합계 ms |
| `mergeMs`, `mergeP95`, `mergeCalls` | `store.merge` 합계 ms, 호출당 p95 ms, 호출 수. B 기준 "flush당 메인 ms p95 ≤5ms"는 `mergeP95`로 봅니다 |
| `mergeFlush`, `mergeChangedNoNew`, `mergeFallback` | 각 카운터 호출 수 |
| `hlcTick` | `store.hlc.tick` 호출 수 |
| `updateInPlaceMs`, `updateInPlaceMaxMs` | `store.updateInPlace` 합계 ms, 호출 1회 최대 ms. D의 "토글 1회 ≤16ms"는 `updateInPlaceMaxMs`(또는 `updateInPlaceMs / toggles`)로 봅니다 |
| `grow`, `growMaxMs` | `list.window.grow` 호출 수, 1회 최대 ms |

해당 동작을 하는 시나리오에만 붙는 키(줄 끝):

| 키 | 붙는 동작 | 뜻 |
|---|---|---|
| `toggles` | `toggleRead`, `toggleStarRepeat`, `nextRepeat`(count), `setRead`/`toggleStar`/`nextArticle`(1) | 토글 횟수. 토글당 지표는 이 값으로 나눕니다. 키가 없으면 나누지 않습니다 |
| `keysPosted`, `keysMoved`, `missedSelection` | `keyRepeat` (C3) | 보낸 ↓ 수, 실제 선택 이동 수, 누락(`posted − moved`) |

`tools/perf/perfreport.py`는 신규 파일이고 `.claude/skills/ui-behavior-forensics/`에 함께 둡니다.
- `perfreport.py perf-runs/<label>`은 `scenario.stats`만 읽어 시나리오별 **median of 5 / worst of 5**를 냅니다(`cold=1`은 따로).
- 같은 로그에 `perf.driver.error`, `perf.quiesce.timeout`, `perf.settle.timeout`, `perf.frame.timeout`이 있으면 그 실행(또는 해당 rep)은 무효로 봅니다.
- `--compare before-ebd5ee6 after-p2`는 5절 표를 markdown으로 출력하고, 임계값 PASS/FAIL과 10% 이상 악화된 회귀를 표시합니다.
- `--trail A1`은 원본 줄을 그대로 출력합니다. 요약을 믿기 전에 원본을 읽으라는 스킬 원칙을 따릅니다.
- `--strict`는 Gate failures가 하나라도 있으면 exit 1입니다.

---

## 5. 지표와 통과 기준

게이트는 `lib-10k`에만 적용합니다. `lib-20k`는 `stalls≥250`, A의 `worstStall<250`, C5의 `growMaxMs`/`stalls100`만 적용하고, `lib-5k`는 보고만 합니다.

| 군 | 지표 | PASS |
|---|---|---|
| **A 전환** | worstStall (worst of 5) | <100ms (20k: <250ms) |
| | stalls≥250 | 0 |
| | ttfr (select → list.settled) | median ≤150ms, worst ≤250ms (cold ≤400ms) |
| | 첫 publish rows | `->≤ max(200, sel+50)` (윈도 동작 확인) |
| | rowcontent / publish | ≤ 2 × 윈도 행 수 (≈400) |
| | publish 횟수 | 전환 1회당 ≤2 (중복 prune/retain 제거 확인) |
| | applyMs | ≤2ms |
| **B 새로고침** | stalls≥250 / stalls≥100 | 0 / 실행당 ≤1 |
| | mergeP95 (merge 호출당 메인 ms) | p95 ≤5ms |
| | publish 횟수 | ≤ ceil(dur / 1.5s) + 1 |
| | mergeChangedNoNew (B1) | 0 |
| | B1의 publish | 0 (새 글 없음 → 관찰 이벤트 없음) |
| | mergeFallback 비율 | ≤10% of flush |
| | idle 목록 hitchRatio | <5 ms/s |
| **C 스크롤** | hitchRatio | <5 ms/s (Apple "good"). 5~10은 경고 |
| | worstFrame | <100ms. C5 경계 포함 |
| | stalls≥100 | 0 (C4 포함) |
| | growMaxMs (`list.window.grow`) | ≤8ms |
| | C3 키 반복 | droppedPct ≤2%, missedSelection 0 |
| **D 열기/토글** | 토글 1회 메인 ms (`updateInPlaceMaxMs`, 다음 commit은 stall/frames로) | ≤16ms |
| | 토글 1회 rowcontent | ≤5 (해당 행만) |
| | 토글 1회 list.body | ≤1 |
| | D1 readerTTFR (select → 리더 첫 표시) | ≤100ms, stall≥100 = 0 |
| | D5 hlcTick / markSeen | 1회 열 때 tick 1회 |

메커니즘 확인 항목은 숫자가 개선된 이유가 계획대로인지 봅니다.
- A1 before에서 `rowcontent/body`가 약 20(250a6a3의 8,865/418 관찰과 같은 비율)인지
- after에서 `publishRows` 상한이 지켜지는지
- B1에서 `changedNoNew`가 0으로 떨어지는지

---

## 6. 보조 측정: xcrun xctrace (헤드리스)

이 머신에서 확인한 사양은 xctrace 16.0입니다. 템플릿은 `Time Profiler`, `Hangs`, `Animation Hitches`, `SwiftUI`, `System Trace`가 있고, instrument는 `Hitches`, `Hangs`, `os_signpost`, `Core Animation Commits`가 있습니다.

```sh
APP=DerivedData-perf/Build/Products/Debug/Nook.app/Contents/MacOS/Nook
xcrun xctrace record --template 'Animation Hitches' --time-limit 60s \
  --output perf-runs/after-p2/C1.trace \
  --launch -- "$APP" -NookPerfLibrary … -NookPerfScript scroll.json -NookPerfLabel after-p2
xcrun xctrace record --template 'Hangs'        … --launch -- "$APP" … switch.json
xcrun xctrace record --template 'Time Profiler' … --launch -- "$APP" … switch.json
xcrun xctrace export --input perf-runs/after-p2/C1.trace --toc          # 스키마 이름 확인
xcrun xctrace export --input … --xpath '/trace-toc/run[@number="1"]/data/table[@schema="<toc에서 확인한 hitches/hang 스키마>"]' > c1-hitches.xml
```

- **역할**: Animation Hitches는 렌더 서버 쪽 히치까지 잡아 ③을 교차 검증합니다. Hangs는 watchdog 수치를 교차 검증합니다. Time Profiler는 정지 구간의 실제 프레임(SwiftUI graph update, NSTableView insert 등)을 보여줍니다. ④의 signpost가 같은 타임라인에 시나리오 구간을 표시합니다.
- **주의 1**: `--launch`나 `--attach`에는 `get-task-allow`가 필요합니다. Debug 빌드는 보통 문제없습니다. `CODE_SIGNING_ALLOWED=NO` 빌드는 entitlement가 없어 샌드박스가 꺼지므로 경로와 동작이 서명 빌드와 다릅니다. before와 after는 반드시 같은 방식으로 빌드합니다.
- **주의 2**: 기본 Debug(`-Onone`)는 앱 코드 비용을 부풀립니다. 자동화 판정용 before/after는 `make perf-build`의 최적화된 Debug(`-O`)로 측정합니다. 최종 확인으로 Release에서 Hangs를 한 번 측정하며, 이 경우 드라이버가 DEBUG 전용이라 A1/B2를 손으로 재현합니다.
- 헤드리스로 돌리려면 GUI 세션이 로그인된 상태여야 합니다(앱이 창을 띄우기 때문). SSH만으로는 불가능합니다.

---

## 7. 결과 표 형식

`perfreport.py --compare` 출력 예시입니다. 값은 형식만 보여주는 자리표시이고 측정값이 아닙니다.

| ID | lib | 지표 | before (med / worst) | after (med / worst) | Δ med | 기준 | 판정 |
|---|---|---|---|---|---|---|---|
| A1 | 10k | worstStall ms | – / – | – / – | – | <100 | – |
| A1 | 10k | ttfr ms | – / – | – / – | – | ≤150 / ≤250 | – |
| A1 | 10k | publishRows · rowcontent/publish | – | – | – | ≤200 · ≤400 | – |
| B2 | 10k | mergeP95 · publish/activeDur | – | – | – | ≤5 · ≤dur/1.5+1 | – |
| B1 | 10k | changedNoNew | – | – | – | 0 | – |
| C1 | 10k | hitchRatio ms/s · worstFrame | – | – | – | <5 · <100 | – |
| C5 | 20k | growMaxMs · stalls≥100 | – | – | – | ≤8 · 0 | – |
| D2 | 10k | toggle ms · rowcontent/toggle | – | – | – | ≤16 · ≤5 | – |

표 아래에는 `run.begin` 줄(label, sha, hz, opt)과 실행 횟수를 붙이고, 인과 근거로 `--trail` 원본 1건을 붙입니다.

---

## 8. 실행 순서
1. **P0 커밋**: 계측 ①~④, 드라이버, 생성기, 피드 서버, perfreport. 제품 동작은 바꾸지 않습니다.
2. 생성기로 `golden/lib-{5k,10k,20k}`와 `feeds/<lib>/{none,trickle,burst,big1}`를 만듭니다.
3. 기준선: `run.sh before-<P0 sha>`로 A/B/C/D를 lib별 5회씩 돌립니다. xctrace는 A1, B2, C1을 1회씩 돌립니다.
4. Phase 1~4가 끝날 때마다 `after-p<N>`으로 같은 세트를 돌리고 `--compare` 표를 커밋 메시지나 보고서에 첨부합니다. Phase 5(NSTableView) 진행 여부는 C1/C5에서 "윈도 상한 패스 1회 >16ms"가 남는지로 판단합니다.
5. 통과 후 계측을 제거할지 남길지 결정합니다. 스킬 원칙은 질문에 답이 나오면 제거하는 것입니다. 드라이버와 생성기는 회귀 방지용으로 남길 수 있습니다.

### 참고 파일
- `/Users/tim/Projects/personal/nook/NookKit/Sources/NookKit/MainThreadLog.swift` (watchdog threshold 0.25, heartbeat 0.05)
- `/Users/tim/Projects/personal/nook/NookKit/Sources/NookKit/ReaderStore.swift` (applyDisplayed 909~978, restoreStorageIfPossible 4157, merge 4724, flushBatchMerges 4937, markVisibleArticlesSeen 2343, RefreshMode 293~)
- `/Users/tim/Projects/personal/nook/Nook/ContentView.swift` (목록 1503~1545, 명령 ⌘⇧M/⌘⇧S/⌘↓ 4130~4165)
- `/Users/tim/Projects/personal/nook/Nook/NookApp.swift` (SUMMARY 154/162, autoRefresh 기본값 199~200)
- `/Users/tim/Projects/personal/nook/.claude/skills/ui-behavior-forensics/readlog.py` (geometry 전용이라 perfreport.py를 새로 만들어야 함)
