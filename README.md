# YouTube Morphe

YouTube patched with [Morphe patches](https://github.com/MorpheApp/morphe-patches), as a non-root APK and a root module. Downloads are in [releases](../../releases).

The non-root APK needs [MicroG-RE](https://github.com/MorpheApp/MicroG-RE).

## Signing key

Verify the installed non-root APK with [AppVerifier](https://github.com/soupslurpr/AppVerifier):

```
app.morphe.android.youtube
37:84:42:C9:FF:DA:9B:21:14:9A:D7:50:65:E2:B2:9F:ED:5B:17:72:0C:A7:41:AC:6B:BE:60:C3:88:CF:09:5B
```

## Secrets

In the `release` environment:

- `KEYSTORE_B64`: base64 of a PKCS12 keystore with key alias `release`
- `KEYSTORE_PASSWORD`: password of the keystore and the key

## Dependencies

- [Morphe patches](https://github.com/MorpheApp/morphe-patches)
- [Morphe CLI](https://github.com/MorpheApp/morphe-desktop)
- Stock YouTube APK from archive.org or APKMirror
- [htmlq](https://github.com/mgdm/htmlq) v0.4.0
- [apksigner](bin/apksigner.jar) from Android build-tools 34
- Android NDK
- `bash`, `curl`, `jq`, `java` 21, `python3` 3.11+, `tar`, `gh` 2.49+
