# bluemis

`/usr/lib/bluemis.dylib` makes installd accept self-signed (ad-hoc) apps. `build.sh` builds `out/bluemis.dylib`.

Boot with kernel 0990 and:

```
sweetenv=backboardd:DYLD_INSERT_LIBRARIES=/usr/lib/blueeagl.dylib;installd|com.apple.MobileInstallationHelperService:DYLD_INSERT_LIBRARIES=/usr/lib/bluemis.dylib
```

How it works:

- InstalledContentLibrary's `MICodeSigningVerifier` calls libmis's `MISValidateSignatureAndCopyInfo`. That is a wrapper that jumps to `MISValidateSignatureAndCopyInfoWithProgress`.
- dyld interposing does not reach this call, because both sides live in the shared cache. So bluemis patches the WithProgress entry in place. The prologue moves to a trampoline page in bluemis's own `__TEXT`, using `VM_PROT_COPY` as blueeagl does.
- The real check still runs. When it fails, the call returns 0 with signing info read from the app binary's own signature:
  - SigningID, CdHash, Entitlements and TeamID
  - SignerType 2
  - Apple's public "Apple iPhone OS Application Signing" certificate as SignerCertificate (`apple-iphone-os-application-signing.der`)
- The idea and the info keys follow AppSync Unified (GPL-3). The code here is separate and MIT.

Test with `tools/bluerun/apptest` and `miinstall`. Install into domain 3 (user, PackageType Developer); domain 1 (system) needs the system-app entitlement.
