# 대량 글 목록 렉 제거 계획 회귀 체크리스트

`docs/perf/plan.md`의 Phase 0~5를 기준으로 정리했습니다. 원본 항목은 91개였고, 중복을 합쳐 71개가 됐습니다. 현재 코드를 grep으로 대조했고 1개를 제외했습니다(맨 아래 참고).

형식은 `[ ] 불변식 — 확인 방법 (커밋) — 위험 Phase`입니다. 그룹 안에서는 위험이 큰 항목이 위에 있습니다.

---

## 1. 새로고침 merge off-main (Phase 3: generation guard)
- [ ] **articles/deletedArticleIDs를 바꾸는 모든 경로가 `articlesGeneration`을 올린다.** 대상 경로는 다음과 같습니다.
  - didSet
  - setRead/setStarred, markFeedRead의 `suppressArticlesDidSet` 경로 (현재 9곳)
  - deleteArticle, removeFeed/removeFolders
  - 카테고리 쓰기: setArticleCategories, bulk categorize, `drainAICategorizeQueue`의 `flushEvery`=25 일괄 대입
  - `performDateResolution`의 `articles = articles.map`
  - apply/reloadMerged/shard materialize

  generation이 다르면 미리 계산한 결과를 절대 설치하지 않는다 — `articles =`, `articles[`, `suppressArticlesDidSet = true`, `deletedArticleIDs` 쓰기를 모두 grep해 하나하나 대조. 300피드 새로고침 중 read/star/delete를 반복해 되돌아가는 토글이 없는지 확인 (c6dd34d, 527c4dc, 6a0e17b, 613e39c, 9cc80df) — 3
- [ ] **사용자 상태는 install 시점의 기존 article에서 가져온다(snapshot 시점 아님).** isRead, isStarred, `article.categories = existing.categories`가 대상이다 — NookKitTests에 "snapshot → setRead/카테고리 flush → install 시 보존" 테스트 추가. 기존 MaterializeTests와 ShardStorageTests 통과 (527c4dc, 8051b5c, 416bc78) — 3
- [ ] **피드의 사용자 필드는 live feeds에서 다시 적용한다.** category, preferredViewMode, customTitle이 대상이다. merge가 진행 중일 때 폴더 이동이나 이름 변경을 해도 유지돼야 한다 — `updated.category = updatedFeeds[...]`(merge ~4755)의 의미를 유지. 테스트: computeMerge 시작 → 피드를 폴더로 이동 → install → 폴더 유지 (d3ccb11, 8fd3e0c) — 3
- [ ] **삭제가 이긴다.** 다음 셋을 install 시점에 다시 검사한다.
  - `deletedArticleIDs.contains(newArticle.id)`
  - bodyCache 쓰기에서 삭제된 id 제외
  - install 직전, 사라진 피드와 tombstone 처리된 피드는 버리고 recordFeedRestored/recordFeedSeed를 호출하지 않음

  `discardPendingBatchMerges`는 removeFeed/removeFolders에 그대로 둔다 — DeletedArticleGuardTests를 `_mergeForTesting` 경로로 통과. 새 테스트: snapshot → removeFeed(X) + 글 A 삭제 → install → X와 A가 없고 ownShard에 restored(X)가 없음 (c7d1a61, af273d0, c6dd34d, 8fd3e0c) — 3
- [ ] **즉시 merge한 피드를 in-flight bucket이 덮지 않는다.** 단일 피드 `merge(_:)`는 즉시 실행되고 `pendingBatchMerges.removeAll{ id == }`로 버퍼를 비운다. 이후 in-flight bucket에 남은 X(old)가 즉시 merge된 X(new)를 덮으면 안 된다 — 테스트: in-flight X(old) + 즉시 X(new) → 결과는 X(new) (c6dd34d) — 3
- [ ] **merge 부수효과는 메인 install에서 bucket당 정확히 1회 실행한다.** fallback 시 중복되지 않고, 성공 시 누락되지 않아야 한다. 대상은 다음과 같다.
  - recordFeedSeed: dedup guard `ownShard.feedState[id]?.seed?.value != seed`(5300) 유지
  - recordFeedRestored와 scheduleShardSave
  - newlyArrivedIDs에 대한 recordArticleCategories(from: [], to:)와 enqueueAICategorization
  - `keywordAutoCategories`: categories 스냅샷이 필요하다
  - flashFeedUpdate: `feedIDsWithArticles`는 batch 전에 계산
  - `datelessArticleIDs.insert`: 새 글과 기존 글 모두
  - 끝난 뒤 pruneSelectionIfHidden

  — install 지점 리뷰. 변경 없는 새로고침이면 `.nook/state` mtime이 그대로인지 확인 (c6dd34d, 6e2345e, 8051b5c, 9cc80df, 4677178, 7edfc70, 8fd3e0c) — 3
- [ ] **`runBatchedFetch`의 두 지점이 in-flight merge의 install까지 await한다.** 시작만 하고 넘어가면 안 된다.
  - 명시적 end flush("Explicit end flush"): lastRefreshedAt, resolveMissingDates, notifier, `retryFailedFeedsOnce`의 healthScore 읽기보다 먼저
  - defer: isBatchRefreshing=false, 최종 비디바운스 필터, `scheduleSave()` 1회보다 먼저

  그래서 refreshAllAndWait, refreshFeedsAndWait, activationRefreshInFlight는 마지막 install이 끝난 뒤에야 끝난다 — 테스트: `await refreshAllAndWait()` 후 store.articles에 모든 글이 있음. 새로고침 직후 종료 → 재실행 시 최신 글 존재. iOS pull-to-refresh 스피너가 새 행이 나온 뒤에 멈추는지 확인 (c6dd34d, 8fd3e0c, f3e0ff9, 424b3e7, 7b66989, 20db6e4) — 3
- [ ] **batched fetch는 직렬로 실행된다.** `startBatchedFetch`가 `predecessor?.value`를 await한다. in-flight computeMerge는 그것을 시작한 batch에 속하므로, 다음 batch의 첫 flush 뒤에 이전 merge가 install되면 안 된다 — Refresh All 직후 pull-to-refresh나 import를 해서, fetch group이 살아 있는 동안 isBatchRefreshing이 false가 되지 않는지 확인 (0ff2c7f) — 3
- [ ] **취소 경로를 지킨다.** addFeed가 refresh를 취소하면 다음이 성립해야 한다.
  - `if Task.isCancelled { continue }`: merge도 health 갱신도 하지 않는다
  - 취소된 refresh의 in-flight bucket은 install하지 않는다
  - defer의 await가 add를 막거나 deadlock시키지 않는다
  - 취소 전에 도착한 결과는 merge한다
  - `activationRefreshThrottle`는 300s를 유지한다

  — Refresh All 중 Add Feed를 눌러 바로 완료되고 unhealthy 표시가 없는지 확인 (5428877) — 3
- [ ] **off-main 계산은 install 전에 메인에서 다시 검증한다.** reloadMerged의 `guard !isRefreshing`, `ownShard.generation == generationBefore`, `snapshot.revision >= appliedReplicaRevision`을 유지한다. 모든 refresh 진입점은 feeds 스냅샷을 잡기 전에 `await reloadMerged()`(syncFirst)를 실행한다 — ReaderStore 1351-1354, 1392, 4275 확인. refresh/refreshFeed 호출부 확인 (6a0e17b, bc56a39, 7c69ac1) — 3
- [ ] **install은 `apply(_:precomputed:)` 패턴을 그대로 따른다.** 순서는 다음과 같다.
  1. feeds를 articles보다 먼저 설치
  2. articles를 `suppressArticlesDidSet` 아래에서 설치
  3. textFilteredArticleIDs, filterClassifyCache, filteredArticleIDs, counts를 함께 설치(바뀐 경우만)
  4. updateUnreadBadge()
  5. scheduleArticleFilter(debounced: true)

  precomputeFilterState는 filters/categories와 한 snapshot이어야 하고, 필터나 카테고리가 바뀌었으면 결과를 버린다 — apply(5030-5048)와 한 줄씩 비교. 새로고침 중 필터를 편집해 Filtered 수가 정확한지 확인 (bc56a39, 36e09bc) — 3
- [ ] **re-key가 끝난 ParsedFeed만 merge에 들어간다.** 대상은 `existingFeedID#seed`와 HTML discovery로 찾은 `target.id`다. merge 결과 순서는 결정적이어야 한다: `Article.isOrdered`로 정렬하고 Dictionary나 Set 순서에 기대지 않는다 — computeMerge에 동일 timestamp 결정성 테스트와 discovered-id 테스트 추가. ArticleOrderingTests 통과 (99c48f4, 8fd3e0c, 7aa2cfe) — 3
- [ ] **`existingArticlesByID[id] != article`(4821)를 대체하는 MergeProjection은 다음을 지킨다.**
  - (a) `if !article.hasExplicitPublishDate { publishedAt = existing }`(4805/4818)를 비교 **전에** 적용
  - (b) title, summary, body(contentHTML/bodyParagraphs) 변경은 changed로 판정. 기존 글이 list-light(body 없음)인 경우도 포함
  - (c) changed 여부와 무관하게 bodyCache는 갱신
  - (d) datelessArticleIDs에 계속 insert

  — 단위 테스트 네 가지: 동일 ParsedFeed 2회 → changed=false이고 articles/feeds 쓰기 0. dateless 글 → first-seen 유지. 날짜가 잘못 저장된 dated 글 → changed. body B1→B2 → changed. CachedBodyFingerprintTests와 NookPostOriginTests 통과 (e9f463a, adc8e17, f6d01c4, 14bbfab, 9cc80df) — 1, 3
- [ ] **변경 없는 새로고침은 아무것도 게시하지 않는다.** articles는 `hasNewArticles || hasChangedArticles`일 때만, feeds는 `feedsChanged`일 때만 대입한다. 이때 lastFetchedAt은 같게 맞춘 뒤 비교한다(`comparable.lastFetchedAt`, 4765). 변경이 없는 outcome은 generation도 올리지 않는다 — Phase 0 카운터 `store.merge.changed`가 0에 가까운지 확인 (14bbfab, 8fd3e0c) — 1, 3
- [ ] **reloadMerged와 shard 적용의 변경 감지는 Article 전체 동등성을 그대로 쓴다.** `merged.articles != articles` 등은 바꾸지 않는다. MergeProjection은 merge(batch:) 안에서만 쓴다 — grep `merged.articles != articles`. 두 기기에서 읽음이나 카테고리가 반영되는지 확인 (886a08c, 8051b5c) — 1
- [ ] **bulk import 규칙을 유지한다.** 대상은 다음과 같다.
  - `bulkImportDepth`는 카운터이고 defer로 감소
  - isBulkImporting 동안 애니메이션 없음
  - flush 간격은 `bulkImportFlushInterval` 1.5s (`batchMergeFlushInterval` 400ms가 아님)이고, schedule 시점에 읽음
  - ensureFavicon은 디스크 읽기를 건너뜀
  - refreshFavicon은 detached로 처리

  새 1.5s 필터 throttle이 import 주기를 줄이면 안 된다 — grep isBulkImporting(현재 7곳). iOS에서 OPML 90개를 import하며 UI 반응을 확인 (c7202fd) — 1, 3
- [ ] **favicon은 `feedIcons[id] == nil`인 피드만 off-main으로 읽는다(5071).** install 때마다 전 피드에 ensureFavicon/loadCachedFavicons를 돌리지 않는다 — loadCachedFavicons의 guard 유지 (50e51a2) — 3
- [ ] **실패는 조용히 처리한다.** refresh가 실패하면 `markFeedUnhealthy`만 호출하고 errorMessage는 쓰지 않는다. merge가 성공하면 healthScore를 리셋한다 — 오프라인에서 새로고침 → 삼각형 표시, 온라인에서 새로고침 → 표시가 지워지고 alert 없음 (7b66989) — 3

## 2. 소스·탭 전환과 선택 (Phase 1.1, 2)
- [ ] **세 selection didSet(`smartSelection`, `feedSelection`, `categorySelection`, ~78-103)은 `guard newValue != oldValue`를 맨 앞에 둔다.** 새로 넣는 `retainedArticleIDs.removeAll()`도 이 guard 뒤, 그리고 **`scheduleArticleFilter()`보다 먼저** 둔다. performArticleFilter가 `retained`를 동기로 캡처하기 때문이다. categorySelection didSet에도 넣는다 — didSet 코드 리뷰. 전체 피드 선택이나 드래그 선택 시 list.publish가 1회인지 확인 (8b88880, 14bbfab, 6e4ee22) — 1
- [ ] **같은 소스를 다시 고를 때의 동작을 명시적으로 정한다.** 현재 selectSmartSource(1074-1075), selectCategory(1084-1085), selectFolder(2380-2381)는 무조건 clear와 prune을 한다. 그대로 유지하거나 변경을 문서화하되, macOS와 iOS가 달라지면 안 된다. iOS는 selectSmartSource를 반복 호출한다(RootView 933, 1162). iOS에서 같은 필터를 다시 고르면 무해한 no-op이어야 한다 — Unread에서 글을 읽은 뒤 Unread를 다시 클릭해, 계획 전과 후의 동작을 비교 (6e4ee22, 8b88880, c58ff64) — 1
- [ ] **ContentView 1602-1606의 onChange 2개를 지우려면, feedSelection을 바꾸는 모든 경로가 retained clear와 prune을 1회씩 해야 한다.** 대상은 selectFolder(빈 폴더라 [] → []인 경우 포함), removeFolders의 subtract, 피드 삭제, My Nook tag, iOS의 직접 쓰기(RootView 407-408, 1197-1198, 2569-2570), openArticle이다 — 빈 폴더 선택으로 prune 확인. category → 빈 폴더로 가면 category가 해제되는지 확인 (8b88880, 397fbb2, c58ff64) — 1
- [ ] **어떤 경로도 selectedArticleID를 non-nil로 자동 설정하지 않는다.** applyDisplayed, window 전체 교체, ensureVisible, requestGrowth, 소스 전환이 대상이다. pruneSelectionIfHidden은 clear만 한다("deliberately does NOT auto-select" 주석). followOwnFeed는 nil로 만든 뒤 피드를 선택한다 — 새 코드에서 grep `selectedArticleID =`. 재실행하면 "Select an Article"이 나오고 unread가 줄지 않는지, My Nook 클릭 시 글이 열리지 않는지 확인 (78f5655, d0c3dec) — 2
- [ ] **applyDisplayed는 install마다 prune을 1회 한다.** isIdentical로 skip하는 경로도 포함한다. 멤버십은 **전체 결과(indexByID)** 기준이며 window.rows 기준이 아니다 — 5,000개 중 900번째 행을 선택한 뒤 refresh나 filter를 해도 선택이 유지되는지 확인 (78f5655, 14bbfab) — 1, 2
- [ ] **retained 글은 dwell과 새로고침 중 다시 필터해도 목록에 남는다.** `(matchesSource || retained.contains && matchesSourceIgnoringReadState)`를 유지한다. 실제로 source가 바뀔 때만 해제하고, 읽음 변경이나 merge install로는 해제하지 않는다 — Unread → 글 열기 → 3s → 새로고침 → 유지, 이후 소스 전환 → 사라짐 (6e4ee22) — 1, 3
- [ ] **`selectSmartSource(.all)`로 돌아가는 경로는 완전한 전환이어야 한다(retained clear, prune, refilter).** 대상은 applyFilterChange(마지막 필터 삭제), applyCategoryChange, removeOffline/clearOfflineCache다 — Filtered에서 필터를 모두 삭제, Downloaded에서 Remove All → All이 되고 잔여 행이 없음 (886a08c, 0e47804) — 1
- [ ] **categorySelection은 다른 scope와 함께 설정되지 않는다.** 대상은 다음과 같다.
  - feedSelection이 비어 있지 않을 때만 didSet에서 category를 해제
  - selectFolder는 빈 폴더여도 category를 해제
  - category 삭제 시 `.all`로 이동
  - category branch에는 read와 hidden 글을 포함

  — 수동: category → 빈 폴더 / hidden 포함 category / 활성 category 삭제 (397fbb2) — 1
- [ ] **사용자가 일으킨 필터(소스·피드·폴더 선택, 검색)는 debounce를 취소하고 즉시 실행한다.** 1.5s throttle은 isBatchRefreshing 중의 데이터 트리거(`debounced: true`)에만 적용한다. 검색을 지우면 즉시 반영되고(빈 쿼리는 debounce 없음), openArticle은 searchDebounceTask를 취소하고 쿼리를 비운다 — 300피드 새로고침 중 피드를 클릭하면 100ms 안에 갱신되는지 확인 (61ce11b, 1a464ad) — 1
- [ ] **retainArticle은 `!contains` guard를 유지한다.** 전체 목록(indexByID)에 없을 때만 필터를 예약한다 — retainArticle 리뷰 (14bbfab) — 2
- [ ] **selectNext/PreviousArticle은 선택을 옮긴 뒤 `syncBrowserModeToSelection()`을 호출한다** — 함수 본문 리뷰 (b4b9e21) — 2

## 3. 윈도 큐와 목록 렌더 (Phase 2)
- [ ] **`displayedArticles`/`visibleArticles`는 항상 정렬된 전체 결과로 observable하게 게시한다.** window prefix가 아니다. 이 목록을 읽는 곳은 다음과 같다.
  - iOS RootView: `List(store.visibleArticles)`, `.onChange(of: visibleArticles.count)`, ListSpotlight, iPad의 `listRowBackground`, ReaderPushingList의 `first(where:)`
  - OfflineDownloadPicker: Select All이 전체를 센다

  updateDisplayedArticleInPlace는 full과 rows를 모두 패치한다 — grep visibleArticles(RootView 10곳). iOS 빌드 후 튜토리얼과 picker 확인 (9e47b51, c58ff64, 5ce2bf2, a31f4c8, eea2692, 320fd44, b12a669) — 2
- [ ] **indexByID는 전체 표시 결과를 색인하고 displayedArticles와 원자적으로 다시 만든다.** article(after:/before:)는 전체 목록 기준이고 id가 없으면 nil을 돌려준다. `article(withID:)`는 `articles`에서 찾는다 — 키보드나 스와이프로 200행 경계를 넘어 이동 (macOS, iOS) (e39f43f, 009284d) — 2
- [ ] **ensureVisible(id:)가 선택 index를 포함하도록 window를 키운다(`max(200, idx+50)`).** 위젯 딥링크, 키보드, Enter가 window 밖 글에서도 동작해야 한다 — 5,000개 라이브러리에서 오래된 글로 위젯 링크 → 선택되고 스크롤됨 (ff13245) — 2
- [ ] **setRead/setStarred는 O(1)을 유지한다.** suppress 경로에서 filteredIDs가 아닐 때만 `bumpUnreadCounts`를 적용한다. displayed 판정은 전체 결과 기준이다. 읽음 처리했고 retained가 아니면 debounce 필터, 표시되지 않던 글이 unread가 되면 필터, star는 항상 debounce 필터 — window 밖 글을 메뉴로 읽음/안읽음 처리해 count와 Unread가 정확한지 확인 (6507670) — 2
- [ ] **isIdentical/RowModel 비교는 행이 렌더하는 모든 필드를 포함한다.** title, summary, isRead, isStarred, publishedAt, feed 제목, readMinutes, categories, isSavedOffline이 대상이고, body와 hasExplicitPublishDate는 제외한다. reader는 id로 `articles`를 조회한다 — computeDisplayDiff 리뷰. reader가 rows의 body를 읽지 않는지 grep (14bbfab) — 2, 4
- [ ] **DisplayResult는 같은 generation의 (articles, filteredIDs) 한 쌍으로 만든다.** filtered 글은 `.filtered`에만 나오고, count(.all) = articles − filtered — 필터가 N개와 매치하면 All이 N개 줄고 Dock도 그만큼 감소 (886a08c) — 2
- [ ] **filter 결과는 latest-wins이다.** detached 결과는 `guard !Task.isCancelled`와 토큰/generation을 확인한다. 600개 미만이고 쿼리가 비었으면 동기 경로(`backgroundFilterThreshold`)를 유지한다. 비어 있지 않은 쿼리는 항상 off-main이다 — scheduleArticleFilter 리뷰 (0a2cff4, a9bf9ef) — 1, 2
- [ ] **빈 상태는 `listWindow.totalCount == 0`으로 판정한다.** "You're All Caught Up"과 View All 버튼은 `query.isEmpty && feedSelection.isEmpty && smartSelection == .unread`일 때만 나오고, iOS는 `onShowAllArticles`를 쓴다. 분리한 child view도 selection을 읽는다 — Unread가 모두 읽음이면 Caught Up, 검색 중이면 No Articles (be07fe0) — 1, 2
- [ ] **모든 행은 onAppear에서 `rowAppeared(id:title:)`, onDisappear에서 `rowDisappeared`를 호출한다(macOS, iOS).** growth sentinel은 이 호출을 대체하지 않고 따로 둔다. 화면에 없는 행에 rowAppeared를 호출하지 않는다 — 번역 off로 All을 연 뒤 설정에서 켜면 스크롤 없이 번역되는지 확인 (3369fcc, 14bbfab) — 2
- [ ] **오프라인 stand-in Article(`articles`에 없음)도 행, 열기, Remove Download가 동작한다.** id 재조회가 실패하면 행 자체의 model로 fallback한다. isSavedOffline은 필터를 돌릴 때마다 메인에서 snapshot한다 — 오프라인 저장 → 피드 삭제 → Downloaded에서 확인 (0e47804) — 2, 4
- [ ] **DEBUG 카운터를 같은 의미의 위치에 유지한다.** 대상은 list.body, list.rowcontent, list.row, list.publish(.skipped/.animated, `rows=a->b`), list.filter다. list.publish는 rows를 실제로 다시 게시할 때 1회만 센다 — grep `MainThreadLog.add` (250a6a3, a157e96) — 0, 2
- [ ] **ReaderStore.init과 ArticleListWindow init은 빈 배열만 만든다.** I/O, 필터, Task는 `bootstrap()`의 `guard !didBootstrap` 이후에만 실행한다 — init 리뷰 (e701467) — 2, 4

## 4. 애니메이션 (Phase 1.3, 2)
- [ ] **`willAnimate` 조건은 한 곳에만 둔다.** 조건은 `animated && !isBulkImporting && !isBatchRefreshing(신규) && oldIDs != newIDs && !oldSet.isEmpty && !isDisjoint && changedRowCount <= maxAnimatedRowDelta(40)`이고, 애니메이션은 `.spring(response: 0.34, dampingFraction: 0.86)`이다. 다음 경우는 항상 애니메이션 없이 처리한다.
  - 소스 전환(전체 교체)
  - 첫 fill과 bootstrap
  - window 전체 교체
  - requestGrowth (`Transaction.disablesAnimations`)

  — grep maxAnimatedRowDelta는 predicate 1곳에만 있어야 한다(현재 949). 테스트: 41행 delta면 false. 수동: feed→All은 즉시, 새 글 3개 새로고침은 slide (e549ab2, 527c4dc, 8b88880, a9bf9ef) — 1, 2
- [ ] **merge의 `withAnimation`을 지우면 그 결정을 마지막 publish로 옮긴다.** batch 끝의 비디바운스 필터 1회는 `animated: mode.animatesInsertion`을 전달한다. 즉 interactive이면서 새 글이 있고 기존 라이브러리가 비어 있지 않을 때만 애니메이션한다. ambient/background(RefreshMode, 동시성 6/2/6) 새로고침은 애니메이션하지 않는다 — 스크롤 중 ambient 새로고침 시 spring이 없는지 확인 (87a0aa6, c6dd34d, 527c4dc, a9bf9ef) — 1, 3
- [ ] **검색 트리거는 항상 `animated: false`이다** — activeSearchQuery didSet 확인 (a9bf9ef) — 1

## 5. 카운트와 배지 (Phase 1.6, 3)
- [ ] **`updateUnreadBadge`는 유일한 writer이고 articles가 바뀔 때마다 호출된다.** isBatchRefreshing 중에도, suppress install 경로에서도 호출된다. 새 prior-value guard는 **실제로 내보낸 값(`showsUnreadBadge ? total : 0`)**을 기준으로 삼는다. 훅이 교체되면 다시 내보낸다(ContentView 247-252, RootView 95-98) — 실행 시 배지 표시, 설정 off/on 전환 시 즉시 반영, 새로고침 중 읽음 토글 시 Dock 즉시 변경 (af69e11, c0d6b41) — 1, 3
- [ ] **recomputeCounts(unreadByFeed, total, today, starred)는 install할 때마다 1회 실행하고, 설치된 articles와 일치해야 한다.** generation이 다르면 버린다. filtered 글은 제외한다 — 새로고침 중 읽음 처리 시 피드, 폴더, Dock 배지가 정확한지 확인 (f3e0ff9, 886a08c) — 3
- [ ] **Today는 반열린 구간 [startOfToday, startOfTomorrow)이다.** 새로 미리 계산하는 count도 `.today` 필터와 같은 정의를 쓴다 — recomputeCounts(1668-1671)와 computeVisibleArticles 대조 (352c643) — 3

## 6. 동기화, CRDT, 영속화 (Phase 1.5~1.6, 3)
- [ ] **seen 일괄 처리를 안전하게 한다.** 조건은 다음과 같다.
  - `isForegroundActive && storage != nil`에서만 실행
  - 표시된 **전체** 결과가 대상(window 아님)
  - unread 중 `seen?.value == true`(2347)가 아닌 것만 기록
  - HLC는 `nextHLC()`로 1회 tick
  - 메인에서 copy→assign 사이에 await 없음 (setRead를 덮지 않도록)
  - 기록한 것이 있을 때만 scheduleShardSave()
  - skip 경로에서도 실행

  — 테스트: 일괄 기록 후 mergedSeenArticleIDs에 모든 표시 unread가 포함. 백그라운드 새로고침은 seen 0. Mac이 무인 상태면 알림 유지 (b3585ab, 3a7e050) — 1, 2
- [ ] **ownShard는 @MainActor에서만 변경한다.** detached computeMerge나 필터 안에서 쓰지 않는다. scheduleShardSave는 1.5s 고정 trailing이고, 삭제 계열은 `urgent: true`(현재 2곳)다. flushPendingShardSave는 resign/terminate와 iOS background 시 실행한다 — grep ownShard 쓰기 위치 (eb5db38, 416bc78) — 3
- [ ] **persistReplica를 detached로 옮겨도 순서를 지킨다.** 순서는 `reloadMerged → refreshAllFeeds → (merge install 완료) → persistReplica await → mergedSeenArticleIDs → reserveNotifications`다. 후보는 완전히 merge된 articles다. `appliedReplicaRevision = max(...)`와 lastKnownContentModDate를 갱신해 자기 쓰기를 외부 변경으로 보지 않게 한다 — refreshAllReportingNew(~2600-2650) 리뷰. 백그라운드에서 새 글 1개 → 알림 1건, peer에서 읽은 글 → 알림 0건, 자기 쓰기 후 reloadMerged 없음 (8f5f136, 729943d, 1cf7ede, f8f3ea7, 8fd3e0c) — 1, 3
- [ ] **isBatchRefreshing 중에는 drainSaves를 멈춘다(`while !isBatchRefreshing`).** defer에서 merge await 뒤 scheduleSave를 1회 호출한다. read/star 토글이 content baseline 저장을 일으키지 않는다 — runBatchedFetch defer 리뷰 (f3e0ff9, 4677178) — 3
- [ ] **bulk 변경은 한 번에 대입한다.** feeds, feedSelection.subtracting, articles를 각각 1회 대입하고 shard save도 1회다. applyBodyCache처럼 `articles[i]` 루프 쓰기는 didSet이 꺼진 상태에서만 한다. generation은 1회만 올린다 — 폴더 5개 삭제 시 list.publish 1회. `store.didset.articles`가 install당 1회인지 확인 (8b88880, 8fd3e0c, 50e51a2) — 1, 3, 5
- [ ] **필터 엔진 상태를 일관되게 유지한다.** 대상은 다음과 같다.
  - recomputeFilteredIDs는 `filterClassifyCache == filterContentHash`일 때만 재사용하고, textFiltered를 기준으로 한다
  - hidden category는 매번 새로 union
  - rebuildFilterEngine은 cache를 비움
  - apply는 filters/categories/rebuild를 articles보다 먼저 설정
  - addFilter/updateFilter/removeFilter/category hide 시 generation(또는 별도 filter generation)을 올림

  — 1705-1840 리뷰 (36e09bc, 8051b5c) — 3
- [ ] **deleteArticle의 동작을 유지한다.** 글 제거, 선택이 일치하면 해제, retained에서 제거, `setArticleTombstone`, 즉시 insert를 수행하고, materialize는 tombstone을 버린다 — 새로고침 중 삭제 → 재실행 후에도 없음 (c7d1a61) — 3

## 7. 행, 스와이프, 메뉴 (Phase 2, 4)
- [ ] **ArticleListView의 ForEach 행에 행 단위 `.id`를 두지 않는다.** id는 article.id(Identifiable)이고 선택은 `.tag(article.id)`다. 메타데이터 하위 뷰의 `.id(model.id)`는 셀 재사용 시 다른 글 사이의 보간을 끊기 위한 것으로, 전체 행 ID와 구분한다. `.id(listGeneration)` 실험은 전체 전환 20회 이상 뒤에도 swipe 버튼이 그려지는지 검증한 뒤 채택한다 — grep `.id(` ContentView (29e53d8) — 1, 2
- [ ] **`.contextMenu { ArticleRowMenu(...) }`와 `.swipeActions(edge: .leading, allowsFullSwipe: true) { ArticleRowSwipeActions(...) }`는 각각 child view 하나만 둔다.** Article 재조회는 child body 안에서 하고, ForEach 클로저에서 하지 않는다. `List.contextMenu(forSelectionType:)`는 쓰지 않는다. 라벨은 현재 isRead/isStarred를 반영한다. `.onKeyPress(.return)`과 `List(selection:)`는 List에 둔다 — ListRowMenuEagernessTests(menuIsDeferred: 0)와 ui-forensics의 list.row.menu ≈ 0. swipe 두 번 하면 라벨이 바뀌는지, Enter로 브라우저가 열리는지 확인 (250a6a3, e41d177, 91b8700, 0c4566b) — 2, 4
- [ ] **ArticleRowModel은 `publishedAt: Date`만 갖는다.** 상대 시간 문자열은 갖지 않는다. 행은 `RelativeTimeText(model.publishedAt)`(macOS, iOS 각 1곳)로 그린다 — 3분 이상 방치하면 시간이 함께 진행되는지 확인 (27cf8fa, c56e8f7) — 4
- [ ] **metadata line 구성을 유지한다.** 구성은 inline `CategoryBadges().fixedSize()`와 0폭 투명 칩 `Text("\u{200B}")...opacity(0)`이다. badge가 행 높이를 바꾸지 않는다. `.animation(isBulkCategorizing || reduceMotion ? nil : .smooth(0.28), value: categories)`는 RowModel의 Equatable categories를 기준으로 하며, 메타데이터 하위 뷰의 `.id(model.id)`로 다른 글이 재사용될 때의 애니메이션을 초기화한다 — AI 태그가 늦게 붙어도 잘리지 않는지 확인 (1186a47) — 4
- [ ] **`isBulkCategorizing`은 `@ObservationIgnored` 값으로, 렌더 시점에 live로 읽는다.** RowModel에 넣어 굳히지 않는다. category 이름이나 색이 바뀌면 `categoriesByID`로 badge를 다시 해석한다 — Settings에서 rename/recolor 시 행이 갱신되는지, 일괄 분류 시 애니메이션이 없는지 확인 (68d1b0e) — 4

## 8. 번역과 행 높이 (Phase 4)
- [ ] **macOS 중간 번역문은 네이티브 텍스트만 갱신한다.** `ListTitleTranslationSlot`은 최초 등장, 블록은 진행 단계만 관찰한다. `updateNSView` 안에서 observable 텍스트를 읽지 않는다. 같은 줄의 중간 문장은 브리지를 재갱신하지 않고, 한 줄→두 줄 전환만 상위 높이에 반영되어야 한다 — `MacListTitleTranslationTextTests`
- [ ] **StateBox의 수명을 지킨다.** 다음이 모두 성립해야 한다.
  - `ListTitleTranslator`는 @Observable이 아니고, 행은 자기 StateBox만 관찰한다
  - box는 행 body를 처음 평가할 때 이미 존재한다(행 생성 시 전달, onAppear 전용 생성은 불가)
  - 해제 조건은 rowDisappeared 또는 window trim 이후 && `activeTasks[id] == nil && dwellTasks[id] == nil`
  - `setState`가 고아 box를 만들지 않는다
  - box를 다시 만들면 `state(for:title:)`로 cache에서 seed한다
  - `cancelAll`은 같은 box 참조를 유지한다
  - layoutRevision은 단조 증가한다

  — 번역 on → window 경계를 지나 스크롤했다가 복귀. 스트리밍 도중 이탈 후 복귀 시 "Translating…"에 멈추지 않는지 확인 (187512d, c493abf) — 4
- [ ] **`MacListRowHeightInvalidator`의 IndexSet 병합은 다음을 지킨다.**
  - (a) `Task.yield()` 뒤에 noteHeightOfRows 호출
  - (b) row index는 실행 시점에 `row(at:)`로 다시 계산 (growth로 index가 밀리므로 캐시 금지)
  - (c) needsAttachmentRetry와 viewDidMoveToWindow 재시도 유지
  - (d) NSCollectionView fallback과 invalidateHostingHierarchy 유지
  - (e) 첫 샘플 무시(ListRowHeightInvalidationTracker)
  - (f) list.row.height 카운터 유지

  `synchronizeNativeListRowHeight`는 바깥 row root에 둔다 — ExpandReveal ~95-160 리뷰, ExpandRevealInvalidationTests. 1,000행 이상을 빠르게 스크롤하며 번역 행이 잘리거나 겹치지 않는지 확인 (c493abf, e41d177) — 4
- [ ] **첫 layout부터 높이가 맞아야 한다.** 조건은 다음과 같다.
  - IntrinsicRevealLayout에 GeometryReader/Preference 피드백 없음
  - @State를 `isVisible`로 seed
  - `state(for: box, title:)`가 동기로 disk cache를 조회 (RowModel이 정확한 title을 전달)
  - macOS는 높이를 즉시 열고 fade만 함 (`guard clamped > 0`)

  병합이 첫 layout 높이를 다음 run-loop로 미루면 안 된다 — 캐시된 번역 행을 빠르게 위로 스크롤해 밀림이나 튐이 없는지 확인 (7fc1767) — 4
- [ ] **번역 시작은 스크롤 상태를 따른다.** fillSlots는 `!isScrolling`일 때만 실행하고, setScrolling(false)가 큐를 비운다. configure는 고착된 isScrolling을 리셋한다. iOS는 onScrollPhaseChange에서 setScrolling을 호출한다 — RootView의 setScrolling 확인 (14bbfab) — 2, 4

## 9. 사이드바 (Phase 4)
- [ ] **`FeedSidebarRow`로 분리해도 다음을 유지한다.**
  - 16×16 ZStack 아이콘 슬롯(ProgressView small / favicon / glyph)과 `.animation(.easeInOut(duration: 0.18), value: isRefreshing)`. isRefreshing은 행마다 전달
  - `.feedActivityFlash(trigger: feedUpdateToken)`
  - healthScore 삼각형
  - unreadCount(feedID:)와 unreadCount(inFolder:)는 캐시를 O(1)로 조회(스캔 금지)

  — 새로고침 중 행 높이와 텍스트 x 위치가 그대로인지, 새 글이 생긴 기존 피드만 flash하는지 확인 (c5e8f11, 6e2345e, 1da4ceb, 7b66989, f3e0ff9) — 4
- [ ] **섹션 순서는 Library → My Nook(`ownNookRow`, feed.id tag) → Drafts(버튼) → 폴더와 피드다** — Plus 로그인 후 확인 (d0c3dec, abae1e5) — 4
- [ ] **`endFeedFetch`에 `contains` guard를 넣어도 실제 제거 경로에서는 refreshingFeedIDs와 spinningFeedIDs 둘 다에서 빼고 `syncIsRefreshing()`을 호출한다.** isRefreshing은 stored 값이고, 값이 바뀔 때만 쓴다. spinner는 interactive 또는 단일 피드일 때만 돈다 — 새로고침이 끝나면 툴바 spinner가 멈추고 버튼이 다시 활성화되는지 확인 (613e39c, 6e2345e) — 1
- [ ] **`importProgress`와 `offlineDownloadProgress`는 전용 leaf View에서만 읽는다.** ArticleListView, ContentView, RootView의 body에서는 읽지 않는다. Phase 1.2의 toolbar와 empty state 분리도 같은 규칙을 따른다 — ContentView와 RootView에서 grep (60c3de2) — 1

---

## 제외한 항목 (1개)
- **3d3676d** "list 제목은 `.translating`을 건너뛰고 한 번에 공개한다(`{ _ in }`)": 현재 코드에 이 동작이 없습니다. `ListTitleTranslator.swift:320`/`335`에서 `setState(.translating(partial…))`로 다시 스트리밍하며, 이후 818b719 "restore streamed list title translations"로 되돌아갔습니다. 대신 "높이 무효화 병합이 스트리밍 중 높이 변화를 깨지 않는다"는 점은 8번 그룹의 invalidator 항목에서 확인합니다.

참고: `ensureVisible`, `articlesGeneration`, `computeMerge`, `ArticleListWindow`, `MergeProjection`은 아직 없는 계획상의 새 심볼이어서 제외 대상이 아닙니다. 나머지 guard는 grep으로 존재를 확인했습니다. 예를 들어 `pruneSelectionIfHidden` 주석, didSet의 equality guard, `willAnimate`(949), `if !article.hasExplicitPublishDate`(4805/4818), seed dedup(5300), seen skip(2347), `feedIcons[$0.id] == nil`(5071), `comparable.lastFetchedAt`(4765), ContentView onChange(1602/1606)가 그렇습니다.