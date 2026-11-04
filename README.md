# Morphe builds

Non-root APKs of YouTube patched with [Morphe patches](https://github.com/MorpheApp/morphe-patches), of X patched with [Piko NewX](https://github.com/crimera/piko-newx), and of Instagram patched with [Piko IG Lite](https://github.com/crimera/piko-ig-lite). YouTube is also built as a root module. Downloads are in [releases](../../releases).

The YouTube APK needs [MicroG-RE](https://github.com/MorpheApp/MicroG-RE).

## Obtainium

Add to [Obtainium](https://github.com/ImranR98/Obtainium):

- [YouTube](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%20%22app.morphe.android.youtube%22%2C%20%22url%22%3A%20%22https%3A%2F%2Fgithub.com%2Fasp345%2Fmorphe-builds%22%2C%20%22author%22%3A%20%22asp345%22%2C%20%22name%22%3A%20%22YouTube%22%2C%20%22preferredApkIndex%22%3A%200%2C%20%22additionalSettings%22%3A%20%22%7B%5C%22includePrereleases%5C%22%3A%20false%2C%20%5C%22fallbackToOlderReleases%5C%22%3A%20true%2C%20%5C%22filterReleaseTitlesByRegEx%5C%22%3A%20%5C%22%5EYouTube%20%5C%22%2C%20%5C%22apkFilterRegEx%5C%22%3A%20%5C%22%5Eyoutube-.%2A%5C%5C%5C%5C.apk%24%5C%22%2C%20%5C%22autoApkFilterByArch%5C%22%3A%20true%2C%20%5C%22versionDetection%5C%22%3A%20false%7D%22%2C%20%22overrideSource%22%3A%20null%7D)
- [X](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%20%22com.twitter.android%22%2C%20%22url%22%3A%20%22https%3A%2F%2Fgithub.com%2Fasp345%2Fmorphe-builds%22%2C%20%22author%22%3A%20%22asp345%22%2C%20%22name%22%3A%20%22X%22%2C%20%22preferredApkIndex%22%3A%200%2C%20%22additionalSettings%22%3A%20%22%7B%5C%22includePrereleases%5C%22%3A%20false%2C%20%5C%22fallbackToOlderReleases%5C%22%3A%20true%2C%20%5C%22filterReleaseTitlesByRegEx%5C%22%3A%20%5C%22%5EX%20%5C%22%2C%20%5C%22apkFilterRegEx%5C%22%3A%20%5C%22%5Ex-.%2A%5C%5C%5C%5C.apk%24%5C%22%2C%20%5C%22autoApkFilterByArch%5C%22%3A%20true%2C%20%5C%22versionDetection%5C%22%3A%20false%7D%22%2C%20%22overrideSource%22%3A%20null%7D)
- [Instagram](https://apps.obtainium.imranr.dev/redirect?r=obtainium://app/%7B%22id%22%3A%20%22com.instagram.android%22%2C%20%22url%22%3A%20%22https%3A%2F%2Fgithub.com%2Fasp345%2Fmorphe-builds%22%2C%20%22author%22%3A%20%22asp345%22%2C%20%22name%22%3A%20%22Instagram%22%2C%20%22preferredApkIndex%22%3A%200%2C%20%22additionalSettings%22%3A%20%22%7B%5C%22includePrereleases%5C%22%3A%20false%2C%20%5C%22fallbackToOlderReleases%5C%22%3A%20true%2C%20%5C%22filterReleaseTitlesByRegEx%5C%22%3A%20%5C%22%5EInstagram%20%5C%22%2C%20%5C%22apkFilterRegEx%5C%22%3A%20%5C%22%5Einstagram-.%2A%5C%5C%5C%5C.apk%24%5C%22%2C%20%5C%22autoApkFilterByArch%5C%22%3A%20true%2C%20%5C%22versionDetection%5C%22%3A%20false%7D%22%2C%20%22overrideSource%22%3A%20null%7D)

## Signing key

Verify an installed non-root APK with [AppVerifier](https://github.com/soupslurpr/AppVerifier):

```
app.morphe.android.youtube
37:84:42:C9:FF:DA:9B:21:14:9A:D7:50:65:E2:B2:9F:ED:5B:17:72:0C:A7:41:AC:6B:BE:60:C3:88:CF:09:5B

com.twitter.android
37:84:42:C9:FF:DA:9B:21:14:9A:D7:50:65:E2:B2:9F:ED:5B:17:72:0C:A7:41:AC:6B:BE:60:C3:88:CF:09:5B

com.instagram.android
37:84:42:C9:FF:DA:9B:21:14:9A:D7:50:65:E2:B2:9F:ED:5B:17:72:0C:A7:41:AC:6B:BE:60:C3:88:CF:09:5B
```

## Secrets

In the `release` environment:

- `KEYSTORE_B64`: base64 of a PKCS12 keystore with key alias `release`
- `KEYSTORE_PASSWORD`: password of the keystore and the key

## Dependencies

- [Morphe patches](https://github.com/MorpheApp/morphe-patches)
- [Piko NewX patches](https://github.com/crimera/piko-newx)
- [Piko IG Lite patches](https://github.com/crimera/piko-ig-lite)
- [Morphe CLI](https://github.com/MorpheApp/morphe-desktop)
- Stock APKs from archive.org (YouTube) and APKMirror
- [htmlq](https://github.com/mgdm/htmlq) v0.4.0
- [apksigner](bin/apksigner.jar) from Android build-tools 34
- Android NDK
- Google Chrome, Xvfb and xdotool, and Node.js 22+, for APKMirror pages behind a Cloudflare challenge
- `bash`, `curl`, `jq`, `java` 21, `python3` 3.11+, `tar`, `gh` 2.49+
