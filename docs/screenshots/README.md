# Mac screenshots

The Beta images and walkthrough are captures of the real macOS app using an isolated, English-language library. Feeds were refreshed in Nook; article titles, dates, authors, images, and text come from their publishers. No article content or interface was composited into the screenshots.

| Asset | What it shows |
| --- | --- |
| `main.png` | Unread articles in Magazine, ordered by local recommendations |
| `map.png` | Meaning-based connections and the selected article's related stories |
| `reader.png` | CSS-Tricks' “scroll-state()” in the native reader, including formatted code |
| `library.png` | English feeds organized into Design, Science, and Technology folders |
| `reading-flow.gif` | Opening NASA's “Lake Pelku,” scrolling its content, and returning to Magazine |
| `classic.png` | The previous README's Classic screenshot, preserved without changing its pixels |

The GIF is a 14-second window recording, sampled at 12 frames per second and 960 pixels wide, with a brief pause at either end. It records actual transitions rather than a slideshow. The Map capture uses the optional local semantic models; its layout and recommendations reflect this sample library's reading activity.

## Try the feeds

Download [feeds.opml](feeds.opml) and import it through Nook's OPML import command, or add individual feed URLs below. Live feeds change over time, so your headlines and article counts will differ.

| Folder | Publication | RSS / Atom feed |
| --- | --- | --- |
| Design | [CSS-Tricks](https://css-tricks.com/) | <https://css-tricks.com/feed/> |
| Design | [Smashing Magazine](https://www.smashingmagazine.com/) | <https://www.smashingmagazine.com/feed/> |
| Science | [NASA Image of the Day](https://www.nasa.gov/image-of-the-day/) | <https://www.nasa.gov/feeds/iotd-feed/> |
| Technology | [Cloudflare Blog](https://blog.cloudflare.com/) | <https://blog.cloudflare.com/rss/> |
| Technology | [Simon Willison's Weblog](https://simonwillison.net/) | <https://simonwillison.net/atom/everything/> |

Article text and imagery belong to their respective publishers. The “Lake Pelku” photograph is credited by NASA to CSA/Joshua Kutryk.

## Recapture safely

- Use an isolated app profile and library. Do not change a daily-use Nook library or its preferences for a screenshot.
- Set both the app language and the capture profile's locale to English. Wait for image loading, extraction, and animations to settle.
- Keep Nook active during thumbnail loading and recording. Ask before taking over the foreground when automating on someone else's desktop.
- Capture only the intended app window by its exact `CGWindowID`, especially when two Nook instances are running. Keep the window shadow for README stills.
- Record the same window without microphone or system audio, then encode the recording as a small GIF. Inspect the beginning, transitions, and end before committing it.
- Keep iOS assets and the preserved Classic image unchanged when refreshing this Beta set.
