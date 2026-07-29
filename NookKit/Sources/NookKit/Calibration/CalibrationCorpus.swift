import Foundation

/// The standardized reading material for 읽기 맞춤 (Reading Fit), one matched set
/// per reading language.
///
/// Deliberately NOT the user's own articles. A trial gets one passage, and the
/// size ladder gives each rung a single trial, so any difference in a passage's
/// topic, vocabulary, or length lands directly on that condition's score.
/// Standardized, matched material is what reading instruments use (MNREAD,
/// IReST) for exactly this reason, and it also makes results comparable between
/// people and between sessions.
///
/// Every passage is **structured** like a real article — a heading, two
/// paragraphs, and one emphasized opening clause — because a flat wall of prose
/// gives the eye nothing to hold on to, and the reader those settings are for is
/// never flat either. Structure is identical across passages (same heading
/// count, same paragraph count, same single emphasis) so it cannot make one
/// trial easier than another.
///
/// Within a language every passage carries the same countable-character load
/// (±12%, verified by the engine tests), uses everyday vocabulary, and
/// avoids proper nouns and jargon whose familiarity varies by reader. Original
/// prose written for this purpose.
public enum CalibrationCorpus {
    public static func passages(for script: CalibrationScript) -> [CalibrationPassage] {
        let entries: [CalibrationPassage]
        switch script {
        case .latin: entries = english
        case .korean: entries = korean
        case .japanese: entries = japanese
        case .chineseSimplified: entries = chinese
        }
        return entries.enumerated().map { index, passage in
            var identified = passage
            identified.id = "corpus-\(script.rawValue)-\(index)"
            return identified
        }
    }

    static let english: [CalibrationPassage] = [
        CalibrationPassage(
            heading: "The Shortest Ceremony",
            paragraphs: [
                "The first cup of coffee in the morning is less about waking up than about ceremony. While the water heats, the window shows whatever weather the day has settled on, and by the time the smell of the grounds rises, the day feels properly begun.",
                "**Small repeated habits**, more than grand plans, are what hold an ordinary life steady.",
            ]
        ),
        CalibrationPassage(
            heading: "Streets Without a Map",
            paragraphs: [
                "Walking without a map turns a familiar neighborhood into a new one. At the end of a street you have passed a hundred times there is suddenly a narrow shop you never noticed, and over the wall beside it a rose bush leans out as if it had been waiting.",
                "**A walk with no destination is slow**, but it shows you far more than the direct route.",
            ]
        ),
        CalibrationPassage(
            heading: "A Room Made of Time",
            paragraphs: [
                "The appeal of a library is not its quiet but its density. Thousands of books stand shoulder to shoulder, each holding its own stretch of time, and simply walking between the shelves seems to sort your thoughts into order.",
                "**You do not even** need to borrow one; running your eyes along the spines is already a kind of reading.",
            ]
        ),
        CalibrationPassage(
            heading: "Reading the Slope",
            paragraphs: [
                "Riding a bicycle teaches you the real shape of a city. Gentle climbs you never noticed from a bus arrive directly in your legs, and every descent pays you back with wind on your face.",
                "**Once you know the ground this way**, the streets stop being flat lines on a map and turn into a landscape with weight and slope.",
            ]
        ),
        CalibrationPassage(
            heading: "A Record of Failures",
            paragraphs: [
                "The secret to cooking well is not a shelf of recipes but a record of failures. The soup that got salted twice, the garlic that burned in seconds, the rice that turned to paste.",
                "**Every one of those** mistakes becomes the next attempt's instinct. A kitchen is a workshop where yesterday's disaster quietly becomes today's measure.",
            ]
        ),
        CalibrationPassage(
            heading: "The Weight Hands Remember",
            paragraphs: [
                "Objects you have used for years carry a weight your hands have memorized. You know exactly where the zipper of an old bag will catch, and a worn pen warns you before its ink runs dry.",
                "**Instead of the shine** of something new there is the calm of the predictable, which is the value of time stored up between you and a thing.",
            ]
        ),
        CalibrationPassage(
            heading: "Walking at the Speed of Thought",
            paragraphs: [
                "The pace of a walk resembles the pace of thinking. Move quickly and the mind hurries toward conclusions; move slowly and the questions multiply one by one.",
                "**On days that demand** a good answer I take the long way around on purpose. By the time my legs begin to ache, my thoughts have usually finished sorting themselves out.",
            ]
        ),
        CalibrationPassage(
            heading: "Turning Toward the Light",
            paragraphs: [
                "A plant on a winter windowsill turns its body a little further toward the sun each day. Leaves that leaned one way in the morning face another by evening.",
                "**Things that look motionless** are alive at their own speed if you watch them closely enough, and on a crowded day that small fact turns out to be strangely comforting.",
            ]
        ),
        CalibrationPassage(
            heading: "What a Train Sounds Like",
            paragraphs: [
                "Half of any train journey is sound rather than scenery. The steady clatter of the rails, a crossing bell fading behind, the low conversation in the next seat.",
                "**Even with your eyes** closed the train tells you roughly where it is. It is one of the rare stretches of life in which the moving, not the arriving, is the point.",
            ]
        ),
        CalibrationPassage(
            heading: "The Day That Passes Twice",
            paragraphs: [
                "Keeping a diary by hand makes each day pass twice: once while you live it and once while you write it down.",
                "**Because a pen is slower than a keyboard the feelings cool a little on the way to the page**, and the sentences come out more honest. No screen has ever matched the lightness of closing a finished notebook.",
            ]
        ),
        CalibrationPassage(
            heading: "An Hour of Geology",
            paragraphs: [
                "At the shore everyone becomes a geologist for an hour. The ridges the waves press into the sand, the shell patterns uncovered by retreating water, the foam vanishing around your ankles.",
                "**In front of such** enormous repetition the urgent matters of the week look small, and carrying that feeling home is the real souvenir.",
            ]
        ),
        CalibrationPassage(
            heading: "The Proof Is the Plain Loaf",
            paragraphs: [
                "A neighborhood bakery proves itself not with clever new pastries but with the same plain loaf every single day. The same crumb as yesterday, the same weight, the same smell in the afternoon.",
                "**Steadiness is harder to show than talent**, which is why anyone who does one thing well for years earns respect before admiration.",
            ]
        ),
        CalibrationPassage(
            heading: "Letting the Eyes Learn the Dark",
            paragraphs: [
                "To really see a night sky you have to give your eyes time to learn the dark. The handful of stars you count at first doubles after ten patient minutes.",
                "**What was invisible was never actually absent**, and the sky teaches that same lesson in the same unhurried way every time somebody is willing to stand still long enough.",
            ]
        ),
        CalibrationPassage(
            heading: "Fifteen Minutes Under an Awning",
            paragraphs: [
                "A sudden shower on the day you forgot an umbrella has a strange way of outlasting other memories. Fifteen minutes under a shop awning, a brief nod exchanged with a stranger sheltering beside you, the smell of wet pavement.",
                "**An unplanned pause can** become the clearest scene of an entire week, which no schedule ever plans for.",
            ]
        ),
        CalibrationPassage(
            heading: "A Calendar Made of Stalls",
            paragraphs: [
                "Shopping at a street market puts the seasons directly into your hands. Young greens in spring, sweet corn in summer, figs taking over the stalls in autumn.",
                "**If a supermarket shelf wears the same face all year**, a market stall is a calendar, and standing in front of it is where the word seasonal finally means something real.",
            ]
        ),
        CalibrationPassage(
            heading: "The Luxury of Waiting",
            paragraphs: [
                "The charm of a film camera is precisely that you cannot see the result right away. The few days between pressing the shutter and holding the print make you replay the memory one more time.",
                "**In a period when everything arrives instantly**, waiting has quietly turned into the most extravagant hobby a person can keep up.",
            ]
        ),
        CalibrationPassage(
            heading: "An Honest Inventory",
            paragraphs: [
                "Only after moving house do you understand the true volume of your belongings. With every box you pack the same question repeats: when did I actually use this last?",
                "**When the rooms change**, every object has to apply again for its place, and whatever survives the sorting becomes an honest inventory of who you are now.",
            ]
        ),
        CalibrationPassage(
            heading: "The Limit Is the Breath",
            paragraphs: [
                "What running really teaches is that the limit is breathing rather than speed. Keep the breath even and the legs last far longer than expected.",
                "**Push too hard and** the next morning collects the debt without fail; hold back a little and you somehow travel further. The body keeps a remarkably honest set of books about effort.",
            ]
        ),
        CalibrationPassage(
            heading: "Weather That Decides for You",
            paragraphs: [
                "Rain on a window is one of the few sounds nobody has to learn to like. It arrives without asking, it covers the noise of the street, and it makes any room feel like the right place to be.",
                "**Some afternoons the weather** does the work of choosing for you, and there is a quiet relief in being told to stay put.",
            ]
        ),
        CalibrationPassage(
            heading: "The Last Unclaimed Hour",
            paragraphs: [
                "A long bus ride is the last unclaimed hour in a busy week. Nothing can be finished, so nothing has to be started, and the window keeps offering scenes that ask for no reply.",
                "**By the time the** last stop arrives you have usually thought through the thing you were avoiding, without ever deciding to think about it.",
            ]
        ),
    ]

    static let korean: [CalibrationPassage] = [
        CalibrationPassage(
            heading: "가장 짧은 의식",
            paragraphs: [
                "아침에 커피를 내리는 일은 하루 중 가장 짧은 의식이다. 물이 끓는 동안 창밖을 보고, 원두 향이 퍼지면 비로소 하루가 시작된다는 감각이 든다.",
                "**대단한 결심보다 이**런 작은 반복이 생활의 균형을 잡아 준다는 것을 해가 갈수록 더 실감하게 되는 것 같다.",
            ]
        ),
        CalibrationPassage(
            heading: "지도 없이 걷는 길",
            paragraphs: [
                "지도를 보지 않고 걷다 보면 동네의 새로운 얼굴을 만나게 된다. 늘 지나치던 골목 끝에 오래된 문방구가 있었고, 그 옆 담장 위로는 언제 심었는지 모를 장미가 넘어와 있었다.",
                "**목적지가 없는** 걸음은 느리지만 그만큼 더 많은 것을 보여 주는 법이다.",
            ]
        ),
        CalibrationPassage(
            heading: "시간으로 지은 방",
            paragraphs: [
                "도서관의 매력은 조용함이 아니라 밀도에 있다고 생각한다. 수천 권의 책이 각자의 시간을 품은 채 나란히 꽂혀 있고, 그 사이를 걷는 것만으로도 생각이 정리된다.",
                "**굳이 빌리지 않아**도 좋다. 책등을 눈으로 훑는 일 자체가 이미 하나의 독서이기 때문이다.",
            ]
        ),
        CalibrationPassage(
            heading: "몸으로 읽는 경사",
            paragraphs: [
                "자전거를 타면 도시의 경사가 몸으로 읽힌다. 버스로는 몰랐던 완만한 오르막이 다리에 그대로 전해지고, 내리막의 바람은 그날의 보상이 된다.",
                "**지형을 아는 만큼 **도시가 입체적으로 보이기 시작하고, 길은 단순한 경로가 아니라 하나의 이야기가 된다.",
            ]
        ),
        CalibrationPassage(
            heading: "실패의 기록",
            paragraphs: [
                "요리를 잘하게 되는 비결은 레시피가 아니라 실패의 기록이라고 생각한다. 소금을 두 번 넣은 국, 태워 버린 마늘, 질어진 밥.",
                "**그 모든 실수가 다**음번의 감각이 된다. 주방은 실험실이고, 어제의 실패는 오늘의 계량컵이 되어 조용히 제 몫을 한다.",
            ]
        ),
        CalibrationPassage(
            heading: "손이 기억하는 무게",
            paragraphs: [
                "오래 쓴 물건에는 손에 익은 무게가 있다. 십 년 된 가방의 지퍼는 어디서 걸리는지 알고, 낡은 만년필은 잉크가 굳는 시점을 먼저 알려 준다.",
                "**새것의 반짝임 대신** 예측 가능함이 주는 안정감. 그것이 물건과 나 사이에 쌓인 시간의 값이라고 생각한다.",
            ]
        ),
        CalibrationPassage(
            heading: "생각의 속도로 걷기",
            paragraphs: [
                "산책의 속도는 생각의 속도와 닮아 있다. 빠르게 걸으면 머릿속도 결론을 서두르고, 천천히 걸으면 질문이 하나씩 늘어난다.",
                "**좋은 답이 필요한 **날에는 일부러 먼 길을 골라 걷는다. 다리가 아플 때쯤이면 대개 마음도 정리되어 있는 것을 여러 번 경험했다.",
            ]
        ),
        CalibrationPassage(
            heading: "빛을 향해 도는 것들",
            paragraphs: [
                "겨울 창가의 화분은 매일 조금씩 해를 따라 몸을 튼다. 아침에 동쪽으로 기울었던 잎이 저녁에는 남쪽을 향해 있다.",
                "**움직이지 않는 것처**럼 보이는 것들도 자세히 보면 저마다의 속도로 살아 있다는 사실이, 바쁜 날일수록 뜻밖의 위로가 되어 준다.",
            ]
        ),
        CalibrationPassage(
            heading: "기차의 소리",
            paragraphs: [
                "기차 여행의 절반은 창밖 풍경이 아니라 소리다. 규칙적인 덜컹임, 멀어지는 건널목 종소리, 옆자리의 낮은 대화.",
                "**눈을 감아도 기차는** 어디쯤 달리고 있는지 알려 준다. 도착보다 이동 그 자체가 목적이 되는 드문 시간이기도 해서 늘 조금 아깝다.",
            ]
        ),
        CalibrationPassage(
            heading: "두 번 흐르는 하루",
            paragraphs: [
                "손글씨로 일기를 쓰면 하루가 두 번 흘러간다. 한 번은 겪을 때, 한 번은 적을 때.",
                "**자판보다 느린 속도 덕분에 감정은 한 김 식고**, 문장은 조금 더 정직해진다. 다 쓴 페이지를 덮는 순간의 가벼움은 어떤 앱도 아직 대신해 주지 못하고 있다.",
            ]
        ),
        CalibrationPassage(
            heading: "한 시간의 지질학",
            paragraphs: [
                "바다에 가면 누구나 잠시 지질학자가 된다. 파도가 만든 모래의 결, 물러날 때 드러나는 조개 무늬, 발밑에서 사라지는 거품의 흔적.",
                "**거대한 반복 앞에서**는 급했던 일들이 문득 작아 보인다. 그 감각을 챙겨 오는 것이 여행의 몫이라고 늘 생각한다.",
            ]
        ),
        CalibrationPassage(
            heading: "증거는 매일의 식빵",
            paragraphs: [
                "동네 빵집의 진짜 실력은 화려한 신제품이 아니라 매일 같은 식빵에서 드러난다. 어제와 같은 결, 같은 무게, 같은 향.",
                "**꾸준함은 재능보다 **증명하기 어렵다. 무엇이든 오래 한결같이 해내는 사람을 보면 감탄보다 존경심이 먼저 든다는 것을 알게 되었다.",
            ]
        ),
        CalibrationPassage(
            heading: "어둠에 눈이 익을 때",
            paragraphs: [
                "밤하늘을 오래 보려면 어둠에 눈이 익을 시간이 필요하다. 처음에는 몇 개뿐이던 별이 십 분쯤 지나면 배로 늘어난다.",
                "**보이지 않던 것이 원래 없던 것은 아니라는 사실을**, 하늘은 매번 같은 방식으로 조용히 가르쳐 준다. 서두르지 않는 사람에게만 보이는 것이다.",
            ]
        ),
        CalibrationPassage(
            heading: "처마 밑의 십오 분",
            paragraphs: [
                "우산을 깜빡한 날의 소나기는 이상하게 기억에 오래 남는다. 처마 밑에서 비를 긋던 십오 분, 옆에 서 있던 낯선 사람과 나눈 짧은 눈인사.",
                "**계획에 없던 멈춤이** 하루의 가장 선명한 장면이 되기도 한다는 걸 그런 날 배우게 되는 것 같다.",
            ]
        ),
        CalibrationPassage(
            heading: "좌판이라는 달력",
            paragraphs: [
                "시장에서 장을 보면 계절이 손에 잡힌다. 봄에는 냉이가, 여름에는 옥수수가, 가을에는 무화과가 좌판의 주인공이 된다.",
                "**마트의 진열대가 일 년 내내 같은 얼굴이라면**, 시장의 좌판은 달력이다. 제철이라는 말의 힘을 나는 그곳에서 처음 제대로 배웠다.",
            ]
        ),
        CalibrationPassage(
            heading: "기다림이라는 사치",
            paragraphs: [
                "필름 카메라의 매력은 결과를 바로 볼 수 없다는 데 있다. 셔터를 누른 순간과 사진을 확인하는 순간 사이의 며칠이, 기억을 한 번 더 곱씹게 만든다.",
                "**즉시성이 당연해진 **시대에 기다림은 그 자체로 사치스러운 취미가 되어 버렸다고 느낄 때가 있다.",
            ]
        ),
        CalibrationPassage(
            heading: "정직한 목록",
            paragraphs: [
                "이사를 하고 나서야 물건의 총량을 실감했다. 상자를 쌀 때마다 같은 질문이 반복된다. 이걸 마지막으로 쓴 게 언제였지.",
                "**공간이 바뀌면 물건**의 쓸모도 다시 심사를 받는다. 결국 남긴 것들이 지금의 나를 설명하는 목록이 된다는 사실이 조금 무섭다.",
            ]
        ),
        CalibrationPassage(
            heading: "한계는 호흡에 있다",
            paragraphs: [
                "달리기를 시작하고 알게 된 것은 속도가 아니라 호흡의 문제라는 사실이다. 숨이 고르면 다리는 생각보다 오래 버틴다.",
                "**무리한 날은 어김없이 다음 날이 무겁고**, 절제한 날은 이상하게 더 멀리 간다. 몸은 정직한 장부를 쓴다는 말을 이제는 믿는다.",
            ]
        ),
        CalibrationPassage(
            heading: "대신 결정해 주는 날씨",
            paragraphs: [
                "창에 부딪히는 빗소리는 배우지 않아도 좋아지는 몇 안 되는 소리다.",
                "**허락을 구하지 않고 찾아와 거리의 소음을 덮고**, 어떤 방이든 지금 있기에 알맞은 자리로 만들어 준다. 날씨가 대신 결정을 내려 주는 오후에는 이상하게 마음이 놓인다.",
            ]
        ),
        CalibrationPassage(
            heading: "마지막 빈 시간",
            paragraphs: [
                "긴 버스 이동은 바쁜 주에 남은 마지막 빈 시간이다. 무엇도 끝낼 수 없으니 시작할 필요도 없고, 창밖은 답을 요구하지 않는 장면만 계속 건넨다.",
                "**종점에 닿을 무렵이**면 미루던 생각이 어느새 정리되어 있다. 정리하려고 마음먹은 적도 없는데 말이다.",
            ]
        ),
    ]

    static let japanese: [CalibrationPassage] = [
        CalibrationPassage(
            heading: "最も短い儀式",
            paragraphs: [
                "朝にコーヒーを淹れる時間は、一日で最も短い儀式のようなものだ。湯が沸くまで窓の外を眺め、豆の香りが広がるころにようやく一日が始まった感覚になる。",
                "**大きな決意よりも**、こうした小さな繰り返しが暮らしを支えてくれるのだと、年々強く感じる。",
            ]
        ),
        CalibrationPassage(
            heading: "地図のない道",
            paragraphs: [
                "地図を見ずに歩くと、いつもの町に新しい顔が現れる。何度も通り過ぎた路地の奥に古い文房具店があり、その隣の塀の上には、いつ植えられたのか分からない薔薇が越えて咲いていた。",
                "**目的地のない歩みは遅いけれど**、そのぶん多くのものを見せてくれるものだ。",
            ]
        ),
        CalibrationPassage(
            heading: "時間でできた部屋",
            paragraphs: [
                "図書館の魅力は静けさではなく密度にあると思う。何千冊もの本がそれぞれの時間を抱えたまま並び、その間を歩くだけで考えが整っていく。",
                "**借りなくてもかまわ**ない。背表紙を目でたどる行為そのものが、すでにひとつの読書になっているからだ。",
            ]
        ),
        CalibrationPassage(
            heading: "体で読む傾き",
            paragraphs: [
                "自転車に乗ると、街の傾きが体で読めるようになる。バスでは気づかなかった緩やかな上り坂が脚に伝わり、下り坂の風はその日のささやかな報酬になる。",
                "**地形を知るほど街は立体的に見えはじめ**、道は単なる経路ではなくひとつの物語に変わっていく。",
            ]
        ),
        CalibrationPassage(
            heading: "失敗の記録",
            paragraphs: [
                "料理が上手になる秘訣は、レシピではなく失敗の記録だと思っている。塩を二度入れた汁物、焦がしてしまった香味野菜、水っぽくなった米。",
                "**そのすべての失敗が次**の感覚になる。台所は実験室であり、昨日の失敗が今日の計量になって静かに働いてくれる。",
            ]
        ),
        CalibrationPassage(
            heading: "手が覚えた重さ",
            paragraphs: [
                "長く使った道具には、手が覚えた重さがある。十年使った鞄はどこで留め具が引っかかるかを知っていて、古い万年筆は墨が固まる頃合いを先に教えてくれる。",
                "**新しさの輝きよりも**、予測できることの安心。それが道具と自分の間に積もった時間の値なのだろう。",
            ]
        ),
        CalibrationPassage(
            heading: "考えの速さで歩く",
            paragraphs: [
                "散歩の速さは考えの速さに似ている。速く歩けば頭も結論を急ぎ、ゆっくり歩けば問いがひとつずつ増えていく。",
                "**よい答えが必要な日には**、わざと遠まわりの道を選ぶ。脚が痛くなるころには、たいてい心のほうも片づいていることに何度も気づかされた。",
            ]
        ),
        CalibrationPassage(
            heading: "光へ向くもの",
            paragraphs: [
                "冬の窓辺の鉢植えは、毎日少しずつ日を追って向きを変える。朝は東に傾いていた葉が、夕方には南を向いている。",
                "**動いていないように見えるものも**、よく見ればそれぞれの速さで生きているという事実が、忙しい日ほど思いがけない慰めになってくれる。",
            ]
        ),
        CalibrationPassage(
            heading: "列車の音",
            paragraphs: [
                "列車の旅の半分は、車窓の景色ではなく音でできている。規則的な揺れの音、遠ざかる踏切の鐘、隣席の低い会話。",
                "**目を閉じていても**、列車はいまどのあたりを走っているかを教えてくれる。到着より移動そのものが目的になる、めずらしい時間でもある。",
            ]
        ),
        CalibrationPassage(
            heading: "二度流れる一日",
            paragraphs: [
                "手書きで日記をつけると、一日が二度流れていく。一度は過ごすとき、もう一度は書くとき。",
                "**鍵盤より遅い速度のおかげで感情はひと息冷め**、文章は少しだけ正直になる。書き終えた頁を閉じる瞬間の軽さは、どんな道具にもまだ代わってもらえていない。",
            ]
        ),
        CalibrationPassage(
            heading: "一時間の地質学",
            paragraphs: [
                "海に行くと、誰でもしばらくの間は地質学者になる。波がつくった砂の筋、引くときに現れる貝の模様、足もとで消えていく泡の跡。",
                "**巨大な繰り返しの前では**、急いでいた用事がふと小さく見える。その感覚を持ち帰ることが、旅の役割なのだと思っている。",
            ]
        ),
        CalibrationPassage(
            heading: "証拠は毎日の食パン",
            paragraphs: [
                "町のパン屋の本当の実力は、目を引く新商品ではなく毎日の同じ食パンに現れる。昨日と同じ気泡、同じ重さ、同じ香り。",
                "**続けることは才能より**も証明が難しい。何であれ長く変わらずやり遂げる人を見ると、感嘆よりも敬意が先に立つのだと知った。",
            ]
        ),
        CalibrationPassage(
            heading: "暗さに目が慣れるとき",
            paragraphs: [
                "夜空を長く見るには、暗さに目が慣れる時間が必要になる。はじめは数えるほどだった星が、十分ほど経つと倍に増えている。",
                "**見えなかったものが**、もともと無かったわけではないという事実を、空は毎回同じやり方で静かに教えてくれるのだった。",
            ]
        ),
        CalibrationPassage(
            heading: "軒下の十五分",
            paragraphs: [
                "傘を忘れた日のにわか雨は、なぜか長く記憶に残る。軒下で雨をやり過ごした十五分、隣に立っていた見知らぬ人と交わした短い会釈、濡れた舗道の匂い。",
                "**予定になかった立ち止まりが**、その週でいちばん鮮明な場面になることを、そんな日に学ぶ。",
            ]
        ),
        CalibrationPassage(
            heading: "台という暦",
            paragraphs: [
                "市場で買い物をすると、季節が手のなかに入ってくる。春には若い菜が、夏には玉蜀黍が、秋には無花果が台の主役になる。",
                "**棚が一年中同じ顔をしているのなら**、市場の台は暦だ。旬という言葉の力を、私はそこではじめてきちんと教わった気がする。",
            ]
        ),
        CalibrationPassage(
            heading: "待つという贅沢",
            paragraphs: [
                "写真の道具として古い機械が持つ魅力は、結果をすぐに見られないことにある。写した瞬間と像を確かめる瞬間の間の数日が、記憶をもう一度たどらせてくれる。",
                "**即時性が当たり前になった時代に**、待つことはそれ自体が贅沢な趣味になってしまった。",
            ]
        ),
        CalibrationPassage(
            heading: "正直な目録",
            paragraphs: [
                "引っ越しをして、はじめて持ち物の総量を実感した。箱に詰めるたびに同じ問いが繰り返される。これを最後に使ったのはいつだったか。",
                "**空間が変わると**、道具の役目もあらためて審査を受ける。結局残したものが、いまの自分を説明する目録になっていく。",
            ]
        ),
        CalibrationPassage(
            heading: "限界は呼吸にある",
            paragraphs: [
                "走りはじめて分かったのは、限界が速さではなく呼吸の問題だということだ。息が整っていれば脚は思ったより長くもつ。",
                "**無理をした日は必ず翌朝が重く**、控えた日はなぜか遠くまで行ける。体は正直な帳簿をつけているという言葉を、いまは信じている。",
            ]
        ),
        CalibrationPassage(
            heading: "代わりに決める天気",
            paragraphs: [
                "窓に当たる雨の音は、習わなくても好きになれる数少ない音のひとつだ。",
                "**許しを求めずに訪れて**、通りの騒がしさを覆い、どんな部屋も今いるのにふさわしい場所に変えてくれる。天気が代わりに決めてくれる午後には、不思議と気持ちが落ち着くのだ。",
            ]
        ),
        CalibrationPassage(
            heading: "最後の空いた時間",
            paragraphs: [
                "長い路線バスの移動は、忙しい週に残った最後の空いた時間だ。何も終えられないから始める必要もなく、車窓は答えを求めない場面ばかりを差し出してくる。",
                "**終点に着くころには**、先延ばしにしていた考えがいつのまにか片づいているのだった。",
            ]
        ),
    ]

    static let chinese: [CalibrationPassage] = [
        CalibrationPassage(
            heading: "最短的仪式",
            paragraphs: [
                "早晨煮咖啡这件事，是一天里最短的仪式。等水开的时候看看窗外，豆子的香气散开时，才真正有了一天开始的感觉。",
                "**比起宏大的决心**，正是这样细小的重复，让日子保持着平衡，这一点越往后越体会得清楚。",
            ]
        ),
        CalibrationPassage(
            heading: "没有地图的路",
            paragraphs: [
                "不看地图随便走走，熟悉的街区就会露出新的面孔。",
                "**走过上百次的巷子尽头**，忽然有一家旧文具店，旁边的墙头上还探出不知何时种下的玫瑰。没有目的地的脚步虽然慢，却能让人看到更多东西。",
            ]
        ),
        CalibrationPassage(
            heading: "由时间造成的房间",
            paragraphs: [
                "图书馆的魅力不在安静，而在密度。上千本书各自抱着自己的时间并肩站着，只在书架之间走一走，思绪就自己排好了顺序。",
                "**其实不必借走什么**，用眼睛沿着书脊看过去，本身就已经是一种阅读了。",
            ]
        ),
        CalibrationPassage(
            heading: "用身体读坡度",
            paragraphs: [
                "骑上自行车，城市的坡度就会被身体读出来。坐公交时从未察觉的缓坡会直接传到腿上，而下坡的风就是那天的报酬。",
                "**越熟悉地形**，城市看起来就越立体，道路也不再只是路线，而变成了一段故事。",
            ]
        ),
        CalibrationPassage(
            heading: "失败的记录",
            paragraphs: [
                "做菜变好的秘诀不是菜谱，而是失败的记录。放了两次盐的汤、几秒就焦掉的蒜、煮得过软的米饭。",
                "**所有这些错误都会**变成下一次的直觉。厨房是实验室，昨天的失败安静地成了今天的量杯。",
            ]
        ),
        CalibrationPassage(
            heading: "手记住的重量",
            paragraphs: [
                "用了很多年的物件，带着一种手已经记住的重量。十年的包知道拉链会在哪里卡住，旧钢笔会提前告诉你墨快干了。",
                "**比起新东西的光亮**，可预料本身就是一种安稳，那是时间在人与物之间存下的数目。",
            ]
        ),
        CalibrationPassage(
            heading: "以思考的速度散步",
            paragraphs: [
                "散步的速度和思考的速度很像。走得快，脑子也急着下结论；走得慢，问题就一个接一个地多起来。",
                "**需要一个好答案的日子**，我会故意选远一点的路。等到腿开始发酸，心里大多也已经理清了。",
            ]
        ),
        CalibrationPassage(
            heading: "朝向光的东西",
            paragraphs: [
                "冬天窗台上的花盆，每天都会顺着太阳把身子稍稍转一点。早上朝东斜着的叶子，到傍晚已经朝南。",
                "**那些看起来完全不动的东西**，仔细看其实都以各自的速度活着，越忙的日子，这件小事越像意外的安慰。",
            ]
        ),
        CalibrationPassage(
            heading: "火车的声音",
            paragraphs: [
                "坐火车旅行，一半的内容不是窗外的风景，而是声音。规律的颠簸声、渐渐远去的道口铃、邻座低低的谈话。",
                "**就算闭着眼**，火车也会告诉你它大概走到了哪里。这是少有的、移动本身成为目的的时间。",
            ]
        ),
        CalibrationPassage(
            heading: "流过两次的一天",
            paragraphs: [
                "用手写日记，一天就会流过两次。一次是经历的时候，一次是写下来的时候。",
                "**因为比键盘慢**，情绪会先凉下来一口气，句子也就更诚实一些。写完合上那一页时的轻松，还没有任何工具能够替代。",
            ]
        ),
        CalibrationPassage(
            heading: "一小时的地质学",
            paragraphs: [
                "到了海边，谁都会短暂地变成地质学家。浪在沙上压出的纹路、退潮时露出的贝壳花样、脚边消失的泡沫痕迹。",
                "**在如此巨大的重复面前**，原本着急的事忽然显得很小。把那种感觉带回家，就是旅行的意义。",
            ]
        ),
        CalibrationPassage(
            heading: "证据是每天的吐司",
            paragraphs: [
                "街角面包店真正的功力，不在花样繁多的新品，而在每天同样的那只吐司。和昨天一样的气孔、一样的重量、一样的香气。",
                "**持续比才华更**难证明。看到把一件事长久做得如一的人，敬意总会先于赞叹。",
            ]
        ),
        CalibrationPassage(
            heading: "眼睛适应黑暗时",
            paragraphs: [
                "想长时间看夜空，眼睛需要时间去适应黑暗。起初只数得出几颗星，过了十分钟就多出一倍。",
                "**看不见的东西并不等于本来不存在**，这件事天空每次都用同样的方式，安静地讲给愿意站住的人听。",
            ]
        ),
        CalibrationPassage(
            heading: "屋檐下的十五分钟",
            paragraphs: [
                "忘了带伞那天的一场急雨，反而在记忆里留得格外久。在屋檐下躲雨的十五分钟、和旁边陌生人交换的一个短短点头、湿了的路面的味道。",
                "**计划之外的停顿**，有时会成为一整周里最清楚的一个画面。",
            ]
        ),
        CalibrationPassage(
            heading: "摊子就是日历",
            paragraphs: [
                "去市场买菜，季节就会落到手里。春天是嫩菜，夏天是玉米，秋天是无花果轮流做摊子的主角。",
                "**如果超市的货架一年到头都是同一张脸**，那市场的摊子就是日历。应季这个词的力量，我是在那里第一次学会的。",
            ]
        ),
        CalibrationPassage(
            heading: "等待这种奢侈",
            paragraphs: [
                "旧相机的魅力，恰恰在于不能马上看到结果。按下快门到看见成像之间的那几天，会让人把记忆再回想一遍。",
                "**在一切都即刻到手的年代**，等待本身已经悄悄变成了一种相当奢侈的爱好。",
            ]
        ),
        CalibrationPassage(
            heading: "诚实的清单",
            paragraphs: [
                "搬过一次家，才真正感受到自己东西的总量。每装一个箱子，同样的问题就重复一次：这个我上次用是什么时候。",
                "**空间一变**，物件的用处也要重新接受审查。最后留下来的那些，成了说明现在的我的清单。",
            ]
        ),
        CalibrationPassage(
            heading: "界限在呼吸",
            paragraphs: [
                "开始跑步之后才明白，界限不在速度，而在呼吸。气息平稳的话，腿能撑得比想象中久。",
                "**勉强的那天**，第二天早上一定会来讨债；克制的那天，反而不知怎么就跑得更远。身体记的是一本很诚实的账。",
            ]
        ),
        CalibrationPassage(
            heading: "替人决定的天气",
            paragraphs: [
                "打在窗上的雨声，是少数不必学习就会喜欢的声音之一。",
                "**它不征求同意就来了**，盖住街上的吵闹，把任何一个房间都变成此刻最合适待着的地方。天气代替人做决定的下午，心里反而格外安定。",
            ]
        ),
        CalibrationPassage(
            heading: "最后一段空时间",
            paragraphs: [
                "长途公交上的那段路，是忙碌一周里剩下的最后一段空时间。什么都完成不了，所以也不必开始，窗外不停递来不要求回答的画面。",
                "**等到终点站**，一直拖着不想的那件事，不知不觉已经想清楚了。",
            ]
        ),
    ]
}
