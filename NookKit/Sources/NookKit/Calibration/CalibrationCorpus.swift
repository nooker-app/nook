import Foundation

/// Bundled fallback paragraphs for 읽기 맞춤, used when the user's own feeds
/// can't supply enough eligible test material. Original prose written for this
/// purpose (no external text), length-banded per script, neutral in topic, and
/// deliberately varied so consecutive trials don't blur together.
public enum CalibrationCorpus {
    public static func paragraphs(for script: CalibrationScript) -> [CalibrationParagraph] {
        let texts = script == .korean ? korean : latin
        return texts.enumerated().map { index, text in
            CalibrationParagraph(
                id: "corpus-\(script.rawValue)-\(index)",
                text: text,
                sourceTitle: String(localized: "Nook's reading samples", bundle: .module)
            )
        }
    }

    static let korean: [String] = [
        "아침에 커피를 내리는 일은 하루 중 가장 짧은 의식이다. 물이 끓는 동안 창밖을 보고, 원두 향이 퍼지면 비로소 하루가 시작된다는 감각이 든다. 대단한 결심보다 이런 작은 반복이 생활의 균형을 잡아 준다는 걸 해가 갈수록 실감하게 된다.",
        "지도를 보지 않고 걷다 보면 동네의 새로운 얼굴을 만나게 된다. 늘 지나치던 골목 끝에 오래된 문방구가 있었고, 그 옆 담장 위로는 언제 심었는지 모를 장미가 넘어와 있었다. 목적지가 없는 걸음은 느리지만, 그만큼 많은 것을 보여 준다.",
        "도서관의 매력은 조용함이 아니라 밀도에 있다. 수천 권의 책이 각자의 시간을 품은 채 나란히 꽂혀 있고, 그 사이를 걷는 것만으로도 생각이 정리된다. 빌리지 않아도 좋다. 책등을 눈으로 훑는 일 자체가 이미 하나의 독서이기 때문이다.",
        "자전거를 타면 도시의 경사가 몸으로 읽힌다. 버스로는 몰랐던 완만한 오르막이 다리에 전해지고, 내리막의 바람은 그날의 보상이 된다. 지형을 아는 만큼 도시가 입체적으로 보이기 시작하고, 길은 단순한 경로가 아니라 이야기가 된다.",
        "요리를 잘하게 되는 비결은 레시피가 아니라 실패의 기록이라고 생각한다. 소금을 두 번 넣은 국, 태워 버린 마늘, 질어진 밥. 그 모든 실수가 다음번의 감각이 된다. 주방은 실험실이고, 어제의 실패는 오늘의 계량컵이 되어 준다.",
        "오래 쓴 물건에는 손에 익은 무게가 있다. 십 년 된 가방의 지퍼는 어디서 걸리는지 알고, 낡은 만년필은 잉크가 굳는 시점을 먼저 알려 준다. 새것의 반짝임 대신 예측 가능함이 주는 안정감. 그것이 물건과 나 사이에 쌓인 시간의 값이다.",
        "산책의 속도는 생각의 속도와 닮아 있다. 빠르게 걸으면 머릿속도 결론을 서두르고, 천천히 걸으면 질문이 하나씩 늘어난다. 좋은 답이 필요한 날에는 일부러 먼 길을 골라 걷는다. 다리가 아플 때쯤이면 대개 마음도 정리되어 있다.",
        "겨울 창가의 화분은 매일 조금씩 해를 따라 몸을 튼다. 아침에 동쪽으로 기울었던 잎이 저녁에는 남쪽을 향해 있다. 움직이지 않는 것처럼 보이는 것들도 자세히 보면 저마다의 속도로 살아 있다는 사실이, 바쁜 날일수록 위로가 된다.",
        "기차 여행의 절반은 창밖 풍경이 아니라 소리다. 규칙적인 덜컹임, 멀어지는 건널목 종소리, 옆자리의 낮은 대화. 눈을 감아도 기차는 어디쯤 달리고 있는지 알려 준다. 도착보다 이동 그 자체가 목적이 되는 드문 시간이기도 하다.",
        "손글씨로 일기를 쓰면 하루가 두 번 흘러간다. 한 번은 겪을 때, 한 번은 적을 때. 자판보다 느린 속도 덕분에 감정은 한 김 식고, 문장은 조금 더 정직해진다. 다 쓴 페이지를 덮는 순간의 가벼움은 어떤 앱도 대신해 주지 못했다.",
        "바다에 가면 누구나 잠시 지질학자가 된다. 파도가 만든 모래의 결, 물러날 때 드러나는 조개 무늬, 발밑에서 사라지는 거품의 흔적. 거대한 반복 앞에서는 급했던 일들이 문득 작아 보인다. 그 감각을 챙겨 오는 것이 여행의 몫이다.",
        "동네 빵집의 진짜 실력은 화려한 신제품이 아니라 매일 같은 식빵에서 드러난다. 어제와 같은 결, 같은 무게, 같은 향. 꾸준함은 재능보다 증명하기 어렵다. 무엇이든 오래 한결같이 해내는 사람을 보면 존경심이 먼저 든다.",
        "밤하늘을 오래 보려면 어둠에 눈이 익을 시간이 필요하다. 처음에는 몇 개뿐이던 별이 십 분쯤 지나면 배로 늘어난다. 보이지 않던 것이 원래 없던 것은 아니라는 사실을, 하늘은 매번 같은 방식으로 조용히 가르쳐 준다.",
        "우산을 깜빡한 날의 소나기는 이상하게 기억에 오래 남는다. 처마 밑에서 비를 긋던 십오 분, 옆에 서 있던 낯선 사람과 나눈 짧은 눈인사. 계획에 없던 멈춤이 하루의 가장 선명한 장면이 되기도 한다는 걸 그런 날 배운다.",
        "시장에서 장을 보면 계절이 손에 잡힌다. 봄에는 냉이가, 여름에는 옥수수가, 가을에는 무화과가 좌판의 주인공이 된다. 마트의 진열대가 일 년 내내 같은 얼굴이라면, 시장의 좌판은 달력이다. 제철이라는 말의 힘을 그곳에서 배웠다.",
        "필름 카메라의 매력은 결과를 바로 볼 수 없다는 데 있다. 셔터를 누른 순간과 사진을 확인하는 순간 사이의 며칠이, 기억을 한 번 더 곱씹게 만든다. 즉시성이 당연해진 시대에 기다림은 그 자체로 사치스러운 취미가 되었다.",
        "이사를 하고 나서야 물건의 총량을 실감했다. 상자를 쌀 때마다 같은 질문이 반복된다. 이걸 마지막으로 쓴 게 언제였지. 공간이 바뀌면 물건의 쓸모도 다시 심사를 받는다. 결국 남긴 것들이 지금의 나를 설명하는 목록이 된다.",
        "달리기를 시작하고 알게 된 것은 속도가 아니라 호흡의 문제라는 사실이다. 숨이 고르면 다리는 생각보다 오래 버틴다. 무리한 날은 어김없이 다음 날이 무겁고, 절제한 날은 이상하게 더 멀리 간다. 몸은 정직한 장부를 쓴다.",
    ]

    static let latin: [String] = [
        "The first cup of coffee in the morning is less about caffeine than about ceremony. While the water heats, the kitchen window shows whatever weather the day has decided on, and by the time the smell of the grounds rises, the day feels officially begun. Small repeated rituals, more than grand resolutions, are what actually hold a life steady.",
        "Walking without a map turns a familiar neighborhood into a new one. At the end of a street you have passed a hundred times there is suddenly an old stationery shop, and over the wall beside it a rose bush leans out as if it had been waiting. A walk with no destination is slow, but it shows you far more than the fastest route ever will.",
        "The charm of a library is not its silence but its density. Thousands of books stand shoulder to shoulder, each holding its own stretch of time, and simply walking between the shelves seems to sort your thoughts into order. You do not even need to borrow anything; running your eyes along the spines is already a kind of reading.",
        "Riding a bicycle teaches you the true topography of a city. Gentle climbs you never noticed from a bus arrive directly in your legs, and every descent pays you back with wind. Once you know the terrain this way, the city stops being flat. Streets are no longer routes between places; they become stories with slopes and turns.",
        "The secret to cooking well is not a recipe collection but a record of failures. The soup that got salted twice, the garlic that burned in seconds, the rice that turned to paste. Every one of those mistakes becomes next time's instinct. A kitchen is a laboratory where yesterday's disaster quietly becomes today's measuring cup.",
        "Objects you have used for years carry a weight your hands have memorized. You know exactly where the zipper of a ten-year-old bag will catch, and an old fountain pen warns you before its ink runs dry. Instead of the sparkle of the new, there is the calm of the predictable, which is the value of time saved up between you and a thing.",
        "The pace of a walk resembles the pace of thought. Walk quickly and your mind hurries toward conclusions; walk slowly and the questions multiply one by one. On days that demand a good answer, I deliberately choose the long way around. By the time my legs begin to ache, my mind has usually finished tidying itself.",
        "A potted plant on a winter windowsill turns its body a little further toward the sun every day. Leaves that leaned east in the morning face south by evening. Things that appear motionless are alive at their own speed if you look closely enough, and on busy days that fact is strangely comforting to remember.",
        "Half of any train journey is sound rather than scenery. The regular clatter of the rails, a crossing bell fading behind, the low conversation in the next seat. Even with your eyes closed, the train tells you roughly where it is. It is one of the rare stretches of life where the moving, not the arriving, is the whole point.",
        "Keeping a diary by hand makes each day pass twice: once while you live it and once while you write it down. Because a pen is slower than a keyboard, the feelings cool a little on the way to the page and the sentences come out more honest. No app has ever matched the lightness of closing a finished page.",
        "At the seaside everyone becomes a geologist for an hour. The ridges the waves press into the sand, the shell patterns uncovered by the retreating water, the foam vanishing around your ankles. In front of such enormous repetition, urgent matters suddenly look small, and carrying that feeling home is the real souvenir.",
        "A neighborhood bakery proves itself not with dazzling new pastries but with the same plain loaf every single day. The same crumb as yesterday, the same weight, the same smell. Consistency is harder to demonstrate than talent, which is why anyone who does one thing steadily for years earns respect before admiration.",
        "To really see the night sky you must give your eyes time to learn the dark. The handful of stars you count at first doubles after ten quiet minutes. What was invisible was never absent, and the sky teaches that same lesson in the same patient way every single time you are willing to stand still for it.",
        "A sudden shower on the day you forgot your umbrella has a strange way of outlasting other memories. Fifteen minutes under a shop awning, a brief nod exchanged with a stranger sheltering beside you. An unplanned pause can turn into the clearest scene of the entire day, which is something schedules never account for.",
        "Shopping at a street market puts the seasons directly into your hands. Shepherd's purse in spring, sweet corn in summer, figs taking over the stalls in autumn. If a supermarket shelf wears the same face all year, a market stall is a calendar, and it is there that the word seasonal finally starts to mean something.",
        "The appeal of a film camera is precisely that you cannot see the result right away. The few days between pressing the shutter and holding the print make you replay the memory one more time. In an age where immediacy is assumed, waiting has quietly become the most luxurious hobby there is.",
        "Only after moving house do you grasp the true volume of your belongings. With every box you pack, the same question repeats: when did I actually use this last? When the space changes, every object must reapply for its place, and whatever survives the cut becomes an honest inventory of who you are right now.",
        "What running actually teaches you is that the limit is breathing, not speed. Keep the breath even and the legs last far longer than expected. Push too hard and the next morning collects the debt without fail; hold back a little and you somehow go further. The body keeps remarkably honest books.",
    ]
}
