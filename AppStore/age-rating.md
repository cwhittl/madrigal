# Age rating answers

App Store Connect → App Information → Age Rating → Edit. This is the
questionnaire Apple introduced in July 2025 (ratings 4+, 9+, 13+, 16+, 18+;
answers required for updates since January 31, 2026). Apple says ratings must
account for **AI assistants and chatbot features**: how often a general-purpose
model *could* produce each kind of content counts, not just what the app ships.

> Re-open the questionnaire right before submitting. Apple keeps adding
> questions (social features, July 2026; new content descriptors reported for
> November 16, 2026). Answer any new item with the same reasoning: Madrigal has
> no social features, no user-to-user messaging and no companion persona.

## How Madrigal's features map to the questions

Madrigal ships no content of its own. Every reply comes from a model the user
connects, and hosted models apply their own safety filters. But the user can
point it at *any* OpenAI-compatible endpoint, including an unfiltered local
model, so an honest answer assumes mature topics can come up occasionally
when the user asks for them.

### Features
| Question | Answer | Why |
|---|---|---|
| Parental controls | No | None in the app. |
| Age assurance | No | No accounts. |
| Unrestricted web access | **No** | There is no in-app browser. Links in replies and sources open in the user's browser, and web search only feeds result text to the model. If you'd rather be conservative, answer Yes: on OS 26 and later that alone leads to **16+**. |
| User-generated content | No | Users can't see each other's content. |
| Messaging and chat (with other people) | No | Chats are between the user and a model; there's no messaging between people. |
| Advertising | No | |

### Mature or suggestive themes, violence, and similar
| Question | Answer | Why |
|---|---|---|
| Profanity or crude humor | **Infrequent/Mild** | A model may swear if asked. |
| Horror or fear themes | **Infrequent/Mild** | Fiction requests. |
| Alcohol, tobacco or drug use or references | **Infrequent/Mild** | General questions (wine pairing, medication). |
| Mature or suggestive themes | **Infrequent/Mild** | Possible on request. |
| Sexual content or nudity | None | Text only; hosted providers refuse explicit content, and the app doesn't market or tune for it. Answering Infrequent here would put the app at 16+ or higher. |
| Graphic sexual content and nudity | None | |
| Cartoon or fantasy violence | **Infrequent/Mild** | Fiction requests. |
| Realistic violence | **Infrequent/Mild** | News and history questions. |
| Prolonged graphic or sadistic violence | None | |
| Guns or other weapons | **Infrequent/Mild** | Questions can mention them. |

### Medical and wellness
| Question | Answer | Why |
|---|---|---|
| Medical or treatment information | **Infrequent** | General health questions are a common chatbot use. The app gives no diagnosis and has no health features. |
| Health or wellness topics | **Infrequent** | Same. |

### Chance-based activities
| Question | Answer |
|---|---|
| Simulated gambling | No |
| Contests | No |
| Loot boxes | No |
| Gambling (real money) | No |

## Expected result: **13+**

Several "Infrequent/Mild" answers in the mature-themes and violence groups put
the app at **13+**. Two answers would move it to **16+**:
- Unrestricted web access = Yes, or
- Mature/suggestive themes or medical topics = Frequent/Intense.

**Recommendation:** accept **13+** with the answers above. If App Review
pushes back that a general chatbot can produce more than mild content,
answer Unrestricted web access = Yes and resubmit at **16+**. That's the
usual outcome for bring-your-own-model chat apps and needs no code change.

There's no separate "AI-generated content" checkbox to tick; Apple folds AI
output into the frequency answers above. Mention it in the review notes
(`review-notes.md` already does).

Sources: [Apple, Updated age ratings in App Store Connect](https://developer.apple.com/news/?id=ks775ehf),
[App Store Connect Help: Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating),
[9to5Mac, July 24, 2025](https://9to5mac.com/2025/07/24/apple-notifies-developers-of-new-app-store-age-rating-system/).
