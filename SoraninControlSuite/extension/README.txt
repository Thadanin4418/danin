Sora All In One v1.14.0

Chrome restore:
- This package is kept as a Chrome extension.
- No Safari project files are included in this folder.
- Load this folder directly in Chrome with `Load unpacked`.
- Download buttons now build direct proxy downloads with `https://soravdl.com/api/proxy/video/<SoraVideoId>` for published `/p/s_...` Sora videos.
- Full published video pages now show a fixed top-left `Download` overlay so the button stays clickable above the Sora player area.
- Manual `Download` buttons on `/explore` and `/p/s_...` now force a fresh download even if that Sora video ID was downloaded before.
- Full published video pages now switch the `Download` button to a compact right-side rail layout on smaller/mobile-sized viewports.
- On mobile-sized published video pages, the `Download` button now anchors itself near the visible `Like/Reply/Remix/Share` rail so it stays close to the native Sora action buttons.
- The mobile rail layout now prefers the `Like` anchor first and places `Download` just to the left of the action rail, so it stays visible on narrow Chrome windows.
- The mobile rail layout now places `Download` above the `Like` action instead of level with it, matching the tighter position next to Sora's right-side action stack.
- Post All Found on `/drafts` now opens all found draft URLs in background tabs, waits for load, tries Post on all tabs in parallel, retries once with refresh if needed, then closes those tabs.
- Delete All Found now rescans the current Sora page automatically before starting, so it can collect fresh video URLs without requiring a manual scan first.
- Post All Found now rescans the current Sora page automatically before starting, and on `/drafts` it always uses the open-all-tabs batch path instead of the old current-tab inline path.
- Draft URL detection now accepts general `https://sora.chatgpt.com/d/...` links, not only `.../d/gen_...`.
- Single draft post actions now pass the exact scanned URL to the background worker.
- Download All URLs now downloads published video URLs only, and draft `/d/...` slugs are no longer treated as generic video IDs.
- Weak draft scanning from page text/scripts/full HTML is now stricter to reduce false positives while still accepting real long `/d/...` URLs.
- Batch `Post All Found` now tolerates query/hash differences while waiting for loaded tabs, skips the caption-edit step in background post tabs, and gives more weight to large bottom `Post` buttons for mobile/desktop layouts.
- In the popup quick actions, `Download All URLs` is now placed above `Delete All Found`.
- The popup `Post Tools` section now also shows a `Post All Found` button next to `Post Draft`.
- The popup now also shows a prominent top `Post All Found` logo button so it is visible immediately without opening hidden tool sections.
- The website itself now shows a floating `Post All Found` button only on `https://sora.chatgpt.com/drafts`.

How to load:
1. Open Chrome and go to chrome://extensions
2. Turn on Developer mode
3. Click Load unpacked
4. Select this folder

What this version includes:
- Quick popup buttons for Copy All Video URLs, Post, Open All Hidden, and one-click Download All URLs
- The popup header now keeps only Post, Delete, and All near the title; the Auto view button was removed
- The Auto Post Drafts toggle was removed from the popup and saved auto-post is forced off
- Download All URLs now locks after one click and shows progress like current item number, started, completed, and failed counts
- The drafts post queue now opens one draft at a time, waits about 4.5 seconds, then tries Post with slower retries for better stability
- If Post is still missing, the draft queue returns to the list, reopens that draft once, and retries automatically
- On the drafts page, `Post All Found` now opens all found draft URLs in new background tabs, waits for them to load, posts them, closes those tabs, and refreshes at the end
- The background `Post All Found` flow now truly waits for all draft tabs to finish loading and settle for about 4.5 seconds before sending the Post action
- On a profile/list page, `Delete All Found` now mirrors that flow: open all found video URLs in new background tabs, wait for them to load and settle, delete them, close those tabs, and refresh at the end
- If a background delete tab fails once, it now refreshes that tab, waits again, retries Delete once more, and then closes the tab automatically
- In the `Delete All Found` batch flow, each opened delete tab now closes immediately after its own delete/retry cycle finishes instead of waiting for the whole batch
- `Post All Found` now uses the same batch pattern: each post tab can refresh and retry once, then closes immediately after its own post/retry cycle finishes
- `Post All Found` no longer fires Post on every tab at the same time; it now waits longer for the tabs to settle and then posts them one-by-one for better reliability
- The popup is now simplified to four visible quick buttons: Copy All Video URLs, Post All Found, Delete All Found, and Download All URLs
- Download All URLs now uses the merged downloader logic from the provided code: stronger ID extraction, duplicate filtering, and already-downloaded skip tracking before the browser download starts
- Download status in the popup now shows failed video IDs so it is clear which items failed
- Post All Found now follows the same parallel open -> wait -> action -> close-tab pattern as Delete All Found, but using Post only
- On `https://sora.chatgpt.com/drafts`, the quick `Post All Found` button now uses the same inline current-tab draft-post script as the stable Post queue buttons for better reliability
- On `https://sora.chatgpt.com/drafts`, quick `Post All Found` now opens all found `/d/gen_...` draft URLs in background tabs, waits for load, retries once with refresh if Post is missing, then closes those tabs automatically
- Before posting a draft page, the content script now tries to open the edit/description UI, replace the text with `hi`, click `Done`, and then continue to `Post`
- Before posting a draft page, the content script now prefers the order `viewbox` -> clear prompt/add `hi` -> `Class` -> `Done` -> `Post`, with fallbacks if some controls are missing
- The pre-post edit step now follows the draft card UI more closely: click the pencil edit button, clear the caption, click the checkmark confirm button, then continue to Post
- The edit/confirm selectors are now anchored to the same visible draft card/panel as the `Post` button, with an active-editor fallback after the pencil click
- `Download All URLs` now starts downloads immediately, remembers failed URLs for retry, retries only failed URLs on the next click, and removes successful URLs from the failed-retry list
- `Download All URLs` now opens the whole download batch in parallel instead of awaiting each URL one-by-one
- `Delete All` and `Open All` now skip URLs whose downloads previously failed, so those URLs stay protected for download retry instead of being opened or deleted
- Those three quick buttons now auto-scan the active Sora page first when needed so they still work without the old extra controls
- The /drafts page is now treated as a Post page in Auto view
- On https://sora.chatgpt.com/drafts, popup Post/Post 5/Post 10/Post All now prefer a current-tab script queue: click Post on visible draft cards, or open that draft in the same tab, post it, and return to the drafts list one-by-one
- On Sora profile/list pages, popup Delete/Delete 5/Delete 10/Delete All now prefer a current-page script queue and work through visible videos one-by-one
- The Stop Delete button now stops that one-by-one current-page delete queue
- Fast Delete Mode now also speeds up that one-by-one current-page delete queue
- The quick Post button now posts all found draft URLs when more than one draft was scanned
- A quick Delete All Found button now deletes all scanned video URLs through the new background-tab batch flow when you are on a profile/list page
- All controls now stay in the Chrome extension popup only; the page-level Show All Menu and floating helper UI are disabled
- Popup view switch for Auto, Post, Delete, or All
- Profile scan now has stronger fallback matching for video URLs
- Worker now uses a single background tab
- Floating page helper buttons and page status panels are disabled by default
- Batch queues now refresh the active Sora page once after the whole Post/Delete run finishes
- Open All Hidden now visits all captured video URLs through the same background tab
- Profile URL scan now also reads full-page HTML and visible thumbnail cards to catch more video URLs
- Post and Delete now reuse one background tab instead of opening a new window
- The background worker tab now closes automatically after Post/Delete/Open Hidden finishes
- Scan Sora project and draft URLs
- Copy all scanned post URLs from the Post section
- Post a single found draft/project URL
- Run Post 5, Post 10, or Post All
- Auto Post Drafts in the same background tab
- Auto Post and hidden background actions now retry worker messaging more safely after page load
- Auto Post is now off by default and only runs when the active tab is a draft detail page
- Auto Post and single-item actions still use the single shared background worker tab
- Faster post queue timing with shorter worker-load, menu-open, retry, and next-item waits
- Smarter post detection that prefers Post/Publish and waits for a success signal before moving on
- Scan visible Sora video cards on a profile/list page
- Copy all scanned Sora video URLs
- Start direct browser downloads for all collected Sora URLs in one click
- Open all scanned Sora video URLs quietly in the background tab
- The page menu can trigger scan, post all, delete all, copy URLs, and open hidden directly on Sora
- Delete a single visible card
- Run Delete 5, Delete 10, or Delete All directly on the current profile/list page script
- Fast Delete Mode toggle for much shorter waits and faster retries
- Project-page delete flow now prefers the three-dots menu before clicking Delete
- Stop either queue after the current item finishes
- Stop the hidden open queue after the current URL finishes

How to use:
1. Open Sora.
2. On a draft/project page, use Scan Post URLs for post actions.
3. On a profile/list page, use Scan Visible Cards for delete actions.
4. Use Copy URLs if you want all scanned Sora video links in one click.
5. Use Open All Hidden if you want the saved video URLs opened quietly through the background worker tab.
6. Turn on Fast Delete Mode if you want shorter waits between delete steps.
7. Use the Post section for post queues and the Delete section for delete queues.
8. Use the matching Stop button if you want that queue to stop after the current item.

Notes:
- Published video URLs are now cached separately, so `Delete All Found` no longer wipes out the URL list that `Download All URLs` and `Copy All Video URLs` can reuse later.
- Download All URLs now always opens each Sora page in the background Chrome tab first, then resolves the media URL through your logged-in Chrome session before downloading.
- Profile-page Copy/Download/Delete buttons now auto-scroll through more cards to collect more video URLs, and the floating profile action buttons now have a keep-alive reattach loop so they come back if Sora rerenders the page.
- Download All URLs now starts all found downloads in parallel again, and the extension icon shows a badge while running (`DL`) and when finished (`OK` or `!` if some failed).
- Download All URLs now resolves Sora pages through one stable background Chrome tab and starts each browser download quickly without waiting for the previous file to finish, so the downloads still overlap but media resolution is more reliable.
- Download All URLs now opens many background tabs again, one for each found Sora URL that still needs media resolution, then starts the browser downloads in parallel and closes those helper tabs.
- On the Sora profile page, `Download All URLs`/`Copy All Video URLs` and `Delete All Found` now use separate URL collectors instead of sharing the same capture path.
- The popup now shows a `Failed Downloads` box that keeps only failed URLs, removes successful ones automatically, and lets you retry or clear the failed list.
- The popup quick actions now also include `Post 5 Found` and `Post 10 Found`, using the same open-and-post flow as `Post All Found`.
- The website now shows floating Copy All Video URLs, Download All URLs, and Delete All Found buttons only on https://sora.chatgpt.com/profile.
- The website Post All Found floating button still shows only on https://sora.chatgpt.com/drafts.
- Download All URLs now tries to resolve the real media URL from each Sora page through your logged-in Chrome session before starting the browser download.
- Download All URLs no longer depends on the old soravdl proxy flow; URLs that still fail are kept in the failed-download retry list.
- Post clicks now use a stronger click path and also treat disabled/disappearing Post buttons as a valid transition signal for batch draft posting.
- After a successful post run, the active Sora tab now redirects to https://sora.chatgpt.com/profile instead of staying on the old draft/list page.
- The post redirect now waits about 3 seconds after a successful post before moving to https://sora.chatgpt.com/profile.
- Parallel Post All Found now uses faster draft-tab settle time and fast-mode Post clicks right after each draft page finishes loading.
- The floating profile buttons now show their own status text and use stronger fallback URL collection on https://sora.chatgpt.com/profile.
- The website Delete All Found button on https://sora.chatgpt.com/profile now uses the background URL delete queue instead of the current-page delete script.
- The website Delete All Found button now merges visible/profile/page-scan URLs and sends all found video URLs into the batch delete-all flow.
- Download All URLs now runs one item at a time: each download finishes (or fails) before the next Sora URL starts.
- Post and Delete queues do not run at the same time in this combined version.
- Posting still uses Sora's visible page UI in the background tab, not a private API.
- Open All Hidden also uses the same background tab and does not open a popup window.
- One-click downloads use Chrome's download manager with the merged proxy downloader flow.
- Chrome still needs one real tab context, so the extension reuses a single background tab.
- Post queues now move to the next draft faster and refresh once at the end of the batch.
- Deleting still depends on Sora's menu and button labels, so selectors may need updates if Sora changes.
- Delete queues now follow the scanned Sora URL list and delete from each video page, closer to how the post queue works.
- Delete queues now refresh once after the whole batch instead of after every item.
- Fast Delete Mode now uses shorter worker-load, menu-open, delete-click, and next-item delays.
- Fast Delete Mode is more aggressive, so test with Delete 5 first before using Delete All.
- Test with Post 5 or Delete 5 first before running the full queues.
- Auto view now changes the popup layout based on the current Sora page type.
- When you are on https://sora.chatgpt.com/drafts, the Post queue now stays in the current tab and works through drafts one-by-one until the list is done or you stop it.
- If you are on a Sora profile/list page, the popup now deletes one visible video at a time through the current page script for better reliability.
- The Chrome popup now stays minimal and tells you to use the floating buttons on the Sora website itself for drafts and profile actions.
- The drafts page now shows three floating website buttons: Post All Found, Post 5 Found, and Post 10 Found.
- The profile page now shows three website delete buttons in order: Delete 5, Delete 10, and Delete All Found.
- The profile page download website button is removed for now, while copy and delete buttons stay available.
- The extension now requires a signed license key in the popup before website actions can run.
- One license key is locked to one computer, but the same key can be used on all Chrome profiles on that same computer.
- License generation/verification was updated so newly generated keys use the correct ECDSA signature format.
- The profile-page Copy All Video URLs button now shows the license remaining-days label directly on the button.
- When no license is active yet, the popup now tries to auto-activate from clipboard, and the license button can paste from clipboard automatically.
- The popup no longer needs an Activate button: it now auto-activates from clipboard or when you paste a key into the input field.
- When a license is active, the popup now shows a Copy License Key button so you can reuse the same key on other Chrome profiles on the same computer.
- Core website/background actions now also verify package integrity, so if the original extension files are edited and the build hash no longer matches, protected actions are blocked until the original package is reinstalled.
- The popup now shows a Build status line so you can see whether the original package is still verified.
- Stored license data is now sealed before saving to Chrome storage, so the raw license key is no longer kept there as plain text.
- Older plain-text stored licenses are migrated automatically to the sealed format after the next successful validation.
- The extension now supports a server-backed license flow. License activation/validation now checks the public server automatically.
- Default server URL is `https://sora-license-server-op4k.onrender.com`.
- If the server is temporarily offline, the extension can still use a recent cached validation for a short grace period.
- Old saved localhost URLs like `http://127.0.0.1:8787` are auto-migrated to the public Render license server.
- Website-side and popup-side activation/validation both use the same background proxy path, so the public Render server works through one consistent channel.
- The popup no longer shows an editable License Server URL field. The extension is locked to `https://sora-license-server-op4k.onrender.com`.
- Automatic license restore now uses a faster one-step server check, so popup unlock is quicker after reinstall or on another Chrome profile on the same computer.
- First use on a new computer now gets a one-time free 1-hour trial from the server. After that hour ends, a license key is required even if the extension is reinstalled.
- The popup now includes a `Buy License` button that opens the public server buy page with the current Device ID filled in automatically.
- The popup now also includes an embedded `Buy License / KHQR` panel so users can choose a plan, prepare a QR, track order status, and auto-restore the license without leaving the extension popup.
- The popup license section is now simplified to keep only `Copy Device ID` as the visible action button.
- The popup `Buy License / KHQR` flow now opens as an in-popup modal overlay, and clicking a plan prepares a fresh KHQR automatically without needing extra prepare buttons.
- The in-popup KHQR modal is now reduced to show only the plan choices and the QR itself for a cleaner purchase flow.
- The in-popup KHQR plan picker now keeps all 3 plans in one top row and clears the old QR immediately before preparing a fresh KHQR for the selected plan.
- The in-popup KHQR QR area is now styled like a standard payment card with a red KHQR header, merchant name, amount, dashed divider, and centered QR.
- USD buy plans in the popup now display as `35 USD`, `105 USD`, and `250 USD` instead of showing the `$` sign directly.
- The round badge at the center of the popup KHQR card now changes with the plan currency, so USD plans show `$` instead of the riel symbol.
- The popup KHQR flow is now two-step: before selection it shows only the plan buttons, and after you click a plan it hides the plans and shows only the QR.
- The popup KHQR card layout is now responsive, so the card, amount, and QR frame scale more cleanly inside the extension popup.
- Opening the buy modal now always starts on the plan-picker screen first, even if an older buy order was saved before.
- The popup KHQR modal and card are now more compact so the QR purchase view fits more comfortably inside the Chrome extension popup.
- On the Sora `/profile` website, if the license is expired or locked, the `Copy All Video URLs` button now changes into `Buy License / KHQR` and opens the public buy flow directly.
- The popup license section now removes the visible `License Key` input entirely, keeping the UI focused on `Copy Device ID` and `Buy License / KHQR` while clipboard auto-activation still works in the background.
