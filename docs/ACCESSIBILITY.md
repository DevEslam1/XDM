# XDM Accessibility Guide

## Standards
- WCAG 2.1 AA compliance
- TalkBack (Android) + VoiceOver (iOS) tested
- Minimum touch target: 48x48dp
- Text scaling: 0.8x to 2.0x supported

## Widget Requirements
All interactive widgets MUST use `XdmSemantics` wrappers:
- Buttons → `XdmSemantics.button()`
- Text fields → `XdmSemantics.textField()`
- Progress → `XdmSemantics.progress()`
- Toggles → `XdmSemantics.toggle()`
- List items → `XdmSemantics.listItem()`
- Headings → `XdmSemantics.heading()`

## Testing
Run: `flutter test test/accessibility/`
Manual: Enable TalkBack/VoiceOver and navigate all screens.
