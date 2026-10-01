# Branding

Drop the PM Radio Logs artwork here as `logo.png` (square, 1024×1024 or larger),
then run:

```bash
./branding/make-icon.sh
```

That writes `RadioQA/Resources/AppIcon.icns` (the Dock and Finder icon) and
`RadioQA/Resources/Logo.png` (shown in the sidebar and on the sign-in sheet).
Rebuild afterwards.

Until the file exists the app shows a system radio symbol instead, so the build
never breaks on missing artwork.
