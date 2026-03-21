# soranin iOS

Native iPhone app for downloading a Sora video from the configured proxy pattern.

The app accepts:

- a raw Sora ID like `s_69b0f220d9a0819197408128217ea9f6`
- a Sora page URL like `https://sora.chatgpt.com/p/s_...`
- a direct proxy URL for the current video proxy service

Downloads are saved into the app's Documents folder so they appear in the Files app under:

`On My iPhone > soranin`

## Generate the Xcode project

```bash
./generate-project.sh
```

## Build on this machine

```bash
./build-local.sh
```

Generated project:

`soranin.xcodeproj`
