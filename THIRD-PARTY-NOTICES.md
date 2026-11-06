# Third-Party Notices

Full license texts ship inside the app at `Contents/Resources/Licenses`.

| Component | Version | License | Use |
|---|---|---|---|
| [RDPKit](https://github.com/steelbrain/RDPKit) © 2026 Steelbrain | 0.7.0 | MIT | RDP engine (Swift package) |
| [swift-nio, swift-nio-ssl, swift-atomics, swift-collections, swift-system](https://github.com/apple) | resolved in Package.resolved | Apache-2.0 | RDPKit dependencies |
| [FreeRDP](https://github.com/FreeRDP/FreeRDP) | 3.32.2 | Apache-2.0 | Second RDP engine, bundled dylibs |
| [OpenSSL](https://www.openssl.org) | 3.x (Homebrew) | Apache-2.0 | FreeRDP TLS, bundled |
| [MIT Kerberos](https://web.mit.edu/kerberos/) | 1.22 (Homebrew) | MIT and BSD-style (see NOTICE) | FreeRDP Kerberos, bundled |
| [libusb](https://libusb.info) | 1.0.30 (Homebrew) | LGPL-2.1-or-later | FreeRDP USB redirection, bundled as a separate replaceable dylib |
| [cJSON](https://github.com/DaveGamble/cJSON) | 1.7 (Homebrew) | MIT | FreeRDP dependency, bundled |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) © 2019-2026 Miguel de Icaza and the xterm.js authors | 1.99.2 | MIT | Terminal emulator of SSH sessions (Swift package, compiled into the app) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser), [swift-png](https://github.com/tayloraswift/swift-png), [h](https://github.com/rarestype/h) | resolved in Package.resolved | Apache-2.0 / MPL-2.0 per package | Declared by SwiftTerm's manifest; resolved at build time, not linked into the app |
| OpenSSH | system (`/usr/bin/ssh`) | BSD | Part of macOS; used, not bundled |
| [RDPeek](https://github.com/steelbrain/RDPeek) © 2026 Anees Iqbal | — | MIT | Reference; `RemoteDesktopCanvas.swift` adapted |

libusb is LGPL: it's linked dynamically, and `Contents/Frameworks/libusb-1.0.0.dylib` can be replaced with a compatible build.

## RDPKit / RDPeek MIT License

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
