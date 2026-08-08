/// The words on the page, written by hand rather than greeked.
///
/// Lorem ipsum reads as slop at any size, and this is an app whose whole claim is
/// typography — placeholder text on the asset would say the opposite of the product.
///
/// The source names are invented on purpose. A real masthead in an App Store asset is a
/// trademark and an implied endorsement, and invented independent titles read as exactly
/// the kind of writing Nook is for.
///
/// The sources are in their own languages and the headlines are in the reader's: that is
/// the translation feature stated typographically, as a standing fact rather than an
/// animation that would have to undo itself every six seconds. A locale never appears as
/// its own source.
export type Column = {
  source: string;
  headline: string[];
  body: string[];
};

export const pageCopy = {
  en: {
    tagline: 'THE READING YOU CHOSE',
    columns: [
      {
        source: '필드 노트',
        headline: ['On keeping a', 'reading table'],
        body: [
          'A table is not storage. What sits on',
          'it is what you have decided to spend',
          'the week with, and everything else',
          'belongs somewhere further away.',
        ],
      },
      {
        source: 'マージナリア',
        headline: ['The margin as', 'a room'],
        body: [
          'Wide margins were never decoration.',
          'They were where the reader was',
          'expected to answer, and a page that',
          'leaves no room expects no reply.',
        ],
      },
      {
        source: '慢水',
        headline: ['Slow water,', 'deep channel'],
        body: [
          'Rivers that move slowly cut deepest.',
          'The same is true of a piece you come',
          'back to for a month, and of the few',
          'writers worth that month.',
        ],
      },
      {
        source: 'NORDLYS',
        headline: ['Light in the', 'long winter'],
        body: [
          'For half the year the reading lamp is',
          'the only sun. What you gather under',
          'it turns out to matter more than what',
          'the summer offered freely.',
        ],
      },
      {
        source: 'PAPIER & ENCRE',
        headline: ['Against the', 'infinite feed'],
        body: [
          'An edition ends. That is its whole',
          'argument. A page that never stops',
          'asks for attention it has not earned',
          'and cannot repay.',
        ],
      },
      {
        source: 'COMMON HOURS',
        headline: ['An hour that', 'belongs to you'],
        body: [
          'The hour is not found; it is defended.',
          'Everything that wants it is louder',
          'than the thing you meant to read,',
          'and none of it will wait quietly.',
        ],
      },
      {
        source: 'Der Anbau',
        headline: ['Building a', 'small annex'],
        body: [
          'A house grows by rooms, not by walls.',
          'A library grows the same way: one',
          'writer at a time, each added because',
          'you went looking for them.',
        ],
      },
      {
        source: 'SMALL HOURS',
        headline: ['Reading before', 'the day starts'],
        body: [
          'Nothing arrives at five in the morning.',
          'That is the point. Whatever is on the',
          'table then is there because you put',
          'it there the night before.',
        ],
      },
      {
        source: 'THE LONG WAY',
        headline: ['Taking the', 'longer road'],
        body: [
          'The direct route is a summary, and a',
          'summary is somebody else deciding',
          'what mattered. The long way is where',
          'the thinking is kept.',
        ],
      },
    ] as Column[],
  },
  ko: {
    tagline: '고른 글만 남습니다',
    columns: [
      {
        source: 'FIELD NOTES',
        headline: ['읽는 책상을', '지킨다는 것'],
        body: [
          '책상은 창고가 아닙니다. 그 위에 놓인',
          '것이 이번 주를 함께 보내기로 정한',
          '것이고, 나머지는 조금 더 먼 곳에',
          '있어야 합니다.',
        ],
      },
      {
        source: 'マージナリア',
        headline: ['여백이라는', '작은 방'],
        body: [
          '넓은 여백은 장식이 아니었습니다.',
          '독자가 답할 자리였고, 자리를 남기지',
          '않은 지면은 애초에 답을 기대하지',
          '않는 지면입니다.',
        ],
      },
      {
        source: '慢水',
        headline: ['느린 물이', '깊게 팹니다'],
        body: [
          '천천히 흐르는 강이 가장 깊게 팹니다.',
          '한 달을 두고 다시 펼치는 글도,',
          '그 한 달을 쓸 만한 몇 안 되는',
          '필자도 그렇습니다.',
        ],
      },
      {
        source: 'NORDLYS',
        headline: ['긴 겨울의', '불빛 하나'],
        body: [
          '한 해의 절반은 독서등이 유일한',
          '해입니다. 그 아래 모아둔 것이',
          '여름이 거저 준 것보다 오래',
          '남습니다.',
        ],
      },
      {
        source: 'PAPIER & ENCRE',
        headline: ['끝없는 피드에', '맞서서'],
        body: [
          '한 호는 끝이 납니다. 그것이 전부의',
          '논거입니다. 끝나지 않는 지면은',
          '얻지 않은 주의를 요구하고 되갚지도',
          '못합니다.',
        ],
      },
      {
        source: 'COMMON HOURS',
        headline: ['내 것인', '한 시간'],
        body: [
          '그 시간은 발견하는 게 아니라 지키는',
          '것입니다. 그것을 노리는 모든 것이',
          '읽으려던 글보다 시끄럽고, 조용히',
          '기다려 주지 않습니다.',
        ],
      },
      {
        source: 'Der Anbau',
        headline: ['작은 별채를', '덧짓기'],
        body: [
          '집은 벽이 아니라 방으로 자랍니다.',
          '서재도 같습니다. 한 번에 한 사람씩,',
          '내가 찾아 나섰기 때문에 더해지는',
          '이름들로.',
        ],
      },
      {
        source: 'SMALL HOURS',
        headline: ['하루가 시작되기', '전에 읽기'],
        body: [
          '새벽 다섯 시에는 아무것도 도착하지',
          '않습니다. 그게 핵심입니다. 그때',
          '책상에 있는 것은 전날 밤 내가',
          '올려둔 것뿐입니다.',
        ],
      },
      {
        source: 'THE LONG WAY',
        headline: ['먼 길로', '돌아가기'],
        body: [
          '지름길은 요약이고, 요약은 무엇이',
          '중요했는지를 남이 정한 것입니다.',
          '생각이 남아 있는 곳은 언제나',
          '먼 길 쪽입니다.',
        ],
      },
    ] as Column[],
  },
} as const;

/// The prose lying on the sill in Concept B. Evergreen, never a product claim, never the
/// app's name.
export const sillCopy = {
  en: {
    headline: 'On keeping a reading table',
    body: [
      'A table is not storage. What sits on it is what you',
      'have decided to spend the week with, and everything',
      'else belongs somewhere further away — in a drawer, on',
      'a shelf, or in somebody else’s week entirely.',
      'The pile is not the problem. Choosing is.',
    ],
  },
  ko: {
    headline: '읽는 책상을 지킨다는 것',
    body: [
      '책상은 창고가 아닙니다. 그 위에 놓인 것이 이번 주를',
      '함께 보내기로 정한 것이고, 나머지는 조금 더 먼 곳에',
      '있어야 합니다. 서랍이든, 선반이든, 아예 다른 사람의',
      '한 주든 말입니다.',
      '쌓인 더미가 문제가 아니라, 고르는 일이 문제입니다.',
    ],
  },
} as const;
