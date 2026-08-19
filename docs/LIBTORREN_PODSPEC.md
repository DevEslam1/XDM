# Libtorrent iOS & macOS Podspec Integration Guide

This guide documents the CocoaPods specification and native compilation flags required to integrate `libtorrent-rasterbar` into the DMX iOS/macOS Flutter Runner target.

---

## 1. Podspec Configuration (`Libtorrent.podspec`)

Place the following `Libtorrent.podspec` in `ios/` (or vendored plugin directory):

```ruby
Pod::Spec.new do |s|
  s.name             = 'Libtorrent'
  s.version          = '2.0.10'
  s.summary          = 'Libtorrent Rasterbar C++ BitTorrent library for iOS/macOS.'
  s.description      = <<-DESC
                        C++ BitTorrent library designed to be very efficient and easy to use.
                       DESC
  s.homepage         = 'https://www.libtorrent.org/'
  s.license          = { :type => 'BSD', :file => 'LICENSE' }
  s.author           = { 'Arvid Norberg' => 'arvid@libtorrent.org' }
  s.source           = { :git => 'https://github.com/arvidn/libtorrent.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  s.source_files = 'src/**/*.{cpp,c}', 'include/**/*.{hpp,h}'
  s.public_header_files = 'include/**/*.hpp', 'include/**/*.h'
  s.header_mappings_dir = 'include'

  s.libraries = 'c++'
  s.frameworks = 'Security', 'CFNetwork'

  s.xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) TORRENT_USE_OPENSSL=1 BOOST_ASIO_STANDALONE=1 TORRENT_DISABLE_LOGGING=1',
    'OTHER_CPLUSPLUSFLAGS' => '$(inherited) -fvisibility=hidden -fvisibility-inlines-hidden'
  }

  s.dependency 'OpenSSL-Universal', '~> 3.0'
end
```

---

## 2. Xcode Build Settings & Optimization

When compiling for iOS devices and simulators:

1. **Bitcode**: Ensure Bitcode is disabled (`ENABLE_BITCODE = NO`).
2. **C++ Standard**: `c++17` or `gnu++17` required.
3. **Exception Handling**: Enable C++ exceptions (`GCC_ENABLE_CPP_EXCEPTIONS = YES`).
4. **Linker Flags**: `-lc++ -lz`
5. **Architectures**: `arm64` (iOS devices & Apple Silicon Simulators), `x86_64` (Intel Simulators).

---

## 3. Background Execution & Memory Considerations

- In iOS background modes, libtorrent active torrent threads must be halted or paused within the 25–30s OS watchdog window.
- Ensure `TorrentService.pauseTorrent` and `_saveResumeDataBeforePause` are called with timeouts to avoid app termination by watchdog `0x8badf00d`.
