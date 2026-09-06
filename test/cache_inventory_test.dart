import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/cache_inventory.dart';
import 'package:bilibeat/widgets/cached_cover_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bilibeat_inventory_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => root.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test('inventory snapshots sizes and excludes in-progress cover downloads', () async {
    const track = Track(
      id: 'song', bvid: 'song', cid: 1, title: 'Song', rawTitle: 'Song',
      uploader: 'Artist', coverUrl: 'https://i0.hdslb.com/test.jpg', duration: 10,
    );
    final dir = await Directory('${root.path}/bilibeat_covers').create();
    final key = md5.convert(utf8.encode(
      CachedCoverImage.sizedUrl(track.coverUrl, 48, 48),
    ));
    final cover = await File('${dir.path}/img_$key.img').writeAsBytes([1, 2, 3]);
    await File('${dir.path}/img_pending.img.part').writeAsBytes([4, 5]);
    final buckets = await CacheInventory.load([track]);
    expect(buckets, hasLength(1));
    expect(buckets.single.coverFiles.single.path, cover.path);
    expect(buckets.single.bytes, 3);
    // Rendering uses a snapshot, with no synchronous file reads after loading.
    await cover.delete();
    expect(buckets.single.bytes, 3);
  });
}
