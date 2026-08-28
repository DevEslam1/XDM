import 'package:dmx/core/services/engine/ssrf_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SsrfGuard.validate — scheme policy', () {
    test('allows http and https', () {
      expect(() => SsrfGuard.validate(Uri.parse('https://example.com')),
          returnsNormally);
      expect(() => SsrfGuard.validate(Uri.parse('http://example.com')),
          returnsNormally);
    });

    test('blocks non-web schemes', () {
      for (final u in [
        'ftp://example.com/file',
        'file:///etc/passwd',
        'data:text/plain,hi',
        'gopher://example.com',
      ]) {
        expect(() => SsrfGuard.validate(Uri.parse(u)),
            throwsA(isA<SsrfBlockedException>()),
            reason: u);
      }
    });

    test('httpsOnly blocks cleartext http but allows https', () {
      expect(
          () => SsrfGuard.validate(Uri.parse('http://example.com'),
              httpsOnly: true),
          throwsA(isA<SsrfBlockedException>()));
      expect(
          () => SsrfGuard.validate(Uri.parse('https://example.com'),
              httpsOnly: true),
          returnsNormally);
    });

    test('blocks empty host', () {
      expect(() => SsrfGuard.validate(Uri.parse('http:///only/path')),
          throwsA(isA<SsrfBlockedException>()));
    });
  });

  group('SsrfGuard.validate — blocked hosts on the download path', () {
    test('refuses the cloud metadata endpoint and loopback (acceptance #4)',
        () {
      expect(
          () => SsrfGuard.validate(
              Uri.parse('http://169.254.169.254/latest/meta-data/')),
          throwsA(isA<SsrfBlockedException>()));
      expect(() => SsrfGuard.validate(Uri.parse('http://127.0.0.1:8080/')),
          throwsA(isA<SsrfBlockedException>()));
      expect(() => SsrfGuard.validate(Uri.parse('http://localhost/')),
          returnsNormally,
          reason: 'hostnames are not resolved at this layer');
    });

    test('refuses integer-encoded loopback (http://2130706433)', () {
      expect(() => SsrfGuard.validate(Uri.parse('http://2130706433/')),
          throwsA(isA<SsrfBlockedException>()));
    });
  });

  group('SsrfGuard.isBlockedHost — IPv4 literal ranges', () {
    test('blocks non-routable / internal ranges', () {
      for (final ip in [
        '0.0.0.0', // this-network
        '10.0.0.1', // private
        '10.255.255.255',
        '127.0.0.1', // loopback
        '169.254.169.254', // link-local + cloud metadata
        '172.16.0.1', // private /12 lower bound
        '172.31.255.255', // private /12 upper bound
        '192.168.1.1', // private
        '100.64.0.1', // CGNAT lower bound
        '100.127.255.255', // CGNAT upper bound
        '224.0.0.1', // multicast
        '239.255.255.255', // multicast
        '240.0.0.1', // reserved
        '255.255.255.255', // broadcast
      ]) {
        expect(SsrfGuard.isBlockedHost(ip), isTrue, reason: ip);
      }
    });

    test('allows ordinary public IPv4 addresses', () {
      for (final ip in [
        '8.8.8.8',
        '1.1.1.1',
        '172.15.0.1', // just below the private /12
        '172.32.0.1', // just above the private /12
        '100.63.255.255', // just below CGNAT
        '100.128.0.1', // just above CGNAT
        '223.255.255.255', // just below multicast
      ]) {
        expect(SsrfGuard.isBlockedHost(ip), isFalse, reason: ip);
      }
    });

    test('allows ordinary hostnames (no DNS resolution here)', () {
      for (final h in ['example.com', 'download.cdn.net', 'localhost']) {
        expect(SsrfGuard.isBlockedHost(h), isFalse, reason: h);
      }
    });
  });

  group('SsrfGuard.isBlockedHost — alternate IPv4 encodings', () {
    test('decimal integer form maps to dotted quad', () {
      expect(SsrfGuard.isBlockedHost('2130706433'), isTrue,
          reason: '2130706433 == 127.0.0.1');
      expect(SsrfGuard.isBlockedHost('134744072'), isFalse,
          reason: '134744072 == 8.8.8.8 (public)');
    });

    test('hex integer form maps to dotted quad', () {
      expect(SsrfGuard.isBlockedHost('0x7f000001'), isTrue,
          reason: '0x7f000001 == 127.0.0.1');
      expect(SsrfGuard.isBlockedHost('0xA9FEA9FE'), isTrue,
          reason: '0xA9FEA9FE == 169.254.169.254');
      expect(SsrfGuard.isBlockedHost('0x08080808'), isFalse,
          reason: '0x08080808 == 8.8.8.8 (public)');
    });

    test('octal integer form maps to dotted quad', () {
      expect(SsrfGuard.isBlockedHost('017700000001'), isTrue,
          reason: '017700000001 (octal) == 127.0.0.1');
    });

    test('out-of-range integers are treated as hostnames, not blocked', () {
      expect(SsrfGuard.isBlockedHost('4294967296'), isFalse,
          reason: '> 0xFFFFFFFF');
    });
  });

  group('SsrfGuard.isBlockedHost — IPv6 literals', () {
    test('blocks loopback, link-local, unique-local and IPv4-mapped internals',
        () {
      for (final ip in [
        '::1', // loopback
        '[::1]', // bracketed form
        'fe80::1', // link-local
        'fc00::1', // unique-local (fc00::/7)
        'fd12:3456::1', // unique-local
        'ff02::1', // multicast
        '::ffff:169.254.169.254', // IPv4-mapped metadata endpoint
        '::ffff:127.0.0.1', // IPv4-mapped loopback
      ]) {
        expect(SsrfGuard.isBlockedHost(ip), isTrue, reason: ip);
      }
    });

    test('allows public IPv6 and IPv4-mapped public addresses', () {
      expect(SsrfGuard.isBlockedHost('2606:4700:4700::1111'), isFalse,
          reason: 'Cloudflare public IPv6');
      expect(SsrfGuard.isBlockedHost('::ffff:8.8.8.8'), isFalse,
          reason: 'IPv4-mapped public');
    });
  });

  group('SsrfGuard — allowPrivate (initial user-typed URL policy)', () {
    test('permits LAN / loopback / private / CGNAT targets', () {
      for (final ip in [
        '127.0.0.1', // loopback (localhost dev server)
        '10.0.0.5', // private
        '172.16.0.1', // private /12
        '192.168.1.100', // private (home NAS/router)
        '100.64.0.1', // CGNAT
      ]) {
        expect(SsrfGuard.isBlockedHost(ip, allowPrivate: true), isFalse,
            reason: ip);
        expect(
            () => SsrfGuard.validate(Uri.parse('http://$ip/'),
                allowPrivate: true),
            returnsNormally,
            reason: ip);
      }
    });

    test('permits IPv6 loopback and unique-local targets', () {
      expect(SsrfGuard.isBlockedHost('::1', allowPrivate: true), isFalse);
      expect(SsrfGuard.isBlockedHost('fc00::1', allowPrivate: true), isFalse);
      expect(SsrfGuard.isBlockedHost('::ffff:127.0.0.1', allowPrivate: true),
          isFalse,
          reason: 'IPv4-mapped loopback follows the v4 policy');
    });

    test('STILL blocks metadata / 0.0.0.0 / multicast / link-local', () {
      for (final ip in [
        '169.254.169.254', // cloud metadata (link-local)
        '0.0.0.0', // this-network
        '224.0.0.1', // multicast
        '240.0.0.1', // reserved
        '255.255.255.255', // broadcast
      ]) {
        expect(SsrfGuard.isBlockedHost(ip, allowPrivate: true), isTrue,
            reason: ip);
        expect(
            () => SsrfGuard.validate(Uri.parse('http://$ip/'),
                allowPrivate: true),
            throwsA(isA<SsrfBlockedException>()),
            reason: ip);
      }
    });

    test('STILL blocks link-local / metadata even via IPv6 forms', () {
      expect(SsrfGuard.isBlockedHost('fe80::1', allowPrivate: true), isTrue,
          reason: 'IPv6 link-local');
      expect(SsrfGuard.isBlockedHost('ff02::1', allowPrivate: true), isTrue,
          reason: 'IPv6 multicast');
      expect(
          SsrfGuard.isBlockedHost('::ffff:169.254.169.254', allowPrivate: true),
          isTrue,
          reason: 'IPv4-mapped metadata endpoint');
      expect(SsrfGuard.isBlockedHost('0xA9FEA9FE', allowPrivate: true), isTrue,
          reason: 'hex-encoded 169.254.169.254');
    });
  });
}
