import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_models.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  // vivo MusicWidgetMix EventType mask:
  // 0x01f = transport/lyrics/progress, 0x040 = heart control,
  // 0x080 = playback mode,
  // 0x100 = current queue, 0x200 = favorites, 0x400 = downloaded songs.
  static const int _vivoSupportEvents = 0x7df;

  MusicAudioHandler() {
    ratingStyle.add(RatingStyle.heart);
    audioPlayer.playbackEventStream
        .map(_playbackStateForEvent)
        .pipe(playbackState);
  }

  final AudioPlayer audioPlayer = AudioPlayer();

  Future<void> Function()? _onNext;
  Future<void> Function()? _onPrevious;
  Future<void> Function(Song song, List<Song> queue)? _onPlaySong;
  bool Function(Song song)? _isLiked;
  Future<void> Function(Song song, bool liked)? _onSetLike;
  Future<List<Song>> Function(int page, int pageSize)? _getFavoriteSongs;
  List<Song> Function()? _getDownloadedSongs;
  int Function()? _getLoopMode;
  void Function(int mode)? _onSetLoopMode;
  final Map<String, List<Song>> _vivoBrowseQueues = {};
  int _queueIndex = 0;
  Song? _currentSong;
  Duration? _resolvedDuration;
  List<Song> _queueSongs = const [];

  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    Future<void> Function(Song song, List<Song> queue)? onPlaySong,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
    _onPlaySong = onPlaySong;
  }

  void attachVivoIntegration({
    required bool Function(Song song) isLiked,
    required Future<void> Function(Song song, bool liked) onSetLike,
    required Future<List<Song>> Function(int page, int pageSize)
    getFavoriteSongs,
    required List<Song> Function() getDownloadedSongs,
    required int Function() getLoopMode,
    required void Function(int mode) onSetLoopMode,
  }) {
    _isLiked = isLiked;
    _onSetLike = onSetLike;
    _getFavoriteSongs = getFavoriteSongs;
    _getDownloadedSongs = getDownloadedSongs;
    _getLoopMode = getLoopMode;
    _onSetLoopMode = onSetLoopMode;
    refreshVivoMetadata();
  }

  void detachTransportControls() {
    _onNext = null;
    _onPrevious = null;
    _onPlaySong = null;
  }

  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    _currentSong = song;
    _resolvedDuration = null;
    _queueSongs = List<Song>.of(queueSongs);
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    final currentItem = _mediaItemFor(song);
    final items = queueSongs.map(_mediaItemFor).toList(growable: false);

    if (items.isNotEmpty) {
      queue.add(items);
    }
    mediaItem.add(currentItem);
    final Duration? resolvedDuration;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      resolvedDuration = await audioPlayer.setUrl(url);
    } else {
      resolvedDuration = await audioPlayer.setAudioSource(
        AudioSource.file(url),
      );
    }
    // Some providers omit duration from their song payload. just_audio learns
    // it while preparing the source; publish that value so external media
    // browsers (including vivo MusicWidgetMix) can render time and seek state.
    if ((song.duration == null || song.duration == Duration.zero) &&
        resolvedDuration != null &&
        resolvedDuration > Duration.zero) {
      _resolvedDuration = resolvedDuration;
      mediaItem.add(_mediaItemFor(song));
    }
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    this.queue.add(queue);
  }

  Future<void> setSongQueue({
    required List<Song> queueSongs,
    required int queueIndex,
    Song? currentSong,
  }) async {
    if (currentSong != null) _currentSong = currentSong;
    _queueSongs = List<Song>.of(queueSongs);
    _queueIndex = queueIndex < 0 ? 0 : queueIndex;
    queue.add(queueSongs.map(_mediaItemFor).toList(growable: false));
    if (currentSong != null) {
      mediaItem.add(_mediaItemFor(currentSong));
    }
  }

  /// 更新当前播放歌曲的 MediaSession Metadata，写入歌词字段。
  ///
  /// 大多数车机系统不会直接读 AVRCP 里的歌词，但通过 media_item extras
  /// 写入 `lyric / currentLyric` 字段后，SuperLyric 模块或第三方车载 App 可从
  /// MediaSession 元数据里取出歌词并展示。
  ///
  /// 当 [lyricText] 为 `null` 时表示清空歌词（暂停/切歌前）。
  void updateLyricMetadata({
    String? lyricText,
    String? translationText,
    String? romanizationText,
  }) {
    final song = _currentSong;
    if (song == null) return;
    final Map<String, dynamic> extras = {
      'hash': song.hash,
      'songId': song.id,
      'vivomusicmix.media.metadata.support_event': _vivoSupportEvents,
      'vivomusicmix.media.metadata.LOOP_MODE': _getLoopMode?.call() ?? 1,
      'lyric': ?lyricText,
      'currentLyric': ?lyricText,
      'translationLyric': ?translationText,
      'romanLyric': ?romanizationText,
    };
    final updated = MediaItem(
      id: song.hash.isEmpty ? song.id : song.hash,
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: _durationFor(song),
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      playable: true,
      rating: Rating.newHeartRating(_isLiked?.call(song) ?? false),
      extras: extras,
    );
    mediaItem.add(updated);
  }

  @override
  Future<void> play() async {
    unawaited(audioPlayer.play());
  }

  @override
  Future<void> pause() async {
    await audioPlayer.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await audioPlayer.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await _onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    await _onPrevious?.call();
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    for (final song in _queueSongs) {
      if (_songId(song) == mediaId) {
        await _onPlaySong?.call(song, _queueSongs);
        return;
      }
    }
    final browseQueue = _vivoBrowseQueues[mediaId];
    if (browseQueue == null) return;
    for (final song in browseQueue) {
      if (_songId(song) == mediaId) {
        await _onPlaySong?.call(song, browseQueue);
        return;
      }
    }
  }

  @override
  Future<void> setRating(Rating rating, [Map<String, dynamic>? extras]) async {
    final song = _currentSong;
    if (song == null || rating.getRatingStyle() != RatingStyle.heart) return;
    final currentlyLiked = _isLiked?.call(song) ?? false;
    if (rating.hasHeart() != currentlyLiked) {
      await _onSetLike?.call(song, rating.hasHeart());
    }
    refreshVivoMetadata();
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == 'vivomusicmix.media.action.PLAY_MODE') {
      final mode = (extras?['vivomusicmix.media.metadata.LOOP_MODE'] as num?)
          ?.toInt();
      if (mode != null && mode >= 1 && mode <= 3) {
        _onSetLoopMode?.call(mode);
        refreshVivoMetadata();
      }
      return null;
    }
    return super.customAction(name, extras);
  }

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    const pageSize = 50;
    final page =
        (options?['vivomusicmix_key_media_page'] as num?)?.toInt() ?? 0;
    List<Song> songs;
    switch (parentMediaId) {
      case 'vivomusicmix_current_list':
        songs = _queueSongs
            .skip(page * pageSize)
            .take(pageSize)
            .toList(growable: false);
        break;
      case 'vivomusicmix_favorite_list':
        songs = await _getFavoriteSongs?.call(page, pageSize) ?? const [];
        break;
      case 'vivomusicmix_local_list':
        songs = (_getDownloadedSongs?.call() ?? const [])
            .skip(page * pageSize)
            .take(pageSize)
            .toList(growable: false);
        break;
      default:
        return const [];
    }
    for (final song in songs) {
      _vivoBrowseQueues[_songId(song)] = songs;
    }
    return List<MediaItem>.generate(
      songs.length,
      (index) => _mediaItemFor(
        songs[index],
        vivoPage: index == songs.length - 1 ? page + 1 : null,
        vivoHasMore: index == songs.length - 1
            ? songs.length == pageSize
            : null,
      ),
      growable: false,
    );
  }

  void refreshVivoMetadata() {
    final song = _currentSong;
    if (song != null) mediaItem.add(_mediaItemFor(song));
    if (_queueSongs.isNotEmpty) {
      queue.add(_queueSongs.map(_mediaItemFor).toList(growable: false));
    }
  }

  @override
  Future<void> stop() async {
    await audioPlayer.stop();
  }

  Future<void> close() async {
    await audioPlayer.dispose();
  }

  String _songId(Song song) => song.hash.isEmpty ? song.id : song.hash;

  Duration? _durationFor(Song song) => identical(song, _currentSong)
      ? (_resolvedDuration ?? song.duration)
      : song.duration;

  MediaItem _mediaItemFor(Song song, {int? vivoPage, bool? vivoHasMore}) {
    return MediaItem(
      id: _songId(song),
      album: song.albumName,
      title: song.title,
      artist: song.artist,
      duration: _durationFor(song),
      artUri: song.coverUrl == null ? null : Uri.tryParse(song.coverUrl!),
      playable: true,
      rating: Rating.newHeartRating(_isLiked?.call(song) ?? false),
      extras: {
        'hash': song.hash,
        'songId': song.id,
        // Bit mask used by vivo MusicWidgetMix: transport, progress and lists.
        'vivomusicmix.media.metadata.support_event': _vivoSupportEvents,
        'vivomusicmix.media.metadata.LOOP_MODE': _getLoopMode?.call() ?? 1,
        if (vivoPage != null) 'vivomusicmix_key_media_page': vivoPage,
        if (vivoHasMore != null) 'vivomusicmix_key_has_more': vivoHasMore,
      },
    );
  }

  PlaybackState _playbackStateForEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (audioPlayer.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekBackward,
        MediaAction.seekForward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[audioPlayer.processingState]!,
      playing: audioPlayer.playing,
      updatePosition: audioPlayer.position,
      bufferedPosition: audioPlayer.bufferedPosition,
      speed: audioPlayer.speed,
      queueIndex: _queueIndex,
    );
  }
}
