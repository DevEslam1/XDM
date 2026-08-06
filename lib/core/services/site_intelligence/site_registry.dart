import 'site_intelligence_service.dart';

class SiteRegistry {
  static final Map<String, SiteProfile> registry = {
    // --- Video Streaming ---
    'youtube.com': const SiteProfile(
      domain: 'youtube.com',
      type: SiteType.videoStreaming,
      displayName: 'YouTube',
      requiresCookies: true,
      supportsRangeRequests: true,
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
      urlPatterns: [r'watch\?v=', r'embed/', r'shorts/'],
      urlsExpire: true,
    ),
    'youtu.be': const SiteProfile(
      domain: 'youtu.be',
      type: SiteType.videoStreaming,
      displayName: 'YouTube',
      requiresCookies: true,
      supportsRangeRequests: true,
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
      urlsExpire: true,
    ),
    'vimeo.com': const SiteProfile(
      domain: 'vimeo.com',
      type: SiteType.videoStreaming,
      displayName: 'Vimeo',
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'dailymotion.com': const SiteProfile(
      domain: 'dailymotion.com',
      type: SiteType.videoStreaming,
      displayName: 'Dailymotion',
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'twitch.tv': const SiteProfile(
      domain: 'twitch.tv',
      type: SiteType.videoStreaming,
      displayName: 'Twitch',
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.browserRequired,
    ),
    'rumble.com': const SiteProfile(
      domain: 'rumble.com',
      type: SiteType.videoStreaming,
      displayName: 'Rumble',
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'bitchute.com': const SiteProfile(
      domain: 'bitchute.com',
      type: SiteType.videoStreaming,
      displayName: 'BitChute',
      contentHint: ContentHint.videoStream,
      strategy: DownloadStrategy.apiExtraction,
    ),

    // --- File Hosting ---
    'mega.nz': const SiteProfile(
      domain: 'mega.nz',
      type: SiteType.fileHosting,
      displayName: 'MEGA',
      strategy: DownloadStrategy.browserRequired,
      contentHint: ContentHint.unknown,
    ),
    'mediafire.com': const SiteProfile(
      domain: 'mediafire.com',
      type: SiteType.fileHosting,
      displayName: 'MediaFire',
      strategy: DownloadStrategy.redirectFollow,
      supportsRangeRequests: true,
    ),
    'rapidgator.net': const SiteProfile(
      domain: 'rapidgator.net',
      type: SiteType.fileHosting,
      displayName: 'Rapidgator',
      requiresCookies: true,
      strategy: DownloadStrategy.browserRequired,
    ),
    '1fichier.com': const SiteProfile(
      domain: '1fichier.com',
      type: SiteType.fileHosting,
      displayName: '1fichier',
      strategy: DownloadStrategy.browserRequired,
    ),
    'uploaded.net': const SiteProfile(
      domain: 'uploaded.net',
      type: SiteType.fileHosting,
      displayName: 'Uploaded',
      strategy: DownloadStrategy.browserRequired,
    ),
    'nitroflare.com': const SiteProfile(
      domain: 'nitroflare.com',
      type: SiteType.fileHosting,
      displayName: 'NitroFlare',
      strategy: DownloadStrategy.browserRequired,
    ),
    'turbobit.net': const SiteProfile(
      domain: 'turbobit.net',
      type: SiteType.fileHosting,
      displayName: 'Turbobit',
      strategy: DownloadStrategy.browserRequired,
    ),
    'filefactory.com': const SiteProfile(
      domain: 'filefactory.com',
      type: SiteType.fileHosting,
      displayName: 'FileFactory',
      strategy: DownloadStrategy.browserRequired,
    ),
    'sendspace.com': const SiteProfile(
      domain: 'sendspace.com',
      type: SiteType.fileHosting,
      displayName: 'SendSpace',
      strategy: DownloadStrategy.redirectFollow,
    ),
    'wetransfer.com': const SiteProfile(
      domain: 'wetransfer.com',
      type: SiteType.fileHosting,
      displayName: 'WeTransfer',
      strategy: DownloadStrategy.browserRequired,
    ),

    // --- Cloud Storage ---
    'drive.google.com': const SiteProfile(
      domain: 'drive.google.com',
      type: SiteType.cloudStorage,
      displayName: 'Google Drive',
      requiresCookies: true,
      supportsRangeRequests: true,
      strategy: DownloadStrategy.redirectFollow,
    ),
    'dropbox.com': const SiteProfile(
      domain: 'dropbox.com',
      type: SiteType.cloudStorage,
      displayName: 'Dropbox',
      supportsRangeRequests: true,
      strategy: DownloadStrategy.redirectFollow,
    ),
    'onedrive.live.com': const SiteProfile(
      domain: 'onedrive.live.com',
      type: SiteType.cloudStorage,
      displayName: 'OneDrive',
      requiresCookies: true,
      strategy: DownloadStrategy.redirectFollow,
    ),

    // --- Audio Streaming ---
    'soundcloud.com': const SiteProfile(
      domain: 'soundcloud.com',
      type: SiteType.audioStreaming,
      displayName: 'SoundCloud',
      contentHint: ContentHint.audioStream,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'mixcloud.com': const SiteProfile(
      domain: 'mixcloud.com',
      type: SiteType.audioStreaming,
      displayName: 'Mixcloud',
      contentHint: ContentHint.audioStream,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'bandcamp.com': const SiteProfile(
      domain: 'bandcamp.com',
      type: SiteType.audioStreaming,
      displayName: 'Bandcamp',
      contentHint: ContentHint.audioFile,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'audiomack.com': const SiteProfile(
      domain: 'audiomack.com',
      type: SiteType.audioStreaming,
      displayName: 'Audiomack',
      contentHint: ContentHint.audioStream,
      strategy: DownloadStrategy.apiExtraction,
    ),

    // --- Social Media ---
    'instagram.com': const SiteProfile(
      domain: 'instagram.com',
      type: SiteType.socialMedia,
      displayName: 'Instagram',
      requiresCookies: true,
      contentHint: ContentHint.mixedMedia,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'facebook.com': const SiteProfile(
      domain: 'facebook.com',
      type: SiteType.socialMedia,
      displayName: 'Facebook',
      requiresCookies: true,
      contentHint: ContentHint.mixedMedia,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'tiktok.com': const SiteProfile(
      domain: 'tiktok.com',
      type: SiteType.socialMedia,
      displayName: 'TikTok',
      contentHint: ContentHint.videoFile,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'twitter.com': const SiteProfile(
      domain: 'twitter.com',
      type: SiteType.socialMedia,
      displayName: 'Twitter',
      contentHint: ContentHint.videoFile,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'x.com': const SiteProfile(
      domain: 'x.com',
      type: SiteType.socialMedia,
      displayName: 'X',
      contentHint: ContentHint.videoFile,
      strategy: DownloadStrategy.apiExtraction,
    ),
    'reddit.com': const SiteProfile(
      domain: 'reddit.com',
      type: SiteType.socialMedia,
      displayName: 'Reddit',
      contentHint: ContentHint.mixedMedia,
      strategy: DownloadStrategy.apiExtraction,
    ),

    // --- Software Repo ---
    'github.com': const SiteProfile(
      domain: 'github.com',
      type: SiteType.softwareRepo,
      displayName: 'GitHub',
      supportsRangeRequests: true,
      contentHint: ContentHint.softwarePackage,
      strategy: DownloadStrategy.multiThread,
      urlPatterns: [r'/releases/download/'],
    ),
    'sourceforge.net': const SiteProfile(
      domain: 'sourceforge.net',
      type: SiteType.softwareRepo,
      displayName: 'SourceForge',
      supportsRangeRequests: true,
      contentHint: ContentHint.softwarePackage,
      strategy: DownloadStrategy.redirectFollow,
    ),
    'f-droid.org': const SiteProfile(
      domain: 'f-droid.org',
      type: SiteType.softwareRepo,
      displayName: 'F-Droid',
      supportsRangeRequests: true,
      contentHint: ContentHint.softwarePackage,
    ),
    'apkmirror.com': const SiteProfile(
      domain: 'apkmirror.com',
      type: SiteType.softwareRepo,
      displayName: 'APKMirror',
      contentHint: ContentHint.softwarePackage,
      strategy: DownloadStrategy.browserRequired,
    ),
    'apkpure.com': const SiteProfile(
      domain: 'apkpure.com',
      type: SiteType.softwareRepo,
      displayName: 'APKPure',
      contentHint: ContentHint.softwarePackage,
      strategy: DownloadStrategy.browserRequired,
    ),
    'uptodown.com': const SiteProfile(
      domain: 'uptodown.com',
      type: SiteType.softwareRepo,
      displayName: 'Uptodown',
      contentHint: ContentHint.softwarePackage,
      strategy: DownloadStrategy.browserRequired,
    ),

    // --- Archive & Misc ---
    'archive.org': const SiteProfile(
      domain: 'archive.org',
      type: SiteType.archiveSite,
      displayName: 'Internet Archive',
      supportsRangeRequests: true,
      strategy: DownloadStrategy.multiThread,
    ),

    // --- Torrent Sites ---
    '1337x.to': const SiteProfile(
      domain: '1337x.to',
      type: SiteType.torrentSite,
      displayName: '1337x',
      contentHint: ContentHint.unknown,
      strategy: DownloadStrategy.browserRequired,
    ),
    'nyaa.si': const SiteProfile(
      domain: 'nyaa.si',
      type: SiteType.torrentSite,
      displayName: 'Nyaa',
      contentHint: ContentHint.unknown,
    ),
    'yts.mx': const SiteProfile(
      domain: 'yts.mx',
      type: SiteType.torrentSite,
      displayName: 'YTS',
      contentHint: ContentHint.videoFile,
    ),
    'fitgirl-repacks.site': const SiteProfile(
      domain: 'fitgirl-repacks.site',
      type: SiteType.torrentSite,
      displayName: 'FitGirl Repacks',
      contentHint: ContentHint.softwarePackage,
    ),

    // Additional common domains
    'uploadever.com': const SiteProfile(
        domain: 'uploadever.com',
        type: SiteType.fileHosting,
        displayName: 'UploadEver'),
    'dailyuploads.net': const SiteProfile(
        domain: 'dailyuploads.net',
        type: SiteType.fileHosting,
        displayName: 'DailyUploads'),
    'userscloud.com': const SiteProfile(
        domain: 'userscloud.com',
        type: SiteType.fileHosting,
        displayName: 'UsersCloud'),
    'uploadrar.com': const SiteProfile(
        domain: 'uploadrar.com',
        type: SiteType.fileHosting,
        displayName: 'UploadRar'),
    'dropapk.to': const SiteProfile(
        domain: 'dropapk.to',
        type: SiteType.fileHosting,
        displayName: 'DropApk'),
    'apkadmin.com': const SiteProfile(
        domain: 'apkadmin.com',
        type: SiteType.fileHosting,
        displayName: 'APKAdmin'),
    'douploads.net': const SiteProfile(
        domain: 'douploads.net',
        type: SiteType.fileHosting,
        displayName: 'DoUploads'),
    'up-load.io': const SiteProfile(
        domain: 'up-load.io',
        type: SiteType.fileHosting,
        displayName: 'Up-load.io'),
    'hexupload.net': const SiteProfile(
        domain: 'hexupload.net',
        type: SiteType.fileHosting,
        displayName: 'HexUpload'),
    'rockloader.co': const SiteProfile(
        domain: 'rockloader.co',
        type: SiteType.fileHosting,
        displayName: 'RockLoader'),
    'speed-down.org': const SiteProfile(
        domain: 'speed-down.org',
        type: SiteType.fileHosting,
        displayName: 'SpeedDown'),
    'uploadship.com': const SiteProfile(
        domain: 'uploadship.com',
        type: SiteType.fileHosting,
        displayName: 'UploadShip'),
    'katfile.com': const SiteProfile(
        domain: 'katfile.com',
        type: SiteType.fileHosting,
        displayName: 'KatFile'),
    'gigapeta.com': const SiteProfile(
        domain: 'gigapeta.com',
        type: SiteType.fileHosting,
        displayName: 'GigaPeta'),
    'mexashare.com': const SiteProfile(
        domain: 'mexashare.com',
        type: SiteType.fileHosting,
        displayName: 'MexaShare'),
    'subyshare.com': const SiteProfile(
        domain: 'subyshare.com',
        type: SiteType.fileHosting,
        displayName: 'SubyShare'),
    'drop.download': const SiteProfile(
        domain: 'drop.download',
        type: SiteType.fileHosting,
        displayName: 'DropDownload'),
    'bayfiles.com': const SiteProfile(
        domain: 'bayfiles.com',
        type: SiteType.fileHosting,
        displayName: 'BayFiles'),
    'anonfiles.com': const SiteProfile(
        domain: 'anonfiles.com',
        type: SiteType.fileHosting,
        displayName: 'AnonFiles'),
    'gofile.io': const SiteProfile(
        domain: 'gofile.io', type: SiteType.fileHosting, displayName: 'GoFile'),
    'filebit.net': const SiteProfile(
        domain: 'filebit.net',
        type: SiteType.fileHosting,
        displayName: 'FileBit'),
    'keep2share.cc': const SiteProfile(
        domain: 'keep2share.cc',
        type: SiteType.fileHosting,
        displayName: 'Keep2Share'),
    'k2s.cc': const SiteProfile(
        domain: 'k2s.cc',
        type: SiteType.fileHosting,
        displayName: 'Keep2Share'),
    'filejoker.net': const SiteProfile(
        domain: 'filejoker.net',
        type: SiteType.fileHosting,
        displayName: 'FileJoker'),
    'tezfiles.com': const SiteProfile(
        domain: 'tezfiles.com',
        type: SiteType.fileHosting,
        displayName: 'TezFiles'),
    'ul.to': const SiteProfile(
        domain: 'ul.to', type: SiteType.fileHosting, displayName: 'Uploaded'),

    // --- More Streaming ---
    'vk.com': const SiteProfile(
        domain: 'vk.com',
        type: SiteType.videoStreaming,
        displayName: 'VK Video'),
    'ok.ru': const SiteProfile(
        domain: 'ok.ru', type: SiteType.videoStreaming, displayName: 'OK.ru'),
    'odnoklassniki.ru': const SiteProfile(
        domain: 'odnoklassniki.ru',
        type: SiteType.videoStreaming,
        displayName: 'OK.ru'),
    'peertube.org': const SiteProfile(
        domain: 'peertube.org',
        type: SiteType.videoStreaming,
        displayName: 'PeerTube'),
    'odysee.com': const SiteProfile(
        domain: 'odysee.com',
        type: SiteType.videoStreaming,
        displayName: 'Odysee'),
    'lbry.tv': const SiteProfile(
        domain: 'lbry.tv', type: SiteType.videoStreaming, displayName: 'LBRY'),
    'bilibili.com': const SiteProfile(
        domain: 'bilibili.com',
        type: SiteType.videoStreaming,
        displayName: 'Bilibili'),
    'veoh.com': const SiteProfile(
        domain: 'veoh.com', type: SiteType.videoStreaming, displayName: 'Veoh'),
    'metacafe.com': const SiteProfile(
        domain: 'metacafe.com',
        type: SiteType.videoStreaming,
        displayName: 'Metacafe'),
    'break.com': const SiteProfile(
        domain: 'break.com',
        type: SiteType.videoStreaming,
        displayName: 'Break'),

    // --- More Software ---
    'softonic.com': const SiteProfile(
        domain: 'softonic.com',
        type: SiteType.softwareRepo,
        displayName: 'Softonic'),
    'cnet.com': const SiteProfile(
        domain: 'cnet.com',
        type: SiteType.softwareRepo,
        displayName: 'CNET Download'),
    'filehippo.com': const SiteProfile(
        domain: 'filehippo.com',
        type: SiteType.softwareRepo,
        displayName: 'FileHippo'),
    'majorgeeks.com': const SiteProfile(
        domain: 'majorgeeks.com',
        type: SiteType.softwareRepo,
        displayName: 'MajorGeeks'),
    'fosshub.com': const SiteProfile(
        domain: 'fosshub.com',
        type: SiteType.softwareRepo,
        displayName: 'FossHub'),

    // --- More Torrent Sites ---
    'thepiratebay.org': const SiteProfile(
        domain: 'thepiratebay.org',
        type: SiteType.torrentSite,
        displayName: 'The Pirate Bay'),
    'limetorrents.info': const SiteProfile(
        domain: 'limetorrents.info',
        type: SiteType.torrentSite,
        displayName: 'LimeTorrents'),
    'torrentgalaxy.to': const SiteProfile(
        domain: 'torrentgalaxy.to',
        type: SiteType.torrentSite,
        displayName: 'TorrentGalaxy'),
    'rarbg.to': const SiteProfile(
        domain: 'rarbg.to', type: SiteType.torrentSite, displayName: 'RARBG'),
    'eztv.re': const SiteProfile(
        domain: 'eztv.re', type: SiteType.torrentSite, displayName: 'EZTV'),
    'zooqle.com': const SiteProfile(
        domain: 'zooqle.com',
        type: SiteType.torrentSite,
        displayName: 'Zooqle'),
    'kickasstorrents.to': const SiteProfile(
        domain: 'kickasstorrents.to',
        type: SiteType.torrentSite,
        displayName: 'KickassTorrents'),
    'skytorrents.to': const SiteProfile(
        domain: 'skytorrents.to',
        type: SiteType.torrentSite,
        displayName: 'SkyTorrents'),
  };
}
