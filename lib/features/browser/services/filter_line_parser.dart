import 'adblock_filter_updater.dart';

class FilterParseResult {
  final Set<String> blocked;
  final Set<String> excepted;
  final Set<String> scriptletRules;
  final Set<String> cosmeticRules;
  final Set<String> globalCosmeticExceptions;
  final Map<String, Set<String>> siteCosmeticRules;
  final Map<String, Set<String>> cosmeticExceptions;
  final Set<String> urlPatterns;
  final List<String> exactPathPatterns;

  FilterParseResult({
    Set<String>? blocked,
    Set<String>? excepted,
    Set<String>? scriptletRules,
    Set<String>? cosmeticRules,
    Set<String>? globalCosmeticExceptions,
    Map<String, Set<String>>? siteCosmeticRules,
    Map<String, Set<String>>? cosmeticExceptions,
    Set<String>? urlPatterns,
    List<String>? exactPathPatterns,
  })  : blocked = blocked ?? <String>{},
        excepted = excepted ?? <String>{},
        scriptletRules = scriptletRules ?? <String>{},
        cosmeticRules = cosmeticRules ?? <String>{},
        globalCosmeticExceptions = globalCosmeticExceptions ?? <String>{},
        siteCosmeticRules = siteCosmeticRules ?? <String, Set<String>>{},
        cosmeticExceptions = cosmeticExceptions ?? <String, Set<String>>{},
        urlPatterns = urlPatterns ?? <String>{},
        exactPathPatterns = exactPathPatterns ?? <String>[];
}

class FilterLineParser {
  static const int maxLineLength = 2048;

  // Pre-compiled regular expressions for high performance in hot parsing loops (P5)
  static final RegExp _exceptionPattern = RegExp(
    r'^@@\|\|([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])\^',
  );

  static final RegExp _whitespacePattern = RegExp(r'\s+');

  static final RegExp _domainValidationPattern = RegExp(
    r'^[a-z0-9][a-z0-9.-]*\.[a-z0-9]+$',
  );

  static final RegExp _abpDomainPattern = RegExp(
    r'^\|\|([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])\^',
  );

  static final RegExp _plainDomainPattern = RegExp(
    r'^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z0-9]+$',
  );

  /// Checks whether parentheses in [text] are balanced.
  static bool areParensBalanced(String text) {
    var openCount = 0;
    for (var i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      if (code == 40) { // '('
        openCount++;
      } else if (code == 41) { // ')'
        openCount--;
        if (openCount < 0) return false;
      }
    }
    return openCount == 0;
  }

  /// Parses filter list lines into structured [FilterParseResult].
  static FilterParseResult parse(List<String> lines, FilterType type) {
    final result = FilterParseResult();

    for (final rawLine in lines) {
      if (rawLine.isEmpty || rawLine.length > maxLineLength) continue;
      final line = rawLine;
      final trimmed = line.trim();

      // ABP Exception rules (@@||domain^)
      if (trimmed.startsWith('@@')) {
        final exceptionMatch = _exceptionPattern.firstMatch(trimmed);
        if (exceptionMatch != null) {
          result.excepted.add(exceptionMatch.group(1)!.toLowerCase());
          continue;
        }
      }

      // Hosts file format: "127.0.0.1 domain.com" or "0.0.0.0 domain.com"
      if (trimmed.startsWith('127.0.0.1') || trimmed.startsWith('0.0.0.0')) {
        var cleanLine = trimmed;
        final commentIdx = cleanLine.indexOf('#');
        if (commentIdx != -1) {
          cleanLine = cleanLine.substring(0, commentIdx).trim();
        }
        final parts = cleanLine.split(_whitespacePattern);
        for (var i = 1; i < parts.length; i++) {
          var domain = parts[i].trim().toLowerCase();
          if (domain.endsWith('.')) {
            domain = domain.substring(0, domain.length - 1);
          }
          if (_domainValidationPattern.hasMatch(domain)) {
            result.blocked.add(domain);
          }
        }
        continue;
      }

      // Comments
      if (line.startsWith('!') ||
          line.startsWith('[') ||
          (line.startsWith('#') &&
              !line.startsWith('##') &&
              !line.startsWith('#@#'))) {
        continue;
      }

      // Scriptlet rules: ##+js(...) or site.com##+js(...)
      // FIX-B27: Reject ##+js(...) with unmatched parens or missing closing paren
      if (line.contains('##+js(')) {
        final idx = line.indexOf('##+js(');
        final firstPart = line.substring(0, idx);
        final afterPrefix = line.substring(idx + 6);
        final closeIdx = afterPrefix.lastIndexOf(')');
        if (closeIdx == -1) {
          // Unclosed scriptlet rule -> reject to prevent corrupting ruleset
          continue;
        }

        if (!areParensBalanced(line)) {
          // Unbalanced nested parens -> reject
          continue;
        }

        final scriptlet = afterPrefix.substring(0, closeIdx).trim();
        if (scriptlet.isNotEmpty) {
          if (firstPart.isEmpty) {
            result.scriptletRules.add(scriptlet);
          } else {
            final domainsList = firstPart.split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty || domain.startsWith('~')) continue;
              result.siteCosmeticRules
                  .putIfAbsent(domain, () => <String>{})
                  .add(scriptlet);
            }
          }
        }
        continue;
      }

      // Cosmetic exception rules: #@#.ad-container, site.com#@#.ad-container
      if (line.contains('#@#')) {
        final idx = line.indexOf('#@#');
        final firstPart = line.substring(0, idx);
        final secondPart = line.substring(idx + 3);
        if (secondPart.isNotEmpty && secondPart.length < 100) {
          final selector = secondPart;
          if (firstPart.isEmpty) {
            result.cosmeticRules.remove(selector);
            result.globalCosmeticExceptions.add(selector);
          } else {
            final domainsList = firstPart.split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty) continue;
              result.cosmeticExceptions
                  .putIfAbsent(domain, () => <String>{})
                  .add(selector);
            }
          }
        }
        continue;
      }

      // Cosmetic rules: ##.ad-container, ###sidebar-ad, site.com##.ad
      if (line.contains('##')) {
        final idx = line.indexOf('##');
        final firstPart = line.substring(0, idx);
        final secondPart = line.substring(idx + 2);
        if (secondPart.isNotEmpty && secondPart.length < 100) {
          final selector = secondPart;
          if (firstPart.isEmpty) {
            result.cosmeticRules.add(selector);
          } else {
            final domainsList = firstPart.split(',');
            for (var domain in domainsList) {
              domain = domain.trim().toLowerCase();
              if (domain.isEmpty) continue;
              if (domain.startsWith('~')) {
                final excDomain = domain.substring(1).trim();
                if (excDomain.isNotEmpty) {
                  result.cosmeticExceptions
                      .putIfAbsent(excDomain, () => <String>{})
                      .add(selector);
                }
              } else {
                result.siteCosmeticRules
                    .putIfAbsent(domain, () => <String>{})
                    .add(selector);
              }
            }
          }
        }
        continue;
      }

      // ABP-style ||domain^ rules
      final domainMatch = _abpDomainPattern.firstMatch(line);
      if (domainMatch != null) {
        final domain = domainMatch.group(1)!.toLowerCase();
        if (domain.contains('.') && !domain.startsWith('.')) {
          result.blocked.add(domain);
        }
        continue;
      }

      // Plain domain-per-line format
      var plainDomain = trimmed;
      if (plainDomain.contains('#') &&
          !plainDomain.startsWith('##') &&
          !plainDomain.startsWith('#@#')) {
        plainDomain = plainDomain.substring(0, plainDomain.indexOf('#')).trim();
      }
      if (plainDomain.endsWith('.')) {
        plainDomain = plainDomain.substring(0, plainDomain.length - 1);
      }
      if (_plainDomainPattern.hasMatch(plainDomain)) {
        final domain = plainDomain.toLowerCase();
        if (!domain.startsWith('.')) {
          result.blocked.add(domain);
        }
        continue;
      }

      // URL path patterns: /ads/banner
      if (line.startsWith('/') && !line.startsWith('//')) {
        result.urlPatterns.add(line);
        if (!line.contains('*')) {
          result.exactPathPatterns.add(line);
        }
        continue;
      }
    }

    return result;
  }
}
