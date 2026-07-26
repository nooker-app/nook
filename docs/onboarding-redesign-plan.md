# Nook iOS 온보딩 재설계 계획 — "RSS를 몰라도 스며드는 첫 경험"

> 2026-07-26. 7-에이전트 설계 감사(전체 첫 실행 인벤토리 → 플로우/카피/비주얼 3트랙 설계 →
> 뉴커머 공감·구현 타당성 비평) 결과의 통합본. 모든 코드 인용은 감사 시점 기준.

## 목표

RSS라는 단어를 모른 채 호기심으로 설치한 사용자가 **10초 안에 앱의 가치를 이해**하고,
**4탭 안에 첫 기분 좋은 읽기**에 도달하며, "유용하다"고 느껴 내일 다시 열게 만든다.
"RSS"는 신규 사용자 정면 표면에서 완전히 제거한다(허용: Add 화면 각주 1회, Settings OPML).

## 현재의 3대 이탈 지점 (인벤토리 확정)

1. **폴더 관문**: 읽을거리를 한 번도 못 본 사용자에게 iOS 파일 피커로 "feeds의 집"을 고르게 함
   (`WelcomeTour.swift:81-90`). 스킵하면 3페이지의 "Copy & Add"가 무설명으로 이 페이지로 되튕김(:133-137).
2. **스타터 = 영문 Hacker News 복붙 5단계**: 복사→탭 전환→시트→붙여넣기 권한 얼럿→Add
   (`WelcomeTour.swift:92-100`, `AddFeedView.swift:65-79`). 재곤 3연타("RSS link", "feed", "Add Feed screen").
3. **첫 읽기를 가로채는 4연속 코치마크** (`ReaderCoachMarks.swift:269-296`).

첫 즐거움까지 최소 8~9탭+권한 얼럿 → 목표 4탭 (Continue → 칩 → Start Reading → 기사 탭).

---

## 구조 결정 (2개)

### 결정 A — 로컬 우선 저장소: 폴더 질문을 온보딩에서 제거

첫 실행 시 앱 Documents 하위 폴더(`Documents/Nook`)로 라이브러리를 자동 구성한다.
`isStorageConfigured` 가드 전체(피드 추가 throw `ReaderStore.swift:1789`, 저장 무음 no-op `:3595`,
빈 화면 봉쇄 등)가 신규 경로에서 사라진다. iCloud는 나중에 "여러 기기에서 이어 보려면"
맥락 카드로 승격 제안.

**타당성 비평의 필수 수정 3건 (그대로 채택):**
- `bootstrap()`은 macOS와 공유되므로 자동 구성은 **iOS 전용 진입점**으로
  (`configureLocalStorageIfNeeded()`를 `RootView.swift:85`의 bootstrap 직후에만 호출).
- 자기 컨테이너를 **북마크로 저장 금지** — iOS는 업데이트마다 컨테이너 경로가 바뀌어
  stale bookmark 알럿이 남. UserDefaults 센티널(`usesLocalLibrary`)을 저장하고
  restore 시 Documents URL을 재계산해 구성.
- 기존 사용자 보호 가드: 자동 구성은 "북마크 없음 + displayPath 기록 없음 +
  `hasCompletedWelcome == false`"일 때만. (stale 북마크 사용자에게 빈 로컬 라이브러리를
  만들어주면 데이터 소실로 보임)

**기각**: "피드를 메모리에 스테이징했다가 폴더 선택 후 커밋" 폴백 — `scheduleSave`가
무음 no-op라 폴더 선택 전 종료 시 read/star가 소리 없이 증발. 로컬 우선이 유일하게 안전.

### 결정 B — 스타터: 복붙 대신 "관심사 칩 → 원탭 구독"

투어 안에서 관심사 묶음 칩(다중 선택) → "Start Reading" 한 번으로 `store.addFeed` 배치 호출.
클립보드/`tutorialPaste`/`wantsAddSampleFeed` 핸드오프 전부 삭제.
스포트라이트 대기 로직은 이미 존재(`tryStartListHint`의 기사 ≥1 조건 + `ListHintRetrigger`) — 재사용.

- 칩 구성 원칙(공감 비평 반영): **저볼륨·고품질 우선**, ko 로케일이면 한국어 묶음 앞에.
  연합뉴스급 대량 피드 금지("다음날 미읽음 300개" 쇼크). 피드당 첫 유입 최신 N개 제한 검토.
  후보: 한국 IT(GeekNews, 기술블로그), 한국 뉴스(저볼륨 소스), 과학, 세계 뉴스(BBC/The Verge),
  테크 커뮤니티(HN — 기존 URL 재사용). **출시 전 실응답 검증 필수. 브런치는 RSS 미제공 — 제외.**
- 칩 페이지에 **"직접 주소로 추가" 보조 버튼 상설**(AddFeedView 오픈) — "내 블로그를 모으고
  싶다"는 P2(40대 즐겨찾기 순회형)의 진짜 아하를 'later'로 미루지 않는다.
- 배치 addFeed는 **부분 실패 허용**으로 감싸기 — 하나 실패 시 `errorMessage`가 투어 직후
  "Something Went Wrong" 알럿으로 튀는 것 억제(`RootView.swift:166-177`).
- "Start Reading" 직후 첫 refresh 동안 **스켈레톤 로딩 상태 필수**(MiniArticleCard 재사용,
  "새 글을 가져오는 중…") + 오프라인 첫 실행 분기 1줄. 이게 없으면 이탈 지점이 투어 밖으로 이사할 뿐.

### 결정 B-보강 — 한국 플랫폼 피드 디스커버리 (P2 생사 문제)

가장 유력한 첫 개인화 시도가 **네이버 블로그**인데, `blog.naver.com`은 `<link rel=alternate>`도
`/rss` 프로빙도 안 맞음(실제 피드는 `rss.blog.naver.com/{id}.xml` 별도 호스트). 실패하면
"내 블로그 안 되는 앱" 판정 → 즉시 삭제. `RSSFeedService.discoverFeed`(:127-252)에
**플랫폼별 규칙**(네이버 블로그, 티스토리 `/rss` 등) 추가 + 실기기 검증. 카피 100줄보다 중요.

---

## 새 플로우 명세

### 투어: 3페이지 → 2페이지

**페이지 1 — 가치 제안** (10초 착지, 3개 페르소나 검증 통과)
- EN: *"Your favorite sites, one quiet place"* / *"Follow the sites you love, and Nook gathers
  their new posts here automatically — no accounts, no algorithm, just your reading."*
- ko: "좋아하는 사이트를 구독하면 새 글이 자동으로 이곳에 모여요. 계정도, 알고리즘도 없이."
- "고를 사이트가 없어도 됨(다음 페이지에서 골라줌)"을 암시하는 한 줄 추가 (P1 불안 해소).
- 비주얼: `NestInboxIllustration` — 사이트 칩 3개에서 미니 기사 카드가 둥지로 떨어져 스며드는
  루프. "구독하면 계속 도착한다"를 무언으로 전달. **Continue 버튼 명시** (현재 도트뿐).

**페이지 2 — 관심사 칩 + 번역 토글**
- 카피 신규 작성 필요(어느 트랙에도 완성본 없음): 제목 *"What do you like to read?"* /
  ko "어떤 글을 즐겨 읽으세요?" + "나중에 어떤 사이트든 추가할 수 있어요."
- Apple Intelligence 가용 시 토글: EN *"Show titles in your language too (translated on your
  iPhone)"* (— "in Korean" 하드코딩 금지) 기본 ON. ON이면 `translateListTitles = true` +
  `hasSeenTranslatePromo = true`(기존 프로모 시트는 폴백으로 유지). 토글 근처에
  "Settings › Experimental에서 끌 수 있어요" 1줄.
- 비주얼: 칩 탭 → 가지(twig)가 둥지로 날아가 꽂히는 애니메이션(가지 색은
  `NestAssemblyView.twigs` 6색 순환) — "주소 하나 = 가지 하나 = 글이 쌓임".
- 하단: "직접 주소로 추가" 보조 버튼 / 주 버튼 "Start Reading" / Skip 유지.

**투어 공통**: 상단에 페이지 도트 대신 **채워지는 둥지 진행 인디케이터**
(`NestAssemblyView(size:28, visibleTwigs:n)`) — 완료 시 마지막 가지 스프링 + `.success` 햅틱.

### 핸드오프: 스포트라이트 → 번역 스트리밍 순서 강제

- 스포트라이트 카피 단순화: *"Tap any story to start reading."* (ko "아무 글이나 탭해서 읽어보세요.")
  — "clean, native reader"는 초보자에게 무의미. "no clutter, no ads"류 과약속 금지(원문 웹뷰엔 광고 있음).
- **제목 번역 스트리밍은 스포트라이트 dismiss 후 시작** — 동시에 벌어지면 서로를 죽임 (P3의
  확정적 "와우" 장면 보호).
- ListTapHint 폴리시: 흰 스트로크 → 액센트 링 + 글로우 + 숨쉬는 펄스, 탭 리플 동심원,
  카드를 rect 기준 배치(`rect.maxY + 24`, 하단 근접 시 위로 플립).

### 리더: 4연속 오버레이 해체 (비평 합의안)

1. **첫 기사 오픈: 오버레이 0개.** 읽게 둔다.
2. **풀업 힌트만 유지하되 맥락형으로**: 스크림 없이, 첫 기사 스크롤이 바닥에 닿는 순간
   `BottomPullAffordance` 옆 글라스 캡슐 1회 — "위로 계속 당기면 다음 글". 실제 풀업 감지로 dismiss.
3. **별표 교육은 오버레이에서 제거** → Starred 빈 상태 카피(*"Double-tap any article to star it —
   starred stories live here."*) + 첫 별표 성공 시 토스트. (두 번째 기사에서 또 오버레이 = 원죄 반복이라 컷)
4. **본문 번역 팁은 '필수'로 승격** (P3에게 구매 이유): 외국어 기사 첫 오픈 시 1회
   "이 글을 한국어로 볼 수 있어요" — 감지 조건 기존재(`ReaderView.swift:131-138`),
   **기기 AI 가용 여부와 무관하게**(시스템 Translation 오버레이 폴백 포함) 노출.
5. 뒤로-스와이프 코치(step 4)는 삭제 — iOS 표준 제스처.
6. **TourFlags 하위호환**: `seenReaderGestureHint == true`인 기존 사용자는 신규 팁 전부 seen 처리
   (우산 플래그). Settings "Replay Tutorial"은 새 플래그 세트 전체를 리셋하도록 갱신.

### 빈 상태: 막다른 길 → 가르치는 화면 (`NestEmptyState` 공통 부품)

| 화면 | 변경 |
|---|---|
| Feeds 탭 피드 0개 (현재 빈 상태 뷰 자체가 없음) | 신설: 빈 둥지 + 고스트 카드 + 버튼 2개 "Browse Starter Picks"(칩 페이지 시트 재사용) / "Add a Site by Address" |
| "You're All Caught Up" | 완성 둥지 + 체크마크 안착 원샷 |
| "No Articles" | 컨텍스트 분기: 피드 0개면 Feeds 빈 상태와 동일 액션, 있으면 "당겨서 새로고침" |
| Starred 비어있음 | 별표 더블탭 교육 카피 (위 3번) |
| Home 폴더 미설정 | 결정 A 후 도달 불가 (안전망으로 버튼이 피커 직접 오픈) |

### iCloud 승격 카드 (온보딩의 후일담, 최고 리스크)

- 트리거: 피드 ≥2 & 세션 ≥2 (또는 기사 5개 읽음) 시 Home 상단 dismissible 카드 1회.
  *"Read on every device — your library lives on this iPhone right now. Move it to iCloud Drive
  and your iPad and Mac stay in sync — it never leaves your own storage."* (프라이버시 서사는 여기로 이사)
- 비주얼: `TwoNestSyncIllustration`(두 기기의 같은 둥지, 점선 아크 왕복) — 삭제된 sync 페이지에서 이식.
- **마이그레이션 설계 (타당성 검증 완료)**: 콘텐츠는 `snapshotLibrary()` 캡처 → 새 폴더 구성 후
  재병합·저장(replica가 신규 HLC로 등록, 베이스라인은 additive union이라 클로버 없음);
  사용자 상태는 구 폴더의 **자기 샤드 파일을 새 폴더로 복사**(같은 deviceID의 자기 샤드만 쓰는
  규칙 무위반, HLC 단조성 유지). **대상 폴더에 기존 라이브러리가 있는 경우**(기존 macOS 사용자)는
  CRDT 샤드 규칙대로 병합됨을 명시 테스트. Settings의 "Change Sync Folder"는 현행 무병합 전환
  의미를 유지하고 **승격 카드 경로와 분리** — 두 의미를 한 버튼에 섞지 않는다.
- 공수 L(사용자 데이터). 실기기 2대 iCloud 왕복 검증 후 출시.

### 용어/카피 체계

- EN "Follow", **ko는 "구독"** (유튜브가 심어둔 전 연령 무료-구독 심상; "팔로우"는 P1 편향).
- "Add Feed" → EN "Follow a Site" / ko "사이트 구독". 플레이스홀더 `feed.xml` → `https://example.com`.
  푸터: *"Paste a website address — Nook finds its posts automatically."* (자동 디스커버리가 실제 보증).
- 에러 카피: 결과 중심 + 다음 행동 — *"Couldn't find new posts at %@. Try the site's main address."*
  ※ NookKit 문자열은 macOS와 공유 — 양쪽 톤 정합 확인. `noDirectorySelected`(macOS 상시 표면) 포함.
- 스플래시 `BootstrapPhase.label`: 로컬 모드에선 "sync folder"가 거짓이 되므로 결정 A와 함께 수정.
- **컷**: 알림 프리-프롬프트(기능 미구현 — 로드맵으로. 단 P1 리텐션의 열쇠임을 기록),
  세그먼트 데모 비주얼, 폴더 페이지용 카피 세트 전체, `tutorialPaste` 관련 전부.

---

## 구현 단계 (리스크 오름차순, 단계별 독립 출시 가능)

| 단계 | 내용 | 공수 | 리스크 |
|---|---|---|---|
| **1. 무손실 폴리시** | 공통 카피 교체(EN+ko), ListTapHint 비주얼/카피, Feeds 빈 상태 신설 + NestEmptyState 4종, MiniArticleCard/visibleTwigs 부품, 되튕김 이유 문구(임시), AddFeed 카피 | S~M | 낮음 |
| **2. 스타터 재설계 (결정 B)** | 칩 그리드 + 배치 addFeed(부분 실패 허용) + 번역 토글 + 로딩 스켈레톤 + 핸드오프 직결 + 페이지 1/2 일러스트 + **한국 플랫폼 디스커버리 규칙** | M | 낮음 (URL 번들 실검증 별도) |
| **3. 로컬 우선 (결정 A)** | iOS 전용 자동 구성(센티널) + sync 페이지 삭제 + 기존 사용자 가드 + 스플래시 문구 | M | 중 |
| **4. iCloud 승격 + 마이그레이션** | 샤드 복사 + union 저장 + 승격 카드 + TwoNestSync 일러스트 + 문서 피커 브리지 | **L** | **높음 — 사용자 데이터, 별도 검증** |
| **5. 코치마크 분산** | 플래그 분리 + TourFlags 마이그레이션 + Replay 갱신 + 바닥-도달 트리거 + 번역 맥락 팁 | M | 중 |

주 파일: `WelcomeTour.swift`(재구성), `RootView.swift`(핸드오프/빈 상태/승격 카드),
`AddFeedView.swift`(카피/tutorialPaste 제거), `ReaderCoachMarks.swift`+`ReaderView.swift`(분산),
`NestSplash.swift`(부품/일러스트), `SettingsView.swift`(Replay/피커), NookKit(`ReaderStore` 로컬 구성·
마이그레이션, `RSSFeedService` 디스커버리 규칙, 공유 카피), `Localizable.xcstrings`.

## 성공 판정 기준 (수동 체크)

- 신규 사용자: 10초 안에 "뭘 해주는 앱인지" 말할 수 있는가 / 4탭 안에 첫 기사를 읽는가 /
  첫 읽기가 오버레이에 안 끊기는가 / "RSS·feed"를 한 번도 안 보는가.
- P2: 네이버 블로그·티스토리 주소가 실기기에서 구독되는가.
- P3: 영문 칩 선택 시 첫 홈에서 제목 번역 타이핑이 스포트라이트와 겹치지 않고 보이는가 /
  외국어 기사 첫 오픈에 본문 번역 팁이 (구형 기기 포함) 뜨는가.
- 기존 사용자: 업데이트 후 투어·팁이 다시 뜨지 않는가 / 로컬 자동 구성에 진입하지 않는가.
