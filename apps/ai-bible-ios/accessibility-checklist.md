# Accessibility checks (manual, on real iPhones) — none run yet

Run on the oldest supported iPhone and on a current iPhone. Record the device, the iOS version, the date
and pass or fail for each item. Only report features in App Store Connect's Accessibility Nutrition Labels
after they pass here.

## VoiceOver
- [ ] Every tab, button and toolbar item has a spoken name (no "button" with nothing else).
- [ ] The Headings rotor jumps through the chapter title and section headings in the reader.
- [ ] Table in grid layout: each cell reads as "header: value".
- [ ] Table in card layout: each card reads as one row.
- [ ] Printed checklists read as "Checklist item: …".
- [ ] Rollout tracker items read as switches with their on or off state.
- [ ] Links in paragraphs can be found and opened through the Links rotor.
- [ ] Unlock sheet: the price, Buy, Restore and any waiting or error message are all reachable and spoken.
- [ ] Locked chapters announce "Included with the full book".

## Larger Text / Dynamic Type
- [ ] At the largest accessibility size (AX5), no text is cut off in the reader, contents, tools, unlock sheet or settings.
- [ ] Tables switch to cards at accessibility sizes and never scroll sideways.
- [ ] Form fields in the cost worksheet stay usable (labels wrap; values are visible).

## Voice Control
- [ ] "Show names" labels every control, and each can be activated by voice.

## Display
- [ ] Dark, Light and Sepia themes: body text meets 4.5:1 contrast (check with Xcode's Accessibility Inspector).
- [ ] Increase Contrast and Bold Text are respected.
- [ ] Nothing relies on colour alone (the lock icon comes with text; answers are words).
- [ ] With Reduce Motion on, jumping to a heading does not animate.

## Offline and state
- [ ] In Airplane mode, a fresh launch opens the saved position; all tools work and save.
- [ ] After force-quitting mid-chapter, the next launch returns to the same paragraph.
