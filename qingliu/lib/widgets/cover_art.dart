import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../cache_service.dart';
import '../models.dart';

/// 封面：本地缓存优先，其次服务端，最后渐变占位。
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.song,
    this.size,
    this.radius = 10,
    this.iconSize = 22,
  });

  final Song song;

  /// 为 null 时填满父级（配合 AspectRatio / Expanded 使用）。
  final double? size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localPath = context
        .select<CacheService, String?>((store) => store.coverFile(song.id)?.path);

    Widget content;
    if (localPath != null) {
      content = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(theme),
      );
    } else {
      final api = context.read<AppState>().api;
      if (song.hasCover && api != null) {
        content = Image.network(
          api.coverUrl(song.id),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _placeholder(theme),
        );
      } else {
        content = _placeholder(theme);
      }
    }

    final clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: content,
    );
    if (size == null) return clipped;
    return SizedBox(width: size, height: size, child: clipped);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primary.withAlpha(217),
            theme.colorScheme.primary.withAlpha(89),
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note,
          size: iconSize,
          color: Colors.white.withAlpha(230),
        ),
      ),
    );
  }
}
